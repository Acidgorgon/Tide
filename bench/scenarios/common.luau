--!optimize 2
-- Library-agnostic scenario builders. A scenario returns a spec the harness drives:
--   clients        connected players (each has a character, owned by its client)
--   observer       index of the client whose CPU and view accuracy are measured
--   rates          send rates (Hz) every adapter is configured with: player / bot / npc
--   playerTracks   [client] = ground-truth track of that client's character
--   serverEntities { {kind = "Bot" | "Npc", name, track} } server-owned models
local Motion = ...

local C = {}

-- Strike's Chrono setup: PLAYER TICK_RATE = 0.92 / PlayerSendRate(90) -> 97.8 Hz.
C.RATES = { player = 90 / 0.92, bot = 30, npc = 20 }

local function split(n: number)
	-- near / mid / far groups around the ball; the observer (player 1) is near the ball
	local near = math.max(2, math.round(n * 0.36))
	local mid = math.round((n - near) / 2)
	local groups = {}
	for i = 1, n do
		groups[i] = if i <= near then "near" elseif i <= near + mid then "mid" else "far"
	end
	return groups
end

function C.players(n: number, duration: number, seed: number)
	return {
		desc = `{n} client-owned characters sending at ~98 Hz from 144 fps clients, football movement on a 360x230 pitch (near/mid/far groups around the ball)`,
		clients = n,
		observer = 1,
		rates = C.RATES,
		playerTracks = Motion.football(split(n), duration, seed),
		serverEntities = {},
	}
end

-- Idle spectators (characters standing still) along a line, the observer first.
local function idleClients(n: number, positions)
	local tracks = {}
	for i = 1, n do
		local p = positions[i]
		tracks[i] = Motion.static(p[1], p[2], p[3] or 0, 1)
	end
	return tracks
end

function C.bots(n: number, clients: number, duration: number, seed: number)
	local positions = { { 0, -122 } }
	for i = 2, clients do
		positions[i] = { -150 + (i - 2) * (300 / math.max(clients - 2, 1)), if i % 2 == 0 then 122 else -122, math.pi }
	end
	local groups = split(n)
	local tracks = Motion.football(groups, duration, seed)
	local ents = {}
	for i = 1, n do
		ents[i] = { kind = "Bot", name = `Bot{i}`, track = tracks[i] }
	end
	return {
		desc = `{n} server-owned bots at 30 Hz playing football (same movement model), {clients} idle spectator clients on the touchlines`,
		clients = clients,
		observer = 1,
		rates = C.RATES,
		playerTracks = idleClients(clients, positions),
		serverEntities = ents,
	}
end

function C.npcs(n: number, clients: number, duration: number, seed: number)
	local r = Motion.rng(seed + 99)
	local positions = { { 0, 0 } }
	for i = 2, clients do
		positions[i] = { (r() * 2 - 1) * 220, (r() * 2 - 1) * 170 }
	end
	local tracks = Motion.walkers(n, 250, 200, duration, seed)
	local ents = {}
	for i = 1, n do
		ents[i] = { kind = "Npc", name = `Npc{i}`, track = tracks[i] }
	end
	return {
		desc = `{n} server-owned walkers (3-8 studs/s) at 20 Hz in a 500x400 area, {clients} idle clients`,
		clients = clients,
		observer = 1,
		rates = C.RATES,
		playerTracks = idleClients(clients, positions),
		serverEntities = ents,
	}
end

return C
