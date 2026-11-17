-- Relay: every included sample reaches each receiver, self skipped, tiers/farEvery/cull,
-- hysteresis, budget, wide slots, split at MaxPacket.
return function(T)
	local DT = 1 / 60

	local function setup(opts, startOpts)
		local world = T.world(opts or { latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.start(startOpts or { players = true })
		local State = T.module(world, "Server", "State")
		local Codec = T.module(world, "Shared", "Codec")
		local remote = world.tideModule:FindFirstChild("TideU")
		local s = { world = world, Tide = State and Tide, State = State, Codec = Codec, sniffed = {}, packets = {} }
		-- client i: decode every relay packet it receives
		function s.sniff(i)
			local log = {}
			local sizes = {}
			s.sniffed[i] = log
			s.packets[i] = sizes
			world:replica(i, remote).OnClientEvent:Connect(function(b)
				local n = buffer.len(b)
				table.insert(sizes, n)
				assert(buffer.readu8(b, 0) == 1, "tag")
				local wide = buffer.readu8(b, 1) % 2 == 1
				local frameTime = buffer.readf64(b, 2)
				local pos = 10
				while pos < n do
					local slot
					if wide then
						slot = buffer.readu16(b, pos)
						pos += 2
					else
						slot = buffer.readu8(b, pos)
						pos += 1
					end
					local ticks
					pos, ticks = Codec.readDt(b, pos)
					local x, y, z, yaw, flags
					pos, x, y, z, yaw, flags = Codec.read(b, pos)
					table.insert(log, { slot = slot, t = frameTime - ticks * 0.0005, x = x, y = y, z = z, yaw = yaw, flags = flags, wide = wide })
				end
				assert(pos == n, "packet fully consumed")
			end)
		end
		function s.step(n)
			for _ = 1, n or 1 do
				world:frame(DT)
			end
		end
		return s
	end

	T.test("each receiver gets every sample of others exactly once; own entity skipped", function()
		local s = setup({ latency = 0.03, jitter = 0.01 })
		local world = s.world
		local chars, cts = {}, {}
		for i = 1, 3 do
			local p = world:addPlayer()
			chars[i] = world:spawnCharacter(p, CFrame.new(i * 10, 3, 0))
		end
		for i = 1, 3 do
			s.sniff(i)
			cts[i] = T.clientTide(world, i)
			cts[i].start()
		end
		for f = 1, 90 do
			local t = world.now + DT
			for i = 1, 3 do
				local hrp = world:replica(i, chars[i].HumanoidRootPart)
				hrp.CFrame = CFrame.new(i * 10 + math.sin(t * 2) * 5, 3, f * 0.1)
			end
			world:frame(DT)
		end
		-- let in-flight packets land without new uploads
		for i = 1, 3 do
			world.clients[i].paused = true
		end
		s.step(10)
		for j = 1, 3 do
			local slot = s.State.bySlotModel[chars[j]]
			local h = s.State.hist[slot]
			-- every history sample (still in the ring) after the receiver became ready
			local samples = {}
			for li = h.last - h.n + 1, h.last do
				local p = li % h.cap + 1
				samples[h.t[p]] = { x = h.x[p], z = h.z[p] }
			end
			for i = 1, 3 do
				local got = {}
				for _, rec in s.sniffed[i] do
					if rec.slot == slot then
						local key = nil
						for t in samples do
							if math.abs(t - rec.t) < 0.00026 then
								key = t
							end
						end
						T.check(key ~= nil, "record matches a history sample")
						T.check(got[key] == nil, "no duplicates")
						got[key] = true
						T.eq(rec.x, samples[key].x, "exact x")
						T.eq(rec.z, samples[key].z, "exact z")
					end
				end
				local count = 0
				for _ in got do
					count += 1
				end
				if i == j then
					T.eq(count, 0, "own entity never relayed back")
				else
					local total = 0
					for t in samples do
						if t > world.now - 1.3 then
							total += 1
						end
					end
					T.check(count >= total - 2, `receiver {i} got {count} of {total} samples of {j}`)
				end
			end
		end
	end)

	T.test("tiers: near every sample, mid/far every farEvery-th, culled nothing", function()
		local s = setup({ latency = 0.02 })
		local world = s.world
		local p = world:addPlayer()
		local char = world:spawnCharacter(p, CFrame.new(0, 3, 0))
		s.sniff(1)
		local ct = T.clientTide(world, 1)
		ct.start()
		s.step(2)
		-- Npc: near 60, far 200, cull 400, farEvery 2, 15 Hz
		local dists = { near = 20, mid = 120, far = 300, culled = 600 }
		local npcs = {}
		for name, d in dists do
			local m = world:spawnModel(name, CFrame.new(d, 3, 0), true)
			npcs[name] = { model = m, d = d }
			s.Tide.add(m, "Npc")
		end
		s.step(2)
		local start = #s.sniffed[1]
		for f = 1, 240 do
			for _, n in npcs do
				n.model.HumanoidRootPart.CFrame = CFrame.new(n.d, 3, math.sin(f * 0.05) * 3)
			end
			world:frame(DT)
		end
		s.step(5)
		local counts = {}
		for name, n in npcs do
			local slot = s.State.bySlotModel[n.model]
			local c = 0
			for k = start + 1, #s.sniffed[1] do
				if s.sniffed[1][k].slot == slot then
					c += 1
				end
			end
			counts[name] = c
		end
		-- 4 s at 15 Hz = ~60 samples
		T.check(counts.near >= 56, "near got " .. counts.near)
		T.check(math.abs(counts.mid - counts.near / 2) <= 2, `mid got {counts.mid} vs near {counts.near}`)
		T.check(math.abs(counts.far - counts.near / 2) <= 2, `far got {counts.far}`)
		T.eq(counts.culled, 0, "culled")
		local _ = char
	end)

	T.test("hysteresis around tier boundaries", function()
		local s = setup()
		local Relay = T.module(s.world, "Server", "Relay")
		local kind = { near = 60, far = 200, cull = 400 }
		T.eq(Relay.tierFor(kind, 50, nil), 1)
		T.eq(Relay.tierFor(kind, 61, 1), 1, "stays near just past the edge")
		T.eq(Relay.tierFor(kind, 65, 1), 2, "moves out beyond the hysteresis")
		T.eq(Relay.tierFor(kind, 57, 2), 2, "stays mid just inside")
		T.eq(Relay.tierFor(kind, 55, 2), 1, "moves in")
		T.eq(Relay.tierFor(kind, 402, 3), 3)
		T.eq(Relay.tierFor(kind, 405, 3), 4, "culled")
		T.eq(Relay.tierFor(kind, 397, 4), 4, "stays culled")
		T.eq(Relay.tierFor(kind, 395, 4), 3)
		T.eq(Relay.tierFor(kind, 1000, 1), 4, "big jumps go straight to the right tier")
		local players = { near = 100, far = 250, cull = math.huge }
		T.eq(Relay.tierFor(players, 1e6, 1), 3, "players are never culled")
	end)

	T.test("teleports reach mid/far receivers even off the farEvery grid", function()
		local s = setup()
		local world = s.world
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		s.sniff(1)
		T.clientTide(world, 1).start()
		s.step(2)
		local m = world:spawnModel("bot", CFrame.new(150, 3, 0), true)
		local h = s.Tide.add(m, "Npc")
		s.step(10)
		local slot = s.State.bySlotModel[m]
		local seen = 0
		for _ = 1, 6 do
			h:teleport(CFrame.new(150, 3, math.random(-50, 50)))
			s.step(7)
		end
		s.step(5)
		for _, rec in s.sniffed[1] do
			if rec.slot == slot and rec.flags % 2 == 1 then
				seen += 1
			end
		end
		T.eq(seen, 6, "all teleports delivered to a mid-tier receiver")
	end)

	T.test("split at MaxPacket and wide slots beyond 255", function()
		local s = setup({ latency = 0.01 })
		local world = s.world
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		s.sniff(1)
		T.clientTide(world, 1).start()
		s.step(2)
		local Config = T.module(world, "Shared", "Config")
		local models = {}
		for k = 1, 300 do
			local m = world:spawnModel("n" .. k, CFrame.new(k % 20, 3, k // 20), true)
			models[k] = m
			s.Tide.add(m, "Bot")
		end
		local start = #s.sniffed[1]
		local startPkts = #s.packets[1]
		for f = 1, 30 do
			for k, m in models do
				m.HumanoidRootPart.CFrame = CFrame.new(k % 20 + f * 0.1, 3, k // 20)
			end
			world:frame(DT)
		end
		s.step(5)
		local maxSize = 0
		for k = startPkts + 1, #s.packets[1] do
			maxSize = math.max(maxSize, s.packets[1][k])
		end
		T.check(maxSize <= Config.MaxPacket, "packet size " .. maxSize)
		T.check(#s.packets[1] - startPkts > 30, "frames were split into several packets")
		local wideSeen, slotsSeen = false, {}
		for k = start + 1, #s.sniffed[1] do
			local rec = s.sniffed[1][k]
			wideSeen = wideSeen or rec.wide
			slotsSeen[rec.slot] = (slotsSeen[rec.slot] or 0) + 1
		end
		T.check(wideSeen, "wide slot flag used")
		for _, m in models do
			local slot = s.State.bySlotModel[m]
			T.check((slotsSeen[slot] or 0) >= 14, "every bot delivered (30 frames at 30 Hz)")
		end
		T.eq(world.stats.oversize, 0)
	end)

	T.test("receiver byte budget drops far records first, never near", function()
		local s = setup({ latency = 0.01 })
		local world = s.world
		local Config = T.module(world, "Shared", "Config")
		Config.ReceiverBytesPerSecond = 4000
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		s.sniff(1)
		T.clientTide(world, 1).start()
		s.step(2)
		local near, far = {}, {}
		for k = 1, 20 do
			local m = world:spawnModel("near" .. k, CFrame.new(k, 3, 0), true)
			s.Tide.add(m, "Bot")
			near[k] = m
			local m2 = world:spawnModel("far" .. k, CFrame.new(300 + k, 3, 0), true)
			s.Tide.add(m2, "Bot")
			far[k] = m2
		end
		local start = #s.sniffed[1]
		for f = 1, 120 do
			for k = 1, 20 do
				near[k].HumanoidRootPart.CFrame = CFrame.new(k, 3, f * 0.1)
				far[k].HumanoidRootPart.CFrame = CFrame.new(300 + k, 3, f * 0.1)
			end
			world:frame(DT)
		end
		s.step(3)
		local nearSlots, farSlots = {}, {}
		for k = 1, 20 do
			nearSlots[s.State.bySlotModel[near[k]]] = true
			farSlots[s.State.bySlotModel[far[k]]] = true
		end
		local nNear, nFar = 0, 0
		for k = start + 1, #s.sniffed[1] do
			local rec = s.sniffed[1][k]
			if nearSlots[rec.slot] then
				nNear += 1
			elseif farSlots[rec.slot] then
				nFar += 1
			end
		end
		-- 2 s at 30 Hz x 20 = ~1200 near records (12 KB) is over the 8 KB budget: near still all sent
		T.check(nNear >= 1150, "near records " .. nNear)
		T.check(nFar < 100, "far records dropped under budget: " .. nFar)
		T.check(s.Tide.stats().budgetDropped > 0)
		Config.ReceiverBytesPerSecond = 40960
	end)

	T.test("idle server entities: keep-alive and rest marker before motion resumes", function()
		local s = setup({ latency = 0.01 })
		local world = s.world
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		s.sniff(1)
		T.clientTide(world, 1).start()
		s.step(2)
		local m = world:spawnModel("idle", CFrame.new(5, 3, 5), true)
		s.Tide.add(m, "Bot")
		local slot = s.State.bySlotModel[m]
		s.step(5)
		local start = #s.sniffed[1]
		s.step(120) -- 2 s idle
		local idle = 0
		for k = start + 1, #s.sniffed[1] do
			if s.sniffed[1][k].slot == slot then
				idle += 1
			end
		end
		T.check(idle >= 3 and idle <= 5, "keep-alives while idle: " .. idle)
		-- start moving: the last idle tick is sent first at the old position
		start = #s.sniffed[1]
		local moveT = world.now
		for f = 1, 10 do
			m.HumanoidRootPart.CFrame = CFrame.new(5 + f * 0.5, 3, 5)
			world:frame(DT)
		end
		s.step(3)
		local recs = {}
		for k = start + 1, #s.sniffed[1] do
			if s.sniffed[1][k].slot == slot then
				table.insert(recs, s.sniffed[1][k])
			end
		end
		T.check(#recs >= 3, "records after motion")
		T.eq(recs[1].x, 5, "rest marker at the old position")
		T.check(recs[1].t < moveT + 0.05, "rest marker is an idle tick")
		T.check(recs[2].x > 5, "then motion")
	end)
end
