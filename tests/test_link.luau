-- v0.4 links (Shared/Link, handle:link): another VM rewinds linked entities from their
-- mirrored history (same answer as Tide.at) and queues owner/teleport/mark intents that the
-- Tide VM applies at the start of its next frame.
return function(T)
	local DT = 1 / 60

	local function setup()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.kind("Body", { rate = 30, rotation = "full", farEvery = 1 })
		Tide.start({ players = false, lockPlayers = false })
		local p1 = world:addPlayer()
		local ct = T.clientTide(world, 1)
		ct.start()
		local m = world:spawnModel("body", CFrame.new(0, 3, 0), true)
		local handle = Tide.add(m, "Body")
		local vm = T.actorVM(world) -- a venue Actor's VM: its own copy of Tide, no shared state
		local s = { world = world, Tide = Tide, ct = ct, p1 = p1, m = m, handle = handle, Link = vm("Shared", "Link") }
		s.State = T.module(world, "Server", "State")
		function s.step(n, model)
			model = model or m
			local dx = if model == m then 0 else 100
			for _ = 1, n do
				local t = world.now
				model.HumanoidRootPart.CFrame = CFrame.new(dx + math.sin(t) * 8, 3 + math.cos(t * 2), t % 5) * CFrame.Angles(0, t, 0.3)
				world:frame(DT)
			end
		end
		return s
	end

	local function sameCF(a, b, msg)
		T.check(a ~= nil and b ~= nil, msg .. ": both known")
		local ca, cb = { a:GetComponents() }, { b:GetComponents() }
		for i = 1, 12 do
			T.eq(ca[i], cb[i], msg .. ": component " .. i)
		end
	end

	T.test("default: nothing linked, nothing mirrored (no SharedTable is created)", function()
		local s = setup()
		s.step(30)
		T.eq(next(s.world.sharedTables), nil)
	end)

	T.test("another VM rewinds a linked entity exactly as Tide.at does", function()
		local s = setup()
		s.step(30)
		s.handle:link("Venue1", "body")
		local venue = s.Link.open("Venue1")
		T.eq(venue:has("body"), true)
		T.eq(venue:at("body", s.world.now), nil, "written at the end of the Tide VM's frame")
		s.step(1)
		for k = 0, 40 do
			local t = s.world.now - k * 0.0123
			sameCF(venue:at("body", t), s.Tide.at(s.m, t), "t = now - " .. k * 0.0123)
		end
		-- incremental: keeps matching as new samples come in (and across the ring wrapping)
		for _ = 1, 4 do
			s.step(200)
			for k = 0, 20 do
				local t = s.world.now - k * 0.031
				sameCF(venue:at("body", t), s.Tide.at(s.m, t), "after more frames")
			end
		end
		local cf, t = venue:latest("body")
		sameCF(cf, s.Tide.latest(s.m), "latest")
		T.eq(t, s.State.hist[s.State.bySlotModel[s.m]].t[s.State.hist[s.State.bySlotModel[s.m]].last % s.State.hist[s.State.bySlotModel[s.m]].cap + 1], "its server time")
		T.eq(venue:has("nobody"), false)
		T.eq(venue:at("nobody", s.world.now), nil)
		-- a second reader opened late gets the whole kept history
		local late = s.Link.open("Venue1")
		sameCF(late:at("body", s.world.now - 1), s.Tide.at(s.m, s.world.now - 1), "late reader")
	end)

	T.test("intents: setOwner, teleport and markTeleport are applied by the Tide VM next frame", function()
		local s = setup()
		s.handle:link("Venue1", 7)
		local venue = s.Link.open("Venue1")
		s.step(10)
		venue:setOwner(7, s.p1.UserId)
		T.eq(s.Tide.owner(s.m), nil, "never synchronous")
		s.world:frame(DT)
		T.eq(s.Tide.owner(s.m), s.p1, "owner set")
		venue:setOwner(7, nil)
		s.world:frame(DT)
		T.eq(s.Tide.owner(s.m), nil, "back to the server")
		-- a teleport of a server-owned entity: moved and flagged
		venue:teleport(7, CFrame.new(500, 3, 0) * CFrame.Angles(0, 1, 0), Vector3.new(1, 2, 3))
		s.world:frame(DT)
		T.check(T.dist(s.m.HumanoidRootPart.CFrame.Position, Vector3.new(500, 3, 0)) < 1e-6, "moved")
		local slot = s.State.bySlotModel[s.m]
		local h = s.State.hist[slot]
		T.eq(h.fl[h.last % h.cap + 1] % 2, 1, "flagged sample")
		-- markTeleport: now, and at a target reached later
		local flagged = s.Tide.stats().teleportFlagged
		s.m.HumanoidRootPart.CFrame = CFrame.new(-300, 3, 0)
		venue:markTeleport(7)
		s.world:frame(DT)
		T.eq(s.Tide.stats().teleportFlagged, flagged + 1, "marked")
		venue:markTeleport(7, CFrame.new(300, 3, 0))
		s.world:frame(DT)
		s.m.HumanoidRootPart.CFrame = CFrame.new(300, 3, 0)
		for _ = 1, 3 do
			s.world:frame(DT)
		end
		T.eq(s.Tide.stats().teleportFlagged, flagged + 2, "marked on arrival")
		-- the reader sees the flagged sample: no sweep across the jump when rewinding
		local mid = venue:at(7, h.t[h.last % h.cap + 1] - 0.001)
		T.check(mid ~= nil and (math.abs(mid.X - 300) < 1 or math.abs(mid.X + 300) < 1), "snaps: " .. tostring(mid and mid.X))
		T.eq(s.Tide.stats().linkBad, 0)
		T.eq(s.Tide.stats().linkUnknown, 0)
	end)

	T.test("unknown keys and players are dropped and counted; unlink, relink and remove", function()
		local s = setup()
		s.handle:link("Venue1", "a")
		local venue = s.Link.open("Venue1")
		s.step(10)
		venue:setOwner("b", s.p1.UserId)
		venue:setOwner("a", 424242)
		s.world:frame(DT)
		T.eq(s.Tide.stats().linkUnknown, 1, "key not linked")
		T.eq(s.Tide.stats().linkBad, 1, "no such player")
		T.eq(s.Tide.owner(s.m), nil)
		T.check(not pcall(function()
			venue:setOwner({}, 1)
		end), "bad key rejected in the writer's VM")
		-- another entity under the same key: the first is unlinked, readers start over
		local m2 = s.world:spawnModel("other", CFrame.new(50, 3, 0), true)
		s.Tide.add(m2, "Body")
		s.step(10, m2)
		local before = venue:at("a", s.world.now - 0.05)
		s.Tide.handle(m2):link("Venue1", "a")
		s.step(2, m2)
		local after = venue:at("a", s.world.now - 0.05)
		T.check(T.dist(before.Position, after.Position) > 10, "now the other entity")
		sameCF(after, s.Tide.at(m2, s.world.now - 0.05), "relinked")
		s.handle:link("Venue1", "c")
		s.world:frame(DT)
		T.eq(venue:has("a"), true)
		T.eq(venue:has("c"), true)
		s.handle:link(nil)
		T.eq(venue:has("c"), false, "unlinked")
		s.Tide.handle(m2):remove()
		T.eq(venue:has("a"), false, "removed")
		venue:teleport("a", CFrame.new())
		s.world:frame(DT)
		T.eq(s.Tide.stats().linkUnknown, 2)
		T.check(not pcall(function()
			s.handle:link("Venue1", {})
		end), "bad key rejected")
	end)
end
