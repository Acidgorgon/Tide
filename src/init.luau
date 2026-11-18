--!strict
-- Tide: replication for moving entities (player characters, bots, NPCs).
--
-- server
--   Tide.start({ players = true, kinds = { Player = { maxFall = 400 } }, ...Config fields })
--                                          -- characters become kind "Player", owned by their player
--   local bot = Tide.add(model, "Bot")     -- server-owned; returns a handle
--   bot:teleport(cf, velocity?)  bot:remove()  bot:setOwner(player?)
--   bot:setAudience(fn(player) -> boolean | { Player } | nil)   -- who receives it (v0.4)
--   Tide.focus(player, part | model | Vector3 | nil)          -- interest without a character (v0.4)
--   Tide.at(model, t)                      -- rewind: CFrame at server time t (what clients drew)
--   Tide.latest(model)                     -- newest accepted sample
--   Tide.velocity(model)                   -- from history
--   Tide.kind("Ball", { rate = 60, rotation = "full" })
--   Tide.onSuspicious(function(player, reason) end)
-- client
--   Tide.start()                           -- false if the server's remotes never appear (Config.startTimeout)
--   Tide.drawn(model)  Tide.delay(model)  Tide.velocity(model)  Tide.latest(model)
--   Tide.sampleInfo(model, into?)          -- stream health: newest, count, age, interval, jitter, idle, ...
-- both
--   Tide.added(fn(model, kindName, owner))  Tide.removed(fn(model, kindName))
--   Tide.stats()  Tide.Config
-- animations (Config.animations = true; game code keeps playing on the Animator as before)
--   Tide.play(model, animation | name, fade?, weight?, speed?) -> AnimationTrack?   (owner side, exact fade)
--   Tide.stop(model, animation | name, fade?)
--   Tide.playing(model, t?)                 -- { [name] = info } (server: at time t; client: own or as drawn)
--   Tide.animated(fn(model, op, name, info)) -- server: accepted events; client: events applied to remote entities
-- timeline state (v0.3; on for kinds with a schema)
--   Tide.state("Ball", { Owner = { type = "ref", mirror = "Owner" }, ShotAt = "time", ... })  -- shared code
--   server: Tide.set(model, field, value, stamp?)  Tide.fire(model, eventField, payload?, stamp?)
--           Tide.get(model, field)  Tide.stateAt(model, field, t)  Tide.changedAt(model, field, t0, t1)
--   client: Tide.get(model, field) (as drawn)  Tide.peek(model, field)  Tide.timeOf(model)
--           Tide.clock(model, fn(now) -> serverTime)   (entities game code draws, e.g. the ball)
--   both:   Tide.changed(model, field, fn(value, old, t))  Tide.stateChanged(fn(model, field, value, old, t))

local RunService = game:GetService("RunService")

local Config = require(script.Shared.Config)
local Kinds = require(script.Shared.Kinds)
local Signal = require(script.Shared.Signal)

local IS_SERVER = RunService:IsServer()

local Side: any = if IS_SERVER then require(script.Server.Server) else require(script.Client.Client)

local Tide = {}

Tide.Config = Config
Tide.isServer = IS_SERVER

-- Defines or updates a kind. Network fields are authoritative on the server;
-- on the client use it for local fields such as `apply`.
function Tide.kind(name: string, opts: { [string]: any }?)
	local kind = Kinds.define(name, opts)
	if IS_SERVER then
		Side.kindsChanged()
	end
	return kind
end

-- Starts Tide. opts: any Config field (type checked), `kinds = { Name = kindOptions }`,
-- and on the server `players = true`. Returns true once running; the client
-- returns false (and warns) when the server's remotes do not appear within
-- Config.startTimeout seconds.
function Tide.start(opts: { [string]: any }?): boolean
	return Side.start(opts)
end

function Tide.added(fn: (model: Instance, kind: string, owner: any) -> ())
	return Signal.connect(Side.addedSignal, fn)
end

function Tide.removed(fn: (model: Instance, kind: string) -> ())
	return Signal.connect(Side.removedSignal, fn)
end

function Tide.latest(model: any): CFrame?
	return Side.latest(model)
end

function Tide.stats(): { [string]: number }
	return Side.stats()
end

-- Animations (Config.animations). Plays on an entity this side owns (server:
-- server-owned entities; client: entities this client owns) with an exact fade;
-- `animation` is an Animation or the name of one under Config.animationFolder.
-- Returns the track (nil if the entity is not owned here or has no Animator).
function Tide.play(model: Instance, animation: any, fade: number?, weight: number?, speed: number?): AnimationTrack?
	return Side.play(model, animation, fade, weight, speed)
end

function Tide.stop(model: Instance, animation: any, fade: number?)
	Side.stop(model, animation, fade)
end

-- What Tide knows an entity plays: { [name] = { id, name, since, timePosition,
-- speed, weight, priority, looped, ... } }; nil when the entity is not animated
-- by Tide. Server: at server time t (default now). Client: own entities from
-- their Animator, remote ones at the time their body is drawn.
function Tide.playing(model: Instance, t: number?): { [string]: any }?
	return Side.playing(model, t)
end

-- fn(model, op, name, info) for each animation event: on the server when it is
-- accepted (info.time = its server time), on a client when it is applied to a
-- remote entity (in step with the body). op: "play" | "stop" | "speed" | "weight"
-- | "seek" | "priority".
function Tide.animated(fn: (model: Instance, op: string, name: string, info: { [string]: any }) -> ())
	return Signal.connect(Side.animatedSignal, fn)
end

-- Timeline state (v0.3). Declares the state fields of a kind, once, in shared code (server and
-- client). fields = { [name] = { type = ..., to = ..., apply = ..., mirror = ..., ... } } or
-- { [name] = "type" }; see Shared/StateSchema for every option.
function Tide.state(kindName: string, fields: { [string]: any })
	Side.state(kindName, fields)
end

-- Server: the current value. Client: the value as drawn (applied when this client's clock for
-- the entity reached the change's stamp). Event fields: stamp of the latest fire, and its payload.
function Tide.get(model: any, field: string): (any, any)
	return Side.get(model, field)
end

-- The server time an entity is at: the server's now on the server; on a client the time its
-- body (and state) is drawn at. Compare "until" times against this, not GetServerTimeNow().
function Tide.timeOf(model: any): number
	return Side.timeOf(model)
end

-- fn(value, old, t) when a field of this model changes (server: on set; client: when applied).
-- Event fields: fn(payload, nil, t) on each fire.
function Tide.changed(model: Instance, field: string, fn: (value: any, old: any, t: number) -> ())
	assert(model ~= nil, "Tide.changed: model expected")
	assert(type(field) == "string", "Tide.changed: field name expected")
	local map = Side.stateFieldSignals
	local byField = map[model]
	if byField == nil then
		byField = {}
		map[model] = byField
	end
	local signal = byField[field]
	if signal == nil then
		signal = Signal.new()
		byField[field] = signal
	end
	return Signal.connect(signal, fn)
end

-- fn(model, field, value, old, t) for every change (server: on set; client: when applied).
function Tide.stateChanged(fn: (model: Instance, field: string, value: any, old: any, t: number) -> ())
	return Signal.connect(Side.stateChangedSignal, fn)
end

if IS_SERVER then
	-- Sets a field (server-authoritative), stamped now or at `stamp` (clamped to
	-- [now - Config.MaxBackdate, now]). nil = the field's default.
	function Tide.set(model: any, field: string, value: any, stamp: number?)
		Side.set(model, field, value, stamp)
	end

	-- Fires an event field (with its payload, if the field declares one).
	function Tide.fire(model: any, field: string, payload: any?, stamp: number?)
		Side.fire(model, field, payload, stamp)
	end

	-- Value in effect at server time t, from the field's history (Config.StateHistory changes).
	function Tide.stateAt(model: any, field: string, t: number): (any, any)
		return Side.stateAt(model, field, t)
	end

	-- Stamp of the first change of a field in (t0, t1], or nil.
	function Tide.changedAt(model: any, field: string, t0: number, t1: number): number?
		return Side.changedAt(model, field, t0, t1)
	end

	-- Client only (no-op here, so shared code may call it).
	function Tide.clock(_model: any, _fn: any) end

	-- Registers a model. owner = nil: server-owned (sampled by the server);
	-- owner = Player: that client samples and uploads it.
	function Tide.add(model: Instance, kind: string?, owner: Player?)
		return Side.add(model, kind, owner)
	end

	function Tide.remove(target: any)
		local slot = Side.slotOf(target)
		if slot then
			Side.remove(slot)
		end
	end

	function Tide.handle(model: Instance)
		return Side.handleOf(model)
	end

	function Tide.at(target: any, t: number): CFrame?
		return Side.at(target, t)
	end

	-- Interest centre for a player without a "Player" entity (spectating, watching a match):
	-- a BasePart or Model (followed), a Vector3, or nil.
	function Tide.focus(player: Player, target: any)
		Side.focus(player, target)
	end

	function Tide.onSuspicious(fn: (player: Player, reason: string) -> ())
		Side.onSuspicious(fn)
	end

	-- Velocity (studs/s) from the entity's history; zero when idle or unknown.
	function Tide.velocity(target: any): Vector3
		return Side.velocity(target)
	end
else
	function Tide.drawn(model: Instance): CFrame?
		return Side.drawn(model)
	end

	function Tide.delay(model: Instance): number
		return Side.delay(model)
	end

	function Tide.velocity(model: Instance): Vector3
		return Side.velocity(model)
	end

	function Tide.at(model: Instance, t: number): CFrame?
		return Side.at(model, t)
	end

	function Tide.sampleInfo(model: Instance, into: { [string]: any }?): { [string]: any }?
		return Side.sampleInfo(model, into)
	end

	-- Newest received value of a field (may be ahead of the drawing), and its stamp.
	function Tide.peek(model: any, field: string): (any, number?)
		return Side.peek(model, field)
	end

	-- Supplies the clock an entity's state applies at, for entities game code draws itself
	-- (e.g. a ball drawn at its own lead): fn(now) -> server time. nil removes it.
	function Tide.clock(model: any, fn: ((now: number) -> number)?)
		Side.clock(model, fn)
	end
end

return Tide
