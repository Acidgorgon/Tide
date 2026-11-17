-- End to end: server + 3 mock clients exchanging 2 s of movement, with latency and jitter.
return function(T)
	local DT = 1 / 60

	local function path(i, t)
		local x = i * 20 + 8 * math.sin(t * 1.3 + i)
		local z = 12 * math.cos(t * 0.9 + i)
		local yaw = math.sin(t * 0.7 + i) * 2
		return x, 3, z, yaw
	end

	local function setup(opts)
		local world = T.world(opts)
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local chars, cts = {}, {}
		for i = 1, 3 do
			local player = world:addPlayer()
			local x, y, z, yaw = path(i, world.now)
			chars[i] = world:spawnCharacter(player, CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0))
		end
		for i = 1, 3 do
			cts[i] = T.clientTide(world, i)
			cts[i].start()
		end
		return world, Tide, chars, cts
	end

	local function drive(world, chars, seconds)
		local frames = math.floor(seconds / DT + 0.5)
		for _ = 1, frames do
			local t = world.now + DT
			for i = 1, #chars do
				local hrp = world:replica(i, chars[i].HumanoidRootPart)
				if hrp then
					local x, y, z, yaw = path(i, t)
					hrp.CFrame = CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0)
				end
			end
			world:frame(DT)
		end
	end

	T.test("3 clients see each other on the known path; server history matches", function()
		local world, Tide, chars, cts = setup({ latency = 0.04, jitter = 0.01, seed = 7, start = 1.7e9 })
		drive(world, chars, 2)

		local now = world.now
		local worst = 0
		for i = 1, 3 do
			local ct = cts[i]
			for j = 1, 3 do
				local model = world:replica(i, chars[j])
				if i == j then
					T.eq(ct.drawn(model), nil, "own character is not drawn by Tide")
				else
					local cf = ct.drawn(model)
					T.check(cf ~= nil, `client {i} draws {j}`)
					local delay = ct.delay(model)
					T.check(delay > 0.04 and delay < 0.2, `client {i} delay for {j}: {delay}`)
					local x, y, z, yaw = path(j, now - delay)
					local err = math.sqrt((cf.X - x) ^ 2 + (cf.Y - y) ^ 2 + (cf.Z - z) ^ 2)
					worst = math.max(worst, err)
					T.check(err < 0.15, `client {i} sees {j} {err} studs off the path`)
					local yerr = math.abs((T.Mock.yawOf(cf) - yaw + math.pi) % (2 * math.pi) - math.pi)
					T.check(yerr < 0.02, `yaw error {yerr}`)
					-- the model itself was moved there (anchored root -> BulkMoveTo)
					local hrp = model.HumanoidRootPart
					T.check(hrp.Anchored, "remote root anchored on the client")
					T.near(hrp.CFrame.X, cf.X, 1e-9)
				end
			end
		end

		-- server rewind: Tide.at matches the path within interpolation error
		for j = 1, 3 do
			for k = 1, 20 do
				local t = now - 0.9 + k * 0.03
				local cf = Tide.at(chars[j], t)
				local x, y, z = path(j, t)
				local err = math.sqrt((cf.X - x) ^ 2 + (cf.Y - y) ^ 2 + (cf.Z - z) ^ 2)
				T.check(err < 0.05, `server rewind error {err} at {t - now}`)
			end
			-- latest ~ newest uploaded sample
			local latest = Tide.latest(chars[j])
			local x, _, z = path(j, now)
			T.check(math.abs(latest.X - x) < 0.6 and math.abs(latest.Z - z) < 0.6, "latest near the newest upload")
		end

		local stats = Tide.stats()
		T.eq(stats.badPacket, 0, "no bad packets")
		T.eq(stats.speed, 0, "no speed drops")
		T.check(stats.samples > 3 * 100, "server accepted uploads: " .. stats.samples)
		T.eq(world.stats.oversize, 0, "no oversize unreliable packets")
		local _ = worst
	end)

	T.test("lock (root mode, default): non-replicated locker inside the root; server root follows", function()
		local world, _Tide, chars, cts = setup({ latency = 0.03 })
		drive(world, chars, 1)
		for j = 1, 3 do
			local hrp = chars[j].HumanoidRootPart
			local x, _, z = path(j, world.now - 0.03)
			T.check(math.abs(hrp.CFrame.X - x) < 1 and math.abs(hrp.CFrame.Z - z) < 1, "server root follows uploads")
			local holder = hrp:FindFirstChild("TideLock")
			T.check(holder ~= nil and holder.ClassName == "Camera", "Camera inside the root")
			local locker = holder:FindFirstChild("TideLocker")
			T.check(locker ~= nil, "locker under the camera")
			T.eq(locker.Anchored, false, "locker unanchored")
			T.eq(locker.RootPriority, 126)
			T.eq(locker.Massless, false)
			T.near(locker.CustomPhysicalProperties.Density, 0.0001, 1e-12)
			T.eq(locker.CanCollide or locker.CanQuery or locker.CanTouch, false)
			local weld = holder:FindFirstChild("TideWeld")
			T.check(weld ~= nil and weld.Part0 == locker and weld.Part1 == hrp, "weld locker -> root")
			T.near(locker.CFrame.X, hrp.CFrame.X, 1e-9)
			-- nothing of the lock replicates to any client
			for i = 1, 3 do
				local rep = world:replica(i, hrp)
				T.eq(rep:FindFirstChild("TideLock"), nil, "lock invisible to client " .. i)
			end
		end
		T.eq(#world.server.Workspace.CurrentCamera:GetChildren(), 0, "nothing in the server camera")
		-- respawn / removal leaves nothing behind
		local hrp1 = chars[1].HumanoidRootPart
		world:removePlayer(world.players[1])
		world:frame(DT)
		T.eq(hrp1:FindFirstChild("TideLock"), nil, "lock removed with the entity")
		local _ = cts
	end)

	T.test("lock (anchored mode) and optional server Humanoid state disabling", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({
			players = true,
			lockMode = "anchored",
			lockHumanoidStates = { Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll },
		})
		local p = world:addPlayer()
		local char = world:spawnCharacter(p, CFrame.new(5, 3, 0))
		local ct = T.clientTide(world, 1)
		ct.start()
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		T.eq(humanoid:GetStateEnabled(Enum.HumanoidStateType.FallingDown), false, "state disabled while locked")
		T.eq(humanoid:GetStateEnabled(Enum.HumanoidStateType.Physics), true, "other states untouched")
		for f = 1, 60 do
			world:replica(1, char.HumanoidRootPart).CFrame = CFrame.new(5 + f * 0.1, 3, 0)
			world:frame(DT)
		end
		local camera = world.server.Workspace.CurrentCamera
		local locker = camera:FindFirstChild("TideLocker")
		T.check(locker ~= nil and locker.Anchored, "anchored locker in the server camera")
		T.eq(char.HumanoidRootPart:FindFirstChild("TideLock"), nil)
		T.check(math.abs(char.HumanoidRootPart.CFrame.X - 10.9) < 0.3, "server root follows: " .. char.HumanoidRootPart.CFrame.X)
		T.check(world.server.bulkMoves > 0, "moved with BulkMoveTo")
		-- unlock restores the Humanoid and removes the locker
		Tide.handle(char):setOwner(nil)
		T.eq(humanoid:GetStateEnabled(Enum.HumanoidStateType.FallingDown), true, "state restored")
		T.eq(camera:FindFirstChild("TideLocker"), nil)
		local Config = T.module(world, "Shared", "Config")
		T.check(not pcall(function()
			Config.lockMode = "bogus"
			local w2 = T.world()
			T.serverTide(w2).start({ lockMode = "bogus" })
		end), "bad lockMode rejected")
		Config.lockMode = "root"
	end)

	T.test("bots (server-owned) replicate to every client", function()
		local world, Tide, chars, cts = setup({ latency = 0.05, jitter = 0.005 })
		local bots = {}
		for k = 1, 4 do
			local model = world:spawnModel("Bot" .. k, CFrame.new(k * 5, 3, 40), true)
			bots[k] = { model = model, handle = Tide.add(model, "Bot") }
		end
		local function botPos(k, t)
			return k * 5 + 6 * math.sin(t + k), 3, 40 + 4 * math.cos(t * 1.7)
		end
		local frames = 120
		for _ = 1, frames do
			local t = world.now + DT
			for k, bot in bots do
				local x, y, z = botPos(k, t)
				bot.model.HumanoidRootPart.CFrame = CFrame.new(x, y, z)
			end
			for i = 1, #chars do
				local hrp = world:replica(i, chars[i].HumanoidRootPart)
				local x, y, z, yaw = path(i, t)
				hrp.CFrame = CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0)
			end
			world:frame(DT)
		end
		for i = 1, 3 do
			for k, bot in bots do
				local model = world:replica(i, bot.model)
				local cf = cts[i].drawn(model)
				T.check(cf ~= nil, "bot drawn")
				local delay = cts[i].delay(model)
				local x, _, z = botPos(k, world.now - delay)
				local err = math.sqrt((cf.X - x) ^ 2 + (cf.Z - z) ^ 2)
				T.check(err < 0.25, `bot error {err} (delay {delay})`)
			end
		end
		-- all bots share one buffer per kind on a client
		local d1 = cts[1].delay(world:replica(1, bots[1].model))
		local d2 = cts[1].delay(world:replica(1, bots[2].model))
		T.eq(d1, d2, "per-kind delay")
	end)

	T.test("ownership hand-over: server -> client -> server", function()
		local world, Tide, chars, cts = setup({ latency = 0.03 })
		local m = world:spawnModel("ball", CFrame.new(0, 3, 10), true)
		local handle = Tide.add(m, "Bot")
		local function ballPos(t)
			return 3 * math.sin(t * 2), 3, 10 + t % 1
		end
		local owner = nil
		local function frames(n)
			for _ = 1, n do
				local t = world.now + DT
				local x, y, z = ballPos(t)
				if owner == nil then
					m.HumanoidRootPart.CFrame = CFrame.new(x, y, z)
				else
					world:replica(owner, m).HumanoidRootPart.CFrame = CFrame.new(x, y, z)
				end
				for i = 1, 3 do
					local px, py, pz, yaw = path(i, t)
					world:replica(i, chars[i].HumanoidRootPart).CFrame = CFrame.new(px, py, pz) * CFrame.Angles(0, yaw, 0)
				end
				world:frame(DT)
			end
		end
		local function checkDrawn(skip)
			for i = 1, 3 do
				if i ~= skip then
					local view = world:replica(i, m)
					local cf = cts[i].drawn(view)
					local x, _, z = ballPos(world.now - cts[i].delay(view))
					T.check(math.abs(cf.X - x) < 0.2 and math.abs(cf.Z - z) < 0.3, `client {i} draws the ball ({cf.X} vs {x})`)
				end
			end
		end
		frames(60)
		checkDrawn(nil)
		-- hand to player 1: client 1 drives it, the others follow its uploads
		owner = 1
		handle:setOwner(world.players[1])
		frames(60)
		T.eq(cts[1].drawn(world:replica(1, m)), nil, "owner does not draw it")
		T.check(not world:replica(1, m).HumanoidRootPart.Anchored or m.HumanoidRootPart.Anchored, "owner restored its anchor state")
		checkDrawn(1)
		T.eq(Tide.stats().speed, 0)
		-- back to the server
		local last = world:replica(1, m).HumanoidRootPart.CFrame
		m.HumanoidRootPart.CFrame = last
		owner = nil
		handle:setOwner(nil)
		frames(60)
		checkDrawn(nil)
	end)

	T.test("upload redundancy survives 30% loss on uploads", function()
		local world = T.world({ latency = 0.03, loss = 0.3, seed = 9 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true, UploadRedundancy = 2 })
		local p = world:addPlayer()
		local char = world:spawnCharacter(p, CFrame.new(0, 3, 0))
		local ct = T.clientTide(world, 1)
		ct.start()
		for f = 1, 180 do
			world:replica(1, char.HumanoidRootPart).CFrame = CFrame.new(f * 0.1, 3, 0)
			world:frame(DT)
		end
		local stats = Tide.stats()
		-- each sample travels twice: lost only if both copies drop (~9%)
		T.check(stats.samples > 180 * 0.85, "samples accepted: " .. stats.samples)
		T.check(stats.stamp > 50, "duplicates were dropped as non-increasing: " .. stats.stamp)
		T.eq(stats.badPacket, 0)
		local Config = T.module(world, "Shared", "Config")
		Config.UploadRedundancy = 1
	end)
end
