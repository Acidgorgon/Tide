-- Tide.span: the server times an entity's history covers. Tide.at holds an end outside them,
-- and until now nothing told a held answer from one read off the path.
return function(T)
	local DT = 1 / 60

	local function setup()
		local world = T.world({ latency = 0.03, start = 1.7e9, seed = 4 })
		local Tide = T.serverTide(world)
		Tide.kind("Ball", { velocity = true, rate = 60, apply = "none" })
		Tide.kind("Flag", { motion = false })
		Tide.state("Flag", { Up = "bool" })
		Tide.start({ players = false })
		local s = { world = world, Tide = Tide, State = T.module(world, "Server", "State"), cts = {}, players = {} }
		for i = 1, 2 do
			s.players[i] = world:addPlayer()
			s.cts[i] = T.clientTide(world, i)
			s.cts[i].kind("Ball", {})
			s.cts[i].start()
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

	T.test("server: oldest and newest sample of a moving entity; Tide.at is exact inside and holds an end outside", function()
		local s = setup()
		local Tide, world = s.Tide, s.world
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), true)
		local handle = Tide.add(m, "Bot")
		local oldest0, newest0 = Tide.span(m)
		T.check(oldest0 ~= nil and oldest0 == newest0, "one sample at add: a range of one instant")
		local x = 0
		local function move()
			x += 20 * DT
			m.HumanoidRootPart.CFrame = CFrame.new(x, 3, 0)
		end
		local t0 = world.now
		s.step(60, move)
		local oldest, newest = Tide.span(m)
		T.eq(oldest, oldest0, "nothing dropped yet: the sample taken at add")
		T.check(oldest >= t0 - DT and oldest <= t0 + 1e-6)
		T.check(newest <= world.now + 1e-6 and newest > world.now - 2 / 30, "the newest sample: within a tick of now")
		local h = s.State.hist[s.State.bySlotModel[m]]
		T.eq(newest, h.t[h.last % h.cap + 1])
		local ho, hn = Tide.span(handle)
		T.eq(ho, oldest, "by handle")
		T.eq(hn, newest)
		-- inside: the path. A game judging at a view time checks the range first
		local function covered(t)
			local a, b = Tide.span(m)
			return a ~= nil and t >= a and t <= b
		end
		T.eq(covered(newest), true)
		T.eq(covered(oldest), true)
		T.eq(covered((oldest + newest) / 2), true)
		T.eq(covered(newest + 0.001), false, "past the newest sample: Tide.at holds it")
		T.eq(covered(oldest - 0.001), false, "before the oldest: Tide.at holds it")
		T.eq(Tide.at(m, newest + 5).X, Tide.at(m, newest).X, "held")
		T.eq(Tide.at(m, oldest - 5).X, Tide.at(m, oldest).X, "held")
		T.check(Tide.at(m, newest - 0.01).X < Tide.at(m, newest).X, "inside: the path")
		-- the ring wraps: the old end moves on, by whole samples
		s.step(600, move)
		local o2, n2 = Tide.span(m)
		T.check(o2 > oldest + 1, "the oldest kept sample moved on")
		T.eq(o2, h.t[(h.last - h.n + 1) % h.cap + 1])
		T.near(n2 - o2, (h.n - 1) / 30, 0.02, "128 samples at 30 Hz")
		T.eq(h.n, h.cap, "a full ring")
	end)

	T.test("server: at rest the newest end follows the ticks that found the entity unchanged; moving again it is a sample", function()
		local s = setup()
		local Tide, world = s.Tide, s.world
		local m = world:spawnModel("crate", CFrame.new(0, 3, 0), true)
		Tide.add(m, "Bot")
		s.step(30)
		local h = s.State.hist[s.State.bySlotModel[m]]
		-- frames at rest that add no sample (all but the keep-alives) still move the end on
		local grew, n2 = 0, 0
		for _ = 1, 20 do
			local last = h.last
			local _, before = Tide.span(m)
			world:frame(DT)
			local _, after = Tide.span(m)
			n2 = after
			T.check(after >= before)
			if h.last == last and after > before then
				grew += 1
				T.check(after > h.t[h.last % h.cap + 1], "past the newest sample")
			end
		end
		T.check(grew >= 8, "the range grew on ticks that added no sample: " .. grew)
		T.check(n2 <= world.now + 1e-6 and n2 > world.now - 2 / 30, "to the last tick")
		-- moves again: the rest marker and the new sample are in the ring; the end is a sample
		m.HumanoidRootPart.CFrame = CFrame.new(4, 3, 0)
		s.step(3)
		local _, n3 = Tide.span(m)
		T.check(n3 >= n2)
		T.eq(n3, math.max(h.t[h.last % h.cap + 1], s.State.heldT[s.State.bySlotModel[m]]))
		-- never ahead of the clock, never going back, frame by frame, moving and resting
		local prev = n3
		for f = 1, 200 do
			if f % 50 < 20 then
				m.HumanoidRootPart.CFrame = CFrame.new(4 + f * 0.1, 3, 0)
			end
			world:frame(DT)
			local o, n = Tide.span(m)
			T.check(n >= prev, "newest never goes back")
			T.check(n <= world.now + 1e-6, "never ahead of the clock")
			T.check(o <= n)
			prev = n
		end
	end)

	T.test("server: a bump in a handler is in the range at once; velocity kinds; nil for unknown and state-only targets", function()
		local s = setup()
		local Tide, world = s.Tide, s.world
		local ball = world:spawnModel("ball", CFrame.new(0, 3, 10), false)
		Tide.add(ball, "Ball")
		s.step(20)
		ball.HumanoidRootPart.AssemblyLinearVelocity = Vector3.new(30, 0, 0)
		local t = Tide.bump(ball)
		local _, newest = Tide.span(ball)
		T.eq(newest, t, "the cut is the new end")
		local _, v = Tide.at(ball, newest)
		T.eq(v.X, 30)
		local flag = T.Mock.newInstance("Part", "Flag")
		flag.CFrame = CFrame.new(0, 2, 0)
		flag.Parent = world.server.Workspace
		local fh = Tide.add(flag, "Flag")
		s.step(5)
		local a, b = Tide.span(flag)
		T.eq(a, nil, "state-only: no path")
		T.eq(b, nil)
		a, b = Tide.span(fh)
		T.eq(a, nil)
		T.eq(b, nil)
		a, b = Tide.span(world.server.Workspace)
		T.eq(a, nil, "unknown")
		T.eq(b, nil)
		a, b = Tide.span(nil)
		T.eq(a, nil, "nil")
		T.eq(b, nil)
		Tide.remove(ball)
		a, b = Tide.span(ball)
		T.eq(a, nil, "removed")
		T.eq(b, nil)
		T.eq(select("#", Tide.span(ball)), 2, "always two values")
	end)

	T.test("server: a client-owned entity is covered up to its newest uploaded sample (no held tick)", function()
		local s = setup()
		local Tide, world = s.Tide, s.world
		local m = world:spawnModel("P", CFrame.new(0, 3, 0))
		local h = Tide.add(m, "Bot")
		s.step(10)
		local rep = world:replica(1, m)
		rep.HumanoidRootPart.CFrame = m.HumanoidRootPart.CFrame
		h:setOwner(s.players[1])
		local x = 0
		s.step(60, function()
			x += 10 * DT
			rep.HumanoidRootPart.CFrame = CFrame.new(x, 3, 0)
		end)
		local slot = s.State.bySlotModel[m]
		local ring = s.State.hist[slot]
		local oldest, newest = Tide.span(m)
		T.eq(newest, ring.t[ring.last % ring.cap + 1], "the newest sample received")
		T.eq(s.State.heldT[slot], 0)
		T.check(newest < world.now and newest > world.now - 0.2, "behind the clock by the upload")
		T.check(oldest < newest)
		-- the owner stops: uploads thin out to the keep-alive, and the range does not grow
		-- between them (the server cannot know the body stands until told)
		s.step(40)
		local _, n1 = Tide.span(m)
		s.step(3)
		local _, n2 = Tide.span(m)
		T.check(n2 - n1 < 3 * DT + 1e-6 and n2 >= n1)
		T.check(world.now - n2 > 0, "the owner's last word")
		-- handed back: the server's own ticks count again
		m.HumanoidRootPart.CFrame = CFrame.new(x, 3, 0)
		h:setOwner(nil)
		s.step(20)
		local _, n3 = Tide.span(m)
		T.check(n3 > world.now - 2 / 30, "server-owned again: to the last tick")
	end)

	T.test("client: the range its buffer holds for a remote entity; nil for unknown ones; its own entity's range stands still", function()
		local s = setup()
		local Tide, world = s.Tide, s.world
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), true)
		local h = Tide.add(m, "Bot")
		local own = world:spawnModel("P", CFrame.new(20, 3, 0))
		local oh = Tide.add(own, "Bot")
		local x = 0
		s.step(90, function()
			x += 15 * DT
			m.HumanoidRootPart.CFrame = CFrame.new(x, 3, 0)
		end)
		local ct = s.cts[1]
		local view = world:replica(1, m)
		local oldest, newest = ct.span(view)
		local so, sn = Tide.span(m)
		T.check(oldest ~= nil and newest ~= nil)
		T.check(oldest >= so - 0.001, "nothing older than the server has")
		T.check(newest <= sn + 0.001 and newest > sn - 0.15, "behind the server by the trip")
		local info = ct.sampleInfo(view)
		T.near(info.newest, newest, 1e-9, "Tide.sampleInfo's newest")
		-- the drawn time lies inside it on a healthy link
		local drawn = ct.timeOf(view)
		T.check(drawn >= oldest and drawn <= newest, "the drawn time is covered")
		-- held outside (no extrapolation asked for)
		T.eq(ct.at(view, newest + 3).X, ct.at(view, newest).X)
		T.eq(ct.at(view, oldest - 3).X, ct.at(view, oldest).X)
		-- its own entity: nothing is received for it, so the range stops at the samples that
		-- came before the grant (Tide.at answers from the same samples)
		local rep = world:replica(1, own)
		rep.HumanoidRootPart.CFrame = own.HumanoidRootPart.CFrame
		oh:setOwner(s.players[1])
		s.step(20)
		local a, b = ct.span(rep)
		T.eq(ct.isMine(rep), true)
		s.step(60)
		local a1, b1 = ct.span(rep)
		T.eq(a1, a, "own entity: the range stands still")
		T.eq(b1, b)
		T.check(b == nil or b < world.now - 1, "and is behind: a view time of now is not covered")
		local a2, b2 = s.cts[2].span(world:replica(2, own))
		T.check(a2 ~= nil and b2 ~= nil and a2 <= b2, "the other client sees a range")
		a, b = ct.span(world.clients[1].Workspace)
		T.eq(a, nil, "unknown")
		T.eq(b, nil)
		h:remove()
		s.step(10)
		a, b = ct.span(view)
		T.eq(a, nil, "removed")
		T.eq(b, nil)
	end)
end
