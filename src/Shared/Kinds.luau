--!strict
-- Kind registry: named entity configs shared by server and client.
-- The server is authoritative for network fields (it sends them in the hello);
-- client-side Tide.kind calls only add local fields such as `apply`.

export type Kind = {
	id: number,
	name: string,
	rate: number, -- samples per second
	rotation: string, -- "yaw" | "full"
	full: boolean,
	near: number,
	far: number,
	cull: number,
	farEvery: number,
	buffer: number, -- minimum interpolation delay (s)
	extrapolate: number, -- max extrapolation (s)
	apply: any, -- "cframe" | "none" | (model, CFrame) -> ()
	afterApply: any, -- false | (model, CFrame) -> (): runs after the pose is applied each frame (client)
	maxSpeed: number, -- studs/s horizontally (client-owned validation)
	maxFall: number, -- studs/s downwards (client-owned validation)
	maxRise: number, -- studs/s upwards
	keepAlive: number, -- idle keep-alive (s): server-owned samples and client uploads
	animations: boolean, -- false: this kind's animations stay Roblox's (Config.animations opt-out)
	motion: boolean, -- false: state-only entities (no samples, no relay, no apply; v0.3 timeline state)
	-- runtime (server ticker)
	acc: number,
	tick: boolean,
}

local Kinds = {}

local byName: { [string]: Kind } = {}
local byId: { [number]: Kind } = {}
local list: { Kind } = {}

Kinds.byName = byName
Kinds.byId = byId
Kinds.list = list

local FIELDS = {
	rate = "number",
	rotation = "string",
	near = "number",
	far = "number",
	cull = "number",
	farEvery = "number",
	buffer = "number",
	extrapolate = "number",
	maxSpeed = "number",
	maxFall = "number",
	maxRise = "number",
	keepAlive = "number",
	animations = "boolean",
	motion = "boolean",
}

local function newKind(name: string): Kind
	return {
		id = 0,
		name = name,
		rate = 30,
		rotation = "yaw",
		full = false,
		near = 100,
		far = 250,
		cull = math.huge,
		farEvery = 2,
		buffer = 0.04,
		extrapolate = 0.1,
		apply = "cframe",
		afterApply = false,
		maxSpeed = 120,
		maxFall = 300,
		maxRise = 60,
		keepAlive = 0.5,
		animations = true,
		motion = true,
		acc = 0,
		tick = false,
	}
end

local function applyOpts(kind: Kind, opts: { [string]: any }?)
	if opts == nil then
		return
	end
	for key, value in opts do
		local expected = FIELDS[key]
		if expected then
			if typeof(value) ~= expected then
				error(`Tide.kind("{kind.name}"): option {key} must be a {expected}`, 3)
			end
			(kind :: any)[key] = value
		elseif key == "apply" then
			if value ~= "cframe" and value ~= "none" and type(value) ~= "function" then
				error(`Tide.kind("{kind.name}"): apply must be "cframe", "none" or a function`, 3)
			end
			kind.apply = value
		elseif key == "afterApply" then
			if value ~= false and type(value) ~= "function" then
				error(`Tide.kind("{kind.name}"): afterApply must be a function or false`, 3)
			end
			kind.afterApply = value
		else
			error(`Tide.kind("{kind.name}"): unknown option {key}`, 3)
		end
	end
	if kind.rotation ~= "yaw" and kind.rotation ~= "full" then
		error(`Tide.kind("{kind.name}"): rotation must be "yaw" or "full"`, 3)
	end
	kind.full = kind.rotation == "full"
	if not (kind.rate > 0 and kind.rate <= 240) then
		error(`Tide.kind("{kind.name}"): rate must be in (0, 240]`, 3)
	end
	kind.farEvery = math.max(1, math.floor(kind.farEvery))
	kind.far = math.max(kind.far, kind.near)
	kind.cull = math.max(kind.cull, kind.far)
end

-- Creates or updates a kind. Ids are assigned in definition order (server side).
function Kinds.define(name: string, opts: { [string]: any }?): Kind
	assert(type(name) == "string" and #name > 0 and #name < 64, "Tide.kind: name must be a short string")
	local kind = byName[name]
	if kind == nil then
		assert(#list < 255, "Tide.kind: at most 255 kinds")
		kind = newKind(name)
		kind.id = #list + 1
		byName[name] = kind
		byId[kind.id] = kind
		table.insert(list, kind)
	end
	applyOpts(kind, opts)
	return kind
end

-- Client: (re)binds a kind to the id the server uses, keeping local fields.
function Kinds.bind(name: string, id: number): Kind
	local kind = byName[name]
	if kind == nil then
		kind = newKind(name)
		byName[name] = kind
		table.insert(list, kind)
	end
	local previous = byId[kind.id]
	if previous == kind then
		byId[kind.id] = nil
	end
	kind.id = id
	byId[id] = kind
	return kind
end

-- Built-ins.
Kinds.define("Player", {
	rate = 60,
	near = 100,
	far = 250,
	cull = math.huge,
	farEvery = 2,
	buffer = 0.02,
})
Kinds.define("Bot", {
	rate = 30,
	near = 100,
	far = 250,
	cull = math.huge,
	farEvery = 2,
	buffer = 0.04,
})
Kinds.define("Npc", {
	rate = 15,
	near = 60,
	far = 200,
	cull = 400,
	farEvery = 2,
	buffer = 0.07,
})

return Kinds
