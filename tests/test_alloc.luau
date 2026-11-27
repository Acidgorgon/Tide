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

	-- Smallest count over up to 4 windows. In windows where the test's own mock CFrames allocate, the
	-- GC runs mid-window; it can shrink a coroutine's Lua stack, and the next deep call regrows it
	-- (one VM allocation, not garbage from Tide). A real per-frame allocation shows in every window.
	local function steady(expected: number, measure: () -> number): number
		local best = math.huge
		for _ = 1, 4 do
			best = math.min(best, measure())
			if best <= expected then
				break
			end
		end
		return best
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
		-- bot CFrame writes above are the test's own (mock CFrame tables): 20 per frame
		local own = allocs(function()
			for k, m in bots do
				m.HumanoidRootPart.CFrame = CFrame.new(k * 3, 3, 30)
			end
		end)
		local n = steady(0, function()
			return allocs(function()
				for _ = 1, 120 do
					frame()
				end
			end) - own * 120
		end)
		T.eq(n, 0, "allocations in 120 server frames")
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
		local f0 = 10
		local n = steady(60 * N_PLAYERS * perCF, function()
			return allocs(function()
				for _ = 1, 60 do
					f0 += 1
					serverFrame(f0)
				end
			end)
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

	-- v0.5: a kind with velocity (4 balls at 60 Hz, a bump every 10th frame), its own world
	T.test("velocity kinds: server tick + bump + relay, client receive + sample: zero allocations", function()
		local w2 = T.world({ latency = 0.03 })
		local Tide2 = T.serverTide(w2)
		Tide2.kind("Ball", { velocity = true, rotation = "full", rate = 60, near = math.huge, apply = "none" })
		Tide2.start({ players = true })
		for i = 1, 2 do
			w2:spawnCharacter(w2:addPlayer(), CFrame.new(i * 6, 3, 0))
		end
		local ct = T.clientTide(w2, 1)
		ct.start()
		T.clientTide(w2, 2).start()
		local balls = {}
		for k = 1, 4 do
			balls[k] = w2:spawnModel("ball" .. k, CFrame.new(k * 4, 5, 20), false)
			Tide2.add(balls[k], "Ball")
		end
		-- poses made up front: the frames below allocate nothing of their own but what `own` counts
		local FRAMES = 400
		local poses = {}
		for f = 1, FRAMES do
			poses[f] = {}
			for k = 1, 4 do
				poses[f][k] = CFrame.new(k * 4 + f * 0.11, 5 + math.sin(f * 0.1 + k) * 3, 20) * CFrame.Angles(f * 0.05, k, 0)
			end
		end
		local function write(f)
			for k = 1, 4 do
				local root = balls[k].HumanoidRootPart
				root.CFrame = poses[f][k]
				root.AssemblyLinearVelocity = Vector3.new(6.6 + (f // 10) % 3, 18 * math.cos(f * 0.1 + k), 0)
				root.AssemblyAngularVelocity = Vector3.new(3, k, (f // 10) % 5)
			end
		end
		for f = 1, 30 do
			write(f)
			w2:frame(DT)
		end
		local S2 = T.module(w2, "Server", "State")
		local Relay2 = T.module(w2, "Server", "Relay")
		local Ticker2 = T.module(w2, "Server", "Ticker")
		local Server2 = T.module(w2, "Server", "Server")
		Relay2.init(fakeRemote)
		local now = w2.now
		local function frame(f)
			now += DT
			write(f)
			if f % 10 == 0 then
				-- as game code after a kick: outside the physics step, sampled at once (1 ms after
				-- the newest sample), then the tick below samples the frame's pose
				Server2.bump(balls[1 + (f // 10) % 4])
			end
			Ticker2.step(now, DT)
			Relay2.step(now, DT)
		end
		for f = 31, 60 do
			frame(f)
		end
		local own = allocs(function()
			write(61)
		end)
		local before = S2.counters.velocitySamples
		local bumps = S2.counters.bumps
		local n = steady(0, function()
			return allocs(function()
				for f = 61, 180 do
					frame(f)
				end
			end) - own * 120
		end)
		T.eq(n, 0, "allocations in 120 server frames with velocity entities")
		T.check(S2.counters.velocitySamples - before >= 4 * 120, "every ball sampled and encoded each frame")
		T.check(S2.counters.bumps - bumps >= 12, "bumps taken")

		-- client: a packet of velocity records per frame, then the render step and direct samples
		local CState = T.clientModule(w2, 1, "Client", "State")
		local CReceive = T.clientModule(w2, 1, "Client", "Receive")
		local CRender = T.clientModule(w2, 1, "Client", "Render")
		local CCodec = T.clientModule(w2, 1, "Shared", "Codec")
		local CInterp = T.clientModule(w2, 1, "Shared", "Interp")
		-- render-only (the other player's character would cost its CFrame)
		for _, kind in T.clientModule(w2, 1, "Shared", "Kinds").list do
			kind.apply = "none"
		end
		local slots = {}
		for k = 1, 4 do
			slots[k] = CState.bySlotModel[w2:replica(1, balls[k])]
			T.check(CState.ring[slots[k]].vel, "the client's ring keeps velocity")
		end
		local pkt = buffer.create(10 + 4 * 28)
		buffer.writeu8(pkt, 0, 1)
		buffer.writeu8(pkt, 1, 0)
		local ct0 = w2.now + 5
		local function clientFrame(f)
			local t = ct0 + f * DT
			buffer.writef64(pkt, 2, t - 0.03)
			local pos = 10
			for k, slot in slots do
				buffer.writeu8(pkt, pos, 0)
				buffer.writeu8(pkt, pos + 2, slot)
				buffer.writeu8(pkt, pos + 3, 0)
				local at = CCodec.write(pkt, pos + 4, k + f * 0.1, 3 + math.sin(f * 0.1), 0, 0, 2, 0, math.sin(f * 0.01), 0, math.cos(f * 0.01))
				local hdr
				at, hdr = CCodec.writeMotion(pkt, at, 6, 18 * math.cos(f * 0.1) + 0.5, 1, 2, 0.5, 1)
				buffer.writeu8(pkt, pos + 1, hdr + (if f % 10 == 0 then CCodec.CUT else 0))
				T.eq(at - pos, 28)
				pos = at
			end
			CReceive.packet(pkt, t)
			CRender.step(t, DT)
			for _, slot in slots do
				CInterp.sample(CState.ring[slot], t - 0.05, 0)
				CInterp.sample(CState.ring[slot], t + 0.02, 0.1)
			end
		end
		for f = 1, 60 do
			clientFrame(f)
		end
		local records = CState.counters.velocityRecords
		local m = allocs(function()
			for f = 61, 300 do
				clientFrame(f)
			end
		end)
		T.eq(m, 0, "allocations in 240 client frames with velocity records")
		T.eq(CState.counters.velocityRecords - records, 240 * 4, "all read")
		T.eq(CState.counters.badPacket, 0)
	end)

	T.test("stop repeats, Tide.flush (with and without a bump) and Tide.span: zero allocations", function()
		local w3 = T.world({ latency = 0.03 })
		local Tide3 = T.serverTide(w3)
		Tide3.kind("Ball", { velocity = true, rotation = "full", rate = 60, near = math.huge, apply = "none", keepAlive = 0.25 })
		Tide3.kind("Crate", { rate = 60, restRepeats = 3 })
		Tide3.start({ players = true })
		for i = 1, 2 do
			w3:spawnCharacter(w3:addPlayer(), CFrame.new(i * 6, 3, 0))
		end
		local ct = T.clientTide(w3, 1)
		ct.start()
		T.clientTide(w3, 2).start()
		local things = {}
		for k = 1, 6 do
			things[k] = w3:spawnModel("thing" .. k, CFrame.new(k * 4, 5, 20), false)
			things[k].HumanoidRootPart.AssemblyAngularVelocity = Vector3.zero
			Tide3.add(things[k], if k <= 3 then "Ball" else "Crate")
		end
		-- every thing moves for 4 frames and rests for 9 (a stop sample, its repeats and, for
		-- the balls, a keep-alive now and then), out of step with one another
		local FRAMES = 420
		local poses, vels = {}, {}
		for f = 1, FRAMES do
			poses[f], vels[f] = {}, {}
			for k = 1, 6 do
				local phase = (f + k * 2) % 13
				local travelled = ((f + k * 2) // 13) * 4 + math.min(phase, 4)
				poses[f][k] = CFrame.new(k * 4 + travelled * 0.3, 5, 20)
				vels[f][k] = if phase >= 1 and phase < 4 then Vector3.new(18, 0, 0) else Vector3.zero
			end
		end
		local function write(f)
			for k = 1, 6 do
				local root = things[k].HumanoidRootPart
				root.CFrame = poses[f][k]
				root.AssemblyLinearVelocity = vels[f][k]
			end
		end
		for f = 1, 30 do
			write(f)
			w3:frame(DT)
		end
		local S3 = T.module(w3, "Server", "State")
		local Relay3 = T.module(w3, "Server", "Relay")
		local Ticker3 = T.module(w3, "Server", "Ticker")
		local Server3 = T.module(w3, "Server", "Server")
		Relay3.init(fakeRemote)
		local kicks = {}
		for i = 0, 4 do
			kicks[i] = Vector3.new(0, 30 + i, 0)
		end
		local now = w3.now
		local spans, flushed = 0, 0
		-- `tide` = false: the frame's writes alone (what the mock itself allocates for them)
		local function frame(f, tide)
			now += DT
			write(f)
			if tide then
				Ticker3.step(now, DT)
				Relay3.step(now, DT)
				-- after the frame's relay, as a Heartbeat connection: nothing bumped, then a kick
				flushed += Server3.flush()
			end
			if f % 7 == 0 then
				local ball = things[1 + (f // 7) % 3]
				ball.HumanoidRootPart.AssemblyLinearVelocity = kicks[f % 5]
				if tide then
					Server3.bump(ball)
					flushed += Server3.flush()
					flushed += Server3.flush()
				end
			end
			if not tide then
				return
			end
			for k = 1, 6 do
				local oldest, newest = Tide3.span(things[k])
				if oldest <= newest then
					spans += 1
				end
			end
		end
		for f = 31, 390 do
			frame(f, true)
		end
		-- the same 300 frames again and again: each pass starts from the last one's end
		local function pass(tide)
			return allocs(function()
				for f = 91, 390 do
					frame(f, tide)
				end
			end)
		end
		pass(true)
		local own = pass(false)
		local repeats, flushes = S3.counters.restRepeats, S3.counters.flushes
		flushed, spans = 0, 0
		local n = steady(0, function()
			return pass(true) - own
		end)
		T.eq(n, 0, "allocations in 300 server frames with stops, repeats, flushes and spans")
		T.check(S3.counters.restRepeats - repeats >= 100, "repeats sent: " .. S3.counters.restRepeats - repeats)
		T.check(S3.counters.flushes - flushes >= 40 and flushed >= 40, "flushes that sent: " .. flushed)
		T.check(spans >= 6 * 300, "spans read")
		T.eq(S3.counters.errors, 0)

		-- client: every packet twice (the second time each record is a copy), and Tide.span
		local CState = T.clientModule(w3, 1, "Client", "State")
		local CReceive = T.clientModule(w3, 1, "Client", "Receive")
		local CCodec = T.clientModule(w3, 1, "Shared", "Codec")
		local views, slots = {}, {}
		for k = 1, 6 do
			views[k] = w3:replica(1, things[k])
			slots[k] = CState.bySlotModel[views[k]]
		end
		local draft = buffer.create(10 + 6 * 32)
		buffer.writeu8(draft, 0, 1)
		buffer.writeu8(draft, 1, 0)
		local pkt: buffer? = nil -- the draft at its exact size (the same every frame)
		local ct0 = w3.now + 5
		local function clientFrame(f)
			local t = ct0 + f * DT
			buffer.writef64(draft, 2, t - 0.03)
			local pos = 10
			for k, slot in slots do
				if k <= 3 then
					buffer.writeu8(draft, pos, 0)
					buffer.writeu8(draft, pos + 1, 0)
					pos += 2
				end
				buffer.writeu8(draft, pos, slot)
				buffer.writeu8(draft, pos + 1, 0)
				pos = CCodec.write(draft, pos + 2, k + (f // 3) * 0.1, 3, 0, 0, if k <= 3 then 2 else 0, 0, 0, 0, 1)
			end
			if pkt == nil or buffer.len(pkt) ~= pos then
				pkt = buffer.create(pos)
			end
			buffer.copy(pkt :: buffer, 0, draft, 0, pos)
			CReceive.packet(pkt, t)
			CReceive.packet(pkt, t + 0.004)
			for k = 1, 6 do
				local oldest, newest = ct.span(views[k])
				if oldest <= newest then
					spans += 1
				end
			end
		end
		for f = 1, 60 do
			clientFrame(f)
		end
		local copies, stored = CState.counters.repeats, CState.counters.records
		local m = allocs(function()
			for f = 61, 300 do
				clientFrame(f)
			end
		end)
		T.eq(m, 0, "allocations in 240 client frames, each packet twice")
		T.eq(CState.counters.repeats - copies, 240 * 6, "the second of each was six copies")
		T.eq(CState.counters.records - stored, 240 * 12)
		T.eq(CState.counters.badPacket, 0)
	end)
end
