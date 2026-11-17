-- Regression tests for review findings on the animation channel (Config.animations).
return function(T)
	local DT = 1 / 60
	local Mock = T.Mock

	local function path(i, t)
		return i * 12 + 6 * math.sin(t * 1.1 + i), 3, 5 * math.cos(t * 0.8 + i)
	end

	-- Same world as test_anim: animations on, a folder of three animations, n players.
	local function setup(opts)
		opts = opts or {}
		local world = T.world({ latency = opts.latency or 0.04, jitter = 0, seed = opts.seed or 5 })
		local Tide = T.serverTide(world)
		local folder = Mock.newInstance("Folder", "Animations")
		folder.Parent = if opts.folderParent == "server" then world.server.ServerStorage else world.server.ReplicatedStorage
		local anims = {
			Idle = world:animation("rbxassetid://101", "Idle", 2.0, true, folder),
			Run = world:animation("rbxassetid://102", "Run", 0.8, true, folder),
			Kick = world:animation("rbxassetid://103", "Kick", 1.2, false, folder),
		}
		local cfg = { players = true, animations = true, animationFolder = folder }
		for k, v in opts.config or {} do
			cfg[k] = v
		end
		Tide.start(cfg)
		local s = { world = world, Tide = Tide, folder = folder, anims = anims, chars = {}, cts = {}, suspicious = {}, moving = true }
		Tide.onSuspicious(function(player, reason)
			table.insert(s.suspicious, { player = player, reason = reason })
		end)
		s.SState = T.module(world, "Server", "State")
		function s.addPlayer()
			local i = #world.players + 1
			local p = world:addPlayer()
			local x, y, z = path(i, world.now)
			s.chars[i] = world:spawnCharacter(p, CFrame.new(x, y, z))
			s.cts[i] = T.clientTide(world, i)
			s.cts[i].start()
			return i
		end
		for _ = 1, opts.players or 3 do
			s.addPlayer()
		end
		function s.frame(n)
			for _ = 1, n or 1 do
				local t = world.now + DT
				if s.moving then
					for i, char in s.chars do
						local hrp = world:replica(i, char.HumanoidRootPart)
						if hrp then
							local x, y, z = path(i, t)
							hrp.CFrame = CFrame.new(x, y, z)
						end
					end
				end
				world:frame(DT)
			end
		end
		function s.animator(viewer, model)
			local view = world:replica(viewer, model)
			local holder = view:FindFirstChildOfClass("Humanoid") or view:FindFirstChildOfClass("AnimationController")
			return holder:FindFirstChildOfClass("Animator"), holder
		end
		function s.anim(viewer, name)
			return world:replica(viewer, anims[name])
		end
		function s.track(animator, id)
			for _, track in animator:GetPlayingAnimationTracks() do
				if track.Animation.AnimationId == id then
					return track
				end
			end
			return nil
		end
		function s.reasons()
			local out = {}
			for _, e in s.suspicious do
				out[e.reason] = (out[e.reason] or 0) + 1
			end
			return out
		end
		s.frame(30)
		return s
	end

	local function registerBuffer(strs)
		local size = 0
		for _, str in strs do
			size += 2 + #str
		end
		local b = buffer.create(size)
		local pos = 0
		for _, str in strs do
			buffer.writeu8(b, pos, 22)
			buffer.writeu8(b, pos + 1, #str)
			buffer.writestring(b, pos + 2, str)
			pos += 2 + #str
		end
		return b
	end

	T.test("in-flight events after an owner change or removal are not reported as suspicious", function()
		local s = setup({ players = 2 })
		local world = s.world
		local animator = s.animator(1, s.chars[1])
		local run = animator:LoadAnimation(s.anim(1, "Run"))
		run:Play(0.1)
		s.frame(30)
		T.eq(s.reasons().animOwner, nil, "nothing reported yet")
		local stats0 = s.Tide.stats()
		-- the server takes the character over; the owner changes speed before it hears of it
		s.Tide.handle(s.chars[1]):setOwner(nil)
		run:AdjustSpeed(2)
		s.frame(30)
		T.check(s.Tide.stats().animOwner > stats0.animOwner, "in-flight event dropped (counted)")
		T.eq(s.reasons().animOwner, nil, "an honest owner is not reported after an owner change")
		-- removal (e.g. respawn) while a STOP is in flight
		local animator2 = s.animator(2, s.chars[2])
		local kick = animator2:LoadAnimation(s.anim(2, "Kick"))
		kick:Play(0.1)
		s.frame(30)
		local stats1 = s.Tide.stats()
		s.Tide.remove(s.chars[2])
		kick:Stop(0.1)
		s.frame(30)
		T.check(s.Tide.stats().animOwner > stats1.animOwner, "in-flight STOP dropped (counted)")
		T.eq(s.reasons().animOwner, nil, "an honest owner is not reported after its entity is removed")
		-- a client claiming someone else's live entity is still reported
		local slot1 = s.SState.bySlotModel[s.chars[1]]
		local Control = T.clientModule(world, 2, "Shared", "Control")
		local AnimCodec = T.clientModule(world, 2, "Shared", "AnimCodec")
		local w = Control.writer(64)
		Control.u8(w, 20)
		Control.f64(w, world.now)
		Control.u8(w, 1)
		AnimCodec.write(w, slot1, 0, 1, 1, 0.1, 1, 1, 0, 0, true)
		world:replica(2, world.tideModule:FindFirstChild("TideR")):FireServer(Control.take(w))
		s.frame(15)
		T.check((s.reasons().animOwner or 0) >= 1, "foreign entity still reported")
	end)

	T.test("REGISTER of an already known id is rate limited (no reply amplification)", function()
		local s = setup({ players = 2 })
		local world = s.world
		local replies = 0
		world:replica(2, world.tideModule:FindFirstChild("TideR")).OnClientEvent:Connect(function(b)
			if buffer.readu8(b, 0) == 23 then
				replies += 1
			end
		end)
		local strs = {}
		for k = 1, 300 do
			strs[k] = "rbxassetid://101"
		end
		world:replica(2, world.tideModule:FindFirstChild("TideR")):FireServer(registerBuffer(strs))
		s.frame(15)
		T.check(replies <= 64, `one request packet made the server send {replies} replies`)
		T.eq(s.Tide.stats().errors, 0)
	end)

	T.test("one player cannot fill the id registry by registering over a long session", function()
		local s = setup({ players = 2 })
		local world = s.world
		local Registry = T.module(world, "Shared", "AnimRegistry")
		local remote = world:replica(2, world.tideModule:FindFirstChild("TideR"))
		local start = Registry.count
		local k = 0
		for _ = 1, 12 do
			local strs = {}
			for _ = 1, 64 do
				k += 1
				table.insert(strs, "rbxassetid://" .. (500000 + k))
			end
			remote:FireServer(registerBuffer(strs))
			s.frame(5)
			world.now += 61 -- a minute later: the per-minute bucket is full again
			s.frame(1)
		end
		local taken = Registry.count - start
		T.check(taken <= 128, `one player registered {taken} ids (MaxAnimIds is 1024)`)
		-- another player still gets its (legit) unknown id registered
		local anim = Mock.newInstance("Animation")
		anim.AnimationId = "rbxassetid://424242"
		s.animator(1, s.chars[1]):LoadAnimation(anim):Play(0)
		s.frame(30)
		T.check(Registry.id("rbxassetid://424242") ~= nil, "a legit id still gets registered")
	end)

	T.test("snapshot does not start an animation before the body's render time reaches it", function()
		local s = setup({ players = 2 })
		local world = s.world
		s.moving = false
		T.module(world, "Shared", "Config").InterestEvery = 0 -- tiers every frame: entering range is seen at once
		for i, char in s.chars do
			world:replica(i, char.HumanoidRootPart).CFrame = CFrame.new(i * 5, 3, 0)
		end
		local bot = world:spawnModel("bot", CFrame.new(900, 3, 0), true)
		local animator = world:addAnimator(bot)
		s.Tide.add(bot, "Npc")
		s.frame(30)
		local CState = T.clientModule(world, 1, "Client", "State")
		local snaps = CState.counters.animSnaps
		-- the bot comes into range and kicks in the same frame
		bot.HumanoidRootPart.CFrame = CFrame.new(30, 3, 0)
		local tPlay = world.now
		animator:LoadAnimation(s.anims.Kick):Play(0)
		local seen = nil
		for _ = 1, 60 do
			s.frame()
			local view = world:replica(1, bot)
			local rt = world.now - s.cts[1].delay(view)
			local a = s.animator(1, bot)
			local track = s.track(a, "rbxassetid://103")
			if track ~= nil and seen == nil then
				seen = rt
			end
		end
		T.check(CState.counters.animSnaps > snaps, "came with a snapshot")
		T.check(seen ~= nil, "kick plays")
		T.check(seen >= tPlay - 1e-6, `kick started {tPlay - seen} s before the body's render time`)
		T.check(seen < tPlay + 2 * DT, `kick started late: {seen - tPlay}`)
	end)

	T.test("folder only on the server: a late joiner plays what already ran once the id table arrives", function()
		local s = setup({ players = 2, folderParent = "server" })
		local world = s.world
		local anim = Mock.newInstance("Animation")
		anim.AnimationId = "rbxassetid://101" -- Idle (a folder id on the server)
		anim:SetAttribute("Length", 2)
		anim:SetAttribute("Looped", true)
		s.animator(1, s.chars[1]):LoadAnimation(anim):Play(0)
		s.frame(30)
		T.check(s.track(s.animator(2, s.chars[1]), "rbxassetid://101") ~= nil, "receiver 2 plays it")
		local i = s.addPlayer()
		s.frame(60)
		local CRegistry = T.clientModule(world, i, "Shared", "AnimRegistry")
		T.check(CRegistry.id("rbxassetid://101") ~= nil, "late joiner got the id table")
		T.check(s.track(s.animator(i, s.chars[1]), "rbxassetid://101") ~= nil, "late joiner plays the idle that was already running")
	end)

	T.test("client started with animations on, server off: no owner-local swaps after the hello", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true }) -- server: animations off (v0.1 behaviour)
		local p = world:addPlayer()
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		local ct = T.clientTide(world, 1)
		ct.start({ animations = true }) -- misconfigured client
		for _ = 1, 30 do
			world:frame(DT)
		end
		local CState = T.clientModule(world, 1, "Client", "State")
		T.check(CState.helloed, "hello received")
		local swaps = CState.counters.animSwapped
		-- respawn: Roblox must keep replicating this character's animations
		world:spawnCharacter(p, CFrame.new(0, 3, 0))
		for _ = 1, 30 do
			world:frame(DT)
		end
		T.eq(CState.counters.animSwapped, swaps, "no Animator swapped once the server said animations are off")
	end)

	T.test("owner change to a client: the receiver's replayed tracks are not sent back as its own", function()
		local s = setup({ players = 2 })
		local world = s.world
		s.moving = false
		for i, char in s.chars do
			world:replica(i, char.HumanoidRootPart).CFrame = CFrame.new(i * 5, 3, 0)
		end
		local bot = world:spawnModel("bot", CFrame.new(20, 3, 0), true)
		local animator = world:addAnimator(bot)
		animator:LoadAnimation(s.anims.Idle):Play(0)
		local handle = s.Tide.add(bot, "Bot")
		s.frame(30)
		T.check(s.track(s.animator(1, bot), "rbxassetid://101") ~= nil, "client 1 replays the bot's idle")
		local log = {}
		s.Tide.animated(function(model, op, name)
			table.insert(log, op .. " " .. name)
		end)
		local sent0 = T.clientModule(world, 1, "Client", "State").counters.animSent
		handle:setOwner(world.players[1])
		s.frame(30)
		local sent = T.clientModule(world, 1, "Client", "State").counters.animSent - sent0
		T.eq(sent, 0, "new owner sent events for tracks it only replayed: " .. table.concat(log, ", "))
		T.eq(#log, 0, "server accepted: " .. table.concat(log, ", "))
	end)

	T.test("an engine error while applying one entity's event does not stall the channel", function()
		local s = setup({ players = 2 })
		local world = s.world
		s.moving = false
		for i, char in s.chars do
			world:replica(i, char.HumanoidRootPart).CFrame = CFrame.new(i * 5, 3, 0)
		end
		local botA = world:spawnModel("botA", CFrame.new(20, 3, 0), true)
		local animA = world:addAnimator(botA)
		s.Tide.add(botA, "Bot")
		local botB = world:spawnModel("botB", CFrame.new(25, 3, 0), true)
		local animB = world:addAnimator(botB)
		s.Tide.add(botB, "Bot")
		s.frame(30)
		-- client 1's Animator for bot A is not in the DataModel any more (e.g. the model
		-- streamed out before Tide heard of it): Roblox's LoadAnimation throws
		local local1 = s.animator(1, botA)
		T.check(Mock.isClientCreated(local1))
		rawset(local1, "LoadAnimation", function()
			error("LoadAnimation requires the Animator object to be a descendant of the game object")
		end)
		animA:LoadAnimation(s.anims.Kick):Play(0)
		animB:LoadAnimation(s.anims.Run):Play(0)
		local ok, err = pcall(s.frame, 60)
		T.check(ok, "error escaped the render step: " .. tostring(err))
		T.check(s.track(s.animator(1, botB), "rbxassetid://102") ~= nil, "bot B still animated on client 1")
		T.check(s.track(s.animator(2, botA), "rbxassetid://103") ~= nil, "client 2 unaffected")
		local CState = T.clientModule(world, 1, "Client", "State")
		T.check(CState.counters.applyErrors >= 1 and CState.counters.applyErrors <= 3, "counted once, not every frame: " .. CState.counters.applyErrors)
	end)
end
