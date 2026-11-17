--!optimize 2
-- Quick hot-path timing (not a test): server relay for 22 players + 20 bots, and one
-- client's receive + render of 21 players + 20 bots. Remotes are no-op fakes.
-- usage: luau-bench [--codegen] tests/bench_hot.luau <tide root>

local ROOT = arg[1] or "."
local function load(path)
	local fn = assert(loadstring(readfile(path) or error("cannot read " .. path), "@" .. path))
	return fn()
end
local Mock = load(ROOT .. "/tests/mock.luau")
Mock.installGlobals()

local DT = 1 / 60
local N = 22
local world = Mock.newWorld({ latency = 0.03 })
local tideModule = world.server:mountTree(ROOT .. "/src", world.server.ReplicatedStorage, "Tide")
local Tide = world.server:require(tideModule)
Tide.start({ players = true })
local chars = {}
for i = 1, N do
	local p = world:addPlayer()
	chars[i] = world:spawnCharacter(p, CFrame.new(i * 6, 3, 0))
end
local client = world.clients[1]
local ct = client:require(client.ReplicatedStorage:FindFirstChild("Tide"))
ct.start()
for i = 2, N do
	-- other clients only need to be "ready" receivers: start them too
	local c = world.clients[i]
	c:require(c.ReplicatedStorage:FindFirstChild("Tide")).start()
end
local bots = {}
for k = 1, 20 do
	local m = world:spawnModel("bot" .. k, CFrame.new(k * 3, 3, 30), true)
	Tide.add(m, "Bot")
	bots[k] = m
end
for _ = 1, 30 do
	world:frame(DT)
end

local function req(env, root, ...)
	local inst = root
	for _, name in { ... } do
		inst = inst:FindFirstChild(name)
	end
	return env:require(inst)
end
local SState = req(world.server, tideModule, "Server", "State")
local Relay = req(world.server, tideModule, "Server", "Relay")
local Ticker = req(world.server, tideModule, "Server", "Ticker")
local Ring = req(world.server, tideModule, "Shared", "Ring")

-- capture one client's packets for the client-side measurement
local captured = {}
local fake = {
	FireClient = function(_self, player, b)
		if player == world.players[1] then
			local copy = buffer.create(buffer.len(b))
			buffer.copy(copy, 0, b, 0, buffer.len(b))
			table.insert(captured, copy)
		end
	end,
}
Relay.init(fake)

local FRAMES = 600
local now = world.now
local hists = {}
for i = 1, N do
	hists[i] = SState.hist[SState.bySlotModel[chars[i]]]
end
-- players upload at 98 Hz: ~1.63 samples per 60 Hz frame
local acc = 0
local t0 = os.clock()
local frameMarks = {}
for f = 1, FRAMES do
	now += DT
	acc += DT * 98
	while acc >= 1 do
		acc -= 1
		for i = 1, N do
			Ring.push(hists[i], now - acc / 98 - 0.03, i * 6 + math.sin(now + i) * 4, 3, math.cos(now + i) * 4, now, 0, 0, 0, 0, 1)
		end
	end
	for k, m in bots do
		m.HumanoidRootPart.CFrame = CFrame.new(k * 3 + math.sin(now + k), 3, 30)
	end
	Ticker.step(now, DT)
	Relay.step(now, DT)
	frameMarks[f] = #captured
end
local serverUs = (os.clock() - t0) / FRAMES * 1e6

-- client: replay the captured packets frame by frame
local CReceive = req(client, client.ReplicatedStorage:FindFirstChild("Tide"), "Client", "Receive")
local CRender = req(client, client.ReplicatedStorage:FindFirstChild("Tide"), "Client", "Render")
CRender.bulkMove = function() end
local cnow = world.now
local k = 1
t0 = os.clock()
for f = 1, FRAMES do
	cnow += DT
	while k <= frameMarks[f] do
		CReceive.packet(captured[k], cnow + 0.03)
		k += 1
	end
	CRender.step(cnow + 0.03, DT)
end
local clientUs = (os.clock() - t0) / FRAMES * 1e6
local bytes = 0
for _, b in captured do
	bytes += buffer.len(b)
end
print(string.format(
	"native=%s  server relay+tick (22 players @98Hz, 20 bots @30Hz, 22 receivers): %.1f us/frame;  client receive+render (21 players + 20 bots): %.1f us/frame;  bytes/s to one client: %.0f (%d packets/s)",
	tostring(__native()),
	serverUs,
	clientUs,
	bytes / (FRAMES * DT),
	#captured / (FRAMES * DT)
))
