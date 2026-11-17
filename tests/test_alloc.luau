-- Hot paths allocate nothing in steady state (exact VM allocation counts from the host).
-- Remotes are replaced by no-op fakes so only Tide's own work is measured.
return function(T)
	local DT = 1 / 60
	local N_PLAYERS = 12

	local function allocs(fn)
		local before = __alloc_count()
		fn()
		return __alloc_count() - before
	end

	local fakeRemote = {}
	function fakeRemote.FireClient(_self, _player, _b) end
	function fakeRemote.FireServer(_self, _b) end

	-- a running world: N players moving, clients rendering each other, 20 bots
	local world = T.world({ latency = 0.03, jitter = 0.005 })
	local Tide = T.serverTide(world)
	Tide.kind("Ghost", { rate = 30 })
	Tide.start({ players = true })
	local chars, cts = {}, {}
	for i = 1, N_PLAYERS do
		local p = world:addPlayer()
		chars[i] = world:spawnCharacter(p, CFrame.new(i * 6, 3, 0))
	end
	for i = 1, N_PLAYERS do
		cts[i] = T.clientTide(world, i)
		cts[i].start()
	end
	local bots = {}
	for k = 1, 20 do
		local m = world:spawnModel("bot" .. k, CFrame.new(k * 3, 3, 30), true)
		Tide.add(m, "Bot")
		bots[k] = m
	end
	local function move(t)
		for i = 1, N_PLAYERS do
			local hrp = world:replica(i, chars[i].HumanoidRootPart)
			hrp.CFrame = CFrame.new(i * 6 + math.sin(t + i) * 4, 3, math.cos(t * 1.3 + i) * 4)
		end
		for k, m in bots do
			m.HumanoidRootPart.CFrame = CFrame.new(k * 3 + math.sin(t + k), 3, 30)
		end
	end
	for _ = 1, 90 do
		move(world.now + DT)
		world:frame(DT)
	end

	local SState = T.module(world, "Server", "State")
	local Relay = T.module(world, "Server", "Relay")
	local Ticker = T.module(world, "Server", "Ticker")
	local Receive = T.module(world, "Server", "Receive")
	local Ring = T.module(world, "Shared", "Ring")
	local Codec = T.module(world, "Shared", "Codec")

	T.test("server relay + ticker: zero allocations per frame", function()
		Relay.init(fakeRemote)
		local now = world.now
		local function frame()
			now += DT
			-- every player gets one new sample (as if uploaded), bots move
			for i = 1, N_PLAYERS do
				local slot = SState.bySlotModel[chars[i]]
				Ring.push(SState.hist[slot], now - 0.03, i * 6 + math.sin(now), 3, 0, 0, 0, 0, 0, 0, 1)
			end
			for k, m in bots do
				m.HumanoidRootPart.CFrame = CFrame.new(k * 3 + math.sin(now + k), 3, 30)
			end
			Ticker.step(now, DT)
			Relay.step(now, DT)
		end
		for _ = 1, 30 do
			frame() -- warm up (lazy exact-size buffers, scratch growth)
		end
		local n = allocs(function()
			for _ = 1, 120 do
				frame()
			end
		end)
		-- bot CFrame writes above are the test's own (mock CFrame tables): 20 per frame
		local own = allocs(function()
			for k, m in bots do
				m.HumanoidRootPart.CFrame = CFrame.new(k * 3, 3, 30)
			end
		end)
		T.eq(n - own * 120, 0, "allocations in 120 server frames")
	end)

	T.test("server receive: zero allocations per upload", function()
		local slot = SState.bySlotModel[chars[1]]
		local player = world.players[1]
		local rx = SState.rx[player]
		local b = buffer.create(2 + 18)
		buffer.writeu8(b, 0, 2)
		buffer.writeu8(b, 1, 1)
		buffer.writeu16(b, 2, slot)
		local h = SState.hist[slot]
		local t = h.t[h.last % h.cap + 1]
		local x = h.x[h.last % h.cap + 1]
		local function one(k)
			buffer.writef64(b, 4, t + k * 0.01)
			Codec.write(b, 12, x + k * 0.01, 3, 0, 0, 0, 0, 0, 0, 1)
			rx.upTokens = 1e9
			Receive.handle(player, rx, b, t + k * 0.01, k)
		end
		for k = 1, 10 do
			one(k)
		end
		local before = SState.counters.samples
		local n = allocs(function()
			for k = 11, 500 do
				one(k)
			end
		end)
		T.eq(SState.counters.samples - before, 490, "all accepted")
		T.eq(n, 0, "allocations")
	end)

	T.test("client receive + render (apply none) + upload: zero allocations per frame", function()
		local CState = T.clientModule(world, 1, "Client", "State")
		local CReceive = T.clientModule(world, 1, "Client", "Receive")
		local CRender = T.clientModule(world, 1, "Client", "Render")
		local CUpload = T.clientModule(world, 1, "Client", "Upload")
		local Kinds = T.clientModule(world, 1, "Shared", "Kinds")
		local CCodec = T.clientModule(world, 1, "Shared", "Codec")
		CUpload.init(fakeRemote)
		-- render-only: switch every kind to apply "none" on this client
		for _, kind in Kinds.list do
			kind.apply = "none"
		end
		-- a relay packet with one record for each remote entity, rewritten per frame
		local slots = {}
		for k = 1, CState.count do
			local slot = CState.active[k]
			if not CState.mine[slot] then
				table.insert(slots, slot)
			end
		end
		local pkt = buffer.create(10 + #slots * 10)
		buffer.writeu8(pkt, 0, 1)
		buffer.writeu8(pkt, 1, 0)
		local now = world.now
		local function frame(f)
			now += DT
			buffer.writef64(pkt, 2, now - 0.03)
			local pos = 10
			for k, slot in slots do
				buffer.writeu8(pkt, pos, slot)
				buffer.writeu8(pkt, pos + 1, 0)
				CCodec.write(pkt, pos + 2, k + math.sin(f * 0.05), 3, f * 0.01, 0, 0, 0, 0, 0, 1)
				pos += 10
			end
			CReceive.packet(pkt, now)
			CRender.step(now, DT)
			CUpload.step(now)
		end
		for f = 1, 60 do
			frame(f)
		end
		local n = allocs(function()
			for f = 61, 300 do
				frame(f)
			end
		end)
		T.eq(n, 0, "allocations in 240 client frames")
		T.check(CState.counters.records > 0)
		-- with apply = "cframe" the only allocations are the CFrames themselves
		for _, kind in Kinds.list do
			kind.apply = "cframe"
		end
		CRender.bulkMove = function() end
		for f = 301, 320 do
			frame(f)
		end
		local perCF = allocs(function()
			local _ = CFrame.new(1, 2, 3, 0, 0, 0, 1)
		end)
		local m = allocs(function()
			for f = 321, 380 do
				frame(f)
			end
		end)
		T.eq(m, 60 * #slots * perCF, "only CFrame allocations when applying")
		CRender.bulkMove = nil
	end)

	T.test("lock + velocity, client upload (moving and idle), sampleInfo(into): zero allocations", function()
		local Lock = T.module(world, "Server", "Lock")
		local perCF = allocs(function()
			local _ = CFrame.new(1, 2, 3, 0, 0, 0, 1)
		end)
		-- server: every locked player gets a new sample each frame -> locker CFrame + velocity
		local now = world.now
		for i = 1, N_PLAYERS do
			now = math.max(now, Ring.newestT(SState.hist[SState.bySlotModel[chars[i]]]))
		end
		local function serverFrame(f)
			now += DT
			for i = 1, N_PLAYERS do
				local slot = SState.bySlotModel[chars[i]]
				Ring.push(SState.hist[slot], now, i * 6 + f * 0.1, 3, 0, 0, 0, 0, 0, 0, 1)
			end
			Lock.step()
		end
		for f = 1, 10 do
			serverFrame(f)
		end
		local n = allocs(function()
			for f = 11, 70 do
				serverFrame(f)
			end
		end)
		T.eq(n, 60 * N_PLAYERS * perCF, "only the locker CFrames")

		-- client 2: its character moves (upload path), then stands still (skip path)
		local CUpload = T.clientModule(world, 2, "Client", "Upload")
		local CClient = T.clientModule(world, 2, "Client", "Client")
		CUpload.init(fakeRemote)
		local hrp = world:replica(2, chars[2].HumanoidRootPart)
		local poses = {}
		for f = 1, 200 do
			poses[f] = CFrame.new(f * 0.1, 3, 0)
		end
		local t = world.now
		local function clientFrame(f)
			t += DT
			if f <= 200 then
				hrp.CFrame = poses[f]
			end
			CUpload.step(t)
		end
		for f = 1, 20 do
			clientFrame(f)
		end
		local m = allocs(function()
			for f = 21, 400 do
				clientFrame(f)
			end
		end)
		T.eq(m, 0, "upload: moving then idle")

		local into = {}
		local model = world:replica(2, chars[1])
		CClient.sampleInfo(model, into)
		local k = allocs(function()
			for _ = 1, 100 do
				CClient.sampleInfo(model, into)
			end
		end)
		T.eq(k, 0, "sampleInfo with a reused table")
	end)
end
