-- Adapter-facing API: sampleInfo, afterApply, server velocity (+ locker velocity),
-- teleportOnWrite, teleport velocity, inbound byte counters, start timeout, start options.
return function(T)
	local DT = 1 / 60

	-- server + 2 clients; client 1 owns chars[1], client 2 watches it
	local function setup(startOpts, netOpts)
		local world = T.world(netOpts or { latency = 0.02 })
		local Tide = T.serverTide(world)
		local opts = startOpts or {}
		opts.players = true
		Tide.start(opts)
		local chars, cts = {}, {}
		for i = 1, 2 do
			local p = world:addPlayer()
			chars[i] = world:spawnCharacter(p, CFrame.new(i * 10, 3, 0))
		end
		for i = 1, 2 do
			cts[i] = T.clientTide(world, i)
			cts[i].start()
		end
		local State = T.module(world, "Server", "State")
		local s = { world = world, Tide = Tide, chars = chars, cts = cts, State = State }
		-- owner-side root of character i
		function s.ownRoot(i)
			return world:replica(i, chars[i]):FindFirstChild("HumanoidRootPart")
		end
		function s.view(i, j)
			return world:replica(i, chars[j])
		end
		local t0 = world.now
		-- each(frame, t): t is seconds since setup for the frame being run
		function s.step(n, each)
			for f = 1, n or 1 do
				if each then
					each(f, world.now + DT - t0)
				end
				world:frame(DT)
			end
		end
		return s
	end

	T.test("sampleInfo: newest, count, age, interval, jitter, idle; reusable table", function()
		local s = setup()
		local root = s.ownRoot(1)
		s.step(120, function(_, t)
			root.CFrame = CFrame.new(10 + 8 * t % 50, 3, 0)
		end)
		local ct = s.cts[2]
		local model = s.view(2, 1)
		local info = ct.sampleInfo(model)
		T.check(info ~= nil, "info for a remote entity")
		local Cs = T.clientModule(s.world, 2, "Client", "State")
		local r = Cs.ring[Cs.bySlotModel[model]]
		T.eq(info.count, r.last, "count = samples received")
		T.eq(info.newest, r.t[r.last % r.cap + 1], "newest sample time")
		T.check(info.age > 0 and info.age < 0.1, "age " .. info.age)
		T.near(info.interval, 1 / 60, 0.004, "interval")
		T.check(info.jitter >= 0 and info.jitter < 0.01, "jitter " .. info.jitter)
		T.eq(info.idle, false, "moving")
		T.near(info.delay, ct.delay(model), 1e-12)
		T.near(info.held, (s.world.now - info.delay) - info.newest, 1e-6)
		-- reuse
		local into = {}
		T.eq(ct.sampleInfo(model, into), into, "fills the given table")
		-- own entity / unknown: nil
		T.eq(s.cts[1].sampleInfo(s.view(1, 1)), nil, "own entity")
		T.eq(ct.sampleInfo(T.Mock.newInstance("Model")), nil, "unknown model")
		-- standing still: idle
		s.step(60)
		info = ct.sampleInfo(model, into)
		T.eq(info.idle, true, "idle once the owner stands still")
	end)

	T.test("afterApply runs after the default apply (root still anchored, pose in place)", function()
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, -50))
		local ct = T.clientTide(world, 1)
		local calls, bad = 0, 0
		ct.kind("Bot", {
			afterApply = function(model, cf)
				calls += 1
				local root = model:FindFirstChild("HumanoidRootPart")
				if not root.Anchored or math.abs(root.CFrame.X - cf.X) > 1e-9 then
					bad += 1
				end
				if ct.drawn(model) ~= cf then
					bad += 1
				end
			end,
		})
		ct.start()
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), false)
		Tide.add(m, "Bot")
		for f = 1, 60 do
			m.HumanoidRootPart.CFrame = CFrame.new(f * 0.2, 3, 0)
			world:frame(DT)
		end
		T.check(calls > 40, "called every drawn frame: " .. calls)
		T.eq(bad, 0, "pose applied (and root anchored) before the hook")
		-- with apply = "none" the hook still gets the pose
		local got = nil
		ct.kind("Bot", {
			apply = "none",
			afterApply = function(_, cf)
				got = cf
			end,
		})
		world:frame(DT)
		T.check(got ~= nil, "afterApply with apply none")
		-- errors are counted, not thrown
		ct.kind("Bot", {
			apply = "cframe",
			afterApply = function()
				error("boom")
			end,
		})
		world:frame(DT)
		T.check(ct.stats().applyErrors > 0, "hook errors counted")
		ct.kind("Bot", { afterApply = false })
	end)

	T.test("server Tide.velocity from history; locker gets the velocity; zero when idle", function()
		local s = setup()
		local root = s.ownRoot(1)
		s.step(90, function(_, t)
			root.CFrame = CFrame.new(10 + 12 * t, 3, -5 * t)
		end)
		local v = s.Tide.velocity(s.chars[1])
		T.near(v.X, 12, 0.3, "vx")
		T.near(v.Z, -5, 0.3, "vz")
		T.near(v.Y, 0, 0.05, "vy")
		local slot = s.State.bySlotModel[s.chars[1]]
		local locker = s.State.locker[slot]
		T.check(locker ~= nil, "locked")
		T.near(locker.AssemblyLinearVelocity.X, 12, 0.3, "locker velocity")
		-- stop: velocity drops to zero (stop sample), no drift
		s.step(30)
		v = s.Tide.velocity(s.chars[1])
		T.near(v.X, 0, 1e-9, "idle")
		T.near(locker.AssemblyLinearVelocity.X, 0, 1e-9, "locker idle")
		T.eq(s.Tide.velocity(T.Mock.newInstance("Model")), Vector3.new(0, 0, 0), "unknown model")
	end)

	T.test("full-rotation kind: locker gets angular velocity", function()
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.kind("Spinner", { rate = 60, rotation = "full" })
		Tide.start({ players = true })
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, -50))
		local ct = T.clientTide(world, 1)
		ct.start()
		local m = world:spawnModel("spinner", CFrame.new(0, 3, 0), false)
		Tide.add(m, "Spinner", p)
		local State = T.module(world, "Server", "State")
		local slot = State.bySlotModel[m]
		local root = world:replica(1, m):FindFirstChild("HumanoidRootPart")
		local t0 = world.now
		for _ = 1, 60 do
			local t = world.now + DT - t0
			root.CFrame = CFrame.new(t * 3, 3, 0) * CFrame.Angles(0, 0, 2 * t)
			world:frame(DT)
		end
		local w = State.locker[slot].AssemblyAngularVelocity
		T.near(w.Z, 2, 0.05, "spin rate about Z")
		T.near(w.X, 0, 0.05)
		T.near(w.Y, 0, 0.05)
	end)

	T.test("teleportOnWrite: server CFrame / PivotTo writes become teleports; no-op writes do not", function()
		local s = setup()
		s.step(30)
		local char = s.chars[1]
		local slot = s.State.bySlotModel[char]
		local hrp = char.HumanoidRootPart
		-- no-op write
		hrp.CFrame = hrp.CFrame
		T.check(not s.State.tpPending[slot], "no-op write ignored")
		-- server game code moves the player
		hrp.CFrame = CFrame.new(300, 3, 300)
		T.check(s.State.tpPending[slot], "CFrame write became a teleport")
		s.step(30)
		T.check(not s.State.tpPending[slot], "owner acknowledged")
		T.near(s.ownRoot(1).CFrame.X, 300, 1e-3, "owner moved there")
		T.near(s.Tide.latest(char).X, 300, 0.05, "server history at the target")
		T.near(hrp.CFrame.X, 300, 0.05, "server copy (lock) at the target")
		T.check(s.cts[2].drawn(s.view(2, 1)).X > 299, "observer snapped")
		-- PivotTo
		char:PivotTo(CFrame.new(-200, 3, 0))
		T.check(s.State.tpPending[slot], "PivotTo became a teleport")
		s.step(30)
		T.near(s.ownRoot(1).CFrame.X, -200, 1e-3)
		T.eq(s.Tide.stats().teleportWait >= 0, true)
		-- the lock's own moves over 2 s never trigger a teleport
		local root = s.ownRoot(1)
		local before = s.Tide.stats().teleportWait
		s.step(120, function(_, t)
			root.CFrame = CFrame.new(-200 + 5 * (t % 10), 3, 0)
		end)
		T.check(not s.State.tpPending[slot], "no spurious teleports")
		T.eq(s.Tide.stats().teleportWait, before, "no uploads dropped")
	end)

	T.test("teleportOnWrite = false leaves server writes alone", function()
		local s = setup({ teleportOnWrite = false })
		s.step(10)
		local slot = s.State.bySlotModel[s.chars[1]]
		s.chars[1].HumanoidRootPart.CFrame = CFrame.new(300, 3, 300)
		T.check(not s.State.tpPending[slot], "no teleport")
	end)

	T.test("teleport velocity reaches the owner", function()
		local s = setup()
		s.step(10)
		s.Tide.handle(s.chars[1]):teleport(CFrame.new(0, 50, 0), Vector3.new(0, 30, 4))
		s.step(5)
		local root = s.ownRoot(1)
		T.near(root.CFrame.Y, 50, 1e-3)
		T.near(root.AssemblyLinearVelocity.Y, 30, 1e-4)
		T.near(root.AssemblyLinearVelocity.Z, 4, 1e-4)
		-- server-owned: velocity on the root
		local m = s.world:spawnModel("bot", CFrame.new(0, 3, 0), false)
		local h = s.Tide.add(m, "Bot")
		h:teleport(CFrame.new(5, 3, 5), Vector3.new(1, 2, 3))
		T.eq(m.HumanoidRootPart.AssemblyLinearVelocity, Vector3.new(1, 2, 3))
		T.eq(s.Tide.velocity(m), Vector3.new(1, 2, 3), "teleport sample reports its velocity")
	end)

	T.test("inbound byte counters", function()
		local s = setup()
		local root = s.ownRoot(1)
		s.step(150, function(_, t)
			root.CFrame = CFrame.new(10 + 8 * t % 40, 3, 0)
		end)
		local st = s.Tide.stats()
		T.check(st.inBytes > 0, "inBytes")
		local up = s.cts[1].stats()
		-- 60 Hz uploads of ~28 B: ~1.7 KB/s from client 1 (client 2 idle)
		T.check(st.inBytesPerSecond > 1000 and st.inBytesPerSecond < 3000, "inBytesPerSecond " .. st.inBytesPerSecond)
		T.check(st.inBytes >= up.uploadBytes, "counts every upload byte")
		T.check(st.relayBytesPerSecond > 0, "relayBytesPerSecond")
	end)

	T.test("client start: times out with a warning and returns false", function()
		local world = T.world({ latency = 0.02 })
		world:addPlayer()
		local ct = T.clientTide(world, 1)
		T.eq(ct.start({ startTimeout = 0.1 }), false, "no server remotes")
		-- once the server runs, a later start succeeds
		local Tide = T.serverTide(world)
		T.eq(Tide.start({ players = true }), true)
		world:frame(DT)
		T.eq(ct.start(), true)
		T.eq(ct.start(), true, "idempotent")
	end)

	T.test("start options: every Config field, type checked; kinds; extras", function()
		local function fresh()
			local world = T.world({ latency = 0.02 })
			return T.serverTide(world), T.module(world, "Shared", "Config"), T.module(world, "Shared", "Kinds")
		end
		local Tide, Config, Kinds = fresh()
		T.eq(
			Tide.start({
				players = true,
				lockHumanoidStates = { Enum.HumanoidStateType.FallingDown },
				ReceiverBytesPerSecond = 20000,
				lockMode = "anchored",
				kinds = { Player = { maxFall = 450 }, Ball = { rate = 60, rotation = "full" } },
			}),
			true
		)
		T.eq(Config.ReceiverBytesPerSecond, 20000)
		T.eq(Config.lockMode, "anchored")
		T.eq(type(Config.lockHumanoidStates), "table")
		T.eq(Kinds.byName.Player.maxFall, 450, "kind option through start")
		T.eq(Kinds.byName.Ball.full, true, "new kind through start")
		local function fails(opts, pattern)
			local t2 = fresh()
			local ok, err = pcall(t2.start, opts)
			T.check(not ok, "should fail: " .. pattern)
			T.check(string.find(tostring(err), pattern, 1, true) ~= nil, tostring(err))
			-- a failed start can be retried
			T.eq(t2.start({}), true, "start after a failed start")
		end
		fails({ nope = 1 }, "unknown option nope")
		fails({ MaxBuffer = "big" }, "MaxBuffer must be a number")
		fails({ lockMode = "frozen" }, "invalid value for lockMode")
		fails({ lockHumanoidStates = true }, "lockHumanoidStates")
		fails({ MaxBuffer = 0 / 0 }, "NaN")
		fails({ players = "yes" }, "players must be a boolean")
		fails({ kinds = { Player = { rate = "fast" } } }, "rate must be a number")
	end)
end
