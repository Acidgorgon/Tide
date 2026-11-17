--!strict
-- Tide: replication for moving entities (player characters, bots, NPCs).
--
-- server
--   Tide.start({ players = true, kinds = { Player = { maxFall = 400 } }, ...Config fields })
--                                          -- characters become kind "Player", owned by their player
--   local bot = Tide.add(model, "Bot")     -- server-owned; returns a handle
--   bot:teleport(cf, velocity?)  bot:remove()  bot:setOwner(player?)
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

if IS_SERVER then
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
end

return Tide
