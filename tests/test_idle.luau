-- Idle streams and kind-shared buffers:
--   * far entities (every farEvery-th sample) do not inflate a kind's shared delay
--   * idle client uploads: stop sample, keep-alives, rest marker; receivers neither
--     drift nor count idle gaps as need; sampleInfo.idle
--   * idle server entities: stop sample (no overshoot), idle markers reach far receivers
return function(T)
	local DT = 1 / 60

	local function newWorld(net)
		local world = T.world(net or { latency = 0.03, jitter = 0.003, seed = 11 })
		local Tide = T.serverTide(world)
		return world, Tide
	end

	-- near bot at x = 10; `far` bots at x = 300 (far tier), all moving along z
	local function sharedDelay(far: number)
		local world, Tide = newWorld()
		Tide.kind("Drone", { rate = 30, farEvery = 3, buffer = 0.02 })
		Tide.start({ players = true })
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		local ct = T.clientTide(world, 1)
		ct.start()
		local bots = {}
		local near = world:spawnModel("near", CFrame.new(10, 3, 0), true)
		Tide.add(near, "Drone")
		bots[1] = { m = near, x = 10 }
		for k = 1, far do
			local m = world:spawnModel("far" .. k, CFrame.new(300, 3, k * 5), true)
			Tide.add(m, "Drone")
			bots[k + 1] = { m = m, x = 300, z = k * 5 }
		end
		local t0 = world.now
		local worstFar = 0
		for f = 1, 240 do
			local t = world.now + DT - t0
			for _, b in bots do
				b.m.HumanoidRootPart.CFrame = CFrame.new(b.x, 3, (b.z or 0) + 6 * t)
			end
			world:frame(DT)
			if f > 120 and far > 0 then
				-- far bots: drawn on their (linear) path despite the near-sized delay
				local view = world:replica(1, bots[2].m)
				local cf = ct.drawn(view)
				local delay = ct.delay(view)
				local want = bots[2].z + 6 * (world.now - delay - t0)
				worstFar = math.max(worstFar, math.abs(cf.Z - want))
			end
		end
		return ct.delay(world:replica(1, near)), worstFar
	end

	T.test("kind-shared buffer: far entities (farEvery) do not inflate the near delay", function()
		local alone = sharedDelay(0)
		local mixed, worstFar = sharedDelay(12)
		T.check(alone > 0.03 and alone < 0.12, "near-only delay " .. alone)
		T.check(math.abs(mixed - alone) < 0.008, string.format("delay with 12 far bots %.4f vs %.4f alone", mixed, alone))
		T.check(worstFar < 0.25, "far bots drawn on their path: " .. worstFar)
	end)

	-- client 1 owns a character that runs, stands still, runs again; client 2 watches
	local function owned()
		local world, Tide = newWorld({ latency = 0.03, jitter = 0.002, seed = 5 })
		Tide.start({ players = true })
		local chars, cts = {}, {}
		for i = 1, 2 do
			chars[i] = world:spawnCharacter(world:addPlayer(), CFrame.new(i * 10, 3, 0))
		end
		for i = 1, 2 do
			cts[i] = T.clientTide(world, i)
			cts[i].start()
		end
		local root = world:replica(1, chars[1]):FindFirstChild("HumanoidRootPart")
		return world, Tide, chars, cts, root
	end

	T.test("idle client uploads: stop sample, keep-alives only, no drift, no need, sampleInfo.idle", function()
		local world, Tide, chars, cts, root = owned()
		local x = 10
		for _ = 1, 60 do
			x += 16 * DT
			root.CFrame = CFrame.new(x, 3, 0)
			world:frame(DT)
		end
		local stopX = x
		local up0 = cts[1].stats()
		local in0 = Tide.stats().inBytes
		local view = world:replica(2, chars[1])
		local Cs = T.clientModule(world, 2, "Client", "State")
		local src = Cs.src[Cs.bySlotModel[view]]
		-- a few frames for the stop to reach the observer, then 3 s standing
		for _ = 1, 15 do
			world:frame(DT)
		end
		local needs0 = src.head + src.count * 1000
		local delay0 = cts[2].delay(view)
		local worst = 0
		local info = {}
		for _ = 1, 180 do
			world:frame(DT)
			local cf = cts[2].drawn(view)
			worst = math.max(worst, math.abs(cf.X - stopX))
			cts[2].sampleInfo(view, info)
			T.eq(info.idle, true, "observer sees the entity at rest")
		end
		local up1 = cts[1].stats()
		local sent = up1.uploads - up0.uploads
		T.check(sent <= 9, "uploads while standing 3.25 s: " .. sent)
		T.check(up1.uploadSkipped - up0.uploadSkipped > 150, "skipped: " .. (up1.uploadSkipped - up0.uploadSkipped))
		local bytes = Tide.stats().inBytes - in0
		T.check(bytes < 400, "idle inbound bytes in 3.25 s: " .. bytes)
		T.check(worst < 0.03, "no extrapolation drift while idle: " .. worst)
		T.eq(src.head + src.count * 1000, needs0, "keep-alives add no need")
		T.near(cts[2].delay(view), delay0, 0.002, "delay unchanged by idle gaps")
		T.check(info.age > 0.0, "age")
		-- server: the newest samples repeat the pose (velocity 0)
		T.eq(Tide.velocity(chars[1]), Vector3.new(0, 0, 0))
	end)

	T.test("idle client resumes: rest marker first, observer follows the motion without smear", function()
		local world, _, chars, cts, root = owned()
		local x = 10
		for _ = 1, 30 do
			x += 16 * DT
			root.CFrame = CFrame.new(x, 3, 0)
			world:frame(DT)
		end
		for _ = 1, 60 do
			world:frame(DT)
		end
		local SState = T.module(world, "Server", "State")
		local slot = SState.bySlotModel[chars[1]]
		local h = SState.hist[slot]
		local lastBefore = h.last
		local stopX = x
		local resumeT = world.now
		local view = world:replica(2, chars[1])
		local worst = 0
		local t0 = world.now
		for f = 1, 60 do
			x += 16 * DT
			root.CFrame = CFrame.new(x, 3, 0)
			world:frame(DT)
			if f > 20 then
				-- where the owner was at the observer's render time
				local rt = world.now - cts[2].delay(view)
				local want = if rt <= t0 then stopX else stopX + 16 * (rt - t0)
				worst = math.max(worst, math.abs(cts[2].drawn(view).X - want))
			end
		end
		-- server history right after the idle period: rest marker (old pose, a skipped tick), then motion
		local p1 = (lastBefore + 1) % h.cap + 1
		local p2 = (lastBefore + 2) % h.cap + 1
		T.near(h.x[p1], stopX, 1 / 64, "rest marker at the standing pose")
		T.check(h.t[p1] > resumeT - 0.05 and h.t[p1] <= resumeT + DT, "rest marker is the last idle tick")
		T.check(h.x[p2] > stopX, "then the motion")
		T.check(h.t[p2] - h.t[p1] < 0.03, "one interval apart")
		T.check(worst < 0.35, "observer follows the restart: " .. worst)
	end)

	T.test("server-owned stop: stop sample, no overshoot; idle markers reach far receivers", function()
		local world, Tide = newWorld({ latency = 0.03, jitter = 0.002, seed = 9 })
		Tide.start({ players = true })
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		local ct = T.clientTide(world, 1)
		ct.start()
		local nearBot = world:spawnModel("near", CFrame.new(10, 3, 0), true)
		Tide.add(nearBot, "Bot")
		local farBot = world:spawnModel("far", CFrame.new(400, 3, 0), true)
		Tide.add(farBot, "Bot")
		local x = 10
		for _ = 1, 45 do
			x += 16 * DT
			nearBot.HumanoidRootPart.CFrame = CFrame.new(x, 3, 0)
			world:frame(DT)
		end
		local view = world:replica(1, nearBot)
		local worst = 0
		for _ = 1, 60 do
			world:frame(DT)
			worst = math.max(worst, ct.drawn(view).X - x)
		end
		T.check(worst < 0.05, "no overshoot past the stop: " .. worst)
		local SState = T.module(world, "Server", "State")
		local h = SState.hist[SState.bySlotModel[nearBot]]
		-- stop sample: an unchanged sample one interval after the last moving one
		local found = false
		for i = h.last - h.n + 2, h.last do
			local a, b = i % h.cap + 1, (i - 1) % h.cap + 1
			if h.x[a] == h.x[b] and h.x[b] ~= h.x[(i - 2) % h.cap + 1] then
				T.check(h.t[a] - h.t[b] < 0.05, "stop sample follows at the tick rate")
				found = true
			end
		end
		T.check(found, "stop sample in history")
		-- the far idle bot: keep-alives arrive even though it is on the farEvery grid
		for _ = 1, 120 do
			world:frame(DT)
		end
		local Cs = T.clientModule(world, 1, "Client", "State")
		local r = Cs.ring[Cs.bySlotModel[world:replica(1, farBot)]]
		local maxGap = 0
		for i = r.last - r.n + 2, r.last do
			maxGap = math.max(maxGap, r.t[i % r.cap + 1] - r.t[(i - 1) % r.cap + 1])
		end
		T.check(r.n >= 4, "far idle samples: " .. r.n)
		T.check(maxGap < 0.6, "far receiver gap while idle: " .. maxGap)
		T.eq(ct.sampleInfo(world:replica(1, farBot)).idle, true)
	end)
end
