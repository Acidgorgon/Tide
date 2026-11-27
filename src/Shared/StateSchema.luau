--!strict
-- Timeline state (v0.3): per-kind field schemas, declared once in shared code with
-- Tide.state(kindName, fields), and the value encoding used on the reliable channel.
--
-- Field options:
--   type      "bool" | "u8" | "u16" | "i16" | "f32" | "f64" | "time" | "ref" | "enum" | "event"
--             | "yaw" (flat direction, Vector3) | "pos" (Vector3) | "vector" (the same as "pos":
--             any Vector3, e.g. a velocity; v0.5) | "cframe" (CFrame; v0.5)
--   default   value before the first set and after set(nil) (bool false, numbers 0, others nil)
--   to        "all" (default) | "owner" | "others" | "server" ("none" is accepted for "server")
--   apply     "drawn" (default: when the receiver's render clock for the entity reaches the stamp)
--             | "arrival"
--   values    enum: list of strings
--   payload   event: type of the optional payload ("bool", "u8", "u16", "i16", "f32", "f64", "enum"
--             with values, "ref", "yaw", "pos", "vector", "cframe"), or (v0.5) a table of named
--             members, each a type name or { type = "enum", values = { ... } }:
--               Kick = { type = "event", payload = { Position = "pos", Velocity = "vector", By = "ref" } }
--               Tide.fire(ball, "Kick", { Position = p, Velocity = v, By = character }, stamp)
--             Member types: every value type and "time" (1 to 32 members). A member left out of
--             a fire is its type's default (false, 0, or nil). Listeners get a frozen table.
--   mirror    attribute name the client sets locally when a change applies
--   mirrorOn  "model" (default) | "player" (the owning Player)
--   mirrorNil attribute value written when the field is nil (string, number or boolean)
--   history   changes of this field kept per entity for Tide.stateAt (default Config.StateHistory)
--
-- Fields are sorted by name and get ids 1..n (at most 127). The server sends its schemas to
-- clients (32 SCHEMA), so a client decodes with exactly what the server encodes; a client's own
-- declaration is only compared (checksum) and a mismatch warned about.
--
-- Values on the wire:
--   bool u8 | u8 | u16 | i16 | f32 | f64 | time i16 (0.5 ms relative to the change's stamp;
--   -32768 = f64 follows) | ref u16 slot | enum u8 index (1-based) | yaw u16 (angle / 2pi * 65536)
--   | pos / vector 3 x f32 | cframe 3 x f32 position + u32 rotation (smallest-three quaternion,
--   10 bits a component: under 0.1 degree) | event: its payload (nothing without one)
--   | members payload: presence bits (u8 up to 8 members, u16 up to 16, else u32; bit i - 1 =
--   member i in name order has a value), then the values of the members present

local Codec = require(script.Parent.Codec)
local Rig = require(script.Parent.Rig)

local StateSchema = {}

export type Field = {
	id: number,
	name: string,
	type: string,
	code: number,
	to: number, -- 0 all, 1 owner, 2 others, 3 server
	arrival: boolean,
	default: any,
	values: { string }?,
	index: { [string]: number }?,
	payload: number, -- event payload type code (0 none)
	payloadField: Field?, -- pseudo field describing the payload
	mirror: string?,
	mirrorOn: string,
	mirrorNil: any,
	history: number,
	event: boolean,
	members: { Field }?, -- payload with named members (code STRUCT): its members, by name
	refMembers: { Field }?, -- those of type ref (nil when none)
}

export type Schema = {
	kind: string,
	fields: { Field },
	byName: { [string]: Field },
	refs: { Field }, -- ref fields (cleared when the referenced entity goes)
	checksum: number,
}

local TICK = 0.0005

StateSchema.TICK = TICK

local CODES = {
	bool = 1,
	u8 = 2,
	u16 = 3,
	i16 = 4,
	f32 = 5,
	f64 = 6,
	time = 7,
	ref = 8,
	enum = 9,
	event = 10,
	yaw = 11,
	pos = 12,
}
local NAMES = {}
for name, code in CODES do
	NAMES[code] = name
end
-- v0.5
CODES.cframe = 13
NAMES[13] = "cframe"
CODES.vector = 12 -- another name for pos (NAMES keeps "pos": one checksum for both spellings)
local STRUCT = 14 -- an event payload with named members (never a field's own type)
NAMES[STRUCT] = "struct"
StateSchema.CODES = CODES
StateSchema.STRUCT = STRUCT
local MAX_MEMBERS = 32

StateSchema.TO_ALL = 0
StateSchema.TO_OWNER = 1
StateSchema.TO_OTHERS = 2
StateSchema.TO_SERVER = 3
local TO = { all = 0, owner = 1, others = 2, server = 3, none = 3 }
local TO_NAMES = { [0] = "all", "owner", "others", "server" }

local MAX_FIELDS = 127

local OPTIONS = {
	type = true,
	default = true,
	to = true,
	apply = true,
	values = true,
	payload = true,
	mirror = true,
	mirrorOn = true,
	mirrorNil = true,
	history = true,
}

-- kind name -> schema declared on this side
StateSchema.byKind = {} :: { [string]: Schema }
StateSchema.count = 0

local scratch = buffer.create(4)
local function toF32(v: number): number
	buffer.writef32(scratch, 0, v)
	return buffer.readf32(scratch, 0)
end

-- A CFrame as a receiver decodes it: f32 position, rotation through the packed quaternion.
local function quantizeCFrame(cf: any): any
	local x, y, z, _, qx, qy, qz, qw = Rig.fromCFrame(cf, true)
	qx, qy, qz, qw = Codec.unpackQuat(Codec.packQuat(qx, qy, qz, qw))
	return Rig.cframe(toF32(x), toF32(y), toF32(z), 0, true, qx, qy, qz, qw)
end

local function defaultOf(code: number): any
	if code == 1 then
		return false
	elseif code >= 2 and code <= 6 then
		return 0
	end
	return nil
end

local INT_RANGE = {
	[2] = { 0, 255 },
	[3] = { 0, 65535 },
	[4] = { -32768, 32767 },
}

local function what(ctx: any, f: Field): string
	if type(ctx) == "string" then
		return ctx
	elseif ctx == 1 then
		return `Tide.set: field {f.name}`
	end
	return `Tide.fire: payload of {f.name}`
end

-- Checks and normalizes a value for a field (nil = the default). Errors at `level` on a bad
-- value (ctx names the caller in the message: 1 set, 2 fire, or a string). Refs are returned
-- as given (the server resolves them). Allocates nothing for bool, numbers and time.
local function normalize(f: Field, code: number, value: any, level: number, ctx: any): any
	if value == nil then
		return f.default
	end
	if code == 1 then
		if type(value) ~= "boolean" then
			error(`{what(ctx, f)} must be a boolean`, level)
		end
		return value
	elseif code >= 2 and code <= 4 then
		local range = INT_RANGE[code]
		if type(value) ~= "number" or value ~= math.floor(value) or value < range[1] or value > range[2] then
			error(`{what(ctx, f)} must be an integer in [{range[1]}, {range[2]}]`, level)
		end
		return value
	elseif code == 5 or code == 6 or code == 7 then
		if type(value) ~= "number" or value ~= value then
			error(`{what(ctx, f)} must be a number (not NaN)`, level)
		end
		return if code == 5 then toF32(value) else value
	elseif code == 8 then
		return value
	elseif code == 9 then
		local index = f.index :: { [string]: number }
		if type(value) ~= "string" or index[value] == nil then
			error(`{what(ctx, f)} must be one of its values`, level)
		end
		return value
	elseif code == 11 then
		local x, z
		if type(value) == "number" and value == value then
			x, z = math.cos(value), math.sin(value)
		elseif typeof(value) == "Vector3" then
			x, z = value.X, value.Z
		else
			error(`{what(ctx, f)} must be a Vector3 (direction) or an angle`, level)
		end
		if x * x + z * z < 1e-12 or x ~= x or z ~= z then
			error(`{what(ctx, f)} must be a non-zero horizontal direction`, level)
		end
		local q = math.round(math.atan2(z, x) / (2 * math.pi) * 65536) % 65536
		local a = q / 65536 * 2 * math.pi
		return Vector3.new(math.cos(a), 0, math.sin(a))
	elseif code == 12 then
		if typeof(value) ~= "Vector3" or value.X ~= value.X or value.Y ~= value.Y or value.Z ~= value.Z then
			error(`{what(ctx, f)} must be a Vector3`, level)
		end
		return Vector3.new(toF32(value.X), toF32(value.Y), toF32(value.Z))
	elseif code == 13 then
		if typeof(value) ~= "CFrame" then
			error(`{what(ctx, f)} must be a CFrame`, level)
		end
		local p = value.Position
		if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z then
			error(`{what(ctx, f)} must be a CFrame (not NaN)`, level)
		end
		return quantizeCFrame(value)
	end
	error(`{what(ctx, f)}: an event field has no value (use Tide.fire)`, level)
end

-- Server: the value to store for a set (errors on a bad value).
function StateSchema.check(f: Field, value: any, level: number): any
	return normalize(f, f.code, value, level + 1, 1)
end

-- Server: the payload to store for a fire (true when the event has no payload).
function StateSchema.checkPayload(f: Field, value: any, level: number): any
	local pf = f.payloadField
	if pf == nil then
		if value ~= nil then
			error(`Tide.fire: event {f.name} has no payload`, level + 1)
		end
		return true
	end
	if value == nil and pf.default == nil and (pf.code == CODES.yaw or pf.code == CODES.pos or pf.code == CODES.cframe) then
		error(`Tide.fire: event {f.name} needs its payload`, level + 1)
	end
	return normalize(pf, pf.code, value, level + 1, 2)
end

local quantizeTime

-- Server: the frozen table to store for a fire of an event whose payload has named members.
-- `stamp` is the fire's stamp (time members are kept as clients decode them); `ref` turns a
-- ref member's value (model or handle) into the model, or errors.
function StateSchema.checkStruct(f: Field, value: any, level: number, stamp: number, ref: (any) -> any): any
	local pf = f.payloadField :: Field
	local members = pf.members :: { Field }
	if type(value) ~= "table" then
		error(`Tide.fire: the payload of {f.name} must be a table of its members`, level + 1)
	end
	for key in value do
		if type(key) ~= "string" or (pf.index :: any)[key] == nil then
			error(`Tide.fire: the payload of {f.name} has no member {tostring(key)}`, level + 1)
		end
	end
	local out = {}
	for _, m in members do
		local v = value[m.name]
		local code = m.code
		if code == CODES.ref then
			v = ref(v)
		else
			v = normalize(m, code, v, level + 1, `Tide.fire: {f.name}.{m.name}`)
			if code == CODES.time and v ~= nil then
				v = quantizeTime(v, stamp)
			end
		end
		out[m.name] = v
	end
	return table.freeze(out)
end

-- A time value on the 0.5 ms grid relative to its stamp (exactly what a client decodes).
function StateSchema.quantizeTime(value: number, stamp: number): number
	local rel = math.round((value - stamp) / TICK)
	if rel >= -32767 and rel <= 32767 then
		return stamp + rel * TICK
	end
	return value
end
quantizeTime = StateSchema.quantizeTime

local function fnv(h: number, s: string): number
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (h * 16777619) % 4294967296
	end
	return h
end

local function checksum(fields: { Field }): number
	local h = 2166136261
	for _, f in fields do
		h = fnv(h, f.name .. ":" .. f.type .. ":" .. TO_NAMES[f.to] .. ":" .. (if f.arrival then "a" else "d"))
		if f.values then
			h = fnv(h, table.concat(f.values, ","))
		end
		h = fnv(h, ":" .. tostring(f.payload) .. ":" .. tostring(f.mirror) .. ":" .. f.mirrorOn)
		local pf = f.payloadField
		if pf ~= nil and pf.members ~= nil then
			for _, m in pf.members do
				h = fnv(h, "|" .. m.name .. ":" .. m.type)
				if m.values then
					h = fnv(h, table.concat(m.values, ","))
				end
			end
		end
	end
	return h
end

local function finish(kind: string, fields: { Field }): Schema
	table.sort(fields, function(a, b)
		return a.name < b.name
	end)
	local byName = {}
	local refs = {}
	for i, f in fields do
		f.id = i
		byName[f.name] = f
		if f.code == CODES.ref then
			table.insert(refs, f)
		end
	end
	return { kind = kind, fields = fields, byName = byName, refs = refs, checksum = checksum(fields) }
end

local function enumIndex(values: { string }): { [string]: number }
	local index = {}
	for i, v in values do
		index[v] = i
	end
	return index
end

-- Builds a schema from a Tide.state declaration (errors on bad declarations).
function StateSchema.build(kind: string, decl: { [string]: any }): Schema
	if type(kind) ~= "string" or #kind == 0 then
		error("Tide.state: kind name must be a string", 3)
	end
	if type(decl) ~= "table" then
		error(`Tide.state("{kind}"): fields must be a table of {"{"} [name] = options {"}"}`, 3)
	end
	local fields = {}
	for name, opts in decl do
		local where = `Tide.state("{kind}"): field {tostring(name)}`
		if type(name) ~= "string" or #name == 0 or #name > 64 then
			error(`{where}: names must be strings of 1 to 64 characters`, 3)
		end
		if type(opts) == "string" then
			opts = { type = opts }
		end
		if type(opts) ~= "table" then
			error(`{where}: options must be a table (or a type name)`, 3)
		end
		for key in opts do
			if not OPTIONS[key] then
				error(`{where}: unknown option {tostring(key)}`, 3)
			end
		end
		local code = CODES[opts.type]
		if code == nil then
			error(`{where}: unknown type {tostring(opts.type)}`, 3)
		end
		local to = TO[opts.to or "all"]
		if to == nil then
			error(`{where}: to must be "all", "owner", "others" or "server"`, 3)
		end
		local apply = opts.apply or "drawn"
		if apply ~= "drawn" and apply ~= "arrival" then
			error(`{where}: apply must be "drawn" or "arrival"`, 3)
		end
		local f: Field = {
			id = 0,
			name = name,
			type = NAMES[code],
			code = code,
			to = to,
			arrival = apply == "arrival",
			default = defaultOf(code),
			values = nil,
			index = nil,
			payload = 0,
			payloadField = nil,
			mirror = nil,
			mirrorOn = "model",
			mirrorNil = nil,
			history = 0, -- 0: Config.StateHistory
			event = code == CODES.event,
			members = nil,
			refMembers = nil,
		}
		local function enumValues(values: any)
			if type(values) ~= "table" or #values == 0 or #values > 255 then
				error(`{where}: an enum needs values = a list of 1 to 255 strings`, 4)
			end
			for _, v in values do
				if type(v) ~= "string" or #v > 255 then
					error(`{where}: enum values must be strings`, 4)
				end
			end
			return table.clone(values), enumIndex(values)
		end
		if code == CODES.enum then
			f.values, f.index = enumValues(opts.values)
		elseif opts.values ~= nil and opts.payload ~= "enum" then
			error(`{where}: values is for enum fields (and events with payload = "enum")`, 3)
		end
		if type(opts.payload) == "table" then
			-- named members (v0.5)
			if not f.event then
				error(`{where}: payload is for event fields`, 3)
			end
			local members = {}
			for mname, mopts in opts.payload do
				local mwhere = `{where}: payload member {tostring(mname)}`
				if type(mname) ~= "string" or #mname == 0 or #mname > 64 then
					error(`{mwhere}: names must be strings of 1 to 64 characters`, 3)
				end
				if type(mopts) == "string" then
					mopts = { type = mopts }
				end
				if type(mopts) ~= "table" then
					error(`{mwhere}: a type name, or {"{"} type = "enum", values = ... {"}"}`, 3)
				end
				for key in mopts do
					if key ~= "type" and key ~= "values" then
						error(`{mwhere}: unknown option {tostring(key)}`, 3)
					end
				end
				local mcode = CODES[mopts.type]
				if mcode == nil or mcode == CODES.event then
					error(`{mwhere}: unknown type {tostring(mopts.type)}`, 3)
				end
				local m: any = table.clone(f)
				m.name = mname
				m.code = mcode
				m.type = NAMES[mcode]
				m.event = false
				m.default = defaultOf(mcode)
				m.values, m.index = nil, nil
				if mcode == CODES.enum then
					local ok, values, index = pcall(enumValues, mopts.values)
					if not ok then
						error(`{mwhere}: an enum needs values = a list of 1 to 255 strings`, 3)
					end
					m.values, m.index = values, index
				elseif mopts.values ~= nil then
					error(`{mwhere}: values is for enum members`, 3)
				end
				table.insert(members, m)
			end
			if #members == 0 or #members > MAX_MEMBERS then
				error(`{where}: a payload has 1 to {MAX_MEMBERS} members`, 3)
			end
			table.sort(members, function(a, b)
				return a.name < b.name
			end)
			local pf: any = table.clone(f)
			pf.code = STRUCT
			pf.type = NAMES[STRUCT]
			pf.event = false
			pf.default = nil
			pf.members = members
			local index = {}
			local refMembers = {}
			for i, m in members do
				m.id = i
				index[m.name] = i
				if m.code == CODES.ref then
					table.insert(refMembers, m)
				end
			end
			pf.index = index
			pf.refMembers = if #refMembers > 0 then refMembers else nil
			f.payload = STRUCT
			f.payloadField = pf
		elseif opts.payload ~= nil then
			local pcode = CODES[opts.payload]
			if not f.event then
				error(`{where}: payload is for event fields`, 3)
			end
			if pcode == nil or pcode == CODES.event or pcode == CODES.time then
				error(`{where}: payload must be a value type (bool, u8, u16, i16, f32, f64, enum, ref, yaw, pos, vector, cframe) or a table of members`, 3)
			end
			local pf: any = table.clone(f)
			pf.code = pcode
			pf.type = NAMES[pcode]
			pf.event = false
			pf.default = defaultOf(pcode)
			if pcode == CODES.enum then
				pf.values, pf.index = enumValues(opts.values)
				f.values = pf.values
			end
			f.payload = pcode
			f.payloadField = pf
		end
		if opts.default ~= nil then
			if code == CODES.ref or code == CODES.cframe or f.event then
				error(`{where}: ref, cframe and event fields have no default`, 3)
			end
			f.default = normalize(f, code, opts.default, 3, `{where}: default`)
		end
		if opts.mirror ~= nil then
			if type(opts.mirror) ~= "string" or #opts.mirror == 0 or #opts.mirror > 100 then
				error(`{where}: mirror must be an attribute name`, 3)
			end
			f.mirror = opts.mirror
		end
		if opts.mirrorOn ~= nil then
			if opts.mirrorOn ~= "model" and opts.mirrorOn ~= "player" then
				error(`{where}: mirrorOn must be "model" or "player"`, 3)
			end
			f.mirrorOn = opts.mirrorOn
		end
		if opts.mirrorNil ~= nil then
			local t = type(opts.mirrorNil)
			if t ~= "string" and t ~= "number" and t ~= "boolean" then
				error(`{where}: mirrorNil must be a string, number or boolean`, 3)
			end
			f.mirrorNil = opts.mirrorNil
		end
		if opts.history ~= nil then
			if type(opts.history) ~= "number" or opts.history < 1 or opts.history > 4096 then
				error(`{where}: history must be a number of changes in [1, 4096]`, 3)
			end
			f.history = math.floor(opts.history)
		end
		table.insert(fields, f)
	end
	if #fields == 0 or #fields > MAX_FIELDS then
		error(`Tide.state("{kind}"): 1 to {MAX_FIELDS} fields`, 3)
	end
	return finish(kind, fields)
end

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

local TWO_PI = 2 * math.pi

-- Writes a (non-default) value. `wire` is the value as sent: refs as slot numbers.
function StateSchema.writeValue(w: any, ensure: (any, number) -> (), code: number, f: Field, wire: any, stamp: number)
	ensure(w, 16)
	local b, p = w.b, w.pos
	if code == 1 then
		buffer.writeu8(b, p, if wire then 1 else 0)
		w.pos = p + 1
	elseif code == 2 then
		buffer.writeu8(b, p, wire)
		w.pos = p + 1
	elseif code == 3 or code == 8 then
		buffer.writeu16(b, p, wire)
		w.pos = p + 2
	elseif code == 4 then
		buffer.writei16(b, p, wire)
		w.pos = p + 2
	elseif code == 5 then
		buffer.writef32(b, p, wire)
		w.pos = p + 4
	elseif code == 6 then
		buffer.writef64(b, p, wire)
		w.pos = p + 8
	elseif code == 7 then
		local rel = math.round((wire - stamp) / TICK)
		if rel >= -32767 and rel <= 32767 then
			buffer.writei16(b, p, rel)
			w.pos = p + 2
		else
			buffer.writei16(b, p, -32768)
			buffer.writef64(b, p + 2, wire)
			w.pos = p + 10
		end
	elseif code == 9 then
		buffer.writeu8(b, p, (f.index :: any)[wire] or 0)
		w.pos = p + 1
	elseif code == 11 then
		buffer.writeu16(b, p, math.round(math.atan2(wire.Z, wire.X) / TWO_PI * 65536) % 65536)
		w.pos = p + 2
	elseif code == 12 then
		buffer.writef32(b, p, wire.X)
		buffer.writef32(b, p + 4, wire.Y)
		buffer.writef32(b, p + 8, wire.Z)
		w.pos = p + 12
	elseif code == 13 then
		local x, y, z, _, qx, qy, qz, qw = Rig.fromCFrame(wire, true)
		buffer.writef32(b, p, x)
		buffer.writef32(b, p + 4, y)
		buffer.writef32(b, p + 8, z)
		buffer.writeu32(b, p + 12, Codec.packQuat(qx, qy, qz, qw))
		w.pos = p + 16
	end
end

-- Bytes of the presence bits of a payload with n members.
local function maskSize(n: number): number
	return if n <= 8 then 1 elseif n <= 16 then 2 else 4
end

-- Writes a payload with named members. `slotOf[model]` is a ref member's slot (nil: the
-- entity is gone; the member is sent as absent).
function StateSchema.writeStruct(w: any, ensure: (any, number) -> (), pf: Field, value: any, stamp: number, slotOf: { [any]: number })
	local members = pf.members :: { Field }
	local ms = maskSize(#members)
	ensure(w, ms)
	local at = w.pos
	w.pos = at + ms
	local mask = 0
	local bit = 1
	for _, m in members do
		local v = if value ~= nil then value[m.name] else nil
		if v ~= nil then
			local code = m.code
			if code == CODES.ref then
				local slot = slotOf[v]
				if slot ~= nil then
					ensure(w, 2)
					buffer.writeu16(w.b, w.pos, slot)
					w.pos += 2
					mask += bit
				end
			else
				StateSchema.writeValue(w, ensure, code, m, v, stamp)
				mask += bit
			end
		end
		bit *= 2
	end
	if ms == 1 then
		buffer.writeu8(w.b, at, mask)
	elseif ms == 2 then
		buffer.writeu16(w.b, at, mask)
	else
		buffer.writeu32(w.b, at, mask)
	end
end

-- Reads a value; returns the next position (-1 if malformed / short) and the value (refs as
-- slot numbers, 0 = nil).
function StateSchema.readValue(b: buffer, p: number, n: number, code: number, f: Field, stamp: number): (number, any)
	if code == 1 then
		if p + 1 > n then
			return -1, nil
		end
		return p + 1, buffer.readu8(b, p) ~= 0
	elseif code == 2 then
		if p + 1 > n then
			return -1, nil
		end
		return p + 1, buffer.readu8(b, p)
	elseif code == 3 or code == 8 then
		if p + 2 > n then
			return -1, nil
		end
		return p + 2, buffer.readu16(b, p)
	elseif code == 4 then
		if p + 2 > n then
			return -1, nil
		end
		return p + 2, buffer.readi16(b, p)
	elseif code == 5 then
		if p + 4 > n then
			return -1, nil
		end
		return p + 4, buffer.readf32(b, p)
	elseif code == 6 then
		if p + 8 > n then
			return -1, nil
		end
		return p + 8, buffer.readf64(b, p)
	elseif code == 7 then
		if p + 2 > n then
			return -1, nil
		end
		local rel = buffer.readi16(b, p)
		if rel == -32768 then
			if p + 10 > n then
				return -1, nil
			end
			return p + 10, buffer.readf64(b, p + 2)
		end
		return p + 2, stamp + rel * TICK
	elseif code == 9 then
		if p + 1 > n then
			return -1, nil
		end
		local values = f.values :: { string }
		local i = buffer.readu8(b, p)
		if i == 0 then
			return p + 1, nil
		end
		local v = values[i]
		if v == nil then
			return -1, nil
		end
		return p + 1, v
	elseif code == 11 then
		if p + 2 > n then
			return -1, nil
		end
		local a = buffer.readu16(b, p) / 65536 * TWO_PI
		return p + 2, Vector3.new(math.cos(a), 0, math.sin(a))
	elseif code == 12 then
		if p + 12 > n then
			return -1, nil
		end
		return p + 12, Vector3.new(buffer.readf32(b, p), buffer.readf32(b, p + 4), buffer.readf32(b, p + 8))
	elseif code == 13 then
		if p + 16 > n then
			return -1, nil
		end
		local x, y, z = buffer.readf32(b, p), buffer.readf32(b, p + 4), buffer.readf32(b, p + 8)
		if x ~= x or y ~= y or z ~= z then
			return -1, nil
		end
		local qx, qy, qz, qw = Codec.unpackQuat(buffer.readu32(b, p + 12))
		return p + 16, Rig.cframe(x, y, z, 0, true, qx, qy, qz, qw)
	elseif code == STRUCT then
		-- named members: a table (ref members as slot numbers; frozen when it has none)
		local members = f.members :: { Field }
		local ms = maskSize(#members)
		if p + ms > n then
			return -1, nil
		end
		local mask = if ms == 1 then buffer.readu8(b, p) elseif ms == 2 then buffer.readu16(b, p) else buffer.readu32(b, p)
		p += ms
		if mask >= 2 ^ #members then
			return -1, nil
		end
		local out = {}
		for _, m in members do
			if mask % 2 == 1 then
				local np, v = StateSchema.readValue(b, p, n, m.code, m, stamp)
				if np < 0 then
					return -1, nil
				end
				p = np
				if m.code == CODES.ref and v == 0 then
					v = nil
				end
				out[m.name] = v
			else
				out[m.name] = m.default
			end
			mask //= 2
		end
		if f.refMembers == nil then
			table.freeze(out)
		end
		return p, out
	elseif code == 10 then
		return p, true
	end
	return -1, nil
end

--------------------------------------------------------------------------------
-- Schema message (32 SCHEMA): u8 kinds, per kind: u8 kind id, u32 checksum, u8 field count,
-- per field (id order): u8 name length, name, u8 type, u8 flags (bits 0-1 to, bit2 arrival,
-- bit3 mirror, bit4 mirror on player, bit5 default, bit6 mirrorNil),
-- [event: u8 payload type; type 14 (named members, v0.5): u8 count, count x (u8 length, name,
-- u8 type, [enum: u8 count, count x (u8 length, string)])],
-- [enum or enum payload: u8 count, count x (u8 length, string)],
-- [mirror: u8 length, name], [mirrorNil: u8 tag (1 string, 2 number, 3 boolean), value],
-- [default: u8 0/1 (bool) | f64 (numbers, time) | u8 index (enum) | 3 x f32 (yaw, pos)]
-- Types: 1 bool .. 12 pos (CODES), 13 cframe (v0.5; "vector" is sent as 12).
--------------------------------------------------------------------------------

local function wstr(w: any, ensure: (any, number) -> (), s: string)
	local n = math.min(#s, 255)
	ensure(w, n + 1)
	buffer.writeu8(w.b, w.pos, n)
	buffer.writestring(w.b, w.pos + 1, s, n)
	w.pos += n + 1
end

local function wu8(w: any, ensure: (any, number) -> (), v: number)
	ensure(w, 1)
	buffer.writeu8(w.b, w.pos, v)
	w.pos += 1
end

local function wf64(w: any, ensure: (any, number) -> (), v: number)
	ensure(w, 8)
	buffer.writef64(w.b, w.pos, v)
	w.pos += 8
end

local function wf32(w: any, ensure: (any, number) -> (), v: number)
	ensure(w, 4)
	buffer.writef32(w.b, w.pos, v)
	w.pos += 4
end

function StateSchema.writeSchema(w: any, ensure: (any, number) -> (), kindId: number, s: Schema)
	wu8(w, ensure, kindId)
	ensure(w, 4)
	buffer.writeu32(w.b, w.pos, s.checksum)
	w.pos += 4
	wu8(w, ensure, #s.fields)
	for _, f in s.fields do
		wstr(w, ensure, f.name)
		wu8(w, ensure, f.code)
		local hasDefault = f.default ~= nil and f.default ~= defaultOf(f.code)
		local flags = f.to
			+ (if f.arrival then 4 else 0)
			+ (if f.mirror then 8 else 0)
			+ (if f.mirrorOn == "player" then 16 else 0)
			+ (if hasDefault then 32 else 0)
			+ (if f.mirrorNil ~= nil then 64 else 0)
		wu8(w, ensure, flags)
		if f.event then
			wu8(w, ensure, f.payload)
			local pf = f.payloadField
			if pf ~= nil and pf.members ~= nil then
				wu8(w, ensure, #pf.members)
				for _, m in pf.members do
					wstr(w, ensure, m.name)
					wu8(w, ensure, m.code)
					if m.values then
						wu8(w, ensure, #m.values)
						for _, v in m.values do
							wstr(w, ensure, v)
						end
					end
				end
			end
		end
		if f.values then
			wu8(w, ensure, #f.values)
			for _, v in f.values do
				wstr(w, ensure, v)
			end
		end
		if f.mirror then
			wstr(w, ensure, f.mirror)
		end
		if f.mirrorNil ~= nil then
			local mn = f.mirrorNil
			if type(mn) == "string" then
				wu8(w, ensure, 1)
				wstr(w, ensure, mn)
			elseif type(mn) == "number" then
				wu8(w, ensure, 2)
				wf64(w, ensure, mn)
			else
				wu8(w, ensure, 3)
				wu8(w, ensure, if mn then 1 else 0)
			end
		end
		if hasDefault then
			local d = f.default
			local code = f.code
			if code == 1 then
				wu8(w, ensure, if d then 1 else 0)
			elseif code == 9 then
				wu8(w, ensure, (f.index :: any)[d])
			elseif code == 11 or code == 12 then
				wf32(w, ensure, d.X)
				wf32(w, ensure, d.Y)
				wf32(w, ensure, d.Z)
			else
				wf64(w, ensure, d)
			end
		end
	end
end

-- Reads one kind's schema; returns the next position (-1 if malformed), kind id, schema.
function StateSchema.readSchema(b: buffer, p: number, n: number): (number, number, Schema?)
	local function need(k: number)
		if p + k > n then
			error("short", 0)
		end
	end
	local function rstr(): string
		need(1)
		local len = buffer.readu8(b, p)
		need(1 + len)
		local s = buffer.readstring(b, p + 1, len)
		p += 1 + len
		return s
	end
	local function ru8(): number
		need(1)
		local v = buffer.readu8(b, p)
		p += 1
		return v
	end
	local ok, kindId, schema = pcall(function(): (number, Schema)
		local kindId = ru8()
		need(4)
		local sum = buffer.readu32(b, p)
		p += 4
		local count = ru8()
		if count == 0 or count > MAX_FIELDS then
			error("count", 0)
		end
		local fields = {}
		for i = 1, count do
			local name = rstr()
			local code = ru8()
			if NAMES[code] == nil or code == STRUCT then
				error("type", 0)
			end
			local flags = ru8()
			local f: Field = {
				id = i,
				name = name,
				type = NAMES[code],
				code = code,
				to = flags % 4,
				arrival = (flags // 4) % 2 == 1,
				default = defaultOf(code),
				values = nil,
				index = nil,
				payload = 0,
				payloadField = nil,
				mirror = nil,
				mirrorOn = if (flags // 16) % 2 == 1 then "player" else "model",
				mirrorNil = nil,
				history = 0,
				event = code == CODES.event,
				members = nil,
				refMembers = nil,
			}
			local values = nil
			if code == CODES.enum then
				values = {}
				for k = 1, ru8() do
					values[k] = rstr()
				end
				f.values, f.index = values, enumIndex(values)
			end
			if f.event then
				local pcode = ru8()
				if pcode ~= 0 then
					if NAMES[pcode] == nil or pcode == CODES.event or pcode == CODES.time then
						error("payload", 0)
					end
					local pf: any = table.clone(f)
					pf.code = pcode
					pf.type = NAMES[pcode]
					pf.event = false
					if pcode == CODES.enum then
						values = {}
						for k = 1, ru8() do
							values[k] = rstr()
						end
						pf.values, pf.index = values, enumIndex(values)
						f.values = values
					elseif pcode == STRUCT then
						local count = ru8()
						if count == 0 or count > MAX_MEMBERS then
							error("members", 0)
						end
						local members = {}
						local index = {}
						local refMembers = {}
						for k = 1, count do
							local mname = rstr()
							local mcode = ru8()
							if NAMES[mcode] == nil or mcode == CODES.event or mcode == STRUCT then
								error("member", 0)
							end
							local m: any = table.clone(f)
							m.id = k
							m.name = mname
							m.code = mcode
							m.type = NAMES[mcode]
							m.event = false
							m.default = defaultOf(mcode)
							if mcode == CODES.enum then
								local mv = {}
								for j = 1, ru8() do
									mv[j] = rstr()
								end
								m.values, m.index = mv, enumIndex(mv)
							end
							members[k] = m
							index[mname] = k
							if mcode == CODES.ref then
								table.insert(refMembers, m)
							end
						end
						pf.default = nil
						pf.members = members
						pf.index = index
						pf.refMembers = if #refMembers > 0 then refMembers else nil
					end
					f.payload = pcode
					f.payloadField = pf
				end
			end
			if (flags // 8) % 2 == 1 then
				f.mirror = rstr()
			end
			if (flags // 64) % 2 == 1 then
				local tag = ru8()
				if tag == 1 then
					f.mirrorNil = rstr()
				elseif tag == 2 then
					need(8)
					f.mirrorNil = buffer.readf64(b, p)
					p += 8
				elseif tag == 3 then
					f.mirrorNil = ru8() ~= 0
				else
					error("mirrorNil", 0)
				end
			end
			if (flags // 32) % 2 == 1 then
				if code == 1 then
					f.default = ru8() ~= 0
				elseif code == 9 then
					f.default = (values :: any)[ru8()]
				elseif code == 11 or code == 12 then
					need(12)
					f.default = Vector3.new(buffer.readf32(b, p), buffer.readf32(b, p + 4), buffer.readf32(b, p + 8))
					p += 12
				else
					need(8)
					f.default = buffer.readf64(b, p)
					p += 8
				end
			end
			fields[i] = f
		end
		local byName = {}
		local refs = {}
		for _, f in fields do
			byName[f.name] = f
			if f.code == CODES.ref then
				table.insert(refs, f)
			end
		end
		return kindId, { kind = "", fields = fields, byName = byName, refs = refs, checksum = sum }
	end)
	if not ok then
		return -1, 0, nil
	end
	return p, kindId, schema
end

-- Declares (or replaces) the schema of a kind on this side.
function StateSchema.define(kind: string, decl: { [string]: any }): Schema
	local s = StateSchema.build(kind, decl)
	if StateSchema.byKind[kind] == nil then
		StateSchema.count += 1
	end
	StateSchema.byKind[kind] = s
	return s
end

return StateSchema
