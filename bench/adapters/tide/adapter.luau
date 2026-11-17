--!optimize 2
-- Tide (this repository's src/). Two profiles:
--
-- "tide" (matched): interest settings mapped onto Strike's Chrono configuration
-- (adapters/chrono/adapter.luau) so bytes compare like for like:
--   Player: near 70 (Chrono RELAY_NEAR_RADIUS) with Config.Hysteresis = 10
--     (RELAY_NEAR_HYSTERESIS; Tide's hysteresis is global, so it applies to every boundary);
--     beyond near every 3rd sample (97.8 / 3 = 32.6 Hz), the closest Tide setting to Chrono's far
--     relay, which forwards the newest sample every 2nd server frame (RELAY_FAR_EVERY 2 = 30 Hz);
--     never culled (Chrono's PLAYER type has HALF_TICK_DISTANCE = math.huge; the half rate
--     beyond 150 only applies when no viewer at all is within 150 studs, which never happens on
--     the pitch, and has no Tide equivalent).
--   Bot / Npc: near 150 (NORMAL_TICK_DISTANCE: every tick), far = cull = 400
--     (HALF_TICK_DISTANCE: every 2nd tick, nothing beyond), farEvery 2.
--   ReceiverBytesPerSecond = 96000 (Chrono MAX_TOTAL_BYTES_PER_FRAME_PER_PLAYER 1600 x 60).
--   Buffers stay Tide's (Player 0.02, Bot 0.04, Npc 0.07; Chrono MIN_BUFFER is 0.025).
-- "tide-defaults": Tide's own defaults (Player near 100 / far 250, Bot near 100 / far 250,
--   Npc near 60 / far 200 / cull 400, farEvery 2, Hysteresis 4, 40960 B/s budget).
--
-- Both profiles use the scenario's sample rates (Player 97.8 Hz, Bot 30 Hz, Npc 20 Hz; Tide's
-- built-in defaults are 60 / 30 / 15). Characters are registered by Tide.start({ players = true });
-- bots / NPCs through Tide.add(model, "Bot" | "Npc"). Positions travel on Tide's own remotes only
-- (Config.lockPlayers stops Roblox's native replication), and every byte is counted.
local ctx = ...

local matched = ctx.adapterName ~= "tide-defaults"

local A = {
	name = ctx.adapterName or "tide",
	nativePhysics = false,
}

local function kinds(Tide, rates)
	if matched then
		Tide.kind("Player", { rate = rates.player, near = 70, far = math.huge, cull = math.huge, farEvery = 3 })
		Tide.kind("Bot", { rate = rates.bot, near = 150, far = 400, cull = 400, farEvery = 2 })
		Tide.kind("Npc", { rate = rates.npc, near = 150, far = 400, cull = 400, farEvery = 2 })
	else
		Tide.kind("Player", { rate = rates.player })
		Tide.kind("Bot", { rate = rates.bot })
		Tide.kind("Npc", { rate = rates.npc })
	end
end

local function startOpts(extra)
	local opts = extra or {}
	if matched then
		opts.Hysteresis = 10
		opts.ReceiverBytesPerSecond = 96000
	end
	return opts
end

function A.startServer(env, rates)
	local module = env:mountTree(`{ctx.outDir}/Tide`, env.ReplicatedStorage, "Tide")
	local Tide = env:require(module)
	kinds(Tide, rates)
	Tide.start(startOpts({ players = true }))
	return {
		add = function(model, kind)
			return Tide.add(model, kind)
		end,
	}
end

function A.startClient(env, rates)
	local module = env.ReplicatedStorage:WaitForChild("Tide")
	local Tide = env:require(module)
	-- bench only: newest received sample time (Tide.latest has no stamp)
	local State = env:require(module.Client.State)
	kinds(Tide, rates) -- the server's hello is authoritative; this only mirrors it
	Tide.start(startOpts())
	local ws = env.Workspace
	return {
		-- Render stamp of what Tide draws for `model`, as a server time (GetServerTimeNow domain).
		renderInfo = function(model)
			if model == nil or Tide.drawn(model) == nil then
				return nil
			end
			return ws:GetServerTimeNow() - Tide.delay(model), "server_time"
		end,
		-- Newest decoded record for `model`: CFrame and the sender's stamp.
		latestInfo = function(model)
			local slot = model and State.bySlotModel[model]
			if slot == nil then
				return nil
			end
			local r = State.ring[slot]
			if r == nil or r.n == 0 then
				return nil
			end
			local cf = Tide.latest(model)
			if cf == nil then
				return nil
			end
			return cf, r.t[r.last % r.cap + 1], "server_time"
		end,
	}
end

return A
