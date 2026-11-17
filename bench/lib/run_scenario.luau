--!optimize 2
-- Runs ONE scenario with ONE adapter once and prints a JSON result line.
--
--   luau-bench [-O2] [--codegen] lib/run_scenario.luau <benchRoot> <adapter> <scenario> <outDir>
--       [seconds=10] [warmup=4] [jitterMs=0] [dropRate=0] [seed=1] [syncErrorMs=0]
--
-- Event-driven: the server runs at 60 Hz, each client at 144 fps with its own phase; a machine
-- frame handles the packets that arrived by its start, then RunService signals in Roblox order
--   client: [receive] PreRender RenderStepped | PreAnimation PreSimulation Stepped
--           | (physics: the client moves its own character) | PostSimulation Heartbeat
--   server: [receive] PreAnimation PreSimulation Stepped | (physics: server-owned models move;
--           NATIVE adapters also get each character's position replicated from its owner after
--           the c2s latency) | PostSimulation Heartbeat
-- then delayed task threads, then the calls fired this frame go on the wire.
-- Timed (real os.clock, exact allocation counts from the host): everything except the physics
-- step, the network phase and the measurements. The GC is paused while timed code runs and
-- stepped between frames in proportion to what was allocated, so CPU numbers exclude GC work
-- (report allocations to judge GC pressure).
--
-- Accuracy (observer client, every frame in the window, right after PreRender = what is drawn):
-- for each other entity, the drawn HumanoidRootPart position vs the ground truth at the time
-- the library is rendering (its render stamp converted to true time; for Tide the server-time
-- stamp, for Chrono the owner's os.clock stamp), and that delay (now - render time).

local realClock = os.clock
local allocBytes, allocCount = __alloc_bytes, __alloc_count

local benchRoot, adapterName, scenarioName, outDir = arg[1], arg[2], arg[3], arg[4]
assert(benchRoot and adapterName and scenarioName and outDir, "usage: run_scenario.luau <benchRoot> <adapter> <scenario> <outDir> [seconds] [warmup] [jitterMs] [dropRate] [seed] [syncErrorMs]")
local SECONDS = tonumber(arg[5]) or 10
local WARMUP = tonumber(arg[6]) or 4
local JITTER = (tonumber(arg[7]) or 0) / 1000
local DROP = tonumber(arg[8]) or 0
local SEED = tonumber(arg[9]) or 1
local SYNC_ERROR = (tonumber(arg[10]) or 0) / 1000

local SERVER_DT = 1 / 60
local CLIENT_DT = 1 / 144
local NEAR_RADIUS = 70

local function import(path: string, ...)
	local src = readfile(path) or error(`cannot read {path}`)
	local fn, err = loadstring(src, "@" .. path)
	if not fn then
		error(err)
	end
	return fn(...)
end

local Json = import(`{benchRoot}/lib/json.luau`)
local R = import(`{benchRoot}/lib/roblox.luau`)
local Mock = import(`{benchRoot}/lib/mock.luau`)
Mock.init(R)
Mock.installGlobals() -- before loading anything that reads os.clock / CFrame / Enum
local Motion = import(`{benchRoot}/lib/motion.luau`)
local Common = import(`{benchRoot}/scenarios/common.luau`, Motion)

local TOTAL = WARMUP + SECONDS
local spec = import(`{benchRoot}/scenarios/{scenarioName}.luau`, Common, { duration = TOTAL + 1, seed = SEED })
local adapter = import(`{benchRoot}/adapters/{adapterName}/adapter.luau`, { Mock = Mock, R = R, outDir = outDir, benchRoot = benchRoot, adapterName = adapterName, import = import })

-- Bytes of one mock CFrame (table + 12-slot array) vs a Roblox CFrame userdata (~72 B).
local CF_MOCK_BYTES
do
	__gc("collect")
	local b0 = allocBytes()
	local _keep = R.mkCFrame(1, 2, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	CF_MOCK_BYTES = allocBytes() - b0
end
local CF_ROBLOX_BYTES = 72

local NCLIENTS = spec.clients
local OBS = spec.observer

local function latencyFor(i: number): number
	if i == OBS then
		return 0.040
	end
	return 0.025 + ((i * 37) % 36) / 1000
end

local world = Mock.newWorld({
	seed = SEED,
	jitter = JITTER,
	dropRate = DROP,
	latency = latencyFor,
	serverClockOffset = 5000 + SEED,
	clockOffset = function(i)
		return 1000 + 523.25 * i
	end,
	syncError = function(i)
		if SYNC_ERROR == 0 then
			return 0
		end
		local r = Motion.rng(SEED * 31 + i)
		return (r() * 2 - 1) * SYNC_ERROR
	end,
})
local server = world.server

local function trackCF(track, t: number)
	local x, y, z, yaw = Motion.sample(track, t)
	local c, s = math.cos(yaw), math.sin(yaw)
	-- CFrame.new(x, y, z) * CFrame.fromOrientation(0, yaw, 0)
	return R.mkCFrame(x, y, z, c, 0, s, 0, 1, 0, -s, 0, c)
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

Mock.setNow(0)
Mock.setCurrent(server)
local serverApi = adapter.startServer(server, spec.rates)
Mock.runDeferred()

-- entities[k] = { serverModel, hrp (server), track, ownerClient (index or nil), kind, name }
local entities = {}
for _, e in spec.serverEntities do
	local model = world:newCharacterModel(server, e.name, trackCF(e.track, 0))
	model.Parent = server.Workspace
	Mock.setCurrent(server)
	serverApi.add(model, e.kind)
	Mock.runDeferred()
	table.insert(entities, { serverModel = model, hrp = rawget(model, "_primary"), track = e.track, kind = e.kind, name = e.name })
end

local clientApis = {}
local characters = {}
for i = 1, NCLIENTS do
	local player, client = world:addClient()
	client.clientPhase = ((i * 0.6180339887) % 1) * CLIENT_DT
	Mock.runDeferred()
	local model = world:spawnCharacter(player, trackCF(spec.playerTracks[i], 0))
	Mock.runDeferred()
	characters[i] = model
	table.insert(entities, { serverModel = model, hrp = rawget(model, "_primary"), track = spec.playerTracks[i], owner = i, kind = "Player", name = `Player{i}` })
	Mock.setCurrent(client)
	clientApis[i] = adapter.startClient(client, spec.rates)
	Mock.runDeferred()
	Mock.setCurrent(server)
end
world:flush(server)
for i = 1, NCLIENTS do
	world:flush(world.clients[i])
end

--------------------------------------------------------------------------------
-- Measurement state
--------------------------------------------------------------------------------

local ERR_BIN = 0.005 -- studs
local ERR_BINS = 6000 -- up to 30 studs
local DELAY_BINS = 2000 -- 0.5 ms bins up to 1 s
local function newAcc()
	return {
		n = 0,
		errSum = 0,
		errMax = 0,
		errNowSum = 0,
		yawSum = 0,
		delaySum = 0,
		delayMax = 0,
		errHist = table.create(ERR_BINS + 1, 0),
		delayHist = table.create(DELAY_BINS + 1, 0),
	}
end
local acc = { all = newAcc(), near = newAcc(), far = newAcc() }
local undrawn = 0
local drawnSamples = 0

local function histP(hist, total, q, binSize)
	if total == 0 then
		return 0
	end
	local target = q * total
	local run = 0
	for i = 1, #hist do
		run += hist[i]
		if run >= target then
			return i * binSize
		end
	end
	return #hist * binSize
end

local function addSample(a, err, errNow, yawErr, delay)
	a.n += 1
	a.errSum += err
	if err > a.errMax then
		a.errMax = err
	end
	a.errNowSum += errNow
	a.yawSum += yawErr
	a.delaySum += delay
	if delay > a.delayMax then
		a.delayMax = delay
	end
	local b = math.min(math.floor(err / ERR_BIN) + 1, ERR_BINS + 1)
	a.errHist[b] += 1
	local d = math.clamp(math.floor(delay * 2000) + 1, 1, DELAY_BINS + 1)
	a.delayHist[d] += 1
end

local observerEnv -- set after setup
local obsReplicaHrp = {} -- [entity] = observer's replica HRP

local function trueTime(stamp: number, domain: string, ent): number
	local ownerEnv = if ent.owner then world.clients[ent.owner] else server
	if domain == "os_owner" then
		return stamp - ownerEnv.clockOffset
	elseif domain == "server_time" then
		return stamp - Mock.SERVER_EPOCH - ownerEnv.syncError
	end
	error("unknown render-time domain " .. tostring(domain))
end

-- Decode check: the newest decoded record of each entity (adapter latestInfo), once per new
-- record, against the pose the sender actually sampled. The record's stamp is snapped to the
-- sender's frame grid (server 60 Hz, owner client 144 fps + phase), where the harness set the
-- root, so wire time quantization does not count as position error.
local DEC_BIN = 0.0005
local DEC_BINS = 400
local dec = { n = 0, posSum = 0, posMax = 0, yawSum = 0, yawMax = 0, posOk = 0, yawOk = 0, hist = table.create(DEC_BINS + 1, 0), stale = 0 }
local decLast = {} -- [entity] = stamp of the last checked record
local function senderFrameTime(tr: number, ent): number
	if ent.owner then
		local phase = world.clients[ent.owner].clientPhase
		return phase + math.round((tr - phase) / CLIENT_DT) * CLIENT_DT
	end
	return math.round(tr / SERVER_DT) * SERVER_DT
end
local function checkDecode(api, ent, model)
	local cf, stamp, domain = api.latestInfo(model)
	if cf == nil or stamp == decLast[ent] then
		return
	end
	decLast[ent] = stamp
	local tf = senderFrameTime(trueTime(stamp, domain, ent), ent)
	local x, y, z, yaw = Motion.sample(ent.track, tf)
	local dx, dy, dz = cf[1] - x, cf[2] - y, cf[3] - z
	local err = math.sqrt(dx * dx + dy * dy + dz * dz)
	local yawErr = math.abs(Motion.wrapAngle(math.atan2(cf[6], cf[12]) - yaw)) * 180 / math.pi
	dec.n += 1
	dec.posSum += err
	dec.posMax = math.max(dec.posMax, err)
	dec.yawSum += yawErr
	dec.yawMax = math.max(dec.yawMax, yawErr)
	if err <= 1 / 64 then
		dec.posOk += 1
	end
	if yawErr <= 0.5 then
		dec.yawOk += 1
	end
	local b = math.min(math.floor(err / DEC_BIN) + 1, DEC_BINS + 1)
	dec.hist[b] += 1
end

local function measureObserver(now: number)
	local api = clientApis[OBS]
	local ox, _, oz = Motion.sample(spec.playerTracks[OBS], now)
	for _, ent in entities do
		-- the observer's own character and idle spectators (static tracks: Chrono never resends
		-- an unchanged CFrame) are not scored
		if ent.owner == OBS or ent.track.n <= 2 then
			continue
		end
		local hrp = obsReplicaHrp[ent]
		if hrp == nil then
			hrp = observerEnv.replicas[ent.hrp] or false
			obsReplicaHrp[ent] = hrp
		end
		local cf = hrp and rawget(hrp, "_cf")
		local replicaModel = observerEnv.replicas[ent.serverModel]
		if api.latestInfo then
			checkDecode(api, ent, replicaModel)
		end
		local stamp, domain = api.renderInfo(replicaModel)
		if not cf or not stamp then
			undrawn += 1
			continue
		end
		drawnSamples += 1
		local tr = trueTime(stamp, domain, ent)
		local delay = now - tr
		local x, y, z, yaw = Motion.sample(ent.track, tr)
		local dx, dy, dz = cf[1] - x, cf[2] - y, cf[3] - z
		local err = math.sqrt(dx * dx + dy * dy + dz * dz)
		local nx, ny, nz = Motion.sample(ent.track, now)
		local ex, ey, ez = cf[1] - nx, cf[2] - ny, cf[3] - nz
		local errNow = math.sqrt(ex * ex + ey * ey + ez * ez)
		local drawnYaw = math.atan2(cf[6], cf[12])
		local yawErr = math.abs(Motion.wrapAngle(drawnYaw - yaw)) * 180 / math.pi
		local ddx, ddz = nx - ox, nz - oz
		local near = ddx * ddx + ddz * ddz <= NEAR_RADIUS * NEAR_RADIUS
		addSample(acc.all, err, errNow, yawErr, delay)
		addSample(if near then acc.near else acc.far, err, errNow, yawErr, delay)
	end
end

local function summarizeAcc(a)
	local n = math.max(a.n, 1)
	return {
		samples = a.n,
		err_mean = a.errSum / n,
		err_p50 = histP(a.errHist, a.n, 0.5, ERR_BIN),
		err_p95 = histP(a.errHist, a.n, 0.95, ERR_BIN),
		err_p99 = histP(a.errHist, a.n, 0.99, ERR_BIN),
		err_max = a.errMax,
		err_now_mean = a.errNowSum / n,
		yaw_err_mean_deg = a.yawSum / n,
		delay_ms_mean = a.delaySum / n * 1000,
		delay_ms_p50 = histP(a.delayHist, a.n, 0.5, 0.5),
		delay_ms_p95 = histP(a.delayHist, a.n, 0.95, 0.5),
		delay_ms_max = a.delayMax * 1000,
	}
end

-- CPU / allocation accumulators
local function newCpu()
	return { frames = 0, us = {}, recv = 0, render = 0, sim = 0, bytes = 0, count = 0, cframes = 0, cfw = 0, bulkParts = 0, bulkCalls = 0 }
end
local cpu = { server = newCpu(), observer = newCpu(), others = newCpu() }

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

local measuring = false
local nativePhysics = adapter.nativePhysics == true
local lastGcBytes = allocBytes()
local function gcStep()
	local now = allocBytes()
	local delta = now - lastGcBytes
	if delta > 256 * 1024 then
		__gc("step", math.floor(delta / 1024) * 2)
		__gc("stop")
		lastGcBytes = allocBytes()
	end
end

local serverEntityList = {}
for _, ent in entities do
	if not ent.owner then
		table.insert(serverEntityList, ent)
	end
end

local function record(c, env, t, recv, render, sim, bytes, count, cframes, stats0)
	c.frames += 1
	table.insert(c.us, t * 1e6)
	c.recv += recv
	c.render += render
	c.sim += sim
	c.bytes += bytes
	c.count += count
	c.cframes += cframes
	local st = env.stats
	c.cfw += st.cframeWrites - stats0[1]
	c.bulkParts += st.bulkMoveParts - stats0[2]
	c.bulkCalls += st.bulkMoveCalls - stats0[3]
end

local function serverFrame(now: number)
	local env = server
	world:collect(env)
	local st = env.stats
	local stats0 = { st.cframeWrites, st.bulkMoveParts, st.bulkMoveCalls }
	local f0, b0, c0, t0 = R.cframes, allocBytes(), allocCount(), realClock()
	world:dispatch(env)
	Mock.runDeferred()
	local t1 = realClock()
	env:fire("PreAnimation", SERVER_DT)
	env:fire("PreSimulation", SERVER_DT)
	env:fire("Stepped", now, SERVER_DT)
	Mock.runDeferred()
	local t2, b2, c2, f2 = realClock(), allocBytes(), allocCount(), R.cframes
	-- physics (untimed)
	for _, ent in serverEntityList do
		Mock.physicsSetCFrame(ent.hrp, trackCF(ent.track, now))
	end
	if nativePhysics then
		-- Roblox replicates each character's physics from its owner to the server
		for i = 1, NCLIENTS do
			local c = world.clients[i]
			Mock.physicsSetCFrame(entities[#serverEntityList + i].hrp, trackCF(spec.playerTracks[i], now - c.link.c2s.base))
		end
	end
	local f3, b3, c3, t3 = R.cframes, allocBytes(), allocCount(), realClock()
	env:fire("PostSimulation", SERVER_DT)
	env:fire("Heartbeat", SERVER_DT)
	Mock.runDeferred()
	Mock.runTimers(env)
	local t4, b4, c4, f4 = realClock(), allocBytes(), allocCount(), R.cframes
	if measuring then
		record(cpu.server, env, (t2 - t0) + (t4 - t3), t1 - t0, 0, (t2 - t1) + (t4 - t3), (b2 - b0) + (b4 - b3), (c2 - c0) + (c4 - c3), (f2 - f0) + (f4 - f3), stats0)
	end
	world:flush(env)
	gcStep()
end

local staticSet = {}
local function clientFrame(i: number, now: number)
	local env = world.clients[i]
	world:collect(env)
	local st = env.stats
	local stats0 = { st.cframeWrites, st.bulkMoveParts, st.bulkMoveCalls }
	local f0, b0, c0, t0 = R.cframes, allocBytes(), allocCount(), realClock()
	world:dispatch(env)
	Mock.runDeferred()
	local t1 = realClock()
	env:fire("PreRender", CLIENT_DT)
	env:fire("RenderStepped", CLIENT_DT)
	Mock.runDeferred()
	local t2, b2, c2, f2 = realClock(), allocBytes(), allocCount(), R.cframes
	if measuring and i == OBS then
		measureObserver(now)
	end
	local f3, b3, c3, t3 = R.cframes, allocBytes(), allocCount(), realClock()
	env:fire("PreAnimation", CLIENT_DT)
	env:fire("PreSimulation", CLIENT_DT)
	env:fire("Stepped", now, CLIENT_DT)
	Mock.runDeferred()
	local t4, b4, c4, f4 = realClock(), allocBytes(), allocCount(), R.cframes
	-- physics (untimed): the client moves its own character
	local track = spec.playerTracks[i]
	if track.n > 2 or not staticSet[i] then
		staticSet[i] = true
		local hrp = env.replicas[rawget(characters[i], "_primary")]
		Mock.physicsSetCFrame(hrp, trackCF(track, now))
	end
	local f5, b5, c5, t5 = R.cframes, allocBytes(), allocCount(), realClock()
	env:fire("PostSimulation", CLIENT_DT)
	env:fire("Heartbeat", CLIENT_DT)
	Mock.runDeferred()
	Mock.runTimers(env)
	local t6, b6, c6, f6 = realClock(), allocBytes(), allocCount(), R.cframes
	if measuring then
		record(
			if i == OBS then cpu.observer else cpu.others,
			env,
			(t2 - t0) + (t4 - t3) + (t6 - t5),
			t1 - t0,
			t2 - t1,
			(t4 - t3) + (t6 - t5),
			(b2 - b0) + (b4 - b3) + (b6 - b5),
			(c2 - c0) + (c4 - c3) + (c6 - c5),
			(f2 - f0) + (f4 - f3) + (f6 - f5),
			stats0
		)
	end
	world:flush(env)
	gcStep()
end

--------------------------------------------------------------------------------
-- Event loop
--------------------------------------------------------------------------------

observerEnv = world.clients[OBS]
__gc("collect")
__gc("stop")
lastGcBytes = allocBytes()

local nextServer = 0
local serverFrameNo = 0
local nextClient = table.create(NCLIENTS)
local clientFrameNo = table.create(NCLIENTS, 0)
for i = 1, NCLIENTS do
	nextClient[i] = world.clients[i].clientPhase
end
local wallStart = realClock()
while true do
	local t, who = nextServer, 0
	for i = 1, NCLIENTS do
		if nextClient[i] < t then
			t, who = nextClient[i], i
		end
	end
	if t >= TOTAL then
		break
	end
	if not measuring and t >= WARMUP then
		measuring = true
		world:setMeasuring(true)
	end
	Mock.setNow(t)
	if who == 0 then
		Mock.setCurrent(server)
		serverFrame(t)
		serverFrameNo += 1
		nextServer = serverFrameNo * SERVER_DT
	else
		Mock.setCurrent(world.clients[who])
		clientFrame(who, t)
		clientFrameNo[who] += 1
		nextClient[who] = world.clients[who].clientPhase + clientFrameNo[who] * CLIENT_DT
	end
end
local wall = realClock() - wallStart
__gc("restart")

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

local function pct(list, q)
	if #list == 0 then
		return 0
	end
	local s = table.clone(list)
	table.sort(s)
	return s[math.clamp(math.ceil(#s * q), 1, #s)]
end

local function summarizeCpu(c, perClients)
	local frames = math.max(c.frames, 1)
	local sum = 0
	for _, v in c.us do
		sum += v
	end
	local adjBytes = c.bytes - c.cframes * (CF_MOCK_BYTES - CF_ROBLOX_BYTES)
	return {
		frames = c.frames,
		us_mean = sum / frames,
		us_p50 = pct(c.us, 0.5),
		us_p95 = pct(c.us, 0.95),
		us_max = pct(c.us, 1),
		recv_us = c.recv * 1e6 / frames,
		render_us = c.render * 1e6 / frames,
		sim_us = c.sim * 1e6 / frames,
		alloc_bytes = c.bytes / frames,
		allocs = c.count / frames,
		cframes_created = c.cframes / frames,
		alloc_bytes_roblox = adjBytes / frames,
		allocs_roblox = (c.count - c.cframes) / frames,
		cframe_writes = c.cfw / frames,
		bulkmove_parts = c.bulkParts / frames,
		bulkmove_calls = c.bulkCalls / frames,
	}
end

local KB = 1024
local function linkSum(field, dir)
	local total, obs = 0, 0
	for i = 1, NCLIENTS do
		local v = world.clients[i].link[dir][field]
		total += v
		if i == OBS then
			obs = v
		end
	end
	return total, obs
end
local s2cBytes, obsS2c = linkSum("bytes", "s2c")
local s2cCalls, obsCalls = linkSum("calls", "s2c")
local s2cPayload = linkSum("payload", "s2c")
local c2sBytes, obsC2s = linkSum("bytes", "c2s")
local c2sCalls = linkSum("calls", "c2s")

local result = {
	scenario = scenarioName,
	adapter = adapterName,
	desc = spec.desc,
	native = __native(),
	seconds = SECONDS,
	warmup = WARMUP,
	jitter_ms = JITTER * 1000,
	drop_rate = DROP,
	seed = SEED,
	clients = NCLIENTS,
	entities = #entities,
	server = summarizeCpu(cpu.server),
	observer = summarizeCpu(cpu.observer),
	other_clients = summarizeCpu(cpu.others),
	net = {
		observer_down_kbps = obsS2c / SECONDS / KB,
		client_down_kbps_mean = s2cBytes / SECONDS / KB / NCLIENTS,
		server_egress_kbps = s2cBytes / SECONDS / KB,
		server_ingress_kbps = c2sBytes / SECONDS / KB,
		client_up_kbps_mean = c2sBytes / SECONDS / KB / NCLIENTS,
		observer_up_kbps = obsC2s / SECONDS / KB,
		observer_calls_per_s = obsCalls / SECONDS,
		s2c_calls_per_s = s2cCalls / SECONDS,
		c2s_calls_per_s = c2sCalls / SECONDS,
		s2c_payload_bytes_per_s = s2cPayload / SECONDS,
		dropped_unreliable = world.stats.droppedUnreliable,
		dropped_oversize = world.stats.droppedOversize,
	},
	accuracy = {
		all = summarizeAcc(acc.all),
		near = summarizeAcc(acc.near),
		far = summarizeAcc(acc.far),
		decode = if dec.n == 0 then nil else {
			records = dec.n,
			pos_err_mean = dec.posSum / dec.n,
			pos_err_p99 = histP(dec.hist, dec.n, 0.99, DEC_BIN),
			pos_err_max = dec.posMax,
			yaw_err_mean_deg = dec.yawSum / dec.n,
			yaw_err_max_deg = dec.yawMax,
			pos_within_1_64 = dec.posOk / dec.n,
			yaw_within_half_deg = dec.yawOk / dec.n,
		},
		undrawn_samples = undrawn,
		drawn_fraction = drawnSamples / math.max(drawnSamples + undrawn, 1),
	},
	mock = { cframe_bytes = CF_MOCK_BYTES, cframe_roblox_bytes = CF_ROBLOX_BYTES },
	warnings = world.stats.warnings,
	warning_samples = world.warnings,
	wall_s = wall,
}
print(Json.encode(result))
