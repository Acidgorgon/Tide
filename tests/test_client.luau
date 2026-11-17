-- Client: smart buffer + Hermite rendering under jitter, bounded extrapolation,
-- correction blend after a stall, teleport snap, gap snap, upload schedule.
return function(T)
	local DT = 1 / 60

	local function setup(netOpts)
		local world = T.world(netOpts)
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, -50))
		local ct = T.clientTide(world, 1)
		ct.start()
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), false)
		local handle = Tide.add(m, "Bot")
		return world, Tide, ct, m, handle
	end

	-- runs frames; move(t) positions the server model for time t; each(frame) observes the client
	local function run(world, model, seconds, move, each)
		local frames = math.floor(seconds / DT + 0.5)
		for f = 1, frames do
			local t = world.now + DT
			local x, y, z, yaw = move(t)
			if x then
				model.HumanoidRootPart.CFrame = CFrame.new(x, y, z) * CFrame.Angles(0, yaw or 0, 0)
			end
			world:frame(DT)
			if each then
				each(f)
			end
		end
	end

	local function curve(t)
		return 10 * math.sin(t * 0.8), 3 + math.sin(t * 2), 10 * math.cos(t * 0.6), t * 0.5
	end

	T.test("render follows a known path under jitter (Hermite + smart buffer)", function()
		local world, _Tide, ct, m = setup({ latency = 0.05, jitter = 0.03, seed = 11, start = 1.7e9 })
		local view = world:replica(1, m)
		run(world, m, 0.6, curve)
		local maxErr, maxYaw, sumDelay, n = 0, 0, 0, 0
		run(world, m, 3, curve, function()
			local cf = ct.drawn(view)
			local delay = ct.delay(view)
			local x, y, z, yaw = curve(world.now - delay)
			local err = math.sqrt((cf.X - x) ^ 2 + (cf.Y - y) ^ 2 + (cf.Z - z) ^ 2)
			maxErr = math.max(maxErr, err)
			local ye = math.abs((T.Mock.yawOf(cf) - yaw + math.pi) % (2 * math.pi) - math.pi)
			maxYaw = math.max(maxYaw, ye)
			sumDelay += delay
			n += 1
		end)
		local avgDelay = sumDelay / n
		T.check(maxErr < 0.08, "max position error " .. maxErr)
		T.check(maxYaw < 0.01, "max yaw error " .. maxYaw)
		-- delay ~ latency + jitter p95 + one tick (33 ms) + a frame; never absurd
		T.check(avgDelay > 0.08 and avgDelay < 0.16, "average delay " .. avgDelay)
	end)

	T.test("delay adapts: higher jitter -> larger buffer, eased not snapped", function()
		local world, _Tide, ct, m = setup({ latency = 0.03, jitter = 0.0, seed = 5 })
		local view = world:replica(1, m)
		run(world, m, 2, curve)
		local calm = ct.delay(view)
		world.jitter = 0.06
		local prev = ct.delay(view)
		local maxStep = 0
		run(world, m, 3, curve, function()
			local d = ct.delay(view)
			maxStep = math.max(maxStep, math.abs(d - prev))
			prev = d
		end)
		local rough = ct.delay(view)
		T.check(rough > calm + 0.03, `delay grew with jitter: {calm} -> {rough}`)
		T.check(maxStep <= 0.25 * DT + 1e-9, "eased (render clock >= 0.75x): step " .. maxStep)
	end)

	T.test("extrapolation is bounded, then holds; resumes with a blended correction", function()
		local world, _Tide, ct, m = setup({ latency = 0.04, seed = 2 })
		local view = world:replica(1, m)
		local function line(t)
			return (t - 1000) * 10, 3, 0, 0
		end
		run(world, m, 1, line)
		local CState = T.clientModule(world, 1, "Client", "State")
		local slot = CState.bySlotModel[view]
		world.blockS2C = true
		local xs = {}
		run(world, m, 0.5, line, function()
			table.insert(xs, ct.drawn(view).X)
		end)
		-- newest received sample
		local r = CState.ring[slot]
		local newestX = r.x[r.last % r.cap + 1]
		local maxX = -math.huge
		for _, x in xs do
			maxX = math.max(maxX, x)
		end
		T.check(maxX <= newestX + 10 * 0.1 + 0.02, `extrapolated at most 0.1 s: {maxX} vs newest {newestX}`)
		T.check(maxX > newestX + 0.5, "it did extrapolate")
		T.near(xs[#xs], xs[#xs - 5], 1e-9, "holding at the end of the stall")
		-- resume: correction blends (no single-frame jump to the path), back on the path in ~0.1 s
		world.blockS2C = false
		local last = xs[#xs]
		local maxJump = 0
		local errAfter = 0
		local f0 = 0
		run(world, m, 0.6, line, function(f)
			local cf = ct.drawn(view)
			maxJump = math.max(maxJump, math.abs(cf.X - last))
			last = cf.X
			f0 = f
			if f > 25 then
				local x = line(world.now - ct.delay(view))
				errAfter = math.max(errAfter, math.abs(cf.X - x))
			end
		end)
		T.check(maxJump < 2.5, "largest per-frame move after resume " .. maxJump)
		T.check(errAfter < 0.05, "back on the path: " .. errAfter)
		local _ = f0
	end)

	T.test("long silence (> SnapGap) snaps instead of sweeping", function()
		local world, _Tide, ct, m = setup({ latency = 0.03 })
		local view = world:replica(1, m)
		local function line(t)
			return (t - 1000) * 10, 3, 0, 0
		end
		run(world, m, 1, line)
		world.blockS2C = true
		run(world, m, 1.5, line)
		world.blockS2C = false
		local positions = {}
		run(world, m, 0.6, line, function()
			table.insert(positions, ct.drawn(view).X)
		end)
		-- the 15 studs skipped are not swept across over many frames: one big step
		local maxJump, bigSteps = 0, 0
		for k = 2, #positions do
			local j = math.abs(positions[k] - positions[k - 1])
			maxJump = math.max(maxJump, j)
			if j > 1 then
				bigSteps += 1
			end
		end
		T.check(maxJump > 10, "snapped: " .. maxJump)
		T.eq(bigSteps, 1, "one snap")
	end)

	T.test("teleport snaps for receivers (never drawn in between)", function()
		local world, _Tide, ct, m, handle = setup({ latency = 0.04, jitter = 0.01 })
		local view = world:replica(1, m)
		local base = 0
		local function wiggle(t)
			return base + math.sin(t * 3), 3, 0, 0
		end
		run(world, m, 1, wiggle)
		handle:teleport(CFrame.new(200, 3, 0))
		base = 200
		local xs = {}
		run(world, m, 1, wiggle, function()
			table.insert(xs, ct.drawn(view).X)
		end)
		for _, x in xs do
			T.check(math.abs(x) < 1.5 or math.abs(x - 200) < 1.5, "drawn between the two places: " .. x)
		end
		T.check(math.abs(xs[#xs] - 200) < 1.5, "arrived")
		T.check(math.abs(xs[1]) < 1.5, "was at the start")
	end)

	T.test("upload schedule is steady at the kind rate", function()
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.kind("Player", { rate = 30 })
		Tide.start({ players = true })
		local p = world:addPlayer()
		local char = world:spawnCharacter(p, CFrame.new(0, 3, 0))
		local ct = T.clientTide(world, 1)
		ct.start()
		-- the owner runs (an idle character would skip unchanged samples)
		local root = world:replica(1, char):FindFirstChild("HumanoidRootPart")
		local x = 0
		local function frame(dt)
			x += 16 * dt
			root.CFrame = CFrame.new(x, 3, 0)
			world:frame(dt)
		end
		-- 144 fps client for 2 s
		for _ = 1, 288 do
			frame(1 / 144)
		end
		local uploads = ct.stats().uploads
		T.check(math.abs(uploads - 60) <= 3, "30 Hz at 144 fps: " .. uploads)
		local before = uploads
		-- 60 fps, rate 30
		for _ = 1, 120 do
			frame(1 / 60)
		end
		T.check(math.abs(ct.stats().uploads - before - 60) <= 2, "30 Hz at 60 fps")
		Tide.kind("Player", { rate = 60 })
	end)

	T.test("velocity, latest and removed signal", function()
		local world, Tide, ct, m, handle = setup({ latency = 0.02 })
		local view = world:replica(1, m)
		local function line(t)
			return (t - 1000) * 8, 3, 0, 0
		end
		run(world, m, 1, line)
		local v = ct.velocity(view)
		T.near(v.X, 8, 0.3, "velocity x")
		T.near(v.Z, 0, 0.05)
		local latest = ct.latest(view)
		T.check(latest.X >= ct.drawn(view).X, "latest is ahead of drawn")
		local removed = {}
		ct.removed(function(model, kind)
			table.insert(removed, { model, kind })
		end)
		handle:remove()
		run(world, m, 0.2, line)
		T.eq(#removed, 1)
		T.eq(removed[1][2], "Bot")
		T.eq(ct.drawn(view), nil, "no longer drawn")
		T.check(not view.HumanoidRootPart.Anchored, "anchor restored on removal")
		local _ = Tide
	end)

	T.test("streaming: model arrives as nil, client asks again and attaches it", function()
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		local ct = T.clientTide(world, 1)
		local added = {}
		ct.added(function(model, kind)
			table.insert(added, { model, kind })
		end)
		ct.start()
		local m = world:spawnModel("far", CFrame.new(500, 3, 0), true)
		world:streamOut(1, m)
		Tide.add(m, "Bot")
		for _ = 1, 30 do
			world:frame(DT)
		end
		local CState = T.clientModule(world, 1, "Client", "State")
		local found = false
		for k = 1, CState.count do
			local slot = CState.active[k]
			if CState.model[slot] == nil then
				found = true
			end
		end
		T.check(found, "entity registered without its model")
		world:streamOut(1, m, false)
		for _ = 1, 90 do
			m.HumanoidRootPart.CFrame = CFrame.new(500, 3, world.now % 5)
			world:frame(DT)
		end
		local view = world:replica(1, m)
		T.check(ct.drawn(view) ~= nil, "drawn after the model streamed in")
		local hasFar = false
		for _, a in added do
			if a[1] == view then
				hasFar = true
			end
		end
		T.check(hasFar, "added fired when the model arrived")
	end)
end
