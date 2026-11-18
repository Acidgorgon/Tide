-- v0.4 per-entity origin (handle:setOrigin): entities far from Config.origin keep the compact
-- record, clients decode exactly the server's history, later changes, late joiners, uploads.
return function(T)
	local DT = 1 / 60

	local function setup(latency)
		local world = T.world({ latency = latency or 0.03 })
		local Tide = T.serverTide(world)
		Tide.kind("Body", { rate = 30, rotation = "full", farEvery = 1 })
		Tide.start({ players = false, origin = Vector3.new(6800, 0, 0), lockPlayers = false, teleportOnWrite = false })
		local State = T.module(world, "Server", "State")
		local Codec = T.module(world, "Shared", "Codec")
		local s = { world = world, Tide = Tide, State = State, sizes = {}, cts = {} }
		local remote = world.tideModule:FindFirstChild("TideU")
		function s.addPlayer()
			local i = #world.players + 1
			world:addPlayer()
			local sizes = {}
			s.sizes[i] = sizes
			world:replica(i, remote).OnClientEvent:Connect(function(b)
				local n = buffer.len(b)
				local pos = 10
				while pos < n do
					local slot = buffer.readu8(b, pos)
					local a = pos
					pos = Codec.readDt(b, pos + 1)
					pos += Codec.sizeAt(b, pos)
					sizes[slot] = sizes[slot] or {}
					table.insert(sizes[slot], pos - a)
				end
			end)
			s.cts[i] = T.clientTide(world, i)
			s.cts[i].start()
			return i
		end
		function s.step(n, each)
			for f = 1, n or 1 do
				if each then
					each(f)
				end
				world:frame(DT)
			end
		end
		return s
	end

	-- the client ring holds exactly the server's history samples (same times, same positions)
	local function sameAsServer(s, i, model)
		local slot = s.State.bySlotModel[model]
		local h = s.State.hist[slot]
		local byT = {}
		for li = h.last - h.n + 1, h.last do
			local p = li % h.cap + 1
			byT[math.round(h.t[p] / 0.0005)] = p
		end
		local CState = T.clientModule(s.world, i, "Client", "State")
		local r = CState.ring[CState.bySlotModel[s.world:replica(i, model)]]
		local matched = 0
		for li = r.last - r.n + 1, r.last do
			local q = li % r.cap + 1
			local p = byT[math.round(r.t[q] / 0.0005)]
			if p then
				T.eq(r.x[q], h.x[p], "x as the server keeps it")
				T.eq(r.y[q], h.y[p], "y")
				T.eq(r.z[q], h.z[p], "z")
				matched += 1
			end
		end
		return matched
	end

	T.test("venues 1600 studs apart from x = 6000: each body at its own origin keeps the 14 B record", function()
		local s = setup()
		s.addPlayer()
		local bodies = {}
		for v = 0, 4 do
			local cx = 6000 + v * 1600
			local m = s.world:spawnModel("b" .. v, CFrame.new(cx + 30, 3, 10), true)
			local h = s.Tide.add(m, "Body")
			h:setOrigin(Vector3.new(cx, 0, 0)) -- same frame as the add: no grace needed
			bodies[v] = { m = m, cx = cx }
		end
		local control = s.world:spawnModel("control", CFrame.new(6000 + 4 * 1600 + 30, 3, 10), true)
		s.Tide.add(control, "Body")
		local function move(f)
			for v, b in bodies do
				b.m.HumanoidRootPart.CFrame = CFrame.new(b.cx + 30 + f * 0.13, 3 + math.sin(f * 0.1), 10 + v) * CFrame.Angles(0, f * 0.05, 0.2)
			end
			control.HumanoidRootPart.CFrame = CFrame.new(6000 + 4 * 1600 + 30 + f * 0.13, 3, 10)
		end
		s.step(90, move)
		for v, b in bodies do
			local slot = s.State.bySlotModel[b.m]
			for _, n in s.sizes[1][slot] do
				T.eq(n, 14, `venue {v}: compact record with full rotation`)
			end
			T.check(sameAsServer(s, 1, b.m) > 20, "client decodes the server's samples exactly")
			local cf = s.cts[1].drawn(s.world:replica(1, b.m))
			T.check(math.abs(cf.X - (b.cx + 30)) < 20, "drawn in its venue")
		end
		for _, n in s.sizes[1][s.State.bySlotModel[control]] do
			T.eq(n, 26, "no origin, 6400 studs from Config.origin: absolute form (v0.3)")
		end
		-- Tide.at on the server matches what was sampled
		local at = s.Tide.at(bodies[3].m, s.world.now - 0.5)
		T.check(math.abs(at.X - (bodies[3].cx + 30 + 60 * 0.13)) < 1, "server rewind in the venue")
		T.check(not pcall(function()
			s.Tide.handle(bodies[1].m):setOrigin(Vector3.new(0 / 0, 0, 0))
		end), "NaN origin rejected")
	end)

	T.test("a later origin change: absolute records for a second, then compact; never decoded wrong", function()
		local s = setup(0.08)
		s.addPlayer()
		local m = s.world:spawnModel("b", CFrame.new(9000, 3, 0), true)
		local h = s.Tide.add(m, "Body")
		local slot = s.State.bySlotModel[m]
		local worst = 0
		local view = s.world:replica(1, m)
		local function move(f)
			m.HumanoidRootPart.CFrame = CFrame.new(9000 + f * 0.1, 3, 0)
			local cf = s.cts[1].drawn(view)
			if cf then
				worst = math.max(worst, math.abs(cf.Y - 3))
			end
		end
		s.step(30, move)
		local before = #s.sizes[1][slot]
		h:setOrigin(Vector3.new(9000.3, 0, 0)) -- snapped to the 1/64 grid of Config.origin
		T.eq(s.State.ox[slot], 9000.296875, "on Config.origin's 1/64 grid")
		s.step(120, function(f)
			move(30 + f)
		end)
		local sizes = s.sizes[1][slot]
		T.eq(sizes[before + 1], 26, "absolute right after the change")
		T.eq(sizes[#sizes], 14, "compact after the grace")
		T.check(sameAsServer(s, 1, m) > 20, "exact")
		T.check(worst < 0.01, "never drawn off the path: " .. worst)
		-- a late joiner gets the origin with the ADD
		s.addPlayer()
		s.step(60, function(f)
			move(150 + f)
		end)
		T.check(sameAsServer(s, 2, m) > 20, "late joiner decodes exactly")
		local s2 = s.sizes[2][slot]
		T.eq(s2[#s2], 14)
		-- back to Config.origin
		h:setOrigin(nil)
		s.step(90, function(f)
			move(210 + f)
		end)
		T.eq(s.State.ox[slot], nil)
		T.check(sameAsServer(s, 1, m) > 20, "exact after clearing")
	end)

	T.test("client-owned entity with its own origin: uploads accepted, history as receivers decode it", function()
		local s = setup(0.03)
		s.addPlayer()
		s.addPlayer()
		local m = s.world:spawnModel("b", CFrame.new(12000, 3, 0))
		local h = s.Tide.add(m, "Body")
		h:setOrigin(Vector3.new(12000, 0, 0))
		h:setOwner(s.world.players[1])
		s.step(10)
		local rep = s.world:replica(1, m).HumanoidRootPart
		s.step(90, function(f)
			rep.CFrame = CFrame.new(12000 + f * 0.1234567, 3.01, 0.5)
		end)
		T.eq(s.Tide.stats().speed, 0)
		T.check(s.Tide.stats().samples > 30, "uploads accepted")
		T.check(sameAsServer(s, 2, m) > 20, "receiver decodes the server's history exactly")
	end)
end
