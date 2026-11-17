-- Ring buffer, interpolation, smart-buffer p95 and server history (Tide.at / Tide.latest).
return function(T)
	local world = T.world()
	local Ring = T.module(world, "Shared", "Ring")
	local Interp = T.module(world, "Shared", "Interp")
	local Buffer = T.module(world, "Client", "Buffer")

	T.test("ring keeps order, wraps, inserts late samples, rejects duplicates", function()
		local r = Ring.new(8, false)
		T.eq(Ring.newestT(r), -math.huge)
		for i = 1, 20 do
			T.check(Ring.push(r, i, i * 10, 0, 0, 0, 0, 0, 0, 0, 1) > 0)
		end
		T.eq(r.n, 8)
		T.eq(Ring.newestT(r), 20)
		T.eq(Ring.push(r, 20, 0, 0, 0, 0, 0, 0, 0, 0, 1), 0, "duplicate")
		T.eq(Ring.push(r, 12, 0, 0, 0, 0, 0, 0, 0, 0, 1), 0, "older than oldest kept")
		T.check(Ring.push(r, 18.5, 185, 0, 0, 0, 0, 0, 0, 0, 1) > 0, "late insert")
		T.eq(r.n, 8)
		local prev = -math.huge
		for li = r.last - r.n + 1, r.last do
			local t = r.t[li % r.cap + 1]
			T.check(t > prev, "sorted")
			prev = t
		end
		T.eq(Ring.find(r, 18.7), r.last - 2)
		T.eq(r.x[Ring.find(r, 18.7) % r.cap + 1], 185)
		T.eq(Ring.find(r, 100), r.last)
		T.eq(Ring.find(r, 0), r.last - r.n, "before oldest")
		-- teleport time tracked
		Ring.push(r, 21, 0, 0, 0, 0, 1, 0, 0, 0, 1)
		T.eq(r.lastTele, 21)
	end)

	T.test("Hermite is exact on linear and quadratic motion; holds before teleports", function()
		local r = Ring.new(32, false)
		for i = 0, 10 do
			local t = i * 0.1
			Ring.push(r, t, 3 * t, 0, 0, 0, 0, 0, 0, 0, 1)
		end
		for k = 1, 50 do
			local t = 0.1 + k * 0.016
			local x, _, _, _, _, _, _, _, state = Interp.sample(r, t, 0.1)
			T.near(x, 3 * t, 1e-9, "linear")
			T.eq(state, Interp.STATE_INTERP)
		end
		local q = Ring.new(32, false)
		for i = 0, 10 do
			local t = i * 0.1
			Ring.push(q, t, t * t, 0, 0, 0, 0, 0, 0, 0, 1)
		end
		for k = 1, 40 do
			local t = 0.15 + k * 0.016
			if t < 0.9 then
				local x = Interp.sample(q, t, 0.1)
				T.near(x, t * t, 1e-3, "quadratic (central differences)")
			end
		end
		-- teleport at t=1.1 to x=100: hold at the previous sample until it is reached
		Ring.push(r, 1.1, 100, 0, 0, 0, 1, 0, 0, 0, 1)
		T.near(Interp.sample(r, 1.05, 0.1), 3.0, 1e-9, "hold before teleport")
		T.near(Interp.sample(r, 1.1, 0.1), 100, 1e-9, "at teleport")
		local _, _, _, _, _, _, _, _, st = Interp.sample(r, 1.15, 0.1)
		T.eq(st, Interp.STATE_EXTRAP)
		T.near(Interp.sample(r, 1.15, 0.1), 100, 1e-9, "no velocity across a teleport")
	end)

	T.test("extrapolation bounded; before oldest clamps; yaw takes the short arc", function()
		local r = Ring.new(16, false)
		Ring.push(r, 0.0, 0, 0, 0, 3.1, 0, 0, 0, 0, 1)
		Ring.push(r, 0.1, 1, 0, 0, -3.1, 0, 0, 0, 0, 1)
		local x, _, _, _, _, _, _, _, st = Interp.sample(r, 0.15, 0.1)
		T.near(x, 1.5, 1e-9)
		T.eq(st, Interp.STATE_EXTRAP)
		x, _, _, _, _, _, _, _, st = Interp.sample(r, 0.5, 0.1)
		T.near(x, 2, 1e-9, "clamped to 0.1 s")
		T.eq(st, Interp.STATE_HOLD)
		x, _, _, _, _, _, _, _, st = Interp.sample(r, -1, 0.1)
		T.eq(x, 0)
		T.eq(st, Interp.STATE_EARLY)
		local _, _, _, yaw = Interp.sample(r, 0.05, 0.1)
		T.check(math.abs(yaw) > 3.1, "yaw went through pi, not through 0: " .. yaw)
		local empty = Ring.new(4, false)
		local _, _, _, _, _, _, _, _, st2 = Interp.sample(empty, 1, 0.1)
		T.eq(st2, Interp.STATE_EMPTY)
	end)

	T.test("full rotation: quaternion nlerp between samples", function()
		local r = Ring.new(8, true)
		local s = math.sin(math.pi / 4)
		Ring.push(r, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
		Ring.push(r, 1, 0, 0, 0, 0, 0, s, 0, 0, s) -- 90 deg about X
		local _, _, _, _, qx, qy, qz, qw = Interp.sample(r, 0.5, 0)
		T.near(qx, math.sin(math.pi / 8), 0.02)
		T.near(qw, math.cos(math.pi / 8), 0.02)
		T.near(qx * qx + qy * qy + qz * qz + qw * qw, 1, 1e-9, "unit")
	end)

	T.test("smart buffer: p95 of needs + margin, clamps, easing", function()
		local Config = T.module(world, "Shared", "Config")
		local src = Buffer.new(0.02)
		for i = 1, 128 do
			Buffer.addNeed(src, i / 1000) -- 1..128 ms
		end
		-- k = ceil(0.05 * 128) = 7th largest = 122 ms
		T.near(Buffer.p95(src), 0.122, 1e-9)
		Buffer.update(src, 1 / 60)
		T.near(src.delay, 0.122 + Config.BufferMargin, 1e-9, "first update takes the target")
		-- small rise eases (<= 0.25 s per s), big rise snaps
		for _ = 1, 128 do
			Buffer.addNeed(src, 0.15)
		end
		local before = src.delay
		Buffer.update(src, 1 / 60)
		T.check(src.delay > before and src.delay - before <= 0.25 / 60 + 1e-12, "eased up")
		for _ = 1, 128 do
			Buffer.addNeed(src, 0.4)
		end
		Buffer.update(src, 1 / 60)
		T.near(src.delay, 0.4 + Config.BufferMargin, 1e-9, "big change snaps")
		-- clamps
		for _ = 1, 128 do
			Buffer.addNeed(src, 5)
		end
		for _ = 1, 300 do
			Buffer.update(src, 1 / 60)
		end
		T.near(src.delay, Config.MaxBuffer, 1e-9, "max clamp")
		for _ = 1, 128 do
			Buffer.addNeed(src, 0.001)
		end
		for _ = 1, 600 do
			Buffer.update(src, 1 / 60)
		end
		T.near(src.delay, 0.02, 1e-6, "min clamp (kind.buffer)")
		-- an outlier below 5% does not move the p95
		local s2 = Buffer.new(0.01)
		for i = 1, 128 do
			Buffer.addNeed(s2, if i % 50 == 0 then 1.0 else 0.05)
		end
		T.near(Buffer.p95(s2), 0.05, 1e-9)
	end)

	T.test("server history: Tide.at interpolates what was relayed; latest; handle; rotation", function()
		local w = T.world({ latency = 0.02 })
		local Tide = T.serverTide(w)
		Tide.kind("Spinner", { rate = 30, rotation = "full" })
		Tide.start()
		local m = w:spawnModel("bot", CFrame.new(0, 3, 0), true)
		local handle = Tide.add(m, "Bot")
		local spin = w:spawnModel("spin", CFrame.new(0, 3, 0), true)
		Tide.add(spin, "Spinner")
		local function pos(t)
			return 5 * math.sin(t), 3, 5 * math.cos(t)
		end
		local start = w.now
		for _ = 1, 150 do
			local t = w.now + 1 / 60
			local x, y, z = pos(t)
			m.HumanoidRootPart.CFrame = CFrame.new(x, y, z)
			spin.HumanoidRootPart.CFrame = CFrame.new(0, 3, 0) * CFrame.Angles(t, 0, 0)
			w:frame(1 / 60)
		end
		local now = w.now
		for k = 0, 36 do -- the newest sample is up to one 30 Hz tick old
			local t = now - 1.0 + k * 0.025
			local cf = Tide.at(m, t)
			local x, y, z = pos(t)
			T.near(cf.X, x, 0.01)
			T.near(cf.Y, y, 0.01)
			T.near(cf.Z, z, 0.01)
			local hcf = Tide.at(handle, t)
			T.eq(hcf.X, cf.X, "handle and model agree")
		end
		-- beyond the newest: newest (no extrapolation on the server)
		local latest = Tide.latest(m)
		T.eq(Tide.at(m, now + 5).X, latest.X)
		-- before the oldest kept sample: oldest
		local oldest = Tide.at(m, start - 100)
		T.check(oldest ~= nil)
		-- full rotation round trip through history
		local scf = Tide.at(spin, now - 0.5)
		local angle = now - 0.5
		local look = scf.LookVector
		local want = (CFrame.Angles(angle, 0, 0)).LookVector
		T.near(look.X, want.X, 0.01)
		T.near(look.Y, want.Y, 0.01)
		T.near(look.Z, want.Z, 0.01)
		T.eq(Tide.at(w.server.Workspace, now), nil, "unknown model")
		-- history ring is bounded
		local State = T.module(w, "Server", "State")
		local h = State.hist[State.bySlotModel[m]]
		T.check(h.n <= 128 and h.n >= 60, "ring bounded: " .. h.n)
	end)
end
