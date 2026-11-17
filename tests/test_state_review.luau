-- Timeline state (v0.3) review regressions: owner changes (no duplicate or lost changes, the owner
-- is never culled from its own entity's state), snapshots with a backdated change in the same frame,
-- history queries after the ring wrapped (events, changedAt).
return function(T)
	local DT = 1 / 60
	local Mock = T.Mock
	local TICK = 0.0005

	local function q(t)
		return math.round(t / TICK) * TICK
	end

	-- a stamp as the server makes it: on the grid, never after t
	local function stampOf(t)
		local k = math.round(t / TICK)
		local s = k * TICK
		if s > t then
			if s - t < 1e-7 then
				return t
			end
			s = (k - 1) * TICK
		end
		return s
	end

	-- A server with Tide started (players = true), n standing players, each client started.
	local function setup(opts)
		opts = opts or {}
		local world = T.world({ latency = opts.latency or 0.04, jitter = opts.jitter or 0, seed = opts.seed or 3 })
		local Tide = T.serverTide(world)
		if opts.schema then
			opts.schema(Tide)
		end
		local cfg = { players = true }
		for k, v in opts.config or {} do
			cfg[k] = v
		end
		Tide.start(cfg)
		local s = { world = world, Tide = Tide, chars = {}, cts = {}, pos = {} }
		function s.addPlayer(cf)
			local i = #world.players + 1
			local p = world:addPlayer()
			s.pos[i] = cf or CFrame.new(i * 6, 3, 0)
			s.chars[i] = world:spawnCharacter(p, s.pos[i])
			local ct = T.clientTide(world, i)
			if opts.schema then
				opts.schema(ct)
			end
			s.cts[i] = ct
			ct.start()
			return i
		end
		for k = 1, opts.players or 2 do
			s.addPlayer(opts.spawn and opts.spawn[k])
		end
		function s.frame(n)
			for _ = 1, n or 1 do
				for i, char in s.chars do
					local hrp = world:replica(i, char.HumanoidRootPart)
					if hrp and s.pos[i] then
						hrp.CFrame = s.pos[i]
					end
				end
				world:frame(DT)
			end
		end
		function s.view(i, model)
			return world:replica(i, model)
		end
		function s.log(i, model, field)
			local log = {}
			s.cts[i].changed(s.view(i, model), field, function(value, old, t)
				table.insert(log, { value = value, old = old, t = t, now = world.now })
			end)
			return log
		end
		s.frame(30)
		return s
	end

	--------------------------------------------------------------------------------

	T.test("owner change: an old owner is not sent the others-fields it already got (events once)", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				Tide.state("Bot", {
					Ping = { type = "event", to = "others", payload = "u8" },
					Seen = { type = "u8", to = "others" },
				})
			end,
		})
		local world, Tide = s.world, s.Tide
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		local h = Tide.add(bot, "Bot")
		s.frame(10)
		local pings = s.log(1, bot, "Ping")
		local seen = s.log(1, bot, "Seen")
		Tide.fire(bot, "Ping", 1)
		Tide.set(bot, "Seen", 1)
		s.frame(30)
		T.eq(#pings, 1, "server-owned: client 1 is one of the others")
		-- client 1 owns it for a moment (well inside StateReplay), then the server again
		h:setOwner(world.players[1])
		s.frame(5)
		h:setOwner(nil)
		s.frame(40)
		T.eq(#pings, 1, "the ping it already fired is not replayed")
		T.eq(#seen, 1, "nor the value it already had")
		T.eq(s.cts[1].get(s.view(1, bot), "Seen"), 1)
		-- a change it missed while it owned the bot does arrive
		h:setOwner(world.players[1])
		s.frame(5)
		Tide.fire(bot, "Ping", 2)
		Tide.set(bot, "Seen", 2)
		s.frame(5)
		h:setOwner(nil)
		s.frame(40)
		T.eq(#pings, 2, "the missed ping, once")
		T.eq(pings[2].value, 2)
		T.eq(s.cts[1].get(s.view(1, bot), "Seen"), 2, "the missed value")
	end)

	T.test("owner change back: owner-only events it already got are not fired again", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				Tide.state("Bot", { Hit = { type = "event", to = "owner", payload = "u8" }, Hp = { type = "u8", to = "owner" } })
			end,
		})
		local world, Tide = s.world, s.Tide
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		local h = Tide.add(bot, "Bot", world.players[1])
		s.frame(10)
		local hits = s.log(1, bot, "Hit")
		Tide.fire(bot, "Hit", 1)
		Tide.set(bot, "Hp", 10)
		s.frame(20)
		T.eq(#hits, 1)
		h:setOwner(world.players[2])
		s.frame(5)
		Tide.set(bot, "Hp", 20) -- missed by client 1
		s.frame(5)
		h:setOwner(world.players[1])
		s.frame(30)
		T.eq(#hits, 1, "hit 1 not replayed to the returning owner")
		T.eq(s.cts[1].get(s.view(1, bot), "Hp"), 20, "the missed owner-only change arrives")
		T.eq(s.cts[2].get(s.view(2, bot), "Hp"), 20, "client 2 got it while it owned the bot")
	end)

	T.test("an entity owned by a client far from it: the owner still gets its state", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				Tide.state("Npc", { Hp = "u8", Mine = { type = "u8", to = "owner" } })
			end,
		})
		local world, Tide = s.world, s.Tide
		-- Npc cull = 400: far from both players
		local npc = world:spawnModel("npc", CFrame.new(3000, 3, 0), true)
		local h = Tide.add(npc, "Npc", world.players[1])
		s.frame(10)
		Tide.set(npc, "Hp", 5)
		Tide.set(npc, "Mine", 6)
		s.frame(30)
		T.eq(s.cts[1].get(s.view(1, npc), "Hp"), 5, "owner gets all-fields")
		T.eq(s.cts[1].get(s.view(1, npc), "Mine"), 6, "and owner fields")
		T.eq(s.cts[2].get(s.view(2, npc), "Hp"), 0, "a far receiver: culled")
		-- given to client 2 while far: from then on it gets them too (a snapshot, then changes)
		h:setOwner(world.players[2])
		s.frame(10)
		Tide.set(npc, "Mine", 7)
		s.frame(30)
		T.eq(s.cts[2].get(s.view(2, npc), "Hp"), 5, "new far owner: snapshot")
		T.eq(s.cts[2].get(s.view(2, npc), "Mine"), 7, "and later changes")
		-- client 1 gave it up and is far: culled now; on coming close it catches up once
		local hp1 = s.log(1, npc, "Hp")
		Tide.set(npc, "Hp", 8)
		s.frame(10)
		T.eq(s.cts[1].get(s.view(1, npc), "Hp"), 5, "old owner, far: culled")
		s.pos[1] = CFrame.new(2990, 3, 0)
		Tide.handle(s.chars[1]):teleport(s.pos[1])
		s.frame(40)
		T.eq(s.cts[1].get(s.view(1, npc), "Hp"), 8, "back in range: caught up")
		T.eq(#hp1, 1, "once")
	end)

	T.test("snapshot in the frame of a backdated change older than its t0: the joiner ends on the server's value", function()
		local s = setup({
			players = 1,
			config = { MaxBackdate = 2.0 },
			schema = function(Tide)
				Tide.state("Bot", { Mode = { type = "enum", values = { "a", "b" } } })
			end,
		})
		local world, Tide = s.world, s.Tide
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		Tide.add(bot, "Bot")
		s.frame(5)
		Tide.set(bot, "Mode", "a")
		s.frame(180) -- 3 s: older than t0 of any snapshot from now on
		-- the joiner becomes ready in the same server frame as a change stamped 1.5 s back
		local StateLog = T.module(world, "Server", "StateLog")
		local onReady = StateLog.onReady
		StateLog.onReady = function(rx)
			onReady(rx)
			Tide.set(bot, "Mode", "b", world.now - 1.5)
		end
		local i = s.addPlayer()
		s.frame(60)
		StateLog.onReady = onReady
		T.eq(Tide.get(bot, "Mode"), "b", "server")
		T.eq(s.cts[1].get(s.view(1, bot), "Mode"), "b", "a client in range all along")
		T.eq(s.cts[i].get(s.view(i, bot), "Mode"), "b", "the joiner")
	end)

	T.test("history after the ring wrapped: event stateAt and changedAt see the base", function()
		local s = setup({
			players = 1,
			schema = function(Tide)
				Tide.state("Bot", {
					Kick = { type = "event", payload = "u8", history = 2 },
					Mode = { type = "u8", history = 2 },
				})
			end,
		})
		local world, Tide = s.world, s.Tide
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		Tide.add(bot, "Bot")
		s.frame(5)
		local stamps = {}
		for k = 1, 3 do
			stamps[k] = stampOf(world.now)
			Tide.fire(bot, "Kick", k)
			Tide.set(bot, "Mode", k)
			s.frame(6)
		end
		-- the ring keeps fires 2 and 3; fire 1 is the base
		local t, p = Tide.stateAt(bot, "Kick", stamps[1] + 0.01)
		T.check(t ~= nil, "the evicted fire is still the latest one at that time")
		T.near(t :: number, stamps[1], 1e-9)
		T.eq(p, 1)
		T.eq(Tide.stateAt(bot, "Mode", stamps[1] + 0.01), 1, "values: base (unchanged behaviour)")
		local c = Tide.changedAt(bot, "Mode", stamps[1] - 0.01, stamps[1] + 0.01)
		T.check(c ~= nil, "changedAt: the evicted change in the window")
		T.near(c :: number, stamps[1], 1e-9)
		local ce = Tide.changedAt(bot, "Kick", stamps[1] - 0.01, stamps[2] + 0.01)
		T.near(ce :: number, stamps[1], 1e-9, "events too: the first in the window")
		T.near(Tide.changedAt(bot, "Mode", stamps[1] + 0.001, stamps[3]) :: number, stamps[2], 1e-9, "kept changes as before")
	end)
	T.test("a change stamped now is in history at now (the 0.5 ms grid never rounds a stamp into the future)", function()
		local s = setup({
			players = 1,
			schema = function(Tide)
				Tide.state("Bot", { ShotAt = { type = "event" }, Owner = "u8" })
			end,
		})
		local world, Tide = s.world, s.Tide
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		Tide.add(bot, "Bot")
		s.frame(5)
		local tried = 0
		for k = 1, 12 do
			local now = world.now
			if q(now) > now then
				tried += 1
				Tide.set(bot, "Owner", k)
				Tide.fire(bot, "ShotAt")
				T.eq(Tide.stateAt(bot, "Owner", now), k, "stateAt(now) right after a set")
				T.check(Tide.changedAt(bot, "Owner", now - 0.1, now) ~= nil, "changedAt(.., now)")
				T.check(Tide.changedAt(bot, "ShotAt", now - 0.1, now) ~= nil, "a fire too")
				local t = Tide.get(bot, "ShotAt")
				T.check(t <= now, "event stamp not after now")
			end
			s.frame()
		end
		T.check(tried > 0, "some frame times round up on the grid")
	end)

	T.test("client: a ref to a removed entity stays nil when its slot is reused (entity culled meanwhile)", function()
		local s = setup({
			players = 2,
			spawn = { CFrame.new(10, 3, 0), CFrame.new(-10, 3, 0) },
			schema = function(Tide)
				Tide.state("Npc", { Target = "ref", Last = { type = "event", payload = "ref" } })
			end,
		})
		local world, Tide = s.world, s.Tide
		local npc = world:spawnModel("npc", CFrame.new(0, 3, 0), true)
		Tide.add(npc, "Npc")
		local b = world:spawnModel("b", CFrame.new(0, 3, 30), true)
		Tide.add(b, "Bot")
		local SState = s.SState or T.module(world, "Server", "State")
		local slotB = SState.bySlotModel[b]
		s.frame(10)
		Tide.set(npc, "Target", b)
		Tide.fire(npc, "Last", b)
		s.frame(40)
		local v2 = s.view(2, npc)
		T.eq(s.cts[2].get(v2, "Target"), s.view(2, b))
		-- client 2 goes far: the npc is culled for it
		s.pos[2] = CFrame.new(-3000, 3, 0)
		Tide.handle(s.chars[2]):teleport(s.pos[2])
		s.frame(30)
		Tide.remove(b)
		s.frame(10)
		T.eq(s.cts[2].get(v2, "Target"), nil, "removed: nil")
		s.frame(150) -- past SlotQuarantine
		local c = world:spawnModel("c", CFrame.new(0, 3, 40), true)
		Tide.add(c, "Bot")
		T.eq(SState.bySlotModel[c], slotB, "the slot is reused")
		s.frame(30)
		T.check(s.view(2, c) ~= nil, "client 2 has the new entity")
		T.eq(s.cts[2].get(v2, "Target"), nil, "still nil, not the new entity")
		T.eq((s.cts[2].peek(v2, "Target")), nil, "peek too")
		T.eq(select(2, s.cts[2].get(v2, "Last")), nil, "event ref payload too")
	end)
end

