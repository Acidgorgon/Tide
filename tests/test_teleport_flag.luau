-- v0.4 teleport flag for server-owned jumps made without handle:teleport: the kind option
-- teleportDistance and handle:markTeleport (now, or when the entity reaches a target).
return function(T)
	local DT = 1 / 60

	local function setup(kindOpts)
		local world = T.world({ latency = 0.04, jitter = 0.01 })
		local Tide = T.serverTide(world)
		Tide.kind("Body", kindOpts or {})
		Tide.start({ players = false })
		world:addPlayer()
		local ct = T.clientTide(world, 1)
		ct.start()
		local m = world:spawnModel("body", CFrame.new(0, 3, 0), true)
		local handle = Tide.add(m, "Body")
		local s = { world = world, Tide = Tide, ct = ct, m = m, handle = handle, base = 0, xs = {} }
		local view = world:replica(1, m)
		-- moves the server model (base + a wiggle) and records what client 1 draws
		function s.run(seconds, before)
			for f = 1, math.floor(seconds / DT + 0.5) do
				if before then
					before(f)
				end
				m.HumanoidRootPart.CFrame = CFrame.new(s.base + math.sin(world.now * 3), 3, 0)
				world:frame(DT)
				local cf = ct.drawn(view)
				if cf then
					table.insert(s.xs, cf.X)
				end
			end
		end
		-- was anything drawn between the two places (a sweep)?
		function s.swept(a, b)
			for _, x in s.xs do
				if math.abs(x - a) > 1.5 and math.abs(x - b) > 1.5 then
					return true
				end
			end
			return false
		end
		return s
	end

	T.test("teleportDistance: a sampled jump above it snaps; normal motion and v0.3 kinds do not", function()
		local s = setup({ teleportDistance = 20 })
		s.run(1)
		local flagged = s.Tide.stats().teleportFlagged
		T.eq(flagged, 0, "normal motion is not flagged")
		s.base = 200 -- a PivotTo / CFrame write somewhere else in the game
		s.xs = {}
		s.run(1)
		T.eq(s.Tide.stats().teleportFlagged, 1, "the jump was flagged")
		T.check(not s.swept(0, 200), "snapped, never drawn in between")
		T.check(math.abs(s.xs[#s.xs] - 200) < 1.5, "arrived")
		-- control: without teleportDistance the same jump is swept (v0.3)
		local c = setup()
		c.run(1)
		c.base = 200
		c.xs = {}
		c.run(1)
		T.check(c.swept(0, 200), "v0.3: swept across")
		T.eq(c.Tide.stats().teleportFlagged, 0)
		T.check(not pcall(s.Tide.kind, "Body", { teleportDistance = 0 }), "must be positive")
	end)

	T.test("markTeleport(): flags the move just made (below any distance threshold)", function()
		local s = setup()
		s.run(1)
		s.xs = {}
		s.run(0.5, function(f)
			if f == 10 then
				s.base = 8
				s.m.HumanoidRootPart.CFrame = CFrame.new(8 + math.sin(s.world.now * 3), 3, 0)
				s.handle:markTeleport()
			end
		end)
		T.check(not s.swept(0, 8), "snapped")
		T.eq(s.Tide.stats().teleportFlagged, 1)
	end)

	T.test("markTeleport(target): flags the sample that reaches it, even frames later; expires after 1 s", function()
		local s = setup()
		s.run(1)
		s.xs = {}
		-- the intent arrives before the move (e.g. from another VM): flag on arrival
		s.handle:markTeleport(CFrame.new(100, 3, 0))
		s.run(0.5, function(f)
			if f == 6 then
				s.base = 100
			end
		end)
		T.check(not s.swept(0, 100), "snapped when it arrived")
		T.eq(s.Tide.stats().teleportFlagged, 1)
		-- an expired mark flags nothing
		s.handle:markTeleport(Vector3.new(300, 3, 0))
		s.run(1.2)
		s.xs = {}
		s.base = 300
		s.run(0.5)
		T.check(s.swept(100, 300), "expired: swept")
		T.eq(s.Tide.stats().teleportFlagged, 1)
		T.check(not pcall(s.handle.markTeleport, s.handle, "here"), "bad target rejected")
	end)

	T.test("markTeleport on a client-owned entity does nothing (use teleport)", function()
		local s = setup()
		s.handle:setOwner(s.world.players[1])
		s.run(0.2)
		local SState = T.module(s.world, "Server", "State")
		local h = SState.hist[SState.bySlotModel[s.m]]
		local n = h.last
		s.handle:markTeleport()
		T.eq(h.last, n, "no sample pushed")
		T.eq(s.Tide.stats().teleportFlagged, 0)
	end)
end
