--!strict
-- Timeline state, receiving side (v0.3). Each change carries the server time it happened at;
-- it is applied when this client's clock for its entity reaches that stamp:
--   * remote entities: the render clock, now - delay (the time the body is drawn at, the same
--     clock as v0.2 animation events);
--   * entities with a clock from game code (Tide.clock, e.g. a ball drawn at its own lead):
--     that clock; state-only entities without one: now - kind.buffer;
--   * entities this client owns, fields with apply = "arrival" and owner-only fields: on arrival.
-- The clock is monotonic per entity (applied state never goes back). Changes wait in a
-- per-entity queue in stamp order (QCAP; when full the oldest is applied early, counted); a
-- change older than the field's applied one is stale and skipped (events always fire). At most
-- Config.StateApplyPerFrame per frame. On apply: the value, `mirror` attribute (set locally),
-- Tide.changed / Tide.stateChanged. A snapshot (31 STATESNAP) brings the values in effect at
-- its t0 (for fields that are not newer here) and the changes after t0 this client missed.
-- Receive paths never throw (malformed messages are counted). Idle steps allocate nothing.

local Players = game:GetService("Players")

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Kinds = require(Shared.Kinds)
local Signal = require(Shared.Signal)
local StateSchema = require(Shared.StateSchema)
local State = require(script.Parent.State)

type Field = StateSchema.Field
type Schema = StateSchema.Schema
type Queue = { t: { number }, f: { any }, v: { any }, head: number, n: number }

local StateApply = {}

StateApply.changedSignal = Signal.new()
local fieldSignals = setmetatable({} :: { [any]: { [string]: Signal.Signal } }, { __mode = "k" })
StateApply.fieldSignals = fieldSignals
-- model -> fn(now) -> server time this entity's state is applied at (Tide.clock)
local clocks = setmetatable({} :: { [any]: (number) -> number }, { __mode = "k" })
StateApply.clocks = clocks

local QCAP = 64
local TICK = StateSchema.TICK
local INF = math.huge
local REF = StateSchema.CODES.ref
local TO_OWNER = StateSchema.TO_OWNER
local TO_SERVER = StateSchema.TO_SERVER

local readValue = StateSchema.readValue
local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readi16 = buffer.readi16
local readf64 = buffer.readf64

local active = State.active
local index = State.index
local mine = State.mine
local models = State.model
local kinds = State.kind
local srcs = State.src
local lags = State.lag
local ownerIds = State.ownerId
local counters = State.counters

local schemas = {} :: { [number]: Schema } -- by kind id (from the server)
local warned = {} :: { [string]: boolean }
local val = {} :: { [number]: { [number]: any } }
local valT = {} :: { [number]: { [number]: number } } -- stamp of the applied change (nil: default)
local peekV = {} :: { [number]: { [number]: any } }
local peekT = {} :: { [number]: { [number]: number } }
local queues = {} :: { [number]: Queue }
local lastClock = {} :: { [number]: number }
local queued = 0

StateApply.schemas = schemas

local function newQueue(): Queue
	return { t = table.create(QCAP, 0), f = table.create(QCAP, false), v = table.create(QCAP, false), head = 1, n = 0 }
end

local function schemaFor(slot: number): Schema?
	local kind = kinds[slot]
	return if kind ~= nil then schemas[kind.id] else nil
end
StateApply.schemaFor = schemaFor

--------------------------------------------------------------------------------
-- Entities
--------------------------------------------------------------------------------

local function dropQueue(slot: number)
	local q = queues[slot]
	if q ~= nil then
		queued -= q.n
		for i = 1, QCAP do
			q.f[i] = false
			q.v[i] = false
		end
		q.n = 0
		q.head = 1
	end
end

function StateApply.onAdd(slot: number)
	dropQueue(slot)
	local v = val[slot]
	if v == nil then
		val[slot] = {}
		valT[slot] = {}
		peekV[slot] = {}
		peekT[slot] = {}
	else
		table.clear(v)
		table.clear(valT[slot])
		table.clear(peekV[slot])
		table.clear(peekT[slot])
	end
	lastClock[slot] = -INF
end

-- Refs are kept as slot numbers: a ref to an entity that goes reads nil from now on, also once its
-- slot is reused (the server's clearing change may never come here, e.g. while culled).
local function isRef(f: Field): boolean
	if f.code == REF then
		return true
	end
	local pf = f.payloadField
	return pf ~= nil and pf.code == REF
end

local function dropRefs(slot: number)
	if next(schemas) == nil then
		return
	end
	for k = 1, State.count do
		local s = active[k]
		local kind = kinds[s]
		local sch = if kind ~= nil then schemas[kind.id] else nil
		if sch == nil or s == slot then
			continue
		end
		local vv, pv = val[s], peekV[s]
		for _, f in sch.fields do
			if isRef(f) then
				-- 0: the nil slot (reads nil; the server's clearing change still applies, mirrors)
				local id = f.id
				if vv ~= nil and vv[id] == slot then
					vv[id] = 0
				end
				if pv ~= nil and pv[id] == slot then
					pv[id] = 0
				end
			end
		end
		local q = queues[s]
		if q ~= nil and q.n > 0 then
			for i = 0, q.n - 1 do
				local p = (q.head + i - 1) % QCAP + 1
				local f = q.f[p]
				if f and q.v[p] == slot and isRef(f) then
					q.v[p] = 0
				end
			end
		end
	end
end

function StateApply.onRemove(slot: number)
	dropQueue(slot)
	val[slot] = nil
	valT[slot] = nil
	peekV[slot] = nil
	peekT[slot] = nil
	lastClock[slot] = nil
	dropRefs(slot)
end

--------------------------------------------------------------------------------
-- Clock
--------------------------------------------------------------------------------

-- Server time this client's state for an entity is at (monotonic).
local function timeOf(slot: number, now: number): number
	local t
	if mine[slot] then
		t = now
	else
		local model = models[slot]
		local fn = if model ~= nil then clocks[model] else nil
		local kind = kinds[slot]
		if fn ~= nil then
			local ok, v = pcall(fn, now)
			if ok and type(v) == "number" and v == v then
				t = v
			else
				counters.stateClockErrors += 1
				t = now - kind.buffer
			end
		elseif kind.motion == false then
			t = now - kind.buffer
		else
			local src = srcs[slot]
			t = if src ~= nil then now - (lags[slot] or src.delay) else now
		end
	end
	local last = lastClock[slot] or -INF
	if t < last then
		return last
	end
	lastClock[slot] = t
	return t
end
StateApply.timeOf = timeOf

--------------------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------------------

local function refModel(v: any): any
	if v ~= nil and v ~= 0 and index[v] ~= nil then
		return models[v]
	end
	return nil
end

-- What a field's applied value means to game code (refs as models).
local function public(f: Field, v: any): any
	if f.code == REF then
		return refModel(v)
	elseif f.event then
		local pf = f.payloadField
		if pf ~= nil and pf.code == REF then
			return refModel(v)
		end
	end
	return v
end

local function playerOf(slot: number): any
	local id = ownerIds[slot]
	if id == nil or id == 0 then
		return nil
	end
	return Players:GetPlayerByUserId(id)
end

local function mirrorValue(f: Field, v: any, t: number): any
	if f.event then
		return t
	elseif v == nil then
		return f.mirrorNil
	elseif f.code == REF then
		if v == 0 or index[v] == nil then
			return f.mirrorNil
		end
		local model = models[v]
		if model ~= nil then
			return model.Name
		end
		local p = playerOf(v)
		return if p ~= nil then p.Name else f.mirrorNil
	end
	return v
end

local function setAttribute(target: any, name: string, value: any)
	target:SetAttribute(name, value)
end

local function mirror(slot: number, f: Field, v: any, t: number)
	local name = f.mirror :: string
	local target = if f.mirrorOn == "player" then playerOf(slot) else models[slot]
	if target == nil then
		return -- written when the model arrives (StateApply.onModel)
	end
	local ok = pcall(setAttribute, target, name, mirrorValue(f, v, t))
	if not ok then
		counters.stateMirrorErrors += 1
	end
end

local function signal(slot: number, f: Field, v: any, old: any, t: number)
	local model = models[slot]
	local general = StateApply.changedSignal
	if #general.fns > 0 then
		Signal.fire(general, model, f.name, public(f, v), public(f, old), t)
	end
	if model ~= nil then
		local byField = fieldSignals[model]
		if byField ~= nil then
			local sig = byField[f.name]
			if sig ~= nil and #sig.fns > 0 then
				Signal.fire(sig, public(f, v), public(f, old), t)
			end
		end
	end
end

local function apply(slot: number, f: Field, t: number, v: any)
	local vv = val[slot]
	local vt = valT[slot]
	if vv == nil then
		return
	end
	local id = f.id
	if f.event then
		local lt = vt[id]
		if lt == nil or t >= lt then
			vt[id] = t
			vv[id] = v
		end
		counters.stateApplied += 1
		if f.mirror then
			mirror(slot, f, v, t)
		end
		signal(slot, f, if f.payload ~= 0 then v else nil, nil, t)
		return
	end
	local lt = vt[id]
	if lt ~= nil and t < lt then
		counters.stateStale += 1
		return
	end
	local old = if lt ~= nil then vv[id] else f.default
	vv[id] = v
	vt[id] = t
	counters.stateApplied += 1
	if old == v then
		return
	end
	if f.mirror then
		mirror(slot, f, v, t)
	end
	signal(slot, f, v, old, t)
end

local function applyHead(slot: number, q: Queue)
	local h = q.head
	local f, t, v = q.f[h], q.t[h], q.v[h]
	q.f[h] = false
	q.v[h] = false
	q.head = h % QCAP + 1
	q.n -= 1
	queued -= 1
	local ok = pcall(apply, slot, f, t, v)
	if not ok then
		counters.applyErrors += 1
	end
end

-- One change for an entity: applied now (own entity, arrival / owner-only fields) or queued
-- in stamp order for its clock.
local function deliver(slot: number, f: Field, t: number, v: any)
	if not f.event then
		local pt = peekT[slot]
		if pt ~= nil then
			local p = pt[f.id]
			if p == nil or t >= p then
				pt[f.id] = t
				peekV[slot][f.id] = v
			end
		end
	end
	if mine[slot] or f.arrival or f.to == TO_OWNER then
		local ok = pcall(apply, slot, f, t, v)
		if not ok then
			counters.applyErrors += 1
		end
		return
	end
	if t <= (lastClock[slot] or -INF) then
		counters.stateLate += 1 -- its time already passed here: applies at the next step
	end
	local q = queues[slot]
	if q == nil then
		q = newQueue()
		queues[slot] = q
	end
	if q.n >= QCAP then
		counters.stateOverflow += 1
		applyHead(slot, q) -- the oldest goes early rather than lost
	end
	-- insert after every queued change with a stamp <= t
	local ts, fs, vs = q.t, q.f, q.v
	local head = q.head
	local i = q.n
	while i > 0 do
		local prev = (head + i - 2) % QCAP + 1
		if ts[prev] <= t then
			break
		end
		local dst = (head + i - 1) % QCAP + 1
		ts[dst], fs[dst], vs[dst] = ts[prev], fs[prev], vs[prev]
		i -= 1
	end
	local p = (head + i - 1) % QCAP + 1
	ts[p], fs[p], vs[p] = t, f, v
	q.n += 1
	queued += 1
end

-- Render step: applies every queued change whose stamp the entity's clock has reached.
function StateApply.step(now: number)
	if queued == 0 then
		return
	end
	local budget = Config.StateApplyPerFrame
	for k = 1, State.count do
		local slot = active[k]
		local q = queues[slot]
		if q ~= nil and q.n > 0 then
			local rt = timeOf(slot, now)
			while q.n > 0 and q.t[q.head] <= rt do
				if budget <= 0 then
					return
				end
				applyHead(slot, q)
				budget -= 1
			end
		end
	end
end

-- The entity's model arrived (streaming): write its mirrors.
function StateApply.onModel(slot: number)
	local s = schemaFor(slot)
	local vt = valT[slot]
	if s == nil or vt == nil then
		return
	end
	for _, f in s.fields do
		if f.mirror and vt[f.id] ~= nil and f.mirrorOn ~= "player" then
			mirror(slot, f, val[slot][f.id], vt[f.id])
		end
	end
end

--------------------------------------------------------------------------------
-- Receive (each returns the next position, -1 when malformed)
--------------------------------------------------------------------------------

local function readField(b: buffer, p: number, n: number, s: Schema, stamp: number): (number, Field?, any)
	if p + 1 > n then
		return -1, nil, nil
	end
	local byte = readu8(b, p)
	p += 1
	local f = s.fields[byte % 128]
	if f == nil then
		return -1, nil, nil
	end
	if byte >= 128 then
		if f.event then
			return -1, nil, nil
		end
		return p, f, f.default
	end
	if f.event then
		local pf = f.payloadField
		if pf == nil then
			return p, f, true
		end
		local np, v = readValue(b, p, n, pf.code, pf, stamp)
		return np, f, v
	end
	local np, v = readValue(b, p, n, f.code, f, stamp)
	if np >= 0 and f.code == REF and v == 0 then
		v = nil
	end
	return np, f, v
end

-- 30 STATE
function StateApply.readState(b: buffer, pos: number, n: number): number
	if pos + 10 > n then
		return -1
	end
	local base = readf64(b, pos)
	local groups = readu16(b, pos + 8)
	pos += 10
	if base ~= base then
		return -1
	end
	for _ = 1, groups do
		if pos + 5 > n then
			return -1
		end
		local slot = readu16(b, pos)
		local t = base + readi16(b, pos + 2) * TICK
		local count = readu8(b, pos + 4)
		pos += 5
		local s = if index[slot] ~= nil then schemaFor(slot) else nil
		if s == nil then
			return -1 -- the server only sends state for known entities with a schema
		end
		for _ = 1, count do
			local np, f, v = readField(b, pos, n, s, t)
			if np < 0 or f == nil then
				return -1
			end
			pos = np
			if f.to ~= TO_SERVER then
				deliver(slot, f, t, v)
			end
		end
	end
	return pos
end

-- 31 STATESNAP
function StateApply.readSnap(b: buffer, pos: number, n: number): number
	if pos + 11 > n then
		return -1
	end
	local slot = readu16(b, pos)
	local t0 = readf64(b, pos + 2)
	local nb = readu8(b, pos + 10)
	pos += 11
	local s = if index[slot] ~= nil then schemaFor(slot) else nil
	if s == nil or t0 ~= t0 then
		return -1
	end
	counters.stateSnaps += 1
	local vt = valT[slot]
	for _ = 1, nb do
		local np, f, v = readField(b, pos, n, s, t0)
		if np < 0 or f == nil then
			return -1
		end
		pos = np
		-- values in effect at t0: only where this client holds nothing newer
		local lt = vt and vt[f.id]
		if not f.event and f.to ~= TO_SERVER and (lt == nil or lt < t0) then
			deliver(slot, f, t0, v)
		end
	end
	if pos + 2 > n then
		return -1
	end
	local m = readu16(b, pos)
	pos += 2
	for _ = 1, m do
		if pos + 2 > n then
			return -1
		end
		local t = t0 + readu16(b, pos) * TICK
		local np, f, v = readField(b, pos + 2, n, s, t)
		if np < 0 or f == nil then
			return -1
		end
		pos = np
		if f.to ~= TO_SERVER then
			deliver(slot, f, t, v)
		end
	end
	return pos
end

-- 32 SCHEMA
function StateApply.readSchemas(b: buffer, pos: number, n: number): number
	if pos + 1 > n then
		return -1
	end
	local count = readu8(b, pos)
	pos += 1
	for _ = 1, count do
		local np, kindId, s = StateSchema.readSchema(b, pos, n)
		if np < 0 or s == nil then
			return -1
		end
		pos = np
		local kind = Kinds.byId[kindId]
		if kind ~= nil then
			s.kind = kind.name
			local mine = StateSchema.byKind[kind.name]
			if mine ~= nil and mine.checksum ~= s.checksum and not warned[kind.name] then
				warned[kind.name] = true
				warn(`Tide: the state of kind {kind.name} differs from the server's; using the server's`)
			end
		end
		schemas[kindId] = s
	end
	return pos
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

local function fieldOf(slot: number, name: any, api: string): Field?
	local s = schemaFor(slot)
	if s == nil then
		return nil -- not known yet (before the server's schema arrives)
	end
	local f = s.byName[name]
	if f == nil then
		error(`{api}: kind {kinds[slot].name} has no field {tostring(name)}`, 4)
	end
	return f
end

-- Applied value (event fields: stamp of the latest applied fire, and its payload).
function StateApply.get(slot: number, name: string): (any, any)
	local f = fieldOf(slot, name, "Tide.get")
	local vt = valT[slot]
	if f == nil or vt == nil then
		return nil, nil
	end
	local t = vt[f.id]
	if f.event then
		if t == nil then
			return nil, nil
		end
		local pf = f.payloadField
		return t, if pf ~= nil then public(pf, val[slot][f.id]) else nil
	end
	if t == nil then
		return f.default, nil
	end
	return public(f, val[slot][f.id]), nil
end

-- Newest received value (ahead of the drawing), and its stamp.
function StateApply.peek(slot: number, name: string): (any, number?)
	local f = fieldOf(slot, name, "Tide.peek")
	local pt = peekT[slot]
	if f == nil or pt == nil then
		return nil, nil
	end
	if f.event then
		return StateApply.get(slot, name)
	end
	local t = pt[f.id]
	local vt = valT[slot]
	local at = vt and vt[f.id]
	if t == nil or (at ~= nil and at > t) then
		return StateApply.get(slot, name), at
	end
	return public(f, peekV[slot][f.id]), t
end

return StateApply
