-- Regressions from the round-4 review: upload validation exploits (silence banking,
-- back-dated bursts, tolerance spam, history flush, forged extrapolation), TELEPORT
-- ordering, rotation change after start, streamed roots, receivers without a
-- character, teleportOnWrite velocity.
return function(T)
	local DT = 1 / 60

	local function setup(nPlayers, opts)
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		local o = opts or {}
		o.players = true
		Tide.start(o)
		local State = T.module(world, "Server", "State")
		local Codec = T.module(world, "Shared", "Codec")
		local players, chars = {}, {}
		for i = 1, nPlayers do
			players[i] = world:addPlayer()
			chars[i] = world:spawnCharacter(players[i], CFrame.new(i * 10, 3, 0))
		end
		local remote = world.tideModule:FindFirstChild("TideU")
		local s = { world = world, Tide = Tide, State = State, chars = chars, players = players }
		function s.send(i, b)
			world:replica(i, remote):FireServer(b)
		end
		-- records = { {slot, stamp, x, y, z} }
		function s.upload(records)
			local b = buffer.create(2 + #records * 40)
			buffer.writeu8(b, 0, 2)
			buffer.writeu8(b, 1, #records)
			local pos = 2
			for _, r in records do
				buffer.writeu16(b, pos, r[1])
				buffer.writef64(b, pos + 2, r[2])
				pos = Codec.write(b, pos + 10, r[3], r[4], r[5], r[6] or 0, r[7] or 0, 0, 0, 0, 1)
			end
			local out = buffer.create(pos)
			buffer.copy(out, 0, b, 0, pos)
			return out
		end
		function s.newest(slot)
			local h = State.hist[slot]
			local p = h.last % h.cap + 1
			return h.t[p], h.x[p], h.y[p], h.z[p]
		end
		function s.step(n)
			for _ = 1, n or 1 do
				world:frame(DT)
			end
		end
		return s
	end

	T.test("silence banks no movement: 20 s quiet, then a 2000-stud jump is dropped", function()
		local s = setup(1)
		local slot = s.State.bySlotModel[s.chars[1]]
		s.step(5)
		local _, x0 = s.newest(slot)
		s.step(60 * 20)
		s.send(1, s.upload({ { slot, s.world.now, x0 + 2000, 3, 0 } }))
		s.step(3)
		local _, x1 = s.newest(slot)
		T.near(x1, x0, 1e-9, "jump dropped")
		-- the most a long silence allows is max(2 keepAlive, MaxBackdate) of motion
		s.send(1, s.upload({ { slot, s.world.now, x0 + 100, 3, 0 } }))
		s.step(3)
		local _, x2 = s.newest(slot)
		T.near(x2, x0 + 100, 1e-9, "a move within maxSpeed x 1 s still passes")
	end)

	T.test("back-dated stamps then stamp = now: the burst is limited by real elapsed time", function()
		local s = setup(1)
		local slot = s.State.bySlotModel[s.chars[1]]
		s.step(5)
		local _, x = s.newest(slot)
		local x0 = x
		-- 1 s of samples stamped ~0.9 s in the past, crawling (stamp time advances slowly)
		local st = s.world.now - 0.9
		for _ = 1, 60 do
			st += 0.01
			s.send(1, s.upload({ { slot, st, x, 3, 0 } }))
			s.step(1)
		end
		-- then one sample at stamp = now, 0.9 s * maxSpeed (108 studs) away
		s.send(1, s.upload({ { slot, s.world.now, x + 108, 3, 0 } }))
		s.step(3)
		local _, x1 = s.newest(slot)
		T.check(x1 - x0 < 10, "burst dropped: moved " .. (x1 - x0))
		T.check(s.Tide.stats().speed >= 1)
	end)

	T.test("tolerance spam: packed tiny-stamp records gain nothing, history is not flushed", function()
		local s = setup(1, { kinds = { Player = { maxSpeed = 20, maxFall = 50 } } })
		local slot = s.State.bySlotModel[s.chars[1]]
		s.step(5)
		local t0, x0, y0 = s.newest(slot)
		local st, x, y = t0, x0, y0
		local t1 = s.world.now
		for frame = 1, 120 do
			if frame % 3 == 0 then
				st = math.max(st, s.world.now - 0.95)
				local recs = {}
				for _ = 1, 16 do
					st += 1e-4
					x += 0.45
					y += 0.45
					table.insert(recs, { slot, st, x, y, 0 })
				end
				s.send(1, s.upload(recs))
			end
			s.step(1)
		end
		local elapsed = s.world.now - t1
		local _, x1, y1 = s.newest(slot)
		-- at most maxSpeed / maxRise over the real elapsed time, plus the small tolerance
		T.check(x1 - x0 <= 20 * elapsed + 1, string.format("horizontal %.1f in %.2f s", x1 - x0, elapsed))
		T.check(y1 - y0 <= 60 * elapsed + 1, string.format("rise %.1f in %.2f s", y1 - y0, elapsed))
		local st2 = s.Tide.stats()
		T.check(st2.spacing + st2.speed + st2.stamp >= 600, "packed records dropped")
		T.check(st2.samples < 40, "accepted " .. st2.samples)
	end)

	T.test("packed duplicate samples cannot flush the server history (Tide.at stays valid)", function()
		local s = setup(1)
		local slot = s.State.bySlotModel[s.chars[1]]
		s.step(5)
		local x = 10
		for _ = 1, 90 do
			x += 16 * DT
			local st = s.world.now
			local recs = {}
			for k = 0, 6 do
				table.insert(recs, { slot, st + k * 1e-5, x, 3, 0 })
			end
			s.send(1, s.upload(recs))
			s.step(1)
		end
		local h = s.State.hist[slot]
		local newest = h.t[h.last % h.cap + 1]
		local oldest = h.t[(h.last - h.n + 1) % h.cap + 1]
		T.check(newest - oldest > 1.2, "history spans " .. (newest - oldest))
		local cf = s.Tide.at(s.chars[1], s.world.now - 0.3 - 0.02)
		T.near(cf.X, x - 16 * 0.3, 0.6, "Tide.at 300 ms back")
	end)

	T.test("forged near-duplicate pair cannot fling the drawn entity (client clamp)", function()
		local s = setup(2)
		local ct2 = T.clientTide(s.world, 2)
		ct2.start()
		s.step(30)
		local slot = s.State.bySlotModel[s.chars[1]]
		local x = 10
		for _ = 1, 30 do
			x += 10 * DT
			s.send(1, s.upload({ { slot, s.world.now, x, 3, 0 } }))
			s.step(1)
		end
		local now = s.world.now
		s.send(1, s.upload({ { slot, now, x + 0.1, 3, 0 }, { slot, now + 0.0006, x + 0.55, 3, 0 } }))
		local worst = 0
		local view = s.world:replica(2, s.chars[1])
		for _ = 1, 60 do
			s.step(1)
			local _, sx = s.newest(slot)
			worst = math.max(worst, math.abs(ct2.drawn(view).X - sx))
		end
		T.check(worst < 2, "drawn within 2 studs of the server pose: " .. worst)
		T.check(s.Tide.stats().spacing >= 1, "second record dropped on the server")

		-- client side alone: a ring holding a 0.6 ms pair extrapolates at most maxSpeed
		local Interp = T.clientModule(s.world, 2, "Shared", "Interp")
		local Ring = T.clientModule(s.world, 2, "Shared", "Ring")
		local r = Ring.new(8, false)
		Ring.push(r, 1, 0, 3, 0, 0, 0, 0, 0, 0, 1)
		Ring.push(r, 1.0006, 0.45, 3, 0, 0, 0, 0, 0, 0, 1)
		local fx = Interp.sample(r, 1.1, 0.1, 0.5 / 60, 120, 60, 300)
		T.near(fx, 0.45, 1e-9, "pair closer than half an interval: no extrapolation")
		local r2 = Ring.new(8, false)
		Ring.push(r2, 1, 0, 3, 0, 0, 0, 0, 0, 0, 1)
		Ring.push(r2, 1.02, 20, 3, 0, 0, 0, 0, 0, 0, 1) -- 1000 studs/s
		local gx, gy = Interp.sample(r2, 1.12, 0.1, 0.5 / 60, 120, 60, 300)
		T.near(gx, 20 + 120 * 0.1, 1e-6, "clamped to maxSpeed")
		T.near(gy, 3, 1e-9)
	end)

	T.test("add + teleport in the same frame: ADD reaches the owner before TELEPORT", function()
		local s = setup(1)
		local ct = T.clientTide(s.world, 1)
		ct.start()
		s.step(10)
		local m = s.world:spawnModel("veh", CFrame.new(0, 3, 0), false)
		local h = s.Tide.add(m, "Bot", s.players[1])
		h:teleport(CFrame.new(50, 3, 50))
		local slot = s.State.bySlotModel[m]
		local frames = 0
		while s.State.tpPending[slot] and frames < 200 do
			s.step(1)
			frames += 1
		end
		T.check(frames < 15, "acknowledged after " .. frames .. " frames")
		T.eq(s.State.tpTries[slot], 1, "no resend needed")
	end)

	T.test("changing a kind's rotation after start does not break live entities", function()
		local s = setup(1)
		local ct = T.clientTide(s.world, 1)
		ct.start()
		local m = s.world:spawnModel("bot", CFrame.new(0, 3, 0), false)
		s.Tide.add(m, "Bot")
		s.step(10)
		s.Tide.kind("Bot", { rotation = "full" })
		local ok, err = pcall(function()
			for i = 1, 30 do
				m.HumanoidRootPart.CFrame = CFrame.new(i * 0.2, 3, 0) * CFrame.Angles(0, i * 0.05, 0)
				s.world:frame(DT)
			end
		end)
		T.check(ok, tostring(err))
		T.eq(s.Tide.stats().errors, 0)
		local cf = ct.drawn(s.world:replica(1, m))
		T.check(cf ~= nil and cf.X > 3, "still drawn and moving")
		T.check(math.abs(T.Mock.yawOf(cf)) > 0.5, "yaw kept on the old (yaw-only) stream")
		-- new entities of the kind use the new layout
		local m2 = s.world:spawnModel("bot2", CFrame.new(5, 3, 0), false)
		s.Tide.add(m2, "Bot")
		s.step(10)
		T.eq(s.State.hist[s.State.bySlotModel[m2]].full, true)
		s.Tide.kind("Bot", { rotation = "yaw" })
	end)

	T.test("streaming: root part arriving after the model is picked up and anchored", function()
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, -50))
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), false)
		world:streamOut(1, m.HumanoidRootPart)
		local ct = T.clientTide(world, 1)
		ct.start()
		Tide.add(m, "Bot")
		for _ = 1, 30 do
			world:frame(DT)
		end
		world:streamOut(1, m.HumanoidRootPart, false)
		for i = 1, 30 do
			m.HumanoidRootPart.CFrame = CFrame.new(i * 0.1, 3, 0)
			world:frame(DT)
		end
		local Cs = T.clientModule(world, 1, "Client", "State")
		local view = world:replica(1, m)
		local slot = Cs.bySlotModel[view]
		local hrp = view:FindFirstChild("HumanoidRootPart")
		T.check(hrp ~= nil, "root streamed in")
		T.eq(Cs.root[slot], hrp, "client resolved the root")
		T.check(hrp.Anchored, "and anchored it")
		T.near(hrp.CFrame.X, ct.drawn(view).X, 1e-9, "driven through the root")
		-- the root streams out (detached) and back in as a new part
		world:streamOut(1, m.HumanoidRootPart)
		rawset(hrp, "_parent", nil)
		for _ = 1, 20 do
			world:frame(DT)
		end
		T.eq(Cs.root[slot], nil, "detached root dropped")
		world:streamOut(1, m.HumanoidRootPart, false)
		for _ = 1, 20 do
			world:frame(DT)
		end
		local hrp2 = view:FindFirstChild("HumanoidRootPart")
		T.check(hrp2 ~= nil and hrp2 ~= hrp, "new part")
		T.eq(Cs.root[slot], hrp2, "new root resolved")
		T.check(hrp2.Anchored, "new root anchored")
	end)

	T.test("receiver without a character: far tier (budgeted), last known position kept", function()
		local s = setup(0)
		local Relay = T.module(s.world, "Server", "Relay")
		local _ = Relay
		local spectator = s.world:addPlayer() -- never spawns
		local ct = T.clientTide(s.world, 1)
		ct.start()
		local m = s.world:spawnModel("bot", CFrame.new(0, 3, 0), true)
		s.Tide.add(m, "Bot")
		s.step(10)
		local slot = s.State.bySlotModel[m]
		local rx = s.State.rx[spectator]
		T.eq(rx.tier[slot], 3, "no position: far")
		-- with a character, then without: tiers keep using the last position
		local char = s.world:spawnCharacter(spectator, CFrame.new(2, 3, 0))
		s.step(10)
		T.eq(rx.tier[slot], 1, "near its character")
		s.Tide.remove(char)
		s.step(10)
		T.eq(rx.tier[slot], 1, "still near the last known position")
	end)

	T.test("teleportOnWrite stops the character by default; 'keep' keeps its velocity", function()
		for _, mode in { "zero", "keep" } do
			local s = setup(1, { teleportOnWriteVelocity = mode })
			local ct = T.clientTide(s.world, 1)
			ct.start()
			s.step(10)
			local root = s.world:replica(1, s.chars[1]):FindFirstChild("HumanoidRootPart")
			root.AssemblyLinearVelocity = Vector3.new(30, 0, 0)
			s.chars[1].HumanoidRootPart.CFrame = CFrame.new(0, 3, 100)
			s.step(10)
			T.near(root.CFrame.Z, 100, 1e-3, mode .. ": moved")
			local vx = root.AssemblyLinearVelocity.X
			if mode == "zero" then
				T.near(vx, 0, 1e-9, "velocity zeroed")
			else
				T.near(vx, 30, 1e-9, "velocity kept")
			end
		end
	end)
end
