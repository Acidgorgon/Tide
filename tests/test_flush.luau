-- Tide.flush: the samples of entities bumped after Tide's step of a frame (a kick made in a
-- Heartbeat connection) leave in that frame instead of with the next frame's packet; audiences,
-- tiers and budgets as in a frame's relay, every byte charged once, nothing sent twice.
return function(T)
	local DT = 1 / 60

	local BALL = { velocity = true, rotation = "full", rate = 60, near = math.huge, apply = "none", restRepeats = 0 }

	local function setup(opts)
		opts = opts or {}
		local world = T.world(opts.net or { latency = 0.04, start = 1.7e9, seed = 2 })
		local Tide = T.serverTide(world)
		Tide.kind("Ball", opts.kind or BALL)
		Tide.start({ players = opts.players ~= false })
		local s = { world = world, Tide = Tide, cts = {}, players = {}, seen = {}, State = T.module(world, "Server", "State") }
		-- relay packets fired, per target
		s.packets = {}
		local send = world._send
		world._send = function(self, remote, fromServer, target, ...)
			local b = ...
			if fromServer and rawget(remote, "ClassName") == "UnreliableRemoteEvent" and type(b) == "buffer" then
				table.insert(s.packets, { to = target, size = buffer.len(b), now = world.now })
				if s.onPacket then
					s.onPacket()
				end
			end
			return send(self, remote, fromServer, target, ...)
		end
		function s.addPlayer(cf)
			local i = #world.players + 1
			s.players[i] = world:addPlayer()
			if opts.players ~= false then
				world:spawnCharacter(s.players[i], cf or CFrame.new(i * 8, 3, 0))
			end
			local ct = T.clientTide(world, i)
			s.seen[i] = {}
			ct.kind("Ball", {
				onSample = function(_, t, cf2, v, _, cut)
					table.insert(s.seen[i], { t = t, x = cf2.X, v = v, cut = cut, at = world.now })
				end,
			})
			ct.start()
			s.cts[i] = ct
			return i
		end
		function s.ball(cf)
			local model = world:spawnModel("ball", cf or CFrame.new(0, 3, 10), false)
			return model, Tide.add(model, "Ball")
		end
		function s.step(n)
			for _ = 1, n or 1 do
				world:frame(DT)
			end
		end
		function s.sent(to)
			local n, bytes = 0, 0
			for _, p in s.packets do
				if to == nil or p.to == to then
					n += 1
					bytes += p.size
				end
			end
			return n, bytes
		end
		return s
	end

	local function kick(model, speed)
		local root = model.HumanoidRootPart
		root.AssemblyLinearVelocity = Vector3.new(speed, 0, 0)
	end

	-- frames from a kick to the client's cut sample; `where` says when in the server's frame
	local function framesToClient(where, flush)
		local s = setup()
		s.addPlayer()
		local model = s.ball()
		s.step(20)
		local world = s.world
		local rs = world.server.RunService
		local armed = false
		local function doKick()
			if armed then
				armed = false
				kick(model, 40)
				T.check(s.Tide.bump(model) ~= nil)
				if flush then
					s.Tide.flush()
				end
			end
		end
		rs.Heartbeat:Connect(function()
			if where == "heartbeat" then
				doKick()
			end
		end)
		rs.Stepped:Connect(function()
			if where == "stepped" then
				doKick()
			end
		end)
		table.clear(s.seen[1])
		armed = true
		if where == "between" then
			doKick() -- a remote handler: before the frame's PreSimulation
		end
		for f = 1, 12 do
			world:frame(DT)
			for _, e in s.seen[1] do
				if e.cut then
					T.eq(e.v.X, 40, "the cut carries the kick")
					return f, s
				end
			end
		end
		error("the cut never arrived")
	end

	T.test("a kick in a Heartbeat connection: with Tide.flush it reaches clients a frame sooner, as soon as any other kick", function()
		local late = framesToClient("heartbeat", false)
		local flushed, s = framesToClient("heartbeat", true)
		local between = framesToClient("between", false)
		local stepped = framesToClient("stepped", false)
		print(string.format("    frames from the kick to the client (40 ms): Heartbeat %d, Heartbeat + flush %d, remote handler %d, Stepped %d", late, flushed, between, stepped))
		T.eq(flushed, late - 1, "one frame sooner")
		-- a kick made in the frame's Stepped leaves with that frame's relay; one made in its
		-- Heartbeat and flushed leaves in the same frame: the same count
		T.eq(flushed, stepped, "as a kick made in Stepped of the same frame")
		-- (a remote handler runs before the frame's step: counted from the frame after it)
		T.eq(between, stepped, "remote handlers and Stepped: the frame's own relay")
		T.eq(s.Tide.stats().flushes, 1)
		T.eq(s.cts[1].stats().repeats, 0, "sent once")
		T.eq(s.cts[1].stats().late, 0)
		-- in the physics window the frame's relay is still to come: a flush there changes nothing
		T.eq(framesToClient("stepped", true), stepped)
		-- in a remote handler it sends at once (the mock steps its clock between the handler and
		-- the frame's step, hence a frame less here; a live server runs both in one frame)
		T.eq(framesToClient("between", true), between - 1)
	end)

	T.test("what flush returns: the entities sent; 0 with nothing bumped, called again, before start, on a client", function()
		local world0 = T.world()
		local Tide0 = T.serverTide(world0)
		T.eq(Tide0.flush(), 0, "before Tide.start")
		local s = setup()
		s.addPlayer()
		s.addPlayer()
		local a = s.ball(CFrame.new(0, 3, 10))
		local b = s.ball(CFrame.new(5, 3, 10))
		local c = s.ball(CFrame.new(9, 3, 10))
		s.step(20)
		local stats = s.Tide.stats
		local n0, size0 = s.sent()
		local bytes0 = stats().relayBytes
		T.eq(s.Tide.flush(), 0, "nothing bumped")
		T.eq(s.sent(), n0, "no packet")
		T.eq(stats().flushes, 0)
		-- a bump that finds nothing changed samples nothing: nothing to flush
		T.check(s.Tide.bump(a) ~= nil)
		T.eq(s.Tide.flush(), 0, "an idle bump")
		kick(a, 30)
		kick(b, -30)
		s.Tide.bump(a)
		s.Tide.bump(b)
		s.Tide.bump(a) -- twice the same entity, unchanged the second time
		T.eq(s.Tide.flush(), 2, "two entities")
		local n1, size1 = s.sent()
		T.eq(n1 - n0, 2, "one packet for each of the two receivers")
		for _ = 1, 50 do
			T.eq(s.Tide.flush(), 0, "again: nothing left")
		end
		T.eq(s.sent(), n1, "no further packet")
		T.eq(stats().flushes, 1)
		-- each flushed byte is counted once: what the stats say is what was fired. A packet is
		-- 10 B and, for each ball, the rest marker and the cut
		T.eq(stats().relayBytes - bytes0, size1 - size0, "bytes counted once")
		T.eq((size1 - size0) % 2, 0, "the same packet for both receivers")
		T.check(size1 - size0 > 2 * 10 and size1 - size0 < 2 * (10 + 4 * 24), "four records in each")
		-- the third ball, kicked now, goes in a flush of its own
		kick(c, 12)
		s.Tide.bump(c)
		T.eq(s.Tide.flush(), 1)
		T.eq(stats().flushes, 2)
		-- the frame's own relay sends nothing of them again: each client has each cut once
		s.step(10)
		for i = 1, 2 do
			local cuts = 0
			for _, e in s.seen[i] do
				if e.cut then
					cuts += 1
				end
			end
			T.eq(cuts, 3, "client " .. i .. ": three cuts")
			T.eq(s.cts[i].stats().repeats, 0)
			T.eq(s.cts[i].stats().late, 0)
			T.eq(s.cts[i].flush(), 0, "client: 0")
		end
		T.eq(stats().errors, 0)
	end)

	T.test("flush charges the receiver's budget without crediting time; mid and far records over budget are dropped as in a frame", function()
		local s = setup({ players = false, kind = { velocity = true, rate = 60, near = 100, far = 250, cull = 400, farEvery = 1, restRepeats = 0 } })
		local Config = T.module(s.world, "Shared", "Config")
		local at = { 0, 150, 300, 1000, 0 }
		for i = 1, 5 do
			s.addPlayer()
			s.Tide.focus(s.players[i], Vector3.new(at[i], 3, 0))
		end
		local model, handle = s.ball(CFrame.new(0, 3, 0))
		handle:setAudience({ s.players[1], s.players[2], s.players[3], s.players[4] })
		s.step(12)
		local slot = s.State.bySlotModel[model]
		local rx = {}
		for i = 1, 5 do
			rx[i] = s.State.rx[s.players[i]]
			T.eq(rx[i].tier[slot], ({ 1, 2, 3, 4, 4 })[i], "tier of receiver " .. i)
		end
		-- every receiver has 15 B of budget left: under a packet
		Config.ReceiverBytesPerSecond = 60
		for i = 1, 5 do
			rx[i].tokens = 15
		end
		table.clear(s.packets)
		local dropped = s.Tide.stats().budgetDropped
		kick(model, 30)
		s.Tide.bump(model)
		T.eq(s.Tide.flush(), 1)
		T.eq(s.sent(s.players[1]), 1, "near: sent whatever the budget")
		T.eq(s.sent(s.players[2]), 1, "mid: 10 B of header fit under 15")
		T.eq(s.sent(s.players[3]), 1, "far: the same")
		T.eq(s.sent(s.players[4]), 0, "culled by distance: nothing")
		T.eq(s.sent(s.players[5]), 0, "outside the audience: nothing")
		local _, bytes = s.sent(s.players[1])
		T.eq(bytes, 10 + 2 * 15, "the rest marker and the cut: yaw-only records with a velocity")
		for i = 1, 3 do
			T.eq(rx[i].tokens, 15 - 40, "receiver " .. i .. ": charged the packet, credited no time")
		end
		T.eq(rx[4].tokens, 15, "nothing sent: nothing charged")
		-- now over budget: a second kick is dropped for mid and far, sent to near
		table.clear(s.packets)
		kick(model, -30)
		s.Tide.bump(model)
		T.eq(s.Tide.flush(), 1)
		T.eq(s.sent(s.players[1]), 1)
		T.eq(s.sent(s.players[2]), 0, "mid: over budget")
		T.eq(s.sent(s.players[3]), 0, "far: over budget")
		T.eq(s.Tide.stats().budgetDropped - dropped, 2)
		local _, bytes2 = s.sent(s.players[1])
		T.eq(rx[1].tokens, 15 - 40 - bytes2)
		T.eq(rx[2].tokens, 15 - 40, "a dropped record costs nothing")
		Config.ReceiverBytesPerSecond = 40960
	end)

	T.test("flush between PreSimulation and the end of Tide's step does nothing: that step's relay sends it", function()
		local s = setup()
		s.addPlayer()
		local model = s.ball()
		s.step(20)
		local rs = s.world.server.RunService
		local results = {}
		local phase = ""
		rs.PreSimulation:Connect(function()
			if phase == "pre" then
				kick(model, 25)
				s.Tide.bump(model)
				table.insert(results, s.Tide.flush())
			end
		end)
		rs.Stepped:Connect(function()
			if phase == "stepped" then
				kick(model, -25)
				s.Tide.bump(model)
				table.insert(results, s.Tide.flush())
			elseif phase == "early" then
				-- bumped at once before PreSimulation (as a remote handler), flushed in Stepped
				table.insert(results, s.Tide.flush())
			end
		end)
		for _, p in { "pre", "stepped" } do
			phase = p
			local n = s.sent()
			s.step(1)
			phase = ""
			T.eq(s.sent() - n, 1, p .. ": one packet in the frame, the relay's")
		end
		kick(model, 60)
		s.Tide.bump(model)
		T.eq(s.State.lateN, 1, "waiting for a relay")
		phase = "early"
		local n = s.sent()
		s.step(1)
		phase = ""
		T.eq(s.sent() - n, 1, "sent by the frame's relay")
		T.eq(s.State.lateN, 0, "and nothing left for a flush")
		T.eq(s.Tide.flush(), 0)
		T.eq(#results, 3)
		for _, r in results do
			T.eq(r, 0, "flush in the physics window")
		end
		T.eq(s.Tide.stats().flushes, 0)
		s.step(8)
		local cuts = 0
		for _, e in s.seen[1] do
			if e.cut then
				cuts += 1
			end
		end
		T.eq(cuts, 3, "all three kicks arrived, once")
		T.eq(s.cts[1].stats().repeats, 0)
	end)

	T.test("flush from callbacks: inside the frame's step and inside a relay it does nothing; from an added handler it sends", function()
		local s = setup({ players = false })
		s.addPlayer()
		s.Tide.focus(s.players[1], Vector3.new(0, 3, 0))
		local model, handle = s.ball(CFrame.new(0, 3, 0))
		s.step(12)
		-- an audience function runs inside the frame's relay: it bumps and flushes there
		local inside = {}
		local hostile = false
		handle:setAudience(function()
			if hostile then
				hostile = false
				kick(model, 33)
				local stamp = s.Tide.bump(model)
				table.insert(inside, { stamp = stamp, flushed = s.Tide.flush() })
			end
			return true
		end)
		s.step(2)
		hostile = true
		local n = s.sent()
		s.step(7) -- an interest recompute (every 0.1 s) falls in here
		T.eq(#inside, 1, "the audience function ran")
		T.check(inside[1].stamp ~= nil, "the bump was taken")
		T.eq(inside[1].flushed, 0, "flush inside Tide's own step")
		s.step(6)
		local cuts = 0
		for _, e in s.seen[1] do
			if e.cut then
				cuts += 1
			end
		end
		T.eq(cuts, 1, "the cut still reached the client, once")
		T.check(s.sent() > n)
		T.eq(s.Tide.stats().errors, 0)
		handle:setAudience(nil)

		-- a flush from inside the remote call a flush makes (a hook in FireClient)
		local nested = {}
		s.onPacket = function()
			s.onPacket = nil
			kick(model, 5)
			s.Tide.bump(model)
			table.insert(nested, s.Tide.flush())
		end
		kick(model, -40)
		s.Tide.bump(model)
		T.eq(s.Tide.flush(), 1)
		T.eq(nested[1], 0, "flush inside a flush")
		T.eq(s.State.lateN, 1, "the bump made in there waits")
		T.eq(s.Tide.flush(), 1, "and goes with the next flush")

		-- an entity added, kicked and flushed in one go, from a Tide.added handler of another
		local second: any = nil
		local sentInAdded = -1
		s.Tide.added(function(m)
			if m ~= second and second == nil then
				second = s.world:spawnModel("ball2", CFrame.new(3, 3, 0), false)
				s.Tide.add(second, "Ball")
				kick(second, 21)
				s.Tide.bump(second)
				sentInAdded = s.Tide.flush()
			end
		end)
		local first = s.world:spawnModel("ball1", CFrame.new(6, 3, 0), false)
		s.Tide.add(first, "Ball")
		T.eq(sentInAdded, 1, "sent from the handler")
		s.step(8)
		local ct = s.cts[1]
		local view = s.world:replica(1, second)
		local _, v = ct.latest(view)
		T.eq(v.X, 21, "the client has the new entity's kick")
		T.eq(ct.stats().unknownSlot, 0, "its ADD went out before the flushed sample")
		T.eq(ct.stats().badPacket, 0)
		T.eq(s.Tide.stats().errors, 0)
	end)

	T.test("bumped, then removed (and its slot reused) before the flush: nothing of it is sent", function()
		local s = setup()
		s.addPlayer()
		local Config = T.module(s.world, "Shared", "Config")
		local model, handle = s.ball()
		local other = s.ball(CFrame.new(4, 3, 10))
		s.step(20)
		local slot = s.State.bySlotModel[model]
		kick(model, 30)
		s.Tide.bump(model)
		handle:remove()
		local n = s.sent()
		T.eq(s.Tide.flush(), 0, "removed: nothing")
		T.eq(s.sent(), n)
		-- bumped, removed, and the slot taken by a new entity before the flush
		Config.SlotQuarantine = 0
		kick(other, 30)
		s.Tide.bump(other)
		local otherSlot = s.State.bySlotModel[other]
		s.Tide.remove(other)
		local fresh = s.world:spawnModel("fresh", CFrame.new(8, 3, 10), false)
		s.Tide.add(fresh, "Ball")
		T.check(s.State.bySlotModel[fresh] == otherSlot or s.State.bySlotModel[fresh] == slot, "a freed slot was reused")
		T.eq(s.Tide.flush(), 0, "the new entity was not bumped: its first sample goes with the frame")
		T.eq(s.sent(), n)
		s.step(8)
		T.check(s.cts[1].latest(s.world:replica(1, fresh)) ~= nil, "which it does")
		T.eq(s.Tide.stats().errors, 0)
		T.eq(s.cts[1].stats().badPacket, 0)
		Config.SlotQuarantine = 2
	end)

	T.test("a kind without velocity: a bumped sample is flushed in the plain record", function()
		local s = setup({ kind = { rate = 20, restRepeats = 0 } })
		s.addPlayer()
		local model = s.world:spawnModel("crate", CFrame.new(0, 3, 10), true)
		s.Tide.add(model, "Ball")
		s.step(20)
		table.clear(s.packets)
		model.HumanoidRootPart.CFrame = CFrame.new(2, 3, 10)
		local stamp = s.Tide.bump(model)
		T.eq(s.Tide.flush(), 1)
		local n, bytes = s.sent()
		T.eq(n, 1)
		-- the rest marker (where it stood, at the last idle tick) and the bumped sample
		T.eq(bytes, 10 + 2 * 10, "two 10 B records")
		s.step(6)
		local view = s.world:replica(1, model)
		T.near(s.cts[1].latest(view).X, 2, 1 / 64)
		local _, newest = s.cts[1].span(view)
		T.check(newest >= stamp - 0.0006, "the bumped sample is on the client")
	end)
end
