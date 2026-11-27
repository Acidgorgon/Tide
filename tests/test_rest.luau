-- Stop redundancy (kind option restRepeats): the stop sample of a server-owned entity goes out
-- again on the next n unchanged ticks, as the same sample (same time), so a lost packet does
-- not leave receivers carrying a stopped body on. With it go the two samples before it: the
-- one that brought the entity to rest (with its teleport and cut flags) and the one before
-- that. Receivers treat a copy as nothing new.
return function(T)
	local DT = 1 / 60
	local TICK = 0.0005

	-- Every relay record the server fires, per target player, before the network may lose it.
	local function tap(world)
		local Codec = T.module(world, "Shared", "Codec")
		local log = {}
		local send = world._send
		world._send = function(self, remote, fromServer, target, ...)
			local b = ...
			if fromServer and rawget(remote, "ClassName") == "UnreliableRemoteEvent" and type(b) == "buffer" then
				local n = buffer.len(b)
				local wide = buffer.readu8(b, 1) % 2 == 1
				local frameTime = buffer.readf64(b, 2)
				local pos = 10
				while pos < n do
					local function slotAt()
						local v = if wide then buffer.readu16(b, pos) else buffer.readu8(b, pos)
						pos += if wide then 2 else 1
						return v
					end
					local slot = slotAt()
					local hdr = -1
					if slot == 0 then
						hdr = buffer.readu8(b, pos)
						pos += 1
						slot = slotAt()
					end
					local ticks
					pos, ticks = Codec.readDt(b, pos)
					local at = pos
					local x, y, z
					pos, x, y, z = Codec.read(b, pos)
					local vx, vy, vz = 0, 0, 0
					if hdr >= 0 then
						pos, vx, vy, vz = Codec.readMotion(b, pos, hdr)
					end
					table.insert(log, {
						to = target,
						slot = slot,
						frame = frameTime,
						ticks = ticks,
						t = frameTime - ticks * TICK,
						x = x,
						y = y,
						z = z,
						vx = vx,
						vy = vy,
						vz = vz,
						cut = hdr >= Codec.CUT,
						body = buffer.readstring(b, at, pos - at),
						size = n,
					})
				end
				assert(pos == n, "packet fully consumed")
			end
			return send(self, remote, fromServer, target, ...)
		end
		return log
	end

	-- every record of the slot (for one receiver, if given) after log entry `from`
	local function ofAll(log, slot, from, to)
		local out = {}
		for i = (from or 0) + 1, #log do
			local r = log[i]
			if r.slot == slot and (to == nil or r.to == to) then
				table.insert(out, r)
			end
		end
		return out
	end

	-- the same, the newest record of each packet only (a repeat's packet: the stop sample)
	local function of(log, slot, from, to)
		local all = ofAll(log, slot, from, to)
		local out = {}
		for i, r in all do
			local nxt = all[i + 1]
			if nxt == nil or nxt.frame ~= r.frame or nxt.to ~= r.to then
				table.insert(out, r)
			end
		end
		return out
	end

	-- one client with a character at the origin; `kindOpts` is the kind "Crate"
	local function setup(kindOpts, opts)
		opts = opts or {}
		local world = T.world(opts.net or { latency = 0.02, start = 1.7e9, seed = 5 })
		local Tide = T.serverTide(world)
		Tide.kind("Crate", kindOpts)
		Tide.start({ players = true })
		local player = world:addPlayer()
		local char = world:spawnCharacter(player, CFrame.new(0, 3, 0))
		local ct = T.clientTide(world, 1)
		if opts.client then
			opts.client(ct)
		end
		ct.start()
		for _ = 1, 3 do
			world:frame(DT)
		end
		local model = world:spawnModel("crate", CFrame.new(5, 3, 0), not kindOpts.velocity)
		local handle = Tide.add(model, "Crate")
		local SState = T.module(world, "Server", "State")
		local s = {
			world = world,
			Tide = Tide,
			ct = ct,
			model = model,
			handle = handle,
			player = player,
			char = char,
			State = SState,
			slot = SState.bySlotModel[model],
			root = model.HumanoidRootPart,
			x = 5,
		}
		function s.step(n)
			for _ = 1, n or 1 do
				world:frame(DT)
			end
		end
		-- moves along +x at `speed` for n frames
		function s.move(n, speed)
			for _ = 1, n do
				s.x += (speed or 12) * DT
				s.root.CFrame = CFrame.new(s.x, 3, 0)
				world:frame(DT)
			end
		end
		function s.ring()
			local Cs = T.clientModule(world, 1, "Client", "State")
			local cslot = Cs.bySlotModel[world:replica(1, model)]
			return Cs.ring[cslot], Cs, cslot
		end
		return s
	end

	T.test("restRepeats: a whole number from 0 to 8; unset it is 2 for velocity kinds and 0 for the others", function()
		local world = T.world()
		local Tide = T.serverTide(world)
		local Kinds = T.module(world, "Shared", "Kinds")
		for _, bad in { -1, 1.5, 9, 0 / 0, math.huge, "2", true } do
			local ok, err = pcall(Tide.kind, "Bad", { restRepeats = bad })
			T.check(not ok and string.find(tostring(err), "restRepeats", 1, true) ~= nil, "refused: " .. tostring(bad))
		end
		T.eq(Kinds.byName.Bot.restRepeats, 0, "built-in kinds: 0")
		T.eq(Kinds.byName.Player.restRepeats, 0)
		T.eq(Tide.kind("Plain", { rate = 20 }).restRepeats, 0, "a plain kind: 0")
		T.eq(Tide.kind("Ball", { velocity = true }).restRepeats, 2, "a velocity kind: 2")
		T.eq(Tide.kind("Ball", { rate = 60 }).restRepeats, 2, "kept across later calls")
		T.eq(Tide.kind("Ball", { velocity = false }).restRepeats, 0, "it follows velocity while unset")
		T.eq(Tide.kind("Ball", { velocity = true, restRepeats = 0 }).restRepeats, 0, "an explicit 0 wins")
		T.eq(Tide.kind("Ball", { rate = 30 }).restRepeats, 0, "and stays")
		T.eq(Tide.kind("Plain", { restRepeats = 8 }).restRepeats, 8)
		T.eq(Tide.kind("Plain", { velocity = true }).restRepeats, 8, "a given value does not follow velocity")
	end)

	T.test("a stop: the stop sample again on each of the next n ticks, the same sample at the same time; then silence", function()
		local samples = 0
		local s = setup({ rate = 30, restRepeats = 2 }, {
			client = function(ct)
				ct.kind("Crate", {
					onSample = function()
						samples += 1
					end,
				})
			end,
		})
		local log = tap(s.world)
		s.move(40)
		local stopX = s.root.CFrame.X
		local mark = #log
		local r, Cs, cslot = s.ring()
		s.step(2) -- the packets in flight land
		local had, needs, called = r.last, Cs.src[cslot].count, samples
		local repeatsBefore = s.ct.stats().repeats
		s.step(18) -- 0.33 s at rest: under the keep-alive (0.5 s)
		local recs = of(log, s.slot, mark)
		-- (the last moving sample may still be among them: skip to the stop pose's first repeat)
		local stop = {}
		for i, rec in recs do
			if i > 1 and rec.x == recs[i - 1].x then
				if #stop == 0 then
					table.insert(stop, recs[i - 1])
				end
				table.insert(stop, rec)
			end
		end
		T.eq(#stop, 3, "the stop sample and two copies")
		T.near(stop[1].x, stopX, 1 / 64, "at the stop pose")
		for i = 2, 3 do
			T.near(stop[i].t, stop[1].t, 1e-6, "copy " .. i - 1 .. ": the stop sample's own time")
			T.eq(stop[i].body, stop[1].body, "copy " .. i - 1 .. ": the same bytes after the age")
			T.near(stop[i].frame - stop[i - 1].frame, 1 / 30, DT + 1e-6, "one tick after the one before")
			T.check(stop[i].ticks > stop[i - 1].ticks, "an older age in a later packet")
		end
		T.eq(recs[#recs], stop[3], "nothing after the copies")
		T.eq(s.Tide.stats().restRepeats, 2, "counted on the server")
		-- each copy's packet: the last of the motion, the sample that reached the stop pose and
		-- the stop sample, oldest first, each as it first went out
		local all = ofAll(log, s.slot, mark)
		local firstOf = {}
		for _, rec in ofAll(log, s.slot, 0) do
			local key = math.round(rec.t / TICK)
			firstOf[key] = firstOf[key] or rec
		end
		for k = 0, 1 do
			local a, b, c = all[#all - 5 + 3 * k], all[#all - 4 + 3 * k], all[#all - 3 + 3 * k]
			T.check(a.frame == c.frame and b.frame == c.frame, "one packet")
			T.eq(c, stop[2 + k])
			T.check(a.t < b.t and b.t < c.t, "oldest first")
			T.check(a.x < b.x, "the last sample of the motion")
			T.eq(b.x, c.x, "the sample that reached the stop pose")
			T.near(c.t - b.t, 1 / 30, DT + 1e-6, "a tick before the stop sample")
			for _, rec in { a, b } do
				local first = firstOf[math.round(rec.t / TICK)]
				T.check(first ~= rec and first.frame < rec.frame, "sent before")
				T.near(rec.t, first.t, 1e-6, "at the same time")
				T.eq(rec.body, first.body, "the same bytes")
			end
		end
		-- the client: one new sample (the stop), the copies are nothing
		T.eq(s.ct.stats().repeats - repeatsBefore, 6, "counted on the client: three records a packet")
		T.eq(s.ct.stats().late, 0, "not late samples")
		T.eq(r.last - had, 1, "one sample stored for three records")
		T.eq(samples - called, 1, "onSample once")
		T.eq(Cs.src[cslot].count, needs, "the stop and its copies add no buffer need")
		T.eq(s.ct.sampleInfo(s.world:replica(1, s.model)).idle, true)
		-- then only keep-alives, which are not repeated
		mark = #log
		s.step(120)
		local idle = of(log, s.slot, mark)
		T.check(#idle >= 3 and #idle <= 5, "2 s at rest: keep-alives only: " .. #idle)
		for i = 2, #idle do
			T.check(idle[i].t - idle[i - 1].t > 0.4, "each a new sample")
		end
		T.eq(s.Tide.stats().restRepeats, 2, "no repeats of keep-alives")
		T.eq(s.ct.stats().badPacket, 0)
	end)

	T.test("restRepeats = 0 (the default of a plain kind): the stop sample once", function()
		local s = setup({ rate = 30 })
		local log = tap(s.world)
		s.move(40)
		s.step(20)
		local recs = of(log, s.slot, 0)
		local stop = recs[#recs]
		T.near(stop.x, s.x, 1 / 64, "the last record is the stop sample")
		T.check(recs[#recs - 1].x == stop.x and recs[#recs - 1].t < stop.t, "after the sample that reached the pose")
		T.check(recs[#recs - 2].x < stop.x, "and nothing else stands there")
		T.eq(s.Tide.stats().restRepeats, 0)
		T.eq(s.ct.stats().repeats, 0)
	end)

	T.test("the stop sample lost: a copy is the sample (stored once, announced once); all lost: the keep-alive", function()
		local seen = {}
		local s = setup({ rate = 30, restRepeats = 2, keepAlive = 1 }, {
			client = function(ct)
				ct.kind("Crate", {
					onSample = function(_, t, cf)
						table.insert(seen, { t = t, x = cf.X })
					end,
				})
			end,
		})
		local log = tap(s.world)
		local world = s.world
		local view = world:replica(1, s.model)
		-- frames until the next record of the entity is fired; `lose` drops that packet
		local function untilRecord(lose)
			local mark = #log
			for _ = 1, 80 do
				world.blockS2C = lose
				world:frame(DT)
				world.blockS2C = false
				if #of(log, s.slot, mark) > 0 then
					return of(log, s.slot, mark)[1]
				end
			end
			error("no record")
		end
		s.move(40)
		s.step(1)
		-- the stop sample is lost; the first copy arrives
		local stop = untilRecord(true)
		T.near(stop.x, s.x, 1 / 64, "the stop sample (lost)")
		table.clear(seen)
		local first = untilRecord(false)
		T.near(first.t, stop.t, 1e-6, "its first copy")
		s.step(3)
		local _, _, _, _ = s.ct.latest(view)
		local r = s.ring()
		T.near(r.t[r.last % r.cap + 1], stop.t, 1e-6, "the client holds the stop sample, at its own time")
		T.eq(#seen, 1, "announced once")
		T.near(seen[1].t, stop.t, 1e-6)
		local had = r.last
		s.step(10) -- the second copy
		T.eq(r.last, had, "the second copy is nothing new")
		T.eq(#seen, 1)
		T.eq(s.ct.stats().repeats, 2 + 3, "two samples of the first packet were held; all three of the second")
		T.eq(s.ct.sampleInfo(view).idle, true, "the stream reads at rest")

		-- move again, stop again; this time the stop and both copies are lost
		s.move(20)
		s.step(1)
		local last = s.ct.latest(view).X
		local sentAt = untilRecord(true).t
		T.near(untilRecord(true).t, sentAt, 1e-6, "copy 1 (lost)")
		T.near(untilRecord(true).t, sentAt, 1e-6, "copy 2 (lost)")
		s.step(6)
		T.check(s.ct.latest(view).X <= last + 12 / 30 + 0.02, "the client knows nothing of the stop yet")
		local keep = untilRecord(false)
		T.check(keep.t - sentAt > 0.9, "the keep-alive, a second later: " .. keep.t - sentAt)
		s.step(3)
		T.near(s.ct.latest(view).X, s.x, 1 / 64, "which carries the stop pose")
		T.eq(s.Tide.stats().restRepeats, 4)
		T.eq(s.ct.stats().badPacket, 0)
	end)

	T.test("moving again before the copies are spent ends them; a teleport and a bump end them too", function()
		local s = setup({ rate = 30, restRepeats = 4 })
		local stats = s.Tide.stats
		local function untilRepeats(n)
			for _ = 1, 40 do
				if stats().restRepeats >= n then
					return
				end
				s.step(1)
			end
			error("repeats never reached " .. n)
		end
		s.move(30)
		untilRepeats(1)
		s.move(10) -- three copies were still owed
		T.eq(stats().restRepeats, 1, "no copy while it moves")
		T.eq(s.State.restLeft[s.slot], 0, "none owed")
		s.step(30)
		T.eq(stats().restRepeats, 5, "the next stop has its own four")
		-- a teleport during the copies
		s.move(10)
		untilRepeats(6)
		s.handle:teleport(CFrame.new(40, 3, 0))
		s.x = 40
		T.eq(s.State.restLeft[s.slot], 0, "a teleport is a new sample: none owed")
		s.step(30)
		T.eq(stats().restRepeats, 10, "then the stop after the teleport, repeated")
		-- a bump that finds the entity moved, during the copies
		s.move(10)
		untilRepeats(11)
		s.x += 3
		s.root.CFrame = CFrame.new(s.x, 3, 0)
		T.check(s.Tide.bump(s.model) ~= nil)
		T.eq(s.State.restLeft[s.slot], 0, "a bump that sampled: none owed")
		-- a bump that finds nothing changed leaves the copies alone
		s.step(4)
		local owed = s.State.restLeft[s.slot]
		T.check(owed > 0 and owed < 4, "the stop after the bump is being repeated: " .. owed)
		s.Tide.bump(s.model)
		T.eq(s.State.restLeft[s.slot], owed, "an idle bump changes nothing")
		s.step(30)
		T.eq(stats().restRepeats, 15)
		T.eq(s.ct.stats().late, 0)
		T.eq(s.ct.stats().repeats, 15 * 3, "every copy reached the client as a copy (three records each)")
		local view = s.world:replica(1, s.model)
		T.near(s.ct.latest(view).X, s.x, 1 / 64)
	end)

	T.test("velocity kinds: a body that stops dead, and one bumped at rest that stays at rest", function()
		local seen = {}
		local s = setup({ velocity = true, rotation = "full", rate = 60, near = math.huge, apply = "none", keepAlive = 1 }, {
			client = function(ct)
				ct.kind("Crate", {
					onSample = function(_, t, cf, v, _, cut)
						table.insert(seen, { t = t, x = cf.X, v = v.X, cut = cut })
					end,
				})
			end,
		})
		local world = s.world
		local log = tap(world)
		local view = world:replica(1, s.model)
		local root = s.root
		local function roll(n, speed)
			for _ = 1, n do
				s.x += speed * DT
				root.CFrame = CFrame.new(s.x, 3, 0)
				root.AssemblyLinearVelocity = Vector3.new(speed, 0, 0)
				world:frame(DT)
			end
		end
		roll(40, 25)
		-- stops dead: the velocity is zero from this frame on, the pose stands
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		local mark = #log
		s.step(30)
		local recs = of(log, s.slot, mark)
		-- the first sample at rest (the velocity changed), the stop sample, two copies of it
		T.eq(#recs, 4, "four records carry the stop")
		for i = 1, 4 do
			T.near(recs[i].x, s.x, 1 / 64, "at the stop pose")
			T.eq(recs[i].vx, 0, "at rest")
			-- a 16 B record; with a copy go the first sample at rest (16 B) and the last one
			-- rolling (22 B: a velocity)
			T.eq(recs[i].size, if i <= 2 then 10 + 16 else 10 + 22 + 16 + 16, "packet " .. i)
		end
		T.check(recs[2].t > recs[1].t, "the stop sample is a sample of its own")
		T.near(recs[3].t, recs[2].t, 1e-6, "copy 1")
		T.near(recs[4].t, recs[2].t, 1e-6, "copy 2")
		T.eq(s.Tide.stats().restRepeats, 2)
		T.eq(s.ct.stats().repeats, 6)

		-- placed somewhere else while at rest (a set piece), and bumped; the cut sample and the
		-- stop sample after it are lost
		s.step(70)
		table.clear(seen)
		s.x = 60
		root.CFrame = CFrame.new(60, 3, 0)
		mark = #log
		local stamp = s.Tide.bump(s.model)
		T.check(stamp ~= nil)
		local lost = 0
		for _ = 1, 40 do
			-- lose the packets with the cut sample and with the stop sample's first copy
			local before = #of(log, s.slot, mark)
			world.blockS2C = lost < 2
			world:frame(DT)
			world.blockS2C = false
			if #of(log, s.slot, mark) > before then
				lost += 1
			end
		end
		recs = ofAll(log, s.slot, mark)
		-- rest marker (old pose) and cut at the new pose; the stop sample; then twice all three
		T.eq(#recs, 2 + 1 + 3 + 3, "records of the placement: " .. #recs)
		T.near(recs[1].x, 5 + 40 * 25 * DT, 1 / 32, "the rest marker, where it stood")
		T.check(recs[2].cut and math.abs(recs[2].x - 60) < 1 / 64, "the cut, where it stands now")
		T.near(recs[2].t, stamp, TICK + 1e-6, "at the bump's stamp")
		T.check(not recs[3].cut and recs[3].x == recs[2].x and recs[3].t > recs[2].t, "the stop sample after it")
		for k = 0, 1 do
			for j = 1, 3 do
				local copy = recs[3 + 3 * k + j]
				T.near(copy.t, recs[j].t, 1e-6, "copy " .. k + 1 .. " of record " .. j)
				T.eq(copy.body, recs[j].body)
				T.eq(copy.cut, recs[j].cut, "the cut flag goes with its sample")
			end
		end
		-- the client lost the marker with the cut, and the stop sample: the first copy brought
		-- all three, the cut as a cut at the time of the bump
		local cf, v, _, t = s.ct.latest(view)
		T.near(cf.X, 60, 1 / 64, "the client has the new pose")
		T.eq(v.X, 0)
		T.near(t, recs[3].t, 1e-6, "the stop sample is its newest")
		T.eq(#seen, 3, "the marker, the cut and the stop sample, once each")
		T.near(seen[1].x, recs[1].x, 1 / 64, "where it stood")
		T.check(seen[2].cut and not seen[1].cut and not seen[3].cut, "the cut arrived as a cut")
		T.near(seen[2].t, stamp, TICK + 1e-6, "at the bump's stamp")
		T.near(seen[2].x, 60, 1 / 64)
		-- so the client's path jumps at the bump, not before: just before it the old place
		T.near(s.ct.at(view, recs[1].t).X, recs[1].x, 1 / 64, "at the marker: the old place")
		T.near(s.ct.at(view, stamp + TICK).X, 60, 1 / 64, "after the cut: the new place")
		T.eq(s.Tide.stats().restRepeats, 4)
		T.eq(s.ct.stats().badPacket, 0)
	end)

	T.test("tiers and budget: copies reach mid and far receivers over budget; never culled ones or ones outside the audience", function()
		local world = T.world({ latency = 0.02, start = 1.7e9 })
		local Tide = T.serverTide(world)
		Tide.kind("Crate", { rate = 30, restRepeats = 2, near = 100, far = 250, cull = 400 })
		Tide.start({ players = false })
		local Config = T.module(world, "Shared", "Config")
		local SState = T.module(world, "Server", "State")
		-- receivers by focus: near, mid, far, culled by distance, near but outside the audience
		local at = { 0, 150, 300, 1000, 0 }
		local players, cts = {}, {}
		for i = 1, 5 do
			players[i] = world:addPlayer()
			Tide.focus(players[i], Vector3.new(at[i], 3, 0))
			cts[i] = T.clientTide(world, i)
			cts[i].start()
		end
		local model = world:spawnModel("crate", CFrame.new(0, 3, 0), true)
		local handle = Tide.add(model, "Crate")
		handle:setAudience({ players[1], players[2], players[3], players[4] })
		local slot = SState.bySlotModel[model]
		for _ = 1, 12 do
			world:frame(DT)
		end
		for i = 1, 5 do
			T.eq(SState.rx[players[i]].tier[slot], ({ 1, 2, 3, 4, 4 })[i], "tier of receiver " .. i)
		end
		-- no budget at all: mid and far records are dropped, every one
		Config.ReceiverBytesPerSecond = 1
		for i = 1, 5 do
			SState.rx[players[i]].tokens = 0
		end
		local log = tap(world)
		local z = 0
		for _ = 1, 40 do
			z += 12 * DT
			model.HumanoidRootPart.CFrame = CFrame.new(0, 3, z)
			world:frame(DT)
		end
		local dropped = Tide.stats().budgetDropped
		T.check(dropped > 0, "the moving samples were dropped for the mid and far receivers")
		local copies = { cts[1].stats().repeats, cts[2].stats().repeats, cts[3].stats().repeats }
		local sentBefore = Tide.stats().restRepeats
		T.eq(#of(log, slot, 0, players[2]), 0, "mid: nothing while over budget")
		T.eq(#of(log, slot, 0, players[3]), 0, "far: nothing while over budget")
		local mark = #log
		for _ = 1, 20 do
			world:frame(DT)
		end
		local nearRecs = of(log, slot, mark, players[1])
		local stop = nearRecs[#nearRecs]
		T.near(stop.z, z, 1 / 64)
		T.near(nearRecs[#nearRecs - 1].t, stop.t, 1e-6, "near: the stop sample and its two copies")
		T.near(nearRecs[#nearRecs - 2].t, stop.t, 1e-6)
		T.check(#nearRecs == 3 or nearRecs[#nearRecs - 3].t < stop.t - 0.01, "and no third copy")
		for i = 2, 3 do
			local recs = of(log, slot, mark, players[i])
			T.eq(#recs, 2, "receiver " .. i .. ": the two copies, whatever the budget")
			T.near(recs[1].z, z, 1 / 64, "the stop pose")
			T.near(recs[1].t, stop.t, 1e-6, "the stop sample, as the near receiver got it")
			T.near(recs[2].t, stop.t, 1e-6)
			local cf = cts[i].latest(world:replica(i, model))
			T.near(cf.Z, z, 1 / 64, "receiver " .. i .. " knows where it stopped")
			T.eq(cts[i].stats().repeats - copies[i], 3, "the first packet was news (three samples), the second three copies")
			T.eq(SState.rx[players[i]].tokens, -1, "charged to the budget all the same (down to its floor, a second's worth)")
		end
		T.eq(#of(log, slot, 0, players[4]), 0, "culled by distance: nothing")
		T.eq(#of(log, slot, 0, players[5]), 0, "outside the audience: nothing")
		T.eq(Tide.stats().restRepeats - sentBefore, 2, "encoded once each, whoever receives them")
		Config.ReceiverBytesPerSecond = 40960
	end)

	T.test("an owner change or a removal during the copies: no copy afterwards, nothing stale, no error", function()
		local s = setup({ rate = 30, restRepeats = 3 })
		local stats = s.Tide.stats
		local function untilRepeats(n)
			for _ = 1, 40 do
				if stats().restRepeats >= n then
					return
				end
				s.step(1)
			end
			error("repeats never reached " .. n)
		end
		s.move(30)
		untilRepeats(1)
		T.eq(s.State.restLeft[s.slot], 2)
		-- handed to the player with two copies owed
		s.handle:setOwner(s.player)
		T.eq(s.State.restLeft[s.slot], 0, "an owner change ends them")
		s.step(40)
		T.eq(stats().restRepeats, 1, "none for a client-owned entity")
		-- back to the server: its first unchanged tick is a stop sample with its own copies
		s.handle:setOwner(nil)
		s.step(40)
		T.eq(stats().restRepeats, 4)
		-- removed with copies owed
		s.move(10)
		untilRepeats(5)
		T.eq(s.State.restLeft[s.slot], 2)
		s.handle:remove()
		T.eq(s.State.restLeft[s.slot], nil)
		s.step(40)
		T.eq(stats().restRepeats, 5, "none for a removed entity")
		T.eq(stats().errors, 0)
		T.eq(s.ct.stats().badPacket, 0)
	end)

	T.test("removed and its slot reused between the tick that asked for a copy and the relay: the copy is dropped", function()
		local s = setup({ rate = 30, restRepeats = 3 })
		local world = s.world
		local Config = T.module(world, "Shared", "Config")
		Config.SlotQuarantine = 0
		local swap = false
		local swapped: any = nil
		-- a profiler probe that finishes between the ticker and the relay runs game code there
		local lh = {}
		function lh.probe(name)
			local p = {}
			function p.begin() end
			function p.finish()
				if name == "Tide.Sample" and swap and s.State.restDue[s.slot] then
					swap = false
					s.handle:remove()
					swapped = world:spawnModel("other", CFrame.new(-20, 3, 0), true)
					s.Tide.add(swapped, "Crate")
				end
			end
			return p
		end
		function lh.net() end
		world.server.shared.Lighthouse = lh
		s.move(30)
		for _ = 1, 20 do
			if s.Tide.stats().restRepeats >= 1 then
				break
			end
			s.step(1)
		end
		T.eq(s.Tide.stats().restRepeats, 1)
		local log = tap(world)
		swap = true
		s.step(3)
		T.check(swapped ~= nil, "swapped between the tick and the relay")
		T.eq(s.State.bySlotModel[swapped], s.slot, "the slot was reused at once")
		local recs = of(log, s.slot, 0)
		T.near(recs[1].x, -20, 1 / 64, "the first record of the slot is the new entity's own")
		world.server.shared.Lighthouse = nil
		s.step(40)
		-- the old entity's two owed copies were never sent; the new one stopped and had its three
		T.eq(s.Tide.stats().restRepeats, 4)
		T.eq(s.Tide.stats().errors, 0)
		T.eq(s.ct.stats().badPacket, 0)
		Config.SlotQuarantine = 2
	end)

	T.test("slow kinds: a copy older than 127 ms uses the long age; older than 30 s it is not sent", function()
		local s = setup({ rate = 10, restRepeats = 8, keepAlive = 5 })
		local log = tap(s.world)
		s.move(40)
		local mark = #log
		s.step(70) -- 1.17 s: the stop and eight copies, 0.1 s apart
		local recs = of(log, s.slot, mark)
		local stop = recs[#recs - 8]
		T.near(stop.x, s.x, 1 / 64)
		for i = #recs - 7, #recs do
			T.near(recs[i].t, stop.t, 1e-6, "a copy")
		end
		T.check(recs[#recs].ticks > 1500, "0.8 s old in its packet: " .. recs[#recs].ticks)
		T.eq(s.Tide.stats().restRepeats, 8)
		T.eq(s.ct.stats().repeats, 8 * 3)
		T.eq(s.ct.stats().late, 0)
		T.eq(s.ct.stats().badPacket, 0)

		-- a tick every 8 s, a keep-alive every 100 s: copies would be 8, 16, 24, 32 ... s old
		local slow = setup({ rate = 0.125, restRepeats = 8, keepAlive = 100 })
		local slowLog = tap(slow.world)
		for _ = 1, 9 * 8 * 10 do
			slow.world:frame(0.1)
		end
		local all = of(slowLog, slow.slot, 0)
		T.eq(slow.Tide.stats().restRepeats, 3, "8, 16 and 24 s old; not 32 and later")
		T.check(all[#all].ticks <= 65535 and all[#all].ticks > 40000, "the oldest fits the age field: " .. all[#all].ticks)
		T.eq(slow.ct.stats().badPacket, 0)
	end)

	T.test("many stops on a jittered clock: every copy decodes to its sample's time (no stray sample, none late)", function()
		local s = setup({ rate = 60, restRepeats = 2 }, { net = { latency = 0.02, start = 1.7e9 + 12345.678, seed = 3 } })
		local world = s.world
		-- (the host has no Random: a small generator of its own)
		local seed = 77
		local rng = {}
		s.step(5)
		function rng:NextNumber()
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		function rng:NextInteger(a, b)
			return a + math.floor(self:NextNumber() * (b - a + 1))
		end
		local h = s.State.hist[s.slot]
		local stops = 0
		for cycle = 1, 400 do
			-- a few frames of motion (to and fro: it stays near), a few at rest, on frame times
			-- that are not on any grid
			for _ = 1, rng:NextInteger(2, 5) do
				s.x += if cycle % 2 == 0 then 0.3 else -0.3
				s.root.CFrame = CFrame.new(s.x, 3, 0)
				world:frame(DT * (0.7 + 0.6 * rng:NextNumber()))
			end
			for _ = 1, rng:NextInteger(3, 6) do
				world:frame(DT * (0.7 + 0.6 * rng:NextNumber()))
			end
			stops += 1
		end
		s.step(10)
		local r = s.ring()
		local sent = s.Tide.stats().restRepeats
		T.check(sent >= stops * 1.5, "copies sent: " .. sent)
		T.check(s.ct.stats().repeats <= sent * 3 and s.ct.stats().repeats >= sent * 3 - 3, "each one dropped as a copy, three records a packet: " .. s.ct.stats().repeats)
		T.eq(s.ct.stats().late, 0)
		-- the client's ring holds the server's samples, one for one
		local n = math.min(r.n, h.n) - 1
		for k = 0, n - 1 do
			local a = r.t[(r.last - k) % r.cap + 1]
			local b = h.t[(h.last - k) % h.cap + 1]
			T.near(a, b, TICK, "sample " .. k .. " back")
		end
		T.eq(s.ct.stats().badPacket, 0)
	end)

	T.test("a sample half a tick off the packets' grid: its copies decode to its time whichever way an age rounds", function()
		local s = setup({ rate = 30, restRepeats = 2 })
		local world = s.world
		local Ring = T.module(world, "Shared", "Ring")
		local St = s.State
		local slot = s.slot
		local h = St.hist[slot]
		s.step(30)
		local r = s.ring()
		for j = 1, 24 do
			-- a sample of the entity (it stands where the sample says) whose age in any packet
			-- ends in half a tick, up to the clock's own rounding
			local t = math.floor(world.now / TICK) * TICK - (2 * j + 0.5) * TICK
			T.check(t > Ring.newestT(h))
			s.x += 0.25
			s.root.CFrame = CFrame.new(s.x, 3, 0)
			T.check(Ring.push(h, t, s.x, 3, 0, 0, 0, 0, 0, 0, 1) > 0)
			St.sentT[slot] = world.now
			local had = r.last
			local copies = s.ct.stats().repeats
			world:frame(DT * 0.9)
			for k = 1, 8 do
				if not St.restDue[slot] then
					St.restDue[slot] = true
					St.restN += 1
					St.restList[St.restN] = slot
				end
				world:frame(DT * (0.6 + 0.07 * k))
			end
			s.step(3)
			T.eq(h.t[h.last % h.cap + 1], t, "no other sample was taken")
			T.eq(r.last - had, 1, "sample " .. j .. ": stored once")
			T.eq(s.ct.stats().repeats - copies, 8 * 3, "sample " .. j .. ": eight copies, of it and the two before")
			T.near(r.t[r.last % r.cap + 1], t, TICK * 0.5 + 1e-6)
		end
		T.eq(s.ct.stats().late, 0)
		T.eq(s.ct.stats().badPacket, 0)
	end)

	T.test("copies of the same record in any order, and twice in one packet: stored once", function()
		local world = T.world({ start = 1.7e9 })
		local Tide = T.serverTide(world)
		Tide.kind("Ball", { velocity = true, rotation = "full", restRepeats = 2 })
		Tide.start({ players = true })
		world:spawnCharacter(world:addPlayer(), CFrame.new(0, 3, 0))
		local ct = T.clientTide(world, 1)
		local seen = 0
		ct.kind("Ball", {
			onSample = function()
				seen += 1
			end,
		})
		ct.start()
		local model = world:spawnModel("ball", CFrame.new(0, 5, 0), false)
		Tide.add(model, "Ball")
		for _ = 1, 10 do
			world:frame(DT)
		end
		local Cs = T.clientModule(world, 1, "Client", "State")
		local Receive = T.clientModule(world, 1, "Client", "Receive")
		local Codec = T.clientModule(world, 1, "Shared", "Codec")
		local cslot = Cs.bySlotModel[world:replica(1, model)]
		local r = Cs.ring[cslot]
		local base = math.ceil((world.now + 1) / TICK) * TICK
		-- a packet at frame time `frame` with samples (tick index from base, x)
		local function packet(frame, list)
			local b = buffer.create(10 + #list * 32)
			buffer.writeu8(b, 0, 1)
			buffer.writeu8(b, 1, 0)
			buffer.writef64(b, 2, frame)
			local pos = 10
			for _, e in list do
				buffer.writeu8(b, pos, 0)
				buffer.writeu8(b, pos + 1, 0)
				buffer.writeu8(b, pos + 2, cslot)
				pos = Codec.writeDt(b, pos + 3, math.round((frame - (base + e[1] * TICK)) / TICK))
				pos = Codec.write(b, pos, e[2], 5, 0, 0, 2, 0, 0, 0, 1)
			end
			local out = buffer.create(pos)
			buffer.copy(out, 0, b, 0, pos)
			return out
		end
		local had, called = r.last, seen
		local before = ct.stats().repeats
		local late = ct.stats().late
		Receive.packet(packet(base + 0.05, { { 0, 1 }, { 40, 2 }, { 80, 3 } }), base + 0.08)
		T.eq(r.last - had, 3)
		-- the newest again from a later packet, an older one from a still later one, the middle
		-- one twice in one packet, and a sample one tick after the oldest (not a copy)
		Receive.packet(packet(base + 0.0835, { { 80, 3 } }), base + 0.1)
		Receive.packet(packet(base + 0.1505, { { 0, 1 } }), base + 0.17)
		Receive.packet(packet(base + 0.2, { { 40, 2 }, { 40, 2 }, { 1, 1.5 } }), base + 0.22)
		T.eq(r.last - had, 4, "three samples and the one a tick later")
		T.eq(seen - called, 4, "onSample for those four")
		T.eq(ct.stats().repeats - before, 4, "four copies")
		T.eq(ct.stats().late - late, 0)
		-- older than everything held and no copy of anything: late, as before
		for k = 1, r.cap do
			Receive.packet(packet(base + 1 + k * 0.02, { { 2000 + k * 40, k } }), base + 1 + k * 0.02)
		end
		Receive.packet(packet(base + 3, { { 500, 9 } }), base + 3)
		T.eq(ct.stats().late - late, 1, "a sample older than the ring holds is late, not a copy")
		T.eq(ct.stats().badPacket, 0)
	end)
end
