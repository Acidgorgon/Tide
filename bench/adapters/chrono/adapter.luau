--!optimize 2
-- Chrono 2.2.0 (Strike's patched copy) configured like Strike:
--   src/server/Bootstrapper.server.luau, src/client/Client/init.client.luau and
--   SharedConfig.Latency: PLAYER TICK_RATE = 0.92 / PlayerSendRate (90) = 97.8 Hz,
--   MIN_BUFFER = PlayerMinBuffer (0.025), ChronoFix on -> RELAY_ALL + STEADY_SEND (+ SMART_BUFFER
--   on the client), Relay on -> near 70 / hysteresis 10 / far every 2 / max pending 3 /
--   slow half 1.4, byte cap 1600, tick distances 150 / 400, PLAYER_REPLICATION AUTOMATIC with the
--   PLAYER type's NATIVE model mode.
-- Not ported: Strike's StallDraw / LookAhead / HonestView game code on top of Chrono.
--
-- Server-owned kinds (bots_22, npcs_150) are not in Strike (FM bots use engine physics). They get
-- Chrono entity types BOT (30 Hz) and NPC (20 Hz) with NATIVE_WITH_LOCK (Chrono's documented mode
-- to switch Roblox's own CFrame replication off), BUFFER 0 (dynamic) and the default tick
-- distances.
--
-- NATIVE mode relies on Roblox physics replication of characters (owner -> server -> clients),
-- which the mock does not simulate or count: the harness only moves each character on the server
-- to its owner's position after the c2s latency (Chrono's interest grid reads it). Reported bytes
-- are Chrono's own remotes only.
local ctx = ...
local R = ctx.R

local A = {
	name = "chrono",
	nativePhysics = true,
}

local function configure(Chrono, rates, isServer: boolean)
	local Config = Chrono.Config
	-- Bootstrapper / init.client: Latency.PlayerSendRate = 90, PlayerMinBuffer = 0.025
	Config.SetConfig("MIN_BUFFER", 0.025)
	local playerType = Config._EntityConfigs.PLAYER
	local custom = table.clone(playerType)
	custom.TICK_RATE = 1 / rates.player -- = 0.92 / 90
	Config.RegisterEntityType("PLAYER", custom)
	-- server-owned kinds for the bot / npc scenarios
	Config.RegisterEntityType("BOT", {
		NAME = "BOT",
		TICK_RATE = 1 / rates.bot,
		BUFFER = 0,
		MODEL_REPLICATION_MODE = "NATIVE_WITH_LOCK",
	} :: any)
	Config.RegisterEntityType("NPC", {
		NAME = "NPC",
		TICK_RATE = 1 / rates.npc,
		BUFFER = 0,
		MODEL_REPLICATION_MODE = "NATIVE_WITH_LOCK",
	} :: any)
	if isServer then
		-- StallDraw.Enabled = "Test" (off in live servers); Relay.ByteCap = 1600 raises the cap
		Config.SetConfig("MAX_TOTAL_BYTES_PER_FRAME_PER_PLAYER", 1600)
	end
	-- ChronoFix.Enabled = true
	Config.SetConfig("RELAY_ALL", true)
	Config.SetConfig("STEADY_SEND", true)
	if not isServer then
		Config.SetConfig("SMART_BUFFER", true) -- ChronoFix.SmartBuffer ~= false
	end
	if isServer then
		-- Relay.Enabled = true
		local set = Config.SetConfig :: any
		set("RELAY_NEAR_RADIUS", 70)
		set("RELAY_NEAR_HYSTERESIS", 10)
		set("RELAY_FAR_EVERY", 2)
		set("RELAY_MAX_PENDING", 3)
		set("RELAY_SLOW_HALF", 1.4)
	end
	Config.SetConfig("DEFAULT_NORMAL_TICK_DISTANCE", 150)
	Config.SetConfig("DEFAULT_HALF_TICK_DISTANCE", 400)
	Chrono.Start()
end

function A.startServer(env, rates)
	local packages = env.InstanceLib.new("Folder")
	packages.Name = "Packages"
	packages.Parent = env.ReplicatedStorage
	local module = env:mountTree(`{ctx.outDir}/chrono`, packages, "Chrono")
	local Chrono = env:require(module)
	configure(Chrono, rates, true)
	local kinds = { Bot = "BOT", Npc = "NPC" }
	return {
		add = function(model, kind)
			return Chrono.Entity.new(kinds[kind] or error("unknown kind " .. kind), model)
		end,
	}
end

function A.startClient(env, rates)
	local Chrono = env:require(env.ReplicatedStorage.Packages.Chrono)
	configure(Chrono, rates, false)
	local Entity = Chrono.Entity
	-- model -> entity (Holder.GetEntityFromModel is O(n))
	local byModel = {}
	Chrono.Events.EntityAdded:Connect(function(entity)
		if entity.model then
			byModel[entity.model] = entity
		end
	end)
	Chrono.Events.EntityRemoved:Connect(function(entity)
		for model, e in byModel do
			if e == entity then
				byModel[model] = nil
			end
		end
	end)
	return {
		-- Render stamp of what is drawn for `model` (observer's replica), in the owner's os.clock
		-- (client-owned: the owner client's clock; server-owned: the server's), or nil if Chrono
		-- does not draw it.
		renderInfo = function(model)
			local entity = byModel[model]
			if entity == nil or entity.destroyed or entity.paused or entity.model ~= model then
				return nil
			end
			local t = Entity.GetTargetRenderTime(entity)
			if t == nil or t <= 0 then
				return nil
			end
			return t, "os_owner"
		end,
		-- Newest decoded record for `model`: CFrame and the sender's stamp (owner's clock).
		latestInfo = function(model)
			local entity = byModel[model]
			local snapshot = entity and entity.snapshot
			local latest = snapshot and snapshot:GetLatest()
			if latest == nil then
				return nil
			end
			return latest.value, latest.t, "os_owner"
		end,
	}
end

return A
