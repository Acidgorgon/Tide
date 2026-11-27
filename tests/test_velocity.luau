-- v0.5: kinds with velocity = true (a ball the server simulates), Tide.bump, apply = "none"
-- from the server, onSample, the server-side lock (kind option lock) and links with velocity.
return function(T)
	local DT = 1 / 60
	local G = -196.2
	local SUB = 4 -- physics substeps per frame (240 Hz, as Roblox integrates)

	local function vec(x, y, z)
		return Vector3.new(x, y, z)
	end

	local BALL = { velocity = true, rotation = "full", rate = 30, near = math.huge, apply = "none" }

	local function setup(opts: any?)
		opts = opts or {}
		local world = T.world(opts.net or { latency = 0.03, jitter = 0.004, seed = 7 })
		local Tide = T.serverTide(world)
		Tide.kind("Ball", opts.kind or BALL)
		if opts.before then
			opts.before(world, Tide)
		end
		Tide.start({ players = true })
		local chars, cts = {}, {}
		for i = 1, opts.clients or 1 do
			chars[i] = world:spawnCharacter(world:addPlayer(), CFrame.new(i * 10, 3, 0))
		end
		for i = 1, opts.clients or 1 do
			cts[i] = T.clientTide(world, i)
			if opts.client then
				opts.client(cts[i], i)
			end
			cts[i].start()
		end
		local model = world:spawnModel("ball", CFrame.new(0, 5, 0), false)
		local handle = Tide.add(model, opts.kindName or "Ball")
		return world, Tide, model, handle, cts, chars
	end

	-- A ball the test simulates as the server's physics would: gravity, a floor at y = 1 it
	-- bounces on (restitution 0.6), spin about Y. write() puts the state on the root part.
	local function newSim(model, x, y, z, vx, vy, vz, wy)
		local sim = { x = x, y = y, z = z, vx = vx, vy = vy, vz = vz, wy = wy or 0, a = 0, bounced = false, gravity = true }
		local root = model.HumanoidRootPart
		function sim.write()
			root.CFrame = CFrame.new(sim.x, sim.y, sim.z) * CFrame.Angles(0, sim.a, 0)
			root.AssemblyLinearVelocity = vec(sim.vx, sim.vy, sim.vz)
			root.AssemblyAngularVelocity = vec(0, sim.wy, 0)
		end
		function sim.step(dt)
			sim.bounced = false
			local h = dt / SUB
			for _ = 1, SUB do
				if sim.gravity then
					sim.vy += G * h
				end
				sim.x += sim.vx * h
				sim.y += sim.vy * h
				sim.z += sim.vz * h
				if sim.gravity and sim.y < 1 then
					sim.y = 1 + (1 - sim.y) * 0.6
					sim.vy = -sim.vy * 0.6
					sim.bounced = true
				end
				sim.a += sim.wy * h
			end
			sim.write()
		end
		sim.write()
		return sim
	end

	-- runs `frames` frames; truth[k] = { t, x, y, z, vx, vy, vz } at each server frame time
	local function run(world, sim, frames, truth, each)
		for f = 1, frames do
			sim.step(DT)
			if truth then
				table.insert(truth, { world.now + DT, sim.x, sim.y, sim.z, sim.vx, sim.vy, sim.vz })
			end
			world:frame(DT)
			if each then
				each(f)
			end
		end
	end

	-- the truth at a sample's time (client times are on the wire's 0.5 ms grid)
	local function truthAt(truth, t)
		for _, s in truth do
			if math.abs(s[1] - t) < 0.0006 then
				return s
			end
		end
		return nil
	end

	----------------------------------------------------------------------------
	-- Codec, Ring, Interp
	----------------------------------------------------------------------------

	T.test("codec: velocity and spin round trip (narrow, wide, zero, non-finite); quantizeMotion is what decodes", function()
		local world = T.world()
		local Codec = T.module(world, "Shared", "Codec")
		local b = buffer.create(64)
		local function trip(vx, vy, vz, wx, wy, wz)
			local off, hdr = Codec.writeMotion(b, 3, vx, vy, vz, wx, wy, wz)
			T.eq(off - 3, Codec.motionSize(hdr), "motionSize")
			local end2, a, bb, c, d, e, f = Codec.readMotion(b, 3, hdr)
			T.eq(end2, off, "read size")
			local qa, qb, qc, qd, qe, qf = Codec.quantizeMotion(vx, vy, vz, wx, wy, wz)
			T.check(a == qa and bb == qb and c == qc and d == qd and e == qe and f == qf, "decoded = quantized")
			-- idempotent: what history keeps is what every later encode sends
			local ra, rb, rc, rd, re, rf = Codec.quantizeMotion(qa, qb, qc, qd, qe, qf)
			T.check(ra == qa and rb == qb and rc == qc and rd == qd and re == qe and rf == qf, "idempotent")
			return hdr, off - 3, a, bb, c, d, e, f
		end
		-- a shot with spin: 6 + 6 bytes, within 1/64 stud/s and 1/128 rad/s
		local hdr, size, vx, vy, vz, wx, wy, wz = trip(87.3312, -41.07, 3.999, 12.3456, -31.4159, 0.007)
		T.eq(hdr, Codec.VEL + Codec.SPIN, "narrow header")
		T.eq(size, 12, "narrow size")
		T.near(vx, 87.3312, 1 / 64, "vx")
		T.near(vy, -41.07, 1 / 64, "vy")
		T.near(vz, 3.999, 1 / 64, "vz")
		T.near(wx, 12.3456, 1 / 128, "wx")
		T.near(wy, -31.4159, 1 / 128, "wy")
		T.near(wz, 0.007, 1 / 128, "wz")
		-- at rest: nothing
		hdr, size = trip(0, 0, 0, 0, 0, 0)
		T.eq(hdr, 0, "rest header")
		T.eq(size, 0, "rest size")
		-- below the grid: also nothing (rounds to zero)
		hdr, size = trip(0.004, -0.004, 0, 0.002, 0, 0)
		T.eq(size, 0, "sub-grid size")
		-- only one of the two
		hdr, size = trip(1, 0, 0, 0, 0, 0)
		T.eq(hdr, Codec.VEL, "velocity only")
		T.eq(size, 6)
		hdr, size = trip(0, 0, 0, 0, 2, 0)
		T.eq(hdr, Codec.SPIN, "spin only")
		T.eq(size, 6)
		-- out of the i16 range: f32, exact to f32
		hdr, size, vx, vy, vz, wx, wy, wz = trip(1500.25, -2, 3, 600, 0, -700.5)
		T.eq(hdr, Codec.VEL + Codec.SPIN + Codec.VEL_WIDE + Codec.SPIN_WIDE, "wide header")
		T.eq(size, 24, "wide size")
		T.eq(vx, 1500.25)
		T.eq(wz, -700.5)
		-- the edge of the narrow range stays narrow
		hdr = trip(1023.96875, -1023.96875, 0, 511.984375, 0, 0)
		T.eq(hdr, Codec.VEL + Codec.SPIN, "edge is narrow")
		hdr = trip(1024, 0, 0, 512, 0, 0)
		T.eq(hdr, Codec.VEL + Codec.SPIN + Codec.VEL_WIDE + Codec.SPIN_WIDE, "past the edge is wide")
		-- non-finite components never reach a receiver
		hdr, size, vx, vy, vz, wx, wy, wz = trip(0 / 0, math.huge, -math.huge, 0 / 0, 1, 2)
		T.check(vx == 0 and vy == 0 and vz == 0, "non-finite velocity is zero")
		T.check(wx == 0 and wy == 1 and wz == 2, "non-finite spin component is zero")
		-- a wide vector with garbage f32 bits decodes finite
		buffer.writef32(b, 0, 0 / 0)
		buffer.writef32(b, 4, math.huge)
		buffer.writef32(b, 8, 5)
		local _, a, bb, c = Codec.readMotion(b, 0, Codec.VEL + Codec.VEL_WIDE)
		T.check(a == 0 and bb == 0 and c == 5, "read never returns non-finite")
	end)

	T.test("ring: velocity travels with its sample (push, out-of-order insert, eviction); plain rings ignore it", function()
		local world = T.world()
		local Ring = T.module(world, "Shared", "Ring")
		local r = Ring.new(4, false, true)
		T.check(r.vel)
		Ring.setVel(r, Ring.push(r, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1), 1, 0, 0, 0, 0, 1)
		Ring.setVel(r, Ring.push(r, 3, 0, 0, 0, 0, 0, 0, 0, 0, 1), 3, 0, 0, 0, 0, 3)
		local li = Ring.push(r, 2, 0, 0, 0, 0, 0, 0, 0, 0, 1) -- between the two
		Ring.setVel(r, li, 2, 0, 0, 0, 0, 2)
		for i = 1, 3 do
			local p = i % r.cap + 1
			T.eq(r.t[p], i, "time order")
			T.eq(r.vx[p], i, "velocity moved with its sample")
			T.eq(r.wz[p], i, "spin moved with its sample")
		end
		-- a rejected push (duplicate time) sets nothing
		Ring.setVel(r, Ring.push(r, 2, 9, 9, 9, 0, 0, 0, 0, 0, 1), 99, 99, 99, 99, 99, 99)
		T.eq(r.vx[2 % r.cap + 1], 2, "duplicate ignored")
		-- a new sample starts with zero velocity until setVel, also in a reused cell
		for t = 4, 9 do
			Ring.push(r, t, 0, 0, 0, 0, 0, 0, 0, 0, 1)
		end
		for i = r.last - r.n + 1, r.last do
			T.eq(r.vx[i % r.cap + 1], 0, "reused cell is zero")
		end
		local plain = Ring.new(4, false)
		T.check(not plain.vel)
		Ring.setVel(plain, Ring.push(plain, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1), 5, 5, 5, 5, 5, 5)
		T.eq(#plain.vx, 0, "no velocity arrays in plain rings")
	end)

	T.test("interp: flight between samples within 0.01 stud, velocity exact; the newest segment too", function()
		local world = T.world()
		local Ring = T.module(world, "Shared", "Ring")
		local Interp = T.module(world, "Shared", "Interp")
		local r = Ring.new(64, false, true)
		local plain = Ring.new(64, false)
		local function pos(t)
			return 10 * t, 5 + 40 * t + 0.5 * G * t * t, -3 * t
		end
		for k = 0, 12 do
			local t = k / 30
			local x, y, z = pos(t)
			Ring.setVel(r, Ring.push(r, 100 + t, x, y, z, 0, 0, 0, 0, 0, 1), 10, 40 + G * t, -3, 0, 2, 0)
			Ring.push(plain, 100 + t, x, y, z, 0, 0, 0, 0, 0, 1)
		end
		local worst, worstV, worstPlain = 0, 0, 0
		for i = 0, 1200 do
			local t = i / 1200 * 12 / 30
			local x, y, z = Interp.sample(r, 100 + t, 0)
			local m = Interp.motion
			local tx, ty, tz = pos(t)
			worst = math.max(worst, math.sqrt((x - tx) ^ 2 + (y - ty) ^ 2 + (z - tz) ^ 2))
			worstV = math.max(worstV, math.abs(m[1] - 10), math.abs(m[2] - (40 + G * t)), math.abs(m[3] + 3))
			T.eq(m[5], 2, "spin")
			local px, py, pz = Interp.sample(plain, 100 + t, 0)
			worstPlain = math.max(worstPlain, math.sqrt((px - tx) ^ 2 + (py - ty) ^ 2 + (pz - tz) ^ 2))
		end
		T.check(worst < 0.01, "velocity ring: worst error " .. worst)
		T.check(worstV < 1e-6, "velocity along the path: worst error " .. worstV)
		-- positions alone: the first and last segments have one-sided tangents
		T.check(worstPlain > 5 * worst, string.format("plain ring is worse at the ends: %.4f vs %.4f", worstPlain, worst))
		-- past the newest sample: its own velocity, bounded
		local nt = 100 + 12 / 30
		local nx, ny = pos(12 / 30)
		local x, y, _, _, _, _, _, _, state = Interp.sample(r, nt + 0.05, 0.1)
		T.eq(state, Interp.STATE_EXTRAP)
		T.near(x, nx + 10 * 0.05, 1e-9, "extrapolated x")
		T.near(y, ny + (40 + G * 12 / 30) * 0.05, 1e-9, "extrapolated y")
		T.near(Interp.motion[2], 40 + G * 12 / 30, 1e-9, "velocity while extrapolating")
		x, y, _, _, _, _, _, _, state = Interp.sample(r, nt + 5, 0.1)
		T.eq(state, Interp.STATE_HOLD)
		T.near(x, nx + 10 * 0.1, 1e-9, "bounded")
		-- before the oldest: held, with its velocity
		x, y, _, _, _, _, _, _, state = Interp.sample(r, 50, 0)
		T.eq(state, Interp.STATE_EARLY)
		T.eq(Interp.motion[1], 10)
	end)

	T.test("interp: a cut is a corner (nothing bends before it); velocities that explain nothing are not used", function()
		local world = T.world()
		local Ring = T.module(world, "Shared", "Ring")
		local Interp = T.module(world, "Shared", "Interp")
		-- rolls along +x at 20 studs/s, kicked at t = 0.1 to +z at 90 studs/s
		local function build(cutFlag, withVel)
			local r = Ring.new(64, false, withVel)
			local function add(t, x, z, vx, vz, fl)
				Ring.setVel(r, Ring.push(r, 100 + t, x, 1, z, 0, fl, 0, 0, 0, 1), vx, 0, vz, 0, 0, 0)
			end
			add(0, 0, 0, 20, 0, 0)
			add(1 / 30, 20 / 30, 0, 20, 0, 0)
			add(2 / 30, 40 / 30, 0, 20, 0, 0)
			add(0.1, 2, 0, 0, 90, cutFlag) -- the kick: same place, new velocity
			add(0.1 + 1 / 30, 2, 3, 0, 90, 0)
			add(0.1 + 2 / 30, 2, 6, 0, 90, 0)
			return r
		end
		local function worstErr(r)
			local worst = 0
			for i = 0, 500 do
				local t = i / 500 * (0.1 + 2 / 30)
				local x, _, z = Interp.sample(r, 100 + t, 0)
				local tx = math.min(t, 0.1) * 20
				local tz = math.max(t - 0.1, 0) * 90
				worst = math.max(worst, math.sqrt((x - tx) ^ 2 + (z - tz) ^ 2))
			end
			return worst
		end
		local cut = worstErr(build(Ring.CUT, true))
		T.check(cut < 1e-9, "with the cut flagged the path is exact: " .. cut)
		-- the cut sample lost (or the kick never bumped): the velocities do not explain the
		-- segment, so it falls back to the positions; still bounded, never a fling
		local unflagged = worstErr(build(0, true))
		T.check(unflagged < 0.5, "unflagged kick: " .. unflagged)
		local plain = worstErr(build(0, false))
		T.check(plain > 20 * math.max(cut, 1e-6), "positions alone bend around the kick: " .. plain)
		-- velocity and spin across the cut: the old ones up to it, the new ones from it
		local r = build(Ring.CUT, true)
		Interp.sample(r, 100 + 0.1 - 1e-4, 0)
		T.near(Interp.motion[1], 20, 1e-6, "before the cut")
		T.near(Interp.motion[3], 0, 1e-6)
		Interp.sample(r, 100 + 0.1 + 1e-4, 0)
		T.near(Interp.motion[1], 0, 1e-6, "after the cut")
		T.near(Interp.motion[3], 90, 1e-6)

		-- a body carried by CFrame (velocity reads zero while it moves): the path is the one a
		-- plain ring gives, exactly
		local a = Ring.new(64, false, true)
		local b = Ring.new(64, false)
		for k = 0, 10 do
			local x = math.sin(k * 0.3) * 6
			Ring.push(a, 100 + k / 30, x, 2, k * 0.4, 0, 0, 0, 0, 0, 1)
			Ring.push(b, 100 + k / 30, x, 2, k * 0.4, 0, 0, 0, 0, 0, 1)
		end
		for i = 0, 300 do
			local t = 100 + i / 300 * 10 / 30
			local ax, ay, az = Interp.sample(a, t, 0)
			local bx, by, bz = Interp.sample(b, t, 0)
			T.check(ax == bx and ay == by and az == bz, "carried body: same path as a plain ring")
		end
		-- a cut whose start velocity explains nothing (caught and thrown in one segment): a line
		local c = Ring.new(8, false, true)
		Ring.setVel(c, Ring.push(c, 100, 0, 1, 0, 0, 0, 0, 0, 0, 1), 0, 0, 0, 0, 0, 0)
		Ring.setVel(c, Ring.push(c, 100.1, 4, 1, 0, 0, Ring.CUT, 0, 0, 0, 1), 50, 0, 0, 0, 0, 0)
		local x = Interp.sample(c, 100.05, 0)
		T.near(x, 2, 1e-9, "straight line")
		-- a teleport still holds until it is reached, with no velocity
		local d = Ring.new(8, false, true)
		Ring.setVel(d, Ring.push(d, 100, 0, 1, 0, 0, 0, 0, 0, 0, 1), 30, 0, 0, 0, 0, 0)
		Ring.setVel(d, Ring.push(d, 100.1, 500, 1, 0, 0, 1, 0, 0, 0, 1), 30, 0, 0, 0, 0, 0)
		x = Interp.sample(d, 100.05, 0)
		T.eq(x, 0, "held before the teleport")
		T.eq(Interp.motion[1], 0, "no velocity while held")
	end)

	----------------------------------------------------------------------------
	-- End to end
	----------------------------------------------------------------------------

	T.test("a ball in flight: clients read pose, velocity and spin at any buffered time; 28 B a sample", function()
		local world, Tide, model, _, cts = setup()
		local ct = cts[1]
		-- bytes on TideU, server -> client
		local bytes, packets = 0, 0
		local send = world._send
		world._send = function(self, remote, fromServer, target, ...)
			local a = ...
			if fromServer and rawget(remote, "ClassName") == "UnreliableRemoteEvent" and type(a) == "buffer" then
				bytes += buffer.len(a)
				packets += 1
			end
			return send(self, remote, fromServer, target, ...)
		end
		local sim = newSim(model, 0, 5, 0, 12, 55, -7, 9)
		local truth = {}
		local view = world:replica(1, model)
		local worst, worstV, checked = 0, 0, 0
		local before = Tide.stats()
		run(world, sim, 100, truth, function(f)
			if f < 30 or sim.bounced then
				return
			end
			-- the pose at the time the ball is drawn (its kind's stream delay)
			local t = ct.timeOf(view)
			-- compare at the server frame time nearest below it (the truth is known there)
			local k = math.floor((t - truth[1][1]) / DT + 1e-6) + 1
			local s = truth[k]
			if s == nil then
				return
			end
			local cf, v, w = ct.at(view, s[1])
			T.check(cf ~= nil and v ~= nil and w ~= nil, "at returns pose, velocity, spin")
			-- skip frames next to a bounce nobody bumped (covered below)
			local near = false
			for j = math.max(1, k - 3), math.min(#truth, k + 3) do
				if truth[j][5] ~= truth[k][5] or math.abs(truth[j][6] - truth[k][6]) > 30 then
					near = true
				end
			end
			if not near then
				worst = math.max(worst, T.dist(cf.Position, vec(s[2], s[3], s[4])))
				worstV = math.max(worstV, T.dist(v, vec(s[5], s[6], s[7])))
				T.near(w.Y, 9, 1 / 64, "spin")
				checked += 1
			end
		end)
		world._send = send
		print(string.format("    ball in flight, 30 Hz, 30 ms +- 4 ms: worst error at the drawn time %.4f studs, %.3f studs/s (%d frames)", worst, worstV, checked))
		T.check(checked > 30, "frames checked: " .. checked)
		T.check(worst < 0.03, "pose at the drawn time: worst " .. worst)
		T.check(worstV < 0.5, "velocity at the drawn time: worst " .. worstV)
		-- the newest received sample, with its server stamp
		local cf, v, w, stamp = ct.latest(view)
		T.check(cf ~= nil and v ~= nil and w ~= nil and type(stamp) == "number", "latest")
		local s = truthAt(truth, stamp)
		T.check(s ~= nil, "the stamp is a server frame time")
		T.check(T.dist(cf.Position, vec(s[2], s[3], s[4])) < 0.03, "latest pose is the server's at its stamp")
		T.check(T.dist(v, vec(s[5], s[6], s[7])) < 0.03, "latest velocity is the server's at its stamp")
		T.check(world.now - stamp < 0.12, "latest is recent")
		-- the server's own history answers the same
		local scf, sv, sw = Tide.at(model, s[1])
		T.check(T.dist(scf.Position, cf.Position) < 1e-9 and T.dist(sv, v) < 1e-9 and T.dist(sw, w) < 1e-9, "server = client at a sample")
		local lcf, lv, lw, lt = Tide.latest(model)
		T.check(lcf ~= nil and lv ~= nil and lw ~= nil and world.now - lt <= DT + 1e-9, "server latest")
		T.check(T.dist(Tide.velocity(model), lv) == 0, "Tide.velocity is the newest sample's")
		-- bytes: every record is 28 B (escape, header, slot, dt, 8 B pose, 4 B rotation, 6 + 6 B)
		local after = Tide.stats()
		local samples = after.velocitySamples - before.velocitySamples
		T.check(samples >= 49 and samples <= 52, "30 Hz for 100 frames: " .. samples)
		-- (the sample taken at Tide.add was encoded before the client was ready for packets)
		local sent = after.velocityBytes - before.velocityBytes
		T.check(sent == samples * 28 or sent == (samples - 1) * 28, "28 B a record: " .. sent .. " B for " .. samples)
		T.eq(bytes - packets * 10, sent, "every relayed byte is a ball record")
		T.check(sent / 28 - ct.stats().velocityRecords <= 2, "the client counted them (the last ones are on the wire)")
		T.eq(ct.stats().badPacket, 0)
	end)

	T.test("apply = \"none\" comes from the server: the client neither moves nor anchors the model; a client's own apply wins", function()
		local applied = 0
		local world, _, model, _, cts = setup({
			clients = 2,
			client = function(ct, i)
				if i == 2 then
					ct.kind("Ball", {
						apply = function()
							applied += 1
						end,
					})
				end
			end,
		})
		local sim = newSim(model, 0, 5, 0, 5, 30, 0, 0)
		run(world, sim, 60)
		local root1 = world:replica(1, model).HumanoidRootPart
		T.check(rawget(root1, "CFrame") == nil, "client 1: Tide never wrote the root's CFrame")
		T.check(rawget(root1, "Anchored") == nil, "client 1: not anchored by Tide")
		T.check(cts[1].drawn(world:replica(1, model)) ~= nil, "still sampled every frame (Tide.drawn)")
		T.check(applied > 20, "client 2: its own apply function runs: " .. applied)
		local Kinds = T.clientModule(world, 1, "Shared", "Kinds")
		T.eq(Kinds.byName.Ball.apply, "none")
		T.check(Kinds.byName.Ball.velocity, "the kind's velocity flag reached the client")
		T.eq(Kinds.byName.Player.apply, "cframe", "other kinds keep the default")
	end)

	T.test("the server takes apply = \"none\" back: entities that exist are drawn and anchored again", function()
		local world, Tide, model, _, cts = setup()
		local sim = newSim(model, 0, 5, 0, 5, 30, 0, 0)
		run(world, sim, 30)
		local root = world:replica(1, model).HumanoidRootPart
		T.check(rawget(root, "Anchored") == nil)
		Tide.kind("Ball", { apply = "cframe" })
		run(world, sim, 30)
		T.eq(rawget(root, "Anchored"), true, "anchored once Tide moves it")
		T.check(rawget(root, "CFrame") ~= nil or cts[1].drawn(world:replica(1, model)) ~= nil)
		Tide.kind("Ball", { apply = "none" })
		run(world, sim, 30)
		T.eq(rawget(root, "Anchored"), false, "anchor given back")
	end)

	T.test("Tide.bump: an immediate cut sample with the new velocity; stamps, counters, what it returns", function()
		local seen = {}
		local world, Tide, model, handle, cts, chars = setup({
			client = function(ct)
				ct.kind("Ball", {
					onSample = function(m, t, cf, v, w, cut)
						table.insert(seen, { m = m, t = t, cf = cf, v = v, w = w, cut = cut })
					end,
				})
			end,
		})
		local SState = T.module(world, "Server", "State")
		local Ring = T.module(world, "Shared", "Ring")
		local slot = SState.bySlotModel[model]
		local h = SState.hist[slot]
		local sim = newSim(model, 0, 1, 0, 8, 0, 0, 0)
		sim.gravity = false
		run(world, sim, 30) -- rolling
		while Ring.newestT(h) == world.now do
			run(world, sim, 1) -- until the last frame was not a tick of the 30 Hz kind
		end
		local newest = Ring.newestT(h)
		local n0 = h.last
		-- a kick: game code sets the velocity, then bumps
		sim.vx, sim.vy, sim.vz, sim.wy = 0, 0, 90, 20
		sim.write()
		local stamp = Tide.bump(model)
		T.eq(h.last, n0 + 1, "sampled at once")
		local p = h.last % h.cap + 1
		T.eq(h.t[p], stamp, "the stamp returned is the sample's")
		T.eq(stamp, world.now, "the time the poses that stand were reached: the last frame's")
		T.eq(h.fl[p], Ring.CUT, "flagged a cut")
		T.eq(h.vz[p], 90, "with the new velocity")
		T.eq(h.wy[p], 20, "and spin")
		T.near(h.x[p], sim.x, 0.02, "at the pose that stands")
		T.check(stamp > newest)
		-- a second bump with nothing changed: no sample, still a stamp
		local again = Tide.bump(model)
		T.eq(h.last, n0 + 1, "nothing changed: nothing sampled")
		T.check(type(again) == "number" and again > stamp, "a later stamp")
		-- changed again in the same frame: a second cut sample, at a later time
		sim.vz = 60
		sim.write()
		local third = handle:bump()
		T.eq(h.last, n0 + 2)
		T.check(third - stamp >= 0.001 - 1e-9, "at least two ticks of the time grid apart")
		T.eq(Tide.stats().bumps, 3)
		T.eq(Tide.stats().bumpsDeferred, 0)
		-- what does not bump
		T.eq(Tide.bump(chars[1]), nil, "client-owned")
		T.eq(Tide.bump(world:spawnModel("stranger", CFrame.new())), nil, "unknown")
		T.eq(cts[1].bump(world:replica(1, model)), nil, "client: nil")
		-- the client: both cuts arrive, flagged, in order, with the kick's velocity
		table.clear(seen)
		run(world, sim, 20)
		local cuts = {}
		for i, s in seen do
			T.check(s.m == world:replica(1, model), "onSample: the client's model")
			if i > 1 then
				T.check(s.t > seen[i - 1].t, "onSample: in time order here (no loss, no reorder)")
			end
			if s.cut then
				table.insert(cuts, s)
			end
		end
		T.eq(#cuts, 2, "two cuts")
		T.near(cuts[1].t, stamp, 0.00051, "cut time (0.5 ms grid)")
		T.eq(cuts[1].v.Z, 90)
		T.eq(cuts[1].w.Y, 20)
		T.eq(cuts[2].v.Z, 60)
		-- the path has a corner at the kick: just before it the ball still rolls along +x
		local view = world:replica(1, model)
		local cfBefore, vBefore = cts[1].at(view, stamp - 0.004)
		local _, vEarlier = cts[1].at(view, stamp - 0.05)
		local _, vAfter = cts[1].at(view, third + 0.004)
		T.near(vEarlier.X, 8, 1e-6, "rolling")
		T.near(vBefore.X, 8, 4, "just before the kick: still rolling (to the positions' grid)")
		T.eq(vBefore.Z, 0, "just before the kick: no z yet")
		T.eq(cfBefore.Position.Z, 0, "just before the kick: on the old line")
		T.near(vAfter.Z, 60, 0.5, "after the kick")
		T.eq(cts[1].stats().applyErrors, 0)
	end)

	T.test("Tide.bump while physics steps: sampled at that frame's step whatever the tick; one sample per frame", function()
		local world, Tide, model = setup({ kind = { velocity = true, rate = 10, near = math.huge, apply = "none" } })
		local SState = T.module(world, "Server", "State")
		local Ring = T.module(world, "Shared", "Ring")
		local h = SState.hist[SState.bySlotModel[model]]
		local sim = newSim(model, 0, 1, 0, 4, 0, 0, 0)
		sim.gravity = false
		run(world, sim, 20)
		-- a Stepped handler (after Tide's PreSimulation hook) kicks and bumps on chosen frames
		local kick = false
		local returned
		world.server.RunService.Stepped:Connect(function()
			if kick then
				kick = false
				sim.vz = 70
				sim.write()
				returned = Tide.bump(model)
				T.check(SState.inSim, "inside the physics window")
			end
		end)
		-- find a frame the 10 Hz kind does not tick on: run until two frames pass without a sample
		local last = h.last
		run(world, sim, 1)
		if h.last ~= last then
			last = h.last
			run(world, sim, 1)
		end
		T.eq(h.last, last, "no tick this frame")
		kick = true
		run(world, sim, 1)
		T.eq(h.last, last + 1, "sampled at the frame's step although the kind did not tick")
		local p = h.last % h.cap + 1
		T.eq(h.t[p], world.now, "at the step's time")
		T.eq(h.fl[p], Ring.CUT, "a cut")
		T.eq(h.vz[p], 70)
		T.check(returned ~= nil and returned <= world.now and world.now - returned <= DT + 1e-9, "returned the time of the call")
		T.eq(Tide.stats().bumpsDeferred, 1)
		T.eq(SState.bumpN, 0, "nothing owed after the step")
		T.check(not SState.inSim, "window closed by Tide's step")
		-- the next frames: the ordinary tick, no leftover cut
		run(world, sim, 12)
		for i = last + 2, h.last do
			T.eq(h.fl[i % h.cap + 1], 0, "later samples are not cuts")
		end
	end)

	T.test("Tide.bump on a kind without velocity: an out-of-tick sample in the v0.4 record (no header, no cut)", function()
		local world, Tide, model, _, cts = setup({ kind = { rate = 10, near = math.huge } })
		local SState = T.module(world, "Server", "State")
		local h = SState.hist[SState.bySlotModel[model]]
		local root = model.HumanoidRootPart
		for f = 1, 20 do
			root.CFrame = CFrame.new(f * 0.1, 3, 0)
			world:frame(DT)
		end
		local sizes = {}
		local send = world._send
		world._send = function(self, remote, fromServer, target, ...)
			local a = ...
			if fromServer and rawget(remote, "ClassName") == "UnreliableRemoteEvent" and type(a) == "buffer" then
				table.insert(sizes, buffer.len(a))
			end
			return send(self, remote, fromServer, target, ...)
		end
		local last = h.last
		root.CFrame = CFrame.new(2.5, 3, 4)
		local stamp = Tide.bump(model)
		T.eq(h.last, last + 1)
		T.eq(h.fl[h.last % h.cap + 1], 0, "no cut flag in a plain ring")
		T.check(not h.vel)
		world:frame(DT)
		world._send = send
		T.check(#sizes >= 1, "sent with the next packet")
		T.eq(sizes[1], 10 + 10, "header + slot, dt, 8 B: the plain record")
		for _ = 1, 10 do
			world:frame(DT)
		end
		local cf, v, w, t = cts[1].latest(world:replica(1, model))
		T.check(cf ~= nil and v == nil and w == nil and t == nil, "plain kinds: latest returns the CFrame alone")
		T.near(cf.Position.Z, 4, 0.02)
		T.check(type(stamp) == "number")
		T.eq(cts[1].stats().velocityRecords, 0)
	end)

	T.test("a bounce nobody bumped and a lost cut: the path stays within the segment, never flung", function()
		for _, loss in { 0, 0.3 } do
			local world, Tide, model, _, cts = setup({ net = { latency = 0.03, jitter = 0.006, loss = loss, seed = 23 } })
			local sim = newSim(model, 0, 3, 0, 6, 0, 2, 5)
			local truth = {}
			local view = world:replica(1, model)
			local ct = cts[1]
			local worst = 0
			run(world, sim, 400, truth, function(f)
				if f % 45 == 0 then
					-- a kick, bumped (some of these packets are lost in the second run)
					sim.vy = 40
					sim.vx = -sim.vx
					sim.write()
					Tide.bump(model)
				end
				if f < 40 then
					return
				end
				local t = ct.timeOf(view)
				local cf = ct.at(view, t)
				-- the truth around t: the ball is between the frames next to it
				local k = math.floor((t - truth[1][1]) / DT + 1e-6) + 1
				local a, b = truth[k], truth[k + 1]
				if a and b then
					local d = math.min(T.dist(cf.Position, vec(a[2], a[3], a[4])), T.dist(cf.Position, vec(b[2], b[3], b[4])))
					worst = math.max(worst, d)
				end
			end)
			-- lossless: within a frame's travel of the truth everywhere, bounces included.
			-- 30 % loss: gaps of several samples across bounces; still bounded by the motion.
			local limit = if loss == 0 then 0.6 else 2.5
			print(string.format("    bounces and kicks, loss %.0f %%: worst distance from the truth %.2f studs", loss * 100, worst))
			T.check(worst < limit, string.format("loss %.1f: worst distance from the truth %.2f", loss, worst))
			T.eq(ct.stats().badPacket, 0, "no bad packets")
			T.eq(ct.stats().applyErrors, 0)
			T.eq(Tide.stats().errors, 0)
		end
	end)

	T.test("a ball at rest sends nothing but keep-alives (16 B, no velocity bytes); a kick from rest is seen at once", function()
		local world, Tide, model, _, cts = setup()
		local sim = newSim(model, 0, 1, 0, 0, 0, 0, 0)
		sim.gravity = false
		local sizes = {}
		local send = world._send
		world._send = function(self, remote, fromServer, target, ...)
			local a = ...
			if fromServer and rawget(remote, "ClassName") == "UnreliableRemoteEvent" and type(a) == "buffer" then
				table.insert(sizes, buffer.len(a))
			end
			return send(self, remote, fromServer, target, ...)
		end
		run(world, sim, 10)
		table.clear(sizes)
		run(world, sim, 120) -- 2 s at rest
		T.check(#sizes >= 3 and #sizes <= 5, "keep-alives only (0.5 s): " .. #sizes)
		for _, n in sizes do
			T.eq(n, 10 + 16, "at rest: escape, header, slot, dt, pose + rotation; no velocity bytes")
		end
		-- kicked from rest
		local view = world:replica(1, model)
		sim.vx, sim.vy = 30, 0
		sim.write()
		local stamp = Tide.bump(model)
		run(world, sim, 6)
		world._send = send
		local _, v, _, t = cts[1].latest(view)
		T.check(t >= stamp, "the kick arrived within 6 frames")
		T.eq(v.X, 30)
		-- the path stands still up to the kick, then leaves at 30 studs/s (no slow start)
		local cfA = cts[1].at(view, stamp - 0.01)
		T.near(cfA.Position.X, 0, 1e-6, "at rest before the kick")
		local SState = T.module(world, "Server", "State")
		local h = SState.hist[SState.bySlotModel[model]]
		local newest = h.t[h.last % h.cap + 1]
		local mid = (stamp + newest) / 2
		local cfB, vB = cts[1].at(view, mid)
		local scfB = Tide.at(model, mid)
		T.near(vB.X, 30, 0.6, "full speed right after the kick")
		T.check(T.dist(cfB.Position, scfB.Position) < 0.02, "the client's path is the server's: " .. T.dist(cfB.Position, scfB.Position))
	end)

	T.test("late joiner and removal: a resting ball reaches a new client within keepAlive; removal mid-buffer is clean", function()
		local world, Tide, model, handle, cts = setup()
		local sim = newSim(model, 3, 1, 4, 0, 0, 0, 0)
		sim.gravity = false
		run(world, sim, 90)
		world:spawnCharacter(world:addPlayer(), CFrame.new(40, 3, 0))
		local ct2 = T.clientTide(world, 2)
		ct2.start()
		run(world, sim, 45) -- 0.75 s: at least one keep-alive (0.5 s)
		local view2 = world:replica(2, model)
		local cf, v, w, t = ct2.latest(view2)
		T.check(cf ~= nil, "the joiner has the ball")
		T.near(cf.Position.X, 3, 0.02)
		T.check(v.X == 0 and w.Y == 0 and t ~= nil, "at rest, with a stamp")
		-- moving: the joiner's next packet has the velocity
		sim.vx = 25
		sim.write()
		Tide.bump(model)
		run(world, sim, 8)
		local _, v2 = ct2.latest(view2)
		T.eq(v2.X, 25)
		-- removed while both clients hold buffered samples
		handle:remove()
		run(world, sim, 10)
		T.eq(ct2.latest(view2), nil, "gone on the joiner")
		T.eq(cts[1].at(world:replica(1, model), world.now), nil, "gone on the first client")
		T.eq(Tide.bump(model), nil, "bump of a removed entity")
		T.eq(Tide.at(model, world.now), nil)
		-- the slot is free for an entity of another kind: a plain ring, plain records
		T.eq(cts[1].stats().badPacket + ct2.stats().badPacket, 0)
		T.eq(Tide.stats().errors, 0)
	end)

	T.test("velocity kinds are server-owned: an owner at add or setOwner is an error; so is motion = false", function()
		local world, Tide, _, handle, _, _ = setup()
		local player = world.players[1]
		local other = world:spawnModel("ball2", CFrame.new(0, 5, 9), false)
		T.check(not pcall(Tide.add, other, "Ball", player), "add with an owner")
		T.check(not pcall(function()
			handle:setOwner(player)
		end), "setOwner")
		T.check(handle:alive() and handle:owner() == nil, "still server-owned")
		T.check(not pcall(Tide.kind, "Bad", { velocity = true, motion = false }), "velocity without motion")
		T.check(not pcall(Tide.kind, "Bad2", { lock = true, motion = false }), "lock without motion")
		T.check(not pcall(Tide.kind, "Bad3", { onSample = 5 }), "onSample must be a function")
		T.check(not pcall(Tide.kind, "Bad4", { velocity = "yes" }), "velocity must be a boolean")
	end)

	----------------------------------------------------------------------------
	-- Wire
	----------------------------------------------------------------------------

	T.test("garbage velocity records never throw: reserved header bits, truncation, slot 0 twice, unknown slots", function()
		local world, Tide, model, _, cts = setup()
		local sim = newSim(model, 0, 5, 0, 5, 20, 0, 3)
		run(world, sim, 30)
		local CReceive = T.clientModule(world, 1, "Client", "Receive")
		local CState = T.clientModule(world, 1, "Client", "State")
		local Codec = T.clientModule(world, 1, "Shared", "Codec")
		local view = world:replica(1, model)
		local slot = CState.bySlotModel[view]
		local r = CState.ring[slot]
		local function packet(build)
			local b = buffer.create(256)
			buffer.writeu8(b, 0, 1)
			buffer.writeu8(b, 1, 0)
			buffer.writef64(b, 2, world.now + 1)
			local n = build(b, 10)
			local out = buffer.create(n)
			buffer.copy(out, 0, b, 0, n)
			return out
		end
		local function record(b, pos, hdrOverride, toSlot, dt, x)
			buffer.writeu8(b, pos, 0)
			local hdrAt = pos + 1
			buffer.writeu8(b, pos + 2, toSlot)
			buffer.writeu8(b, pos + 3, dt)
			pos = Codec.write(b, pos + 4, x, 2, 0, 0, 2, 0, 0, 0, 1)
			local hdr
			pos, hdr = Codec.writeMotion(b, pos, 10, 0, 0, 0, 5, 0)
			buffer.writeu8(b, hdrAt, hdrOverride or hdr)
			return pos
		end
		local bad0 = CState.counters.badPacket
		local n0 = r.last
		-- 1. well formed: accepted
		CReceive.packet(packet(function(b, pos)
			return record(b, pos, nil, slot, 10, 1)
		end), world.now)
		T.eq(r.last, n0 + 1, "a good record is stored")
		T.eq(r.vx[r.last % r.cap + 1], 10)
		T.eq(CState.counters.badPacket, bad0)
		-- 2. reserved header bits: the packet stops there, counted, nothing stored
		for _, hdr in { 32, 64, 128, 255 } do
			CReceive.packet(packet(function(b, pos)
				return record(b, pos, hdr, slot, 9, 2)
			end), world.now)
		end
		T.eq(r.last, n0 + 1, "reserved bits: nothing stored")
		T.eq(CState.counters.badPacket, bad0 + 4)
		-- 3. every truncation of a good two-record packet: no throw, at most the first record
		local full = packet(function(b, pos)
			pos = record(b, pos, nil, slot, 8, 3)
			return record(b, pos, nil, slot, 7, 4)
		end)
		for n = 10, buffer.len(full) - 1 do
			local cut = buffer.create(n)
			buffer.copy(cut, 0, full, 0, n)
			CReceive.packet(cut, world.now)
		end
		T.check(r.last <= n0 + 3, "truncations store whole records only")
		-- 4. the escape twice (slot 0 after the header)
		local before = CState.counters.badPacket
		CReceive.packet(packet(function(b, pos)
			return record(b, pos, nil, 0, 6, 5)
		end), world.now)
		T.eq(CState.counters.badPacket, before + 1, "slot 0 is never an entity")
		-- 5. a velocity record for a slot this client does not know, then a good one: the
		-- unknown one is skipped by its own size
		local last = r.last
		CReceive.packet(packet(function(b, pos)
			pos = record(b, pos, nil, 200, 5, 6)
			return record(b, pos, nil, slot, 4, 7)
		end), world.now)
		T.eq(r.last, last + 1, "the record after an unknown slot is read")
		-- 6. random bytes
		math.randomseed(5)
		for _ = 1, 300 do
			local n = math.random(11, 80)
			local b = buffer.create(n)
			for i = 0, n - 1 do
				buffer.writeu8(b, i, math.random(0, 255))
			end
			buffer.writeu8(b, 0, 1)
			buffer.writeu8(b, 1, math.random(0, 1))
			buffer.writef64(b, 2, world.now)
			if math.random(0, 1) == 0 then
				buffer.writeu8(b, 10, 0) -- make it start as a velocity record
			end
			CReceive.packet(b, world.now)
		end
		-- every stored velocity is finite
		for i = r.last - r.n + 1, r.last do
			local p = i % r.cap + 1
			T.check(r.vx[p] == r.vx[p] and math.abs(r.vx[p]) < math.huge, "finite")
			T.check(r.wy[p] == r.wy[p] and math.abs(r.wy[p]) < math.huge, "finite")
		end
		-- the stream goes on
		run(world, sim, 10)
		T.check(cts[1].latest(view) ~= nil)
		T.eq(Tide.stats().errors, 0)
	end)

	T.test("a velocity record for a plain ring (and a plain record for a velocity ring) is read, velocity zero", function()
		local world, _, model, _, _ = setup()
		local sim = newSim(model, 0, 5, 0, 5, 20, 0, 3)
		run(world, sim, 20)
		local CReceive = T.clientModule(world, 1, "Client", "Receive")
		local CState = T.clientModule(world, 1, "Client", "State")
		local Codec = T.clientModule(world, 1, "Shared", "Codec")
		local ballSlot = CState.bySlotModel[world:replica(1, model)]
		-- a plain record addressed to the ball
		local b = buffer.create(10 + 14)
		buffer.writeu8(b, 0, 1)
		buffer.writeu8(b, 1, 0)
		buffer.writef64(b, 2, world.now + 1)
		buffer.writeu8(b, 10, ballSlot)
		buffer.writeu8(b, 11, 0)
		Codec.write(b, 12, 7, 2, 0, 0, 2, 0, 0, 0, 1)
		CReceive.packet(b, world.now)
		local r = CState.ring[ballSlot]
		local p = r.last % r.cap + 1
		T.near(r.x[p], 7, 0.02, "pose stored")
		T.eq(r.vx[p], 0, "no velocity")
		T.eq(CState.counters.badPacket, 0)
	end)

	T.test("wide slots (more than 255 entities) and mixed packets: plain and velocity records side by side", function()
		local world, Tide, _, _, cts = setup({ kind = { velocity = true, rotation = "full", rate = 30, near = math.huge, apply = "none" } })
		local bots = {}
		for k = 1, 260 do
			bots[k] = world:spawnModel("b" .. k, CFrame.new(k % 20, 3, 20 + k // 20), true)
			Tide.add(bots[k], "Bot")
		end
		local ball2 = world:spawnModel("ball2", CFrame.new(0, 5, 9), false)
		Tide.add(ball2, "Ball")
		local SState = T.module(world, "Server", "State")
		T.check(SState.bySlotModel[ball2] > 255, "a wide slot")
		local sim = newSim(ball2, 0, 5, 9, 9, 30, 0, 4)
		local truth = {}
		run(world, sim, 60, truth, function(f)
			-- a few bots move too: their plain records share the ball's packets
			for k = 1, 10 do
				bots[k].HumanoidRootPart.CFrame = CFrame.new(k + f * 0.05, 3, 20)
			end
		end)
		local view = world:replica(1, ball2)
		local cf, v, _, t = cts[1].latest(view)
		local s = truthAt(truth, t)
		T.check(s ~= nil and T.dist(cf.Position, vec(s[2], s[3], s[4])) < 0.03, "wide velocity record decoded")
		T.check(T.dist(v, vec(s[5], s[6], s[7])) < 0.03)
		T.check(cts[1].drawn(world:replica(1, bots[3])) ~= nil, "plain records in the same packets")
		T.eq(cts[1].stats().badPacket, 0)
	end)

	T.test("mid / far receivers: thinned samples keep their velocity; cuts always get through", function()
		local seen, cuts = 0, 0
		local world, Tide, model, _, cts = setup({
			kind = { velocity = true, rate = 30, near = 20, far = 500, cull = 2000, farEvery = 3, apply = "none" },
			client = function(ct)
				ct.kind("Ball", {
					onSample = function(_, _, _, v, _, cut)
						seen += 1
						if cut then
							cuts += 1
						end
						assert(v ~= nil)
					end,
				})
			end,
		})
		local sim = newSim(model, 100, 1, 0, 0, 0, 3, 0) -- 90 studs from the client's character: mid tier
		sim.gravity = false
		run(world, sim, 60)
		local base = seen
		T.check(base >= 8 and base <= 14, "every third sample of 30 Hz: " .. base)
		local bumps = 0
		run(world, sim, 60, nil, function(f)
			if f % 7 == 0 then
				sim.vx = (f % 2) * 10
				sim.write()
				Tide.bump(model)
				bumps += 1
			end
		end)
		run(world, sim, 10)
		T.eq(cuts, bumps, "every cut reached the mid-tier receiver")
		local _, v = cts[1].latest(world:replica(1, model))
		T.eq(v.Z, 3, "velocity on thinned samples")
	end)

	T.test("samples older than 127 ms in a packet (u16 dt) and a late, out-of-order packet keep their velocity", function()
		local world, _, model, _, cts = setup({ net = { latency = 0.03, jitter = 0.05, seed = 3 } }) -- jitter above the sample gap: reordering
		local sim = newSim(model, 0, 5, 0, 4, 35, 0, 2)
		local truth = {}
		run(world, sim, 120, truth)
		local CState = T.clientModule(world, 1, "Client", "State")
		local r = CState.ring[CState.bySlotModel[world:replica(1, model)]]
		local checked = 0
		for i = r.last - r.n + 1, r.last do
			local p = i % r.cap + 1
			if i > r.last - r.n + 1 then
				T.check(r.t[p] > r.t[(i - 1) % r.cap + 1], "ring in time order")
			end
			local s = truthAt(truth, r.t[p])
			if s ~= nil then
				T.check(math.abs(r.vy[p] - s[6]) < 0.02, "each sample has its own velocity after reordering")
				checked += 1
			end
		end
		T.check(checked > 20, "samples checked: " .. checked)
		-- a hand-built packet with a sample 400 ms before the frame time
		local Codec = T.clientModule(world, 1, "Shared", "Codec")
		local CReceive = T.clientModule(world, 1, "Client", "Receive")
		local slot = CState.bySlotModel[world:replica(1, model)]
		local b = buffer.create(64)
		buffer.writeu8(b, 0, 1)
		buffer.writeu8(b, 1, 0)
		local ft = world.now + 2
		buffer.writef64(b, 2, ft)
		buffer.writeu8(b, 10, 0)
		buffer.writeu8(b, 12, slot)
		local pos = Codec.writeDt(b, 13, 800)
		pos = Codec.write(b, pos, 1, 2, 3, 0, 2, 0, 0, 0, 1)
		local hdr
		pos, hdr = Codec.writeMotion(b, pos, 11, 0, 0, 0, 0, 0)
		buffer.writeu8(b, 11, hdr + Codec.CUT)
		local out = buffer.create(pos)
		buffer.copy(out, 0, b, 0, pos)
		CReceive.packet(out, world.now)
		local p = r.last % r.cap + 1
		T.near(r.t[p], ft - 0.4, 1e-9, "u16 dt")
		T.eq(r.vx[p], 11)
		T.eq(CState.counters.badPacket, 0)
		T.check(cts[1].latest(world:replica(1, model)) ~= nil)
	end)

	T.test("onSample: an error in the callback is counted, never thrown; the samples are still stored", function()
		local world, _, model, _, cts = setup({
			client = function(ct)
				ct.kind("Ball", {
					onSample = function()
						error("boom")
					end,
				})
			end,
		})
		local sim = newSim(model, 0, 5, 0, 5, 20, 0, 3)
		run(world, sim, 30)
		local stats = cts[1].stats()
		T.check(stats.applyErrors > 5, "errors counted: " .. stats.applyErrors)
		T.eq(stats.badPacket, 0, "the packets were still read")
		T.check(cts[1].latest(world:replica(1, model)) ~= nil, "and stored")
	end)

	----------------------------------------------------------------------------
	-- Lock, links, Lighthouse
	----------------------------------------------------------------------------

	T.test("kind option lock: a non-replicated assembly root on the server's body; gone with the entity; off by default", function()
		local owned = {}
		local world, Tide, model, handle, cts = setup({ kind = { velocity = true, lock = true, near = math.huge, apply = "none" } })
		local root = model.HumanoidRootPart
		local Lock = T.module(world, "Server", "Lock")
		local SState = T.module(world, "Server", "State")
		local slot = SState.bySlotModel[model]
		local camera = root:FindFirstChild("TideLock")
		T.check(camera ~= nil and camera.ClassName == "Camera", "a Camera inside the root (its children never replicate)")
		local locker = camera:FindFirstChild("TideLocker")
		local weld = camera:FindFirstChild("TideWeld")
		T.check(locker ~= nil and weld ~= nil, "locker and weld")
		T.eq(locker.RootPriority, 126)
		T.eq(locker.Anchored, false)
		T.eq(locker.CanCollide, false)
		T.check(weld.Part0 == locker and weld.Part1 == root)
		T.check(Lock.serverLocked(slot))
		T.eq(SState.locker[slot], nil, "not a client-owned lock: Lock.step leaves it alone")
		T.eq(Tide.stats().serverLocks, 1)
		-- the body moves by the server's physics (the test moves the assembly); samples follow
		local x = 0
		for _ = 1, 40 do
			x += 0.2
			local cf = CFrame.new(x, 5, 0)
			locker.CFrame = cf
			root.CFrame = cf
			root.AssemblyLinearVelocity = vec(12, 0, 0)
			world:frame(DT)
		end
		local cf, v = cts[1].latest(world:replica(1, model))
		T.near(cf.Position.X, x, 1.2, "samples follow the body")
		T.eq(v.X, 12)
		T.near(root.CFrame.Position.X, x, 1e-6, "Tide did not move the body")
		-- teleport moves the whole assembly
		handle:teleport(CFrame.new(50, 5, 50))
		world:frame(DT)
		T.near(root.CFrame.Position.X, 50, 1e-6)
		-- removal takes the lock away
		handle:remove()
		T.eq(root:FindFirstChild("TideLock"), nil, "lock removed with the entity")
		T.check(not Lock.serverLocked(slot))
		-- SetNetworkOwner(nil) is asked for on unanchored roots (and tolerated when it throws)
		local m2 = world:spawnModel("ball2", CFrame.new(0, 5, 9), false)
		rawset(m2.HumanoidRootPart, "SetNetworkOwner", function(_, who)
			table.insert(owned, who == nil)
		end)
		Tide.add(m2, "Ball")
		T.eq(#owned, 1, "SetNetworkOwner(nil) called")
		T.check(owned[1])
		local m3 = world:spawnModel("ball3", CFrame.new(0, 5, 19), false)
		rawset(m3.HumanoidRootPart, "SetNetworkOwner", function()
			error("cannot set the owner")
		end)
		Tide.add(m3, "Ball")
		T.check(m3.HumanoidRootPart:FindFirstChild("TideLock") ~= nil, "locked although SetNetworkOwner threw")
		-- default: no lock
		Tide.kind("Plain", { velocity = true })
		local m4 = world:spawnModel("ball4", CFrame.new(0, 5, 29), false)
		Tide.add(m4, "Plain")
		T.eq(m4.HumanoidRootPart:FindFirstChild("TideLock"), nil, "off by default")
		-- no lock parts on the client
		T.eq(world:replica(1, m2).HumanoidRootPart:FindFirstChild("TideLock") and "replicated" or nil, nil, "nothing on clients")
	end)

	T.test("links: another VM reads pose, velocity and spin (venue:at / latest) and bumps (venue:bump)", function()
		local world, Tide, model, handle = setup()
		handle:link("Pitch", "ball")
		local vm = T.actorVM(world)
		local venue = vm("Shared", "Link").open("Pitch")
		local sim = newSim(model, 0, 5, 0, 7, 40, -2, 6)
		local truth = {}
		run(world, sim, 60, truth)
		local s = truth[#truth - 5]
		local cf, v, w = venue:at("ball", s[1] - DT / 2)
		local scf, sv, sw = Tide.at(model, s[1] - DT / 2)
		T.check(cf ~= nil and v ~= nil and w ~= nil, "at with velocity and spin")
		T.check(T.dist(cf.Position, scf.Position) < 1e-9, "same pose as Tide.at")
		T.check(T.dist(v, sv) < 1e-9 and T.dist(w, sw) < 1e-9, "same velocity and spin")
		local lcf, lt, lv, lw = venue:latest("ball")
		local tcf, tv, tw, tt = Tide.latest(model)
		T.eq(lt, tt, "latest stamp")
		T.check(T.dist(lcf.Position, tcf.Position) < 1e-9 and T.dist(lv, tv) < 1e-9 and T.dist(lw, tw) < 1e-9, "latest")
		-- a kick decided in the other VM
		local SState = T.module(world, "Server", "State")
		local Ring = T.module(world, "Shared", "Ring")
		local h = SState.hist[SState.bySlotModel[model]]
		sim.vx = -50
		sim.write()
		venue:bump("ball")
		local cutsBefore = 0
		for i = h.last - h.n + 1, h.last do
			if h.fl[i % h.cap + 1] >= Ring.CUT then
				cutsBefore += 1
			end
		end
		run(world, sim, 2)
		local cuts = 0
		for i = h.last - h.n + 1, h.last do
			if h.fl[i % h.cap + 1] >= Ring.CUT then
				cuts += 1
			end
		end
		T.eq(cuts, cutsBefore + 1, "the intent bumped the ball at the Tide VM's next frame")
		T.eq(Tide.stats().linkBad, 0)
		-- a plain entity on the same link keeps the v0.4 answers
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		Tide.add(bot, "Bot"):link("Pitch", "bot")
		run(world, sim, 5)
		local bcf, bv = venue:at("bot", world.now)
		T.check(bcf ~= nil and bv == nil, "plain entities: the CFrame alone")
		local _, bt, bvel = venue:latest("bot")
		T.check(bt ~= nil and bvel == nil)
	end)

	T.test("Lighthouse: velocity samples, bytes and bumps are counted; net totals still match the bytes fired", function()
		local counts = {}
		local nets = 0
		local lh = {}
		function lh.probe()
			return { begin = function() end, finish = function() end }
		end
		function lh.net(_, channel, dir, bytes)
			if channel == "Relay" and dir == "out" then
				nets += bytes
			end
		end
		function lh.count(name, n)
			counts[name] = (counts[name] or 0) + (n or 1)
		end
		function lh.gauge() end
		local world, Tide, model = setup({
			before = function(w)
				w.server.shared.Lighthouse = lh
			end,
		})
		local sim = newSim(model, 0, 5, 0, 5, 30, 0, 2)
		run(world, sim, 60, nil, function(f)
			if f % 20 == 0 then
				sim.vx = -sim.vx
				sim.write()
				Tide.bump(model)
			end
		end)
		local stats = Tide.stats()
		T.eq(counts["Tide.Bump"], 3)
		T.eq(counts["Tide.Velocity.samples"], stats.velocitySamples)
		T.eq(counts["Tide.Velocity.bytes"], stats.velocityBytes)
		T.check(stats.velocityBytes > 0 and stats.velocityBytes <= stats.relayBytes)
		T.eq(nets, stats.relayBytes, "Relay net total")
	end)
end
