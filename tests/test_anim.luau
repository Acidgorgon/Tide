-- Animation channel (Config.animations): owners' Animators are watched, events replay on
-- receivers at the entity's render time, snapshots, registry, bots, validation, allocations.
return function(T)
	local DT = 1 / 60
	local Mock = T.Mock

	local function path(i, t)
		return i * 12 + 6 * math.sin(t * 1.1 + i), 3, 5 * math.cos(t * 0.8 + i)
	end

	-- A server with animations on, a folder of three animations, n players (moving),
	-- each client started. opts: players, latency, jitter, config (extra Tide.start fields),
	-- folderParent ("server" puts the folder in ServerStorage).
	local function setup(opts)
		opts = opts or {}
		local world = T.world({ latency = opts.latency or 0.04, jitter = opts.jitter or 0, seed = opts.seed or 5 })
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
		local s = {
			world = world,
			Tide = Tide,
			folder = folder,
			anims = anims,
			chars = {},
			cts = {},
			suspicious = {},
			moving = true,
		}
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
				if s.beforeFrame then
					s.beforeFrame(t)
				end
				world:frame(DT)
			end
		end
		-- the Animator client `viewer` uses for server model `model`
		function s.animator(viewer, model)
			local view = world:replica(viewer, model)
			local holder = view:FindFirstChildOfClass("Humanoid") or view:FindFirstChildOfClass("AnimationController")
			return holder:FindFirstChildOfClass("Animator"), holder
		end
		-- client `viewer`'s replica of a folder animation
		function s.anim(viewer, name)
			return world:replica(viewer, anims[name])
		end
		-- the playing track of an AnimationId on an animator (nil if none)
		function s.track(animator, id)
			for _, track in animator:GetPlayingAnimationTracks() do
				if track.Animation.AnimationId == id then
					return track
				end
			end
			return nil
		end
		-- events seen by client `viewer` through Tide.animated (with the render time at apply)
		function s.record(viewer)
			local log = {}
			local CClient = T.clientModule(world, viewer, "Client", "Client")
			s.cts[viewer].animated(function(model, op, name, info)
				local delay = CClient.delay(model)
				table.insert(log, { model = model, op = op, name = name, info = info, now = world.now, rt = world.now - delay })
			end)
			return log
		end
		function s.serverLog()
			local log = {}
			Tide.animated(function(model, op, name, info)
				table.insert(log, { model = model, op = op, name = name, info = info, now = world.now })
			end)
			return log
		end
		function s.slot(model)
			return s.SState.bySlotModel[model]
		end
		s.frame(30)
		return s
	end

	-- the receiving clients' tracks of a remote entity for one AnimationId
	local function remoteTracks(s, ownerIndex, id)
		local out = {}
		for i in s.cts do
			if i ~= ownerIndex then
				out[i] = s.track(s.animator(i, s.chars[ownerIndex]), id)
			end
		end
		return out
	end

	T.test("owner play reaches receivers at the body's render time (never before), owner-local Animator", function()
		local s = setup()
		local world = s.world
		-- owner-local swap: client 1 plays on a client-created Animator; receivers too
		local ownerAnimator, humanoid = s.animator(1, s.chars[1])
		T.check(Mock.isClientCreated(ownerAnimator), "owner's Animator is client-created")
		local count = 0
		for _, c in humanoid:GetChildren() do
			if c.ClassName == "Animator" then
				count += 1
			end
		end
		T.eq(count, 1, "one Animator under the owner's Humanoid")
		for i = 2, 3 do
			local a = s.animator(i, s.chars[1])
			T.check(Mock.isClientCreated(a), `receiver {i} plays on its own Animator`)
		end
		local logs = { [2] = s.record(2), [3] = s.record(3) }

		-- game code on the owner: load and play, as it does today
		local track = ownerAnimator:LoadAnimation(s.anim(1, "Kick"))
		local tPlay = world.now
		track:Play(0.2, 1, 1)
		local seen = {}
		for _ = 1, 40 do
			s.frame()
			for i = 2, 3 do
				if seen[i] == nil then
					local rt = world:replica(i, s.chars[1]) and (world.now - s.cts[i].delay(world:replica(i, s.chars[1])))
					local rtrack = s.track(s.animator(i, s.chars[1]), "rbxassetid://103")
					if rtrack ~= nil then
						seen[i] = { now = world.now, rt = rt, track = rtrack }
					else
						T.check(rt < tPlay + 1e-9 or rt < tPlay + DT, `receiver {i} would have been late`)
					end
				end
			end
		end
		for i = 2, 3 do
			local e = seen[i]
			T.check(e ~= nil, `receiver {i} plays the kick`)
			T.check(e.rt >= tPlay - 1e-6, `not before the body: rt {e.rt - tPlay}`)
			T.check(e.rt < tPlay + DT + 1e-6, `applied on the first frame the body passes it: {e.rt - tPlay}`)
			local log = logs[i]
			T.eq(log[1].op, "play")
			T.eq(log[1].name, "Kick")
			T.near(log[1].info.time, tPlay, 0.001, "event time = play time")
			T.near(log[1].info.fade, 0.2, 0.03, "fade estimate")
			T.check(log[1].rt >= log[1].info.time - 1e-6, "applied at render time")
			-- the body is drawn at that same render time
			local view = world:replica(i, s.chars[1])
			local cf = s.cts[i].drawn(view)
			local x, _, z = path(1, world.now - s.cts[i].delay(view))
			T.check(math.abs(cf.X - x) < 0.3 and math.abs(cf.Z - z) < 0.3, "body on the same timeline")
		end
		-- in step with the owner: receiver's time position = owner's at the receiver's render time
		local view = world:replica(2, s.chars[1])
		local rt = world.now - s.cts[2].delay(view)
		local rtrack = s.track(s.animator(2, s.chars[1]), "rbxassetid://103") or seen[2].track
		T.near(rtrack.TimePosition, math.min(1.2, rt - tPlay + DT), 0.03, "time position follows the render time")
		T.eq(s.Tide.stats().animEvents, 1, "one PLAY")
		T.eq(s.Tide.stats().animOwner + s.Tide.stats().animRate + s.Tide.stats().animBad, 0)
	end)

	T.test("stop / speed / weight / seek / priority propagate, each at render time", function()
		local s = setup()
		local world = s.world
		local log = s.record(2)
		local animator = s.animator(1, s.chars[1])
		local track = animator:LoadAnimation(s.anim(1, "Run"))
		track:Play(0.1, 1, 1)
		s.frame(20)
		local times = {}
		times.speed = world.now
		track:AdjustSpeed(1.5)
		s.frame(10)
		times.weight = world.now
		track:AdjustWeight(0.5, 0.1)
		s.frame(10)
		times.seek = world.now
		local target = (track.TimePosition + 0.4) % 0.8 -- half a loop away: clearly a jump
		track.TimePosition = target
		s.frame(10)
		times.priority = world.now
		track.Priority = Enum.AnimationPriority.Action
		s.frame(10)
		times.stop = world.now
		track:Stop(0.15)
		s.frame(30)
		local byOp = {}
		for _, e in log do
			byOp[e.op] = e
			T.check(e.rt >= e.info.time - 1e-6, `{e.op} applied before the body reached it`)
			T.check(e.rt < e.info.time + 2 * DT, `{e.op} applied late: {e.rt - e.info.time}`)
		end
		for _, op in { "play", "speed", "weight", "seek", "priority", "stop" } do
			T.check(byOp[op] ~= nil, "receiver got " .. op)
		end
		T.near(byOp.speed.info.speed, 1.5, 1 / 256)
		T.near(byOp.weight.info.weight, 0.5, 0.01)
		T.near(byOp.weight.info.fade, 0.1, 0.03, "weight fade estimate")
		T.near(byOp.seek.info.timePosition, (target + DT * 1.5) % 0.8, 0.01, "seek position")
		T.near(byOp.stop.info.fade, 0.15, 0.03, "stop fade estimate")
		-- stamps: within a watch step of the real change (the seek/speed/weight are seen at the next step)
		for op, t in times do
			T.check(byOp[op].info.time >= t - 0.0005 and byOp[op].info.time <= t + 2 * DT, `{op} stamp`)
		end
		local view = world:replica(2, s.chars[1])
		local info = s.cts[2].playing(view)
		T.eq(info.Run, nil, "Run no longer playing on the receiver")
		T.eq(#s.animator(2, s.chars[1]):GetPlayingAnimationTracks(), 0, "receiver track stopped")
		T.eq(s.Tide.playing(s.chars[1]).Run, nil, "server: stopped")
	end)

	T.test("fade estimate within 0.03 s (play and stop, several fades and speeds)", function()
		local s = setup({ players = 2 })
		local world = s.world
		local log = s.serverLog()
		local animator = s.animator(1, s.chars[1])
		local cases = { { 0, 1 }, { 0.05, 1 }, { 0.1, 1 }, { 0.25, 0.7 }, { 0.5, 1.3 }, { 0.8, 1 } }
		for _, c in cases do
			local fade, speed = c[1], c[2]
			local track = animator:LoadAnimation(s.anim(1, "Idle"))
			local before = #log
			track:Play(fade, 0.8, speed)
			s.frame(math.floor(fade / DT) + 12)
			track:Stop(fade)
			s.frame(math.floor(fade / DT) + 12)
			local play, stop = nil, nil
			for k = before + 1, #log do
				if log[k].op == "play" then
					play = log[k]
				elseif log[k].op == "stop" then
					stop = log[k]
				end
			end
			T.check(play ~= nil and stop ~= nil, "play and stop seen")
			T.near(play.info.fade, fade, 0.03, `play fade {fade}`)
			T.near(play.info.weight, 0.8, 0.01)
			T.near(play.info.speed, speed, 1 / 256)
			T.near(stop.info.fade, fade, 0.03, `stop fade {fade}`)
		end
		local _ = world
	end)

	T.test("Animate-style blending (AdjustSpeed / AdjustWeight every frame) is coalesced", function()
		local s = setup({ players = 2 })
		local log = s.serverLog()
		local animator = s.animator(1, s.chars[1])
		local run = animator:LoadAnimation(s.anim(1, "Run"))
		run:Play(0.1, 1, 1)
		s.frame(10)
		local start = #log
		for f = 1, 120 do
			run:AdjustSpeed(1 + f * 0.004)
			run:AdjustWeight(1 - f * 0.004, 0.1)
			s.frame()
		end
		s.frame(20)
		local speeds, weights = 0, 0
		for k = start + 1, #log do
			if log[k].op == "speed" then
				speeds += 1
			elseif log[k].op == "weight" then
				weights += 1
			end
		end
		-- 120 changes each; at most one update per 0.2 s (or per 0.05 speed / 0.1 weight jump)
		T.check(speeds >= 6 and speeds <= 13, "speed updates over 2 s: " .. speeds)
		T.check(weights >= 6 and weights <= 13, "weight updates over 2 s: " .. weights)
		local server = s.Tide.playing(s.chars[1]).Run
		T.near(server.speed, 1.48, 1 / 256, "final speed arrives")
		T.near(server.weight, 0.52, 0.01, "final weight arrives")
		local remote = s.track(s.animator(2, s.chars[1]), "rbxassetid://102")
		T.near(remote.Speed, 1.48, 1 / 256)
		T.near(remote.WeightTarget, 0.52, 0.01)
		T.eq(s.Tide.stats().animRate, 0, "under the rate cap")
	end)

	T.test("Tide.play / Tide.stop: exact fades, sent once; Tide.playing on both sides", function()
		local s = setup({ players = 2 })
		local world = s.world
		local log = s.serverLog()
		local view1 = world:replica(1, s.chars[1])
		local track = s.cts[1].play(view1, "Kick", 0.37, 0.9, 1.25)
		T.check(track ~= nil, "track returned")
		T.eq(s.cts[2].play(world:replica(2, s.chars[1]), "Kick"), nil, "not the owner: nil")
		s.frame(30)
		T.eq(#log, 1, "one event")
		T.eq(log[1].op, "play")
		T.near(log[1].info.fade, 0.37, 0.005, "exact fade")
		T.near(log[1].info.speed, 1.25, 1 / 256)
		local own = s.cts[1].playing(view1)
		T.check(own.Kick ~= nil and own.Kick.track == track, "owner: playing from its Animator")
		local remote = s.cts[2].playing(world:replica(2, s.chars[1]))
		T.check(remote.Kick ~= nil, "receiver: playing")
		T.near(remote.Kick.speed, 1.25, 1 / 256)
		local server = s.Tide.playing(s.chars[1])
		T.check(server.Kick ~= nil, "server: playing")
		T.near(server.Kick.timePosition, (world.now - server.Kick.since) * 1.25, 0.02)
		s.cts[1].stop(view1, "Kick", 0.5)
		s.frame(12)
		T.eq(#log, 2)
		T.eq(log[2].op, "stop")
		T.near(log[2].info.fade, 0.5, 0.005, "exact stop fade")
		T.check(s.Tide.playing(s.chars[1]).Kick.stopping, "server: fading out")
		s.frame(40)
		-- Tide.playing(model, t) on the server: what played at a past time
		local tMid = log[1].info.time + 0.05
		T.check(s.Tide.playing(s.chars[1], tMid).Kick ~= nil, "server: at a past time it played")
		T.eq(s.Tide.playing(s.chars[1]).Kick, nil, "server: stopped now")
		T.check(not pcall(s.cts[1].play, view1, "Nope"), "unknown name is an error")
	end)

	T.test("snapshot: a late joiner sees what already plays, at the right time position", function()
		local s = setup({ players = 2 })
		local world = s.world
		local animator = s.animator(1, s.chars[1])
		local track = animator:LoadAnimation(s.anim(1, "Run"))
		local tPlay = world.now
		track:Play(0, 1, 1)
		s.frame(60)
		local i = s.addPlayer()
		s.frame(60) -- the late joiner's delay settles meanwhile; tracks follow it
		local rtrack = s.track(s.animator(i, s.chars[1]), "rbxassetid://102")
		T.check(rtrack ~= nil, "late joiner plays Run")
		local view = world:replica(i, s.chars[1])
		local rt = world.now - s.cts[i].delay(view)
		T.near(rtrack.TimePosition, (rt - tPlay + DT) % 0.8, 0.03, "caught-up time position")
		T.near(rtrack.WeightTarget, 1, 0.01)
		local CState = T.clientModule(world, i, "Client", "State")
		T.check(CState.counters.animSnaps >= 1, "came from a snapshot")
		-- and the late joiner's own character is watched: others see its anims
		local own = s.animator(i, s.chars[i])
		T.check(Mock.isClientCreated(own))
		own:LoadAnimation(s.anim(i, "Kick")):Play(0.1)
		s.frame(20)
		T.check(s.track(s.animator(1, s.chars[i]), "rbxassetid://103") ~= nil, "others see the late joiner's anim")
	end)

	T.test("bots: the server watches server-owned Animators; snapshot when entering cull range", function()
		local s = setup({ players = 2 })
		local world = s.world
		s.moving = false
		-- receivers stand still near the origin
		for i, char in s.chars do
			world:replica(i, char.HumanoidRootPart).CFrame = CFrame.new(i * 5, 3, 0)
		end
		local bot = world:spawnModel("bot", CFrame.new(20, 3, 0), true)
		local animator = world:addAnimator(bot)
		local idle = animator:LoadAnimation(s.anims.Idle)
		idle:Play(0) -- already playing when Tide sees the bot: sent with fade 0
		s.Tide.add(bot, "Npc")
		s.frame(20)
		for i = 1, 2 do
			local a = s.animator(i, bot)
			T.check(Mock.isClientCreated(a), "client plays bots on its own Animator")
			T.check(s.track(a, "rbxassetid://101") ~= nil, `client {i} plays the bot's idle`)
		end
		T.check(s.Tide.playing(bot).Idle ~= nil, "server knows")
		-- an AnimationId that is not in the folder: the server assigns an id itself
		local extra = world:animation("rbxassetid://555", "Wave", 1, true)
		animator:LoadAnimation(extra):Play(0.1)
		s.frame(20)
		for i = 1, 2 do
			T.check(s.track(s.animator(i, bot), "rbxassetid://555") ~= nil, `client {i} plays the runtime-registered anim`)
		end
		-- far beyond cull (Npc cull 400): no events; meanwhile the bot stops idle and kicks
		bot.HumanoidRootPart.CFrame = CFrame.new(900, 3, 0)
		s.frame(20)
		local CState = T.clientModule(world, 1, "Client", "State")
		local applied = CState.counters.animApplied
		idle:Stop(0.1)
		local kick = animator:LoadAnimation(s.anims.Kick)
		kick:Play(0.1)
		s.frame(20)
		T.eq(CState.counters.animApplied, applied, "culled: nothing relayed")
		T.check(s.track(s.animator(1, bot), "rbxassetid://101") ~= nil, "stale idle still on the client")
		-- back in range: the snapshot stops idle and starts the kick where it is
		local snaps = CState.counters.animSnaps
		bot.HumanoidRootPart.CFrame = CFrame.new(30, 3, 0)
		s.frame(20)
		T.check(CState.counters.animSnaps > snaps, "snapshot on entering range")
		local a = s.animator(1, bot)
		local kt = s.track(a, "rbxassetid://103")
		T.check(kt ~= nil, "kick playing after the snapshot")
		T.near(kt.TimePosition, kick.TimePosition - s.cts[1].delay(world:replica(1, bot)), 0.06, "kick time position")
		local it = s.track(a, "rbxassetid://101")
		T.check(it == nil, "stale idle stopped")
	end)

	T.test("receivers ignore the replicated Animator; removal stops tracks; kind opt-out", function()
		local s = setup({ players = 2 })
		local world = s.world
		s.Tide.kind("Prop", { animations = false })
		local bot = world:spawnModel("bot", CFrame.new(20, 3, 0), true)
		local animator = world:addAnimator(bot)
		local handle = s.Tide.add(bot, "Bot")
		local prop = world:spawnModel("prop", CFrame.new(25, 3, 0), true)
		local propAnimator = world:addAnimator(prop)
		s.Tide.add(prop, "Prop")
		s.frame(10)
		-- the replicated (server-created) Animator is gone on the client; Tide's local one replaced it
		local view = world:replica(1, bot)
		local holder = view:FindFirstChildOfClass("Humanoid")
		local animators = 0
		for _, c in holder:GetChildren() do
			if c.ClassName == "Animator" then
				animators += 1
				T.check(Mock.isClientCreated(c), "only the client-created Animator is left")
			end
		end
		T.eq(animators, 1)
		-- a replicated Animator turning up later goes too
		local late = Mock.newInstance("Animator")
		Mock.makeAnimator(late, world.clients[1], true)
		late.Parent = holder
		world.task._runDeferred()
		T.eq(late.Parent, nil, "late replicated Animator destroyed")
		-- opted-out kind: Roblox's Animator stays, nothing relayed
		local pa = s.animator(1, prop)
		T.check(not Mock.isClientCreated(pa), "opted-out kind keeps Roblox's Animator")
		propAnimator:LoadAnimation(s.anims.Idle):Play(0)
		animator:LoadAnimation(s.anims.Run):Play(0)
		s.frame(20)
		T.eq(s.Tide.playing(prop), nil, "opted-out kind: not animated by Tide")
		local a = s.animator(1, bot)
		local rt = s.track(a, "rbxassetid://102")
		T.check(rt ~= nil, "bot run playing")
		-- removal: tracks stopped and destroyed
		handle:remove()
		s.frame(20)
		T.eq(#a:GetPlayingAnimationTracks(), 0, "tracks stopped on removal")
		T.check(rawget(rt, "_destroyed") == true, "track destroyed")
	end)

	T.test("streaming: events while the model is missing are kept and applied when it arrives", function()
		local s = setup({ players = 1 })
		local world = s.world
		local bot = world:spawnModel("far", CFrame.new(50, 3, 0), true)
		local animator = world:addAnimator(bot)
		world:streamOut(1, bot)
		s.Tide.add(bot, "Bot")
		s.frame(10)
		local tPlay = world.now
		animator:LoadAnimation(s.anims.Run):Play(0)
		s.frame(30)
		local CState = T.clientModule(world, 1, "Client", "State")
		T.check(CState.counters.animApplied >= 1, "event applied to the state without a model")
		world:streamOut(1, bot, false)
		s.SState.rx[world.players[1]].resendT = nil -- RESEND is rate limited on os.clock, not mock time
		for _ = 1, 90 do
			bot.HumanoidRootPart.CFrame = CFrame.new(50, 3, world.now % 5)
			s.frame()
		end
		local a = s.animator(1, bot)
		local rt = s.track(a, "rbxassetid://102")
		T.check(rt ~= nil, "plays once the model is in")
		local view = world:replica(1, bot)
		local renderT = world.now - s.cts[1].delay(view)
		T.near(rt.TimePosition, (renderT - tPlay + DT) % 0.8, 0.06, "at the right time position (drift kept under 0.05)")
	end)

	T.test("registry: unknown AnimationId registered once (events held until the id arrives); caps", function()
		local s = setup({ players = 2 })
		local world = s.world
		local Registry = T.module(world, "Shared", "AnimRegistry")
		T.eq(Registry.seeded, 3, "three folder ids")
		local CRegistry = T.clientModule(world, 2, "Shared", "AnimRegistry")
		T.eq(CRegistry.count, 3, "client seeded the same folder")
		-- owner plays an animation the server has never heard of
		local anim = Mock.newInstance("Animation")
		anim.AnimationId = "rbxassetid://777"
		local animator = s.animator(1, s.chars[1])
		local tPlay = world.now
		animator:LoadAnimation(anim):Play(0.1)
		local log = s.record(2)
		s.frame(40)
		T.eq(Registry.count, 4, "id assigned")
		T.eq(CRegistry.id("rbxassetid://777"), 4, "receiver learned it")
		T.eq(#log, 1, "one play")
		T.check(log[1].info.time >= tPlay - 0.0005, "stamp not before the play")
		T.check(s.track(s.animator(2, s.chars[1]), "rbxassetid://777") ~= nil, "receiver plays it")
		T.eq(world.stats.c2sCalls > 0, true)

		-- raw REGISTER requests from client 2
		local remote = world:replica(2, world.tideModule:FindFirstChild("TideR"))
		local function register(str)
			local b = buffer.create(2 + #str)
			buffer.writeu8(b, 0, 22)
			buffer.writeu8(b, 1, #str)
			buffer.writestring(b, 2, str)
			remote:FireServer(b)
		end
		local stats0 = s.Tide.stats()
		register("not an asset")
		register(string.rep("9", 120))
		s.frame(15)
		T.eq(s.Tide.stats().animRegister - stats0.animRegister, 2, "invalid strings refused")
		-- 64 new ids per player per minute
		for k = 1, 70 do
			register("rbxassetid://" .. (10000 + k))
		end
		s.frame(15)
		T.eq(Registry.count, 4 + 64, "64 per player per minute")
		T.eq(s.Tide.stats().animRegister - stats0.animRegister, 2 + 6, "over the per-minute cap refused")
		local reasons = {}
		for _, e in s.suspicious do
			reasons[e.reason] = true
		end
		T.check(reasons.animRegister, "onSuspicious(animRegister)")
		-- Config.MaxAnimIds in total
		local Config = T.module(world, "Shared", "Config")
		Config.MaxAnimIds = Registry.count
		register("rbxassetid://424242")
		local remote1 = world:replica(1, world.tideModule:FindFirstChild("TideR"))
		local b = buffer.create(2 + 18)
		buffer.writeu8(b, 0, 22)
		buffer.writeu8(b, 1, 18)
		buffer.writestring(b, 2, "rbxassetid://31337")
		remote1:FireServer(b)
		s.frame(15)
		T.check(s.Tide.stats().animIdsFull >= 1, "MaxAnimIds reached")
		T.eq(Registry.id("rbxassetid://31337"), nil)
	end)

	T.test("folder only on the server: the client asks for the whole id table", function()
		local s = setup({ players = 2, folderParent = "server" })
		local world = s.world
		local CRegistry = T.clientModule(world, 2, "Shared", "AnimRegistry")
		local Registry = T.module(world, "Shared", "AnimRegistry")
		T.eq(CRegistry.count, 3, "every id")
		T.eq(CRegistry.id("rbxassetid://102"), Registry.id("rbxassetid://102"), "ids from the server's table")
		local found = false
		for _, w in world.warnings do
			if string.find(w, "animation folder differs", 1, true) then
				found = true
			end
		end
		T.check(found, "warned")
		-- the owner plays with an Animation of its own (the folder is not visible to clients)
		local anim = Mock.newInstance("Animation")
		anim.AnimationId = "rbxassetid://102"
		s.animator(1, s.chars[1]):LoadAnimation(anim):Play(0)
		s.frame(30)
		T.check(s.track(s.animator(2, s.chars[1]), "rbxassetid://102") ~= nil, "receiver plays it")
	end)

	T.test("validation: ownership, rate cap, stamps, unknown ids, garbage -> counted and reported", function()
		local s = setup({ players = 2 })
		local world = s.world
		local slot1 = s.slot(s.chars[1])
		local slot2 = s.slot(s.chars[2])
		local remote2 = world:replica(2, world.tideModule:FindFirstChild("TideR"))
		local Control = T.clientModule(world, 2, "Shared", "Control")
		local AnimCodec = T.clientModule(world, 2, "Shared", "AnimCodec")
		local function message(events, base)
			local w = Control.writer(64)
			Control.u8(w, 20)
			Control.f64(w, base or world.now)
			Control.u8(w, #events)
			for _, e in events do
				AnimCodec.write(w, e.slot, e.dt or 0, e.op or 1, e.id or 1, 0.1, 1, 1, 0, e.prio or 0, true)
			end
			return Control.take(w)
		end
		local log = s.record(1)
		local stats0 = s.Tide.stats()
		-- client 2 claims client 1's character
		remote2:FireServer(message({ { slot = slot1 } }))
		s.frame(15)
		local st = s.Tide.stats()
		T.eq(st.animOwner - stats0.animOwner, 1, "ownership")
		T.eq(st.animEvents, stats0.animEvents, "not accepted")
		-- unknown id, bad priority
		remote2:FireServer(message({ { slot = slot2, id = 999 }, { slot = slot2, prio = 9 } }))
		s.frame(15)
		T.eq(s.Tide.stats().animUnknown - stats0.animUnknown, 2, "unknown id / priority")
		-- stamps never go backwards per entity
		remote2:FireServer(message({ { slot = slot2, dt = 0 } }, world.now))
		remote2:FireServer(message({ { slot = slot2, dt = 0 } }, world.now - 0.2))
		s.frame(15)
		T.eq(s.Tide.stats().animStamp - stats0.animStamp, 1, "older stamp dropped")
		-- rate: 100 events at once, burst 30
		s.frame(120) -- refill
		local before = s.Tide.stats()
		local events = {}
		for k = 1, 100 do
			events[k] = { slot = slot2, id = 1 + k % 3, dt = k }
		end
		remote2:FireServer(message(events))
		s.frame(15)
		local after = s.Tide.stats()
		T.eq(after.animEvents - before.animEvents, 30, "burst")
		T.eq(after.animRate - before.animRate, 70, "over the rate dropped")
		local reasons = {}
		for _, e in s.suspicious do
			reasons[e.reason] = true
		end
		T.check(reasons.animOwner and reasons.animRate, "onSuspicious(animOwner, animRate)")
		-- garbage never throws
		math.randomseed(11)
		local errors0 = s.Tide.stats().errors
		for _ = 1, 300 do
			local n = math.random(1, 60)
			local b = buffer.create(n)
			for k = 0, n - 1 do
				buffer.writeu8(b, k, math.random(0, 255))
			end
			buffer.writeu8(b, 0, if math.random() < 0.5 then 20 else 22)
			remote2:FireServer(b)
		end
		s.frame(15)
		T.eq(s.Tide.stats().errors, errors0, "no errors")
		T.check(s.Tide.stats().animBad > 0, "counted")
		-- the receiver got only the accepted events, at render time
		for _, e in log do
			T.check(e.rt >= e.info.time - 1e-6, "render time")
		end
		-- client side: malformed relayed messages never throw either
		local CState = T.clientModule(world, 1, "Client", "State")
		local rep = world:replica(1, world.tideModule:FindFirstChild("TideR"))
		for _ = 1, 200 do
			local n = math.random(1, 40)
			local b = buffer.create(n)
			for k = 0, n - 1 do
				buffer.writeu8(b, k, math.random(0, 255))
			end
			buffer.writeu8(b, 0, 21 + math.random(0, 3))
			rep.OnClientEvent:_fire(b, {})
		end
		T.check(CState.counters.animBad > 0, "client counted bad animation messages")
	end)

	T.test("animations off (default): no animation bytes, Roblox's Animators untouched", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local p = world:addPlayer()
		local char = world:spawnCharacter(p, CFrame.new(0, 3, 0))
		local p2 = world:addPlayer()
		world:spawnCharacter(p2, CFrame.new(5, 3, 0))
		local sizes = {}
		for i = 1, 2 do
			world:replica(i, world.tideModule:FindFirstChild("TideR")).OnClientEvent:Connect(function(b)
				local tag = buffer.readu8(b, 0)
				table.insert(sizes, { tag = tag, n = buffer.len(b), lock = if tag == 14 then buffer.readu8(b, 26) else nil })
			end)
		end
		local ct1 = T.clientTide(world, 1)
		ct1.start()
		T.clientTide(world, 2).start()
		for _ = 1, 30 do
			world:frame(DT)
		end
		-- hello: v0.1 layout (version 3), 3 built-in kinds
		local hello = sizes[1]
		T.eq(hello.tag, 14)
		local kindBytes = 0
		for _, name in { "Player", "Bot", "Npc" } do
			kindBytes += 2 + #name + 4 + 1 + 4 * 6
		end
		T.eq(hello.lock, 1, "flags byte = lock only")
		local adds = 2 * 14
		T.eq(hello.n, 1 + 1 + 24 + 1 + 1 + 1 + kindBytes + adds, "hello + adds, no animation fields")
		for _, e in sizes do
			T.check(e.tag ~= 21 and e.tag ~= 23 and e.tag ~= 24, "no animation messages")
		end
		local animator = world:replica(1, char):FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator")
		T.check(not Mock.isClientCreated(animator), "owner keeps Roblox's Animator")
		local other = world:replica(2, char):FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator")
		T.check(not Mock.isClientCreated(other), "receivers keep Roblox's Animator")
		T.eq(Tide.playing(char), nil)
		T.eq(ct1.playing(world:replica(1, char)), nil)
		-- an animation message from a client is a bad packet
		local b = buffer.create(10)
		buffer.writeu8(b, 0, 20)
		local bad = Tide.stats().badPacket
		world:replica(1, world.tideModule:FindFirstChild("TideR")):FireServer(b)
		for _ = 1, 4 do
			world:frame(DT)
		end
		T.eq(Tide.stats().badPacket, bad + 1)
	end)

	T.test("owner-local swap is skipped when game code already plays on the Animator", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		local folder = Mock.newInstance("Folder", "Animations")
		folder.Parent = world.server.ReplicatedStorage
		local idle = world:animation("rbxassetid://101", "Idle", 2, true, folder)
		Tide.start({ players = true, animations = true, animationFolder = folder })
		local p = world:addPlayer()
		local char = world:spawnCharacter(p, CFrame.new(0, 3, 0))
		world:addPlayer()
		-- the Animate script got there first (before Tide's ADD reached the client)
		local view = world:replica(1, char)
		local replicated = view:FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator")
		replicated:LoadAnimation(world:replica(1, idle)):Play(0)
		T.clientTide(world, 1).start()
		T.clientTide(world, 2).start()
		for _ = 1, 30 do
			world:frame(DT)
		end
		local animator = view:FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator")
		T.eq(animator, replicated, "kept the Animator game code uses")
		local CState = T.clientModule(world, 1, "Client", "State")
		T.eq(CState.counters.animSwapSkipped, 1)
		-- still watched: the receiver plays idle through Tide
		local other = world:replica(2, char):FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator")
		T.check(Mock.isClientCreated(other))
		local playing = other:GetPlayingAnimationTracks()
		T.eq(#playing, 1, "receiver plays the idle")
	end)

	T.test("zero allocations: watch step (owner and server) and apply step with no events", function()
		local s = setup({ players = 4 })
		local world = s.world
		local function allocs(fn)
			local before = __alloc_count()
			fn()
			return __alloc_count() - before
		end
		-- see test_alloc: a GC mid-window can regrow a coroutine stack once; real garbage shows every time
		local function steady(measure: () -> number): number
			local best = math.huge
			for _ = 1, 4 do
				best = math.min(best, measure())
				if best == 0 then
					break
				end
			end
			return best
		end
		-- every player runs two looped anims; five bots idle (server-watched)
		for i, char in s.chars do
			local a = s.animator(i, char)
			a:LoadAnimation(s.anim(i, "Run")):Play(0.1)
			a:LoadAnimation(s.anim(i, "Idle")):Play(0.1, 0.5)
		end
		for k = 1, 5 do
			local bot = world:spawnModel("bot" .. k, CFrame.new(k * 4, 3, 20), true)
			world:addAnimator(bot):LoadAnimation(s.anims.Idle):Play(0)
			s.Tide.add(bot, "Bot")
		end
		s.frame(90)
		T.check(#s.animator(2, s.chars[1]):GetPlayingAnimationTracks() == 2, "receiver plays the owner's two anims")

		local client = world.clients[1]
		local AnimOwner = T.clientModule(world, 1, "Client", "AnimOwner")
		local AnimPlay = T.clientModule(world, 1, "Client", "AnimPlay")
		local CState = T.clientModule(world, 1, "Client", "State")
		local t = world.now
		local function clientStep()
			t += DT
			Mock.stepAnimators(client, DT)
			AnimOwner.step(t, DT)
			AnimPlay.step(t, DT)
		end
		for _ = 1, 60 do
			clientStep() -- warm up (a first step on the new clock may see a seek)
		end
		local sent, applied = CState.counters.animSent, CState.counters.animApplied
		local n = steady(function()
			return allocs(function()
				for _ = 1, 240 do
					clientStep()
				end
			end)
		end)
		T.eq(CState.counters.animSent, sent, "no events while measuring")
		T.eq(CState.counters.animApplied, applied)
		T.eq(n, 0, "client: owner watch + receiver apply, 240 frames")

		local Anim = T.module(world, "Server", "Anim")
		local SState = s.SState
		local st = world.now
		local function serverStep()
			st += DT
			Mock.stepAnimators(world.server, DT)
			Anim.step(st, DT)
			Anim.flush(st)
		end
		for _ = 1, 60 do
			serverStep()
		end
		local events = SState.counters.animEvents
		local m = steady(function()
			return allocs(function()
				for _ = 1, 240 do
					serverStep()
				end
			end)
		end)
		T.eq(SState.counters.animEvents, events, "no events while measuring")
		T.eq(m, 0, "server: bot watch + flush, 240 frames")
	end)
end
