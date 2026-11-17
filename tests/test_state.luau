-- Timeline state (v0.3): fields declared per kind, set on the server, applied on each client when its
-- clock for the entity reaches the change's stamp; history, snapshots, mirrors, state-only entities,
-- refs, events, validation, allocations, and v0.2 unchanged without a schema.
return function(T)
	local DT = 1 / 60
	local Mock = T.Mock
	local TICK = 0.0005

	local function q(t)
		return math.round(t / TICK) * TICK
	end

	local function path(i, t)
		return i * 12 + 6 * math.sin(t * 1.1 + i), 3, 5 * math.cos(t * 0.8 + i)
	end

	-- A server with Tide started (players = true), n players (moving on a path), each client started.
	-- opts.schema(Tide) runs on the server before start and on each client before its start
	-- (shared code); opts.clientSchema = false skips the clients.
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
		local s = { world = world, Tide = Tide, chars = {}, cts = {}, suspicious = {}, moving = opts.moving ~= false }
		Tide.onSuspicious(function(_player, reason)
			table.insert(s.suspicious, reason)
		end)
		s.SState = T.module(world, "Server", "State")
		s.pos = {}
		function s.addPlayer(cf)
			local i = #world.players + 1
			local p = world:addPlayer()
			local x, y, z = path(i, world.now)
			s.chars[i] = world:spawnCharacter(p, cf or CFrame.new(x, y, z))
			local ct = T.clientTide(world, i)
			if opts.schema and opts.clientSchema ~= false then
				opts.schema(ct)
			end
			s.cts[i] = ct
			ct.start()
			return i
		end
		for k = 1, opts.players or 3 do
			local cf = opts.spawn and opts.spawn[k]
			if cf then
				s.pos[k] = cf
			end
			s.addPlayer(cf)
		end
		-- moves a player's character (a server teleport the owner follows)
		function s.move(i, cf)
			s.pos[i] = cf
			Tide.handle(s.chars[i]):teleport(cf)
		end
		function s.frame(n)
			for _ = 1, n or 1 do
				local t = world.now + DT
				for i, char in s.chars do
					local hrp = world:replica(i, char.HumanoidRootPart)
					if hrp then
						if s.pos[i] then
							hrp.CFrame = s.pos[i]
						elseif s.moving then
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
		function s.view(i, model)
			return world:replica(i, model)
		end
		-- render time of a remote entity on client i this frame
		function s.rt(i, model)
			return world.now - s.cts[i].delay(s.view(i, model))
		end
		function s.cstate(i)
			return T.clientModule(world, i, "Client", "State")
		end
		s.frame(30)
		return s
	end

	--------------------------------------------------------------------------------

	T.test("drawn fields apply at the entity's render time (never before); owner on arrival; peek; timeOf", function()
		local s = setup({
			players = 3,
			schema = function(Tide)
				Tide.state("Player", {
					Blocking = { type = "bool", mirror = "Blocking" },
					SlideAt = { type = "time", mirror = "SlideAt" },
					Speed = "u8",
				})
			end,
		})
		local world = s.world
		local char = s.chars[1]
		s.frame(30)
		local logs = {}
		for i = 1, 3 do
			logs[i] = {}
			local view = s.view(i, char)
			s.cts[i].changed(view, "Blocking", function(value, old, t)
				table.insert(logs[i], { value = value, old = old, t = t, now = world.now, rt = world.now - s.cts[i].delay(view) })
			end)
		end
		local tSet = world.now
		local slideAt = tSet - 0.0123
		s.Tide.set(char, "Blocking", true)
		s.Tide.set(char, "SlideAt", slideAt)
		s.Tide.set(char, "Speed", 42)
		T.eq(s.Tide.get(char, "Blocking"), true, "server get")
		T.near(s.Tide.get(char, "SlideAt"), slideAt, 0.00026, "time on the 0.5 ms grid")
		T.eq(s.Tide.timeOf(char), world.now, "server timeOf = now")
		local window = { false, false, false }
		for _ = 1, 40 do
			s.frame()
			for i = 2, 3 do
				local view = s.view(i, char)
				local rt = world.now - s.cts[i].delay(view)
				local got = s.cts[i].get(view, "Blocking")
				if rt < q(tSet) - 1e-9 then
					T.eq(got, false, `receiver {i} applied before the body got there`)
					if s.cts[i].peek(view, "Blocking") == true then
						window[i] = true
					end
				end
				T.near(s.cts[i].timeOf(view), rt, 1e-9, "timeOf = render time")
			end
		end
		for i = 2, 3 do
			local log = logs[i]
			T.eq(#log, 1, `receiver {i}: one change`)
			T.eq(log[1].value, true)
			T.eq(log[1].old, false)
			T.near(log[1].t, tSet, 0.00051, "stamp (on the 0.5 ms grid, never after the set)")
			T.check(log[1].rt >= log[1].t - 1e-9, "not before its stamp")
			T.check(log[1].rt < log[1].t + DT * 1.15, `on the first frame past it ({log[1].rt - log[1].t})`)
			local view = s.view(i, char)
			T.near(s.cts[i].get(view, "SlideAt"), s.Tide.get(char, "SlideAt"), 1e-6, "time value")
			T.eq(s.cts[i].get(view, "Speed"), 42)
			T.eq(view:GetAttribute("Blocking"), true, "mirror")
			T.near(view:GetAttribute("SlideAt"), s.Tide.get(char, "SlideAt"), 1e-6, "time mirror")
		end
		-- the owner applies on arrival: one-way latency (plus up to the jitter) after the set, rounded
		-- up to frames (the flush in the next server frame, the apply in the frame it arrives in),
		-- well before the others
		local own = logs[1][1]
		T.check(own ~= nil, "owner applied")
		T.check(own.now <= tSet + world.latency + world.jitter + 2 * DT + 1e-9, `owner on arrival ({own.now - tSet})`)
		T.check(own.now < logs[2][1].now, "owner before the receivers")
		T.eq(s.cts[1].timeOf(s.view(1, char)), world.now, "owner's clock is now")
		-- unknown field: error on both sides
		T.check(not pcall(s.Tide.set, char, "Nope", 1), "server: unknown field")
		T.check(not pcall(s.cts[2].get, s.view(2, char), "Nope"), "client: unknown field")
		T.check(not pcall(s.Tide.set, char, "Speed", 300), "u8 range")
		T.check(not pcall(s.Tide.set, char, "Blocking", 1), "bool type")
	end)

	T.test("apply = arrival, to = owner / others / server, owner change snapshot", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				local fields = {
					Window = { type = "time", apply = "arrival" },
					HitAt = { type = "time", to = "owner" },
					Seen = { type = "bool", to = "others" },
					Secret = { type = "u16", to = "server" },
				}
				Tide.state("Player", fields)
				Tide.state("Bot", { Hp = { type = "u8", to = "owner" }, Team = { type = "enum", values = { "Red", "Blue" } } })
			end,
		})
		local world = s.world
		local char = s.chars[1]
		local tSet = world.now
		s.Tide.set(char, "Window", tSet + 0.5)
		s.Tide.set(char, "HitAt", tSet)
		s.Tide.set(char, "Seen", true)
		s.Tide.set(char, "Secret", 7)
		local arrivalSeen = false
		for _ = 1, 30 do
			s.frame()
			local view = s.view(2, char)
			local rt = s.rt(2, char)
			if s.cts[2].get(view, "Window") ~= nil and rt < q(tSet) then
				arrivalSeen = true
			end
		end
		T.check(arrivalSeen, "arrival field applied before the render time reached the stamp")
		local v1, v2 = s.view(1, char), s.view(2, char)
		T.near(s.cts[2].get(v2, "Window"), tSet + 0.5, 0.0003)
		T.near(s.cts[1].get(v1, "HitAt"), tSet, 0.0003, "owner gets owner fields")
		T.eq(s.cts[2].get(v2, "HitAt"), nil, "others do not")
		T.eq(s.cts[2].peek(v2, "HitAt"), nil, "not even received")
		T.eq(s.cts[2].get(v2, "Seen"), true, "others field")
		T.eq(s.cts[1].get(v1, "Seen"), false, "not to the owner")
		T.eq(s.cts[1].get(v1, "Secret"), 0, "server-only: default on clients")
		T.eq(s.cts[2].get(v2, "Secret"), 0)
		T.eq(s.Tide.get(char, "Secret"), 7, "server keeps it")

		-- owner change: the new owner gets the owner-only fields it never saw
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		local handle = s.Tide.add(bot, "Bot")
		s.Tide.set(bot, "Hp", 50)
		s.Tide.set(bot, "Team", "Blue")
		s.frame(30)
		T.eq(s.cts[2].get(s.view(2, bot), "Hp"), 0, "server-owned: nobody gets Hp")
		T.eq(s.cts[2].get(s.view(2, bot), "Team"), "Blue")
		handle:setOwner(world.players[2])
		s.frame(10)
		T.eq(s.cts[2].get(s.view(2, bot), "Hp"), 50, "new owner got Hp (snapshot)")
		T.eq(s.cts[1].get(s.view(1, bot), "Hp"), 0)
		s.Tide.set(bot, "Hp", 40)
		s.frame(10)
		T.eq(s.cts[2].get(s.view(2, bot), "Hp"), 40, "and its changes")
		T.check(not pcall(s.Tide.set, bot, "Team", "Green"), "enum value checked")
	end)

	T.test("history: stateAt across past stamps (out of order), ring eviction, clamps, changedAt, stale on clients", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				Tide.state("Bot", {
					Mode = { type = "enum", values = { "idle", "run", "slide" }, history = 4 },
					Until = "time",
					Flag = "bool",
					Power = "f32",
				})
			end,
		})
		local world = s.world
		local Tide = s.Tide
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		Tide.add(bot, "Bot")
		s.frame(30)
		local now = world.now
		Tide.set(bot, "Mode", "run", now - 0.4)
		Tide.set(bot, "Mode", "slide", now - 0.2)
		Tide.set(bot, "Mode", "idle", now - 0.3) -- older than the current one: history only
		T.eq(Tide.get(bot, "Mode"), "slide", "current = newest stamp")
		T.eq(Tide.stateAt(bot, "Mode", now - 0.5), nil, "before the first change: default")
		T.eq(Tide.stateAt(bot, "Mode", now - 0.35), "run")
		T.eq(Tide.stateAt(bot, "Mode", now - 0.25), "idle")
		T.eq(Tide.stateAt(bot, "Mode", now - 0.1), "slide")
		T.eq(Tide.stateAt(bot, "Mode", q(now - 0.3)), "idle", "at the stamp itself")
		T.near(Tide.changedAt(bot, "Mode", now - 0.45, now) :: number, q(now - 0.4), 1e-9, "first change in the window")
		T.near(Tide.changedAt(bot, "Mode", now - 0.35, now) :: number, q(now - 0.3), 1e-9)
		T.eq(Tide.changedAt(bot, "Mode", now - 0.19, now), nil)

		-- stamps clamp to [now - MaxBackdate, now]
		local c0 = Tide.stats().stateClamped
		Tide.set(bot, "Flag", true, now - 5)
		T.eq(Tide.stats().stateClamped, c0 + 1)
		T.eq(Tide.stateAt(bot, "Flag", now - 1.0 + 0.001), true, "clamped to now - MaxBackdate")
		T.eq(Tide.stateAt(bot, "Flag", now - 1.0 - 0.001), false)
		Tide.set(bot, "Flag", false, now + 3)
		T.eq(Tide.stats().stateClamped, c0 + 2, "future stamp clamped to now")
		T.eq(Tide.get(bot, "Flag"), false)
		-- same value: no change recorded
		local same = Tide.stats().stateSame
		Tide.set(bot, "Flag", false)
		T.eq(Tide.stats().stateSame, same + 1)
		-- f32 and time values as clients decode them
		Tide.set(bot, "Power", 0.1)
		T.check(Tide.get(bot, "Power") ~= 0.1 and math.abs(Tide.get(bot, "Power") - 0.1) < 1e-7, "f32 rounded")
		Tide.set(bot, "Until", now + 0.3337)
		T.near(Tide.get(bot, "Until"), now + 0.3337, 0.00026)

		-- eviction: 6 changes into a 4-change ring; the newest evicted becomes the base
		s.frame(30)
		local stamps = {}
		local modes = { "run", "idle", "slide", "run", "idle", "slide" }
		for k = 1, 6 do
			Tide.set(bot, "Mode", modes[k])
			stamps[k] = q(world.now)
			s.frame(3)
		end
		T.eq(Tide.stateAt(bot, "Mode", stamps[3] + 0.001), "slide", "kept")
		T.eq(Tide.stateAt(bot, "Mode", stamps[2] + 0.001), "idle", "base: exact back to the newest evicted change")
		T.eq(Tide.stateAt(bot, "Mode", stamps[6] + 1), "slide")

		-- clients: a change older than the one already applied is stale
		s.frame(30)
		local CState = s.cstate(2)
		local view = s.view(2, bot)
		T.eq(s.cts[2].get(view, "Mode"), "slide")
		local stale = CState.counters.stateStale
		Tide.set(bot, "Mode", "run", world.now - 0.6)
		s.frame(30)
		T.eq(Tide.get(bot, "Mode"), "slide", "server: still the newest")
		T.eq(s.cts[2].get(view, "Mode"), "slide", "client: too")
		T.eq(CState.counters.stateStale, stale + 1, "skipped as stale")
		T.near(s.cts[2].get(view, "Until"), Tide.get(bot, "Until"), 1e-6, "time value matches the server's")
		T.eq(s.cts[2].get(view, "Power"), Tide.get(bot, "Power"), "f32 matches")
	end)

	T.test("late joiner: values from the recent past, then later changes on its own render clock", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				Tide.state("Bot", { Count = "u16", Mode = { type = "enum", values = { "a", "b" } }, Pulse = { type = "event", payload = "u8" } })
				Tide.state("Player", { Blocking = "bool" })
			end,
		})
		local world = s.world
		local Tide = s.Tide
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		Tide.add(bot, "Bot")
		for k = 1, 40 do
			Tide.set(bot, "Count", k)
			if k == 5 then
				Tide.set(bot, "Mode", "b")
				Tide.fire(bot, "Pulse", 1) -- long before the join (older than StateReplay)
			end
			s.frame(3)
		end
		Tide.fire(bot, "Pulse", 2) -- inside the replay window
		Tide.set(s.chars[1], "Blocking", true)
		s.frame(5)
		-- join; the last change goes out right before the joiner is ready
		local i = s.addPlayer()
		local ct = s.cts[i]
		local applied = {}
		ct.stateChanged(function(model, field, value, old, t)
			table.insert(applied, { model = model, field = field, value = value, old = old, t = t, now = world.now })
		end)
		local tLast = world.now
		Tide.set(bot, "Count", 1000)
		s.frame(60)
		local view = s.view(i, bot)
		T.eq(ct.get(view, "Count"), 1000)
		T.eq(ct.get(view, "Mode"), "b", "from the snapshot base")
		T.eq(ct.get(s.view(i, s.chars[1]), "Blocking"), true, "players' state too")
		local pulses = {}
		local last1000 = nil
		for _, e in applied do
			if e.field == "Pulse" then
				table.insert(pulses, e.value)
			elseif e.field == "Count" and e.value == 1000 then
				last1000 = e
			end
		end
		T.eq(#pulses, 1, "only the event inside the window is replayed")
		T.eq(pulses[1], 2)
		T.check(last1000 ~= nil, "the newest change applied")
		local delay = ct.delay(view)
		T.check(last1000.now - delay >= q(tLast) - 1e-9, "on the joiner's render clock")
		T.eq(s.cstate(i).counters.stateSnaps, 2, "one snapshot per entity with state (bot, char 1)")
		-- the joiner holds the same timeline as everyone else
		for k = 1, 2 do
			T.eq(s.cts[k].get(s.view(k, bot), "Count"), 1000)
		end
	end)

	T.test("cull: nothing while culled, snapshot on re-entry, each event exactly once", function()
		local s = setup({
			players = 2,
			moving = false,
			spawn = { CFrame.new(10, 3, 0), CFrame.new(2000, 3, 0) },
			schema = function(Tide)
				Tide.state("Npc", { Hp = "u8", Hit = { type = "event", payload = "u8" } })
			end,
		})
		local world = s.world
		local Tide = s.Tide
		local npc = world:spawnModel("npc", CFrame.new(0, 3, 0), true)
		Tide.add(npc, "Npc")
		s.frame(20)
		local hits = { {}, {} }
		local hps = { {}, {} }
		for i = 1, 2 do
			s.cts[i].stateChanged(function(model, field, value)
				if field == "Hit" then
					table.insert(hits[i], value)
				elseif field == "Hp" then
					table.insert(hps[i], value)
				end
			end)
		end
		Tide.set(npc, "Hp", 10)
		Tide.fire(npc, "Hit", 1)
		s.frame(30)
		T.eq(s.cts[1].get(s.view(1, npc), "Hp"), 10)
		T.eq(s.cts[2].get(s.view(2, npc), "Hp"), 0, "culled: nothing")
		T.eq(select(2, s.cts[2].peek(s.view(2, npc), "Hp")), nil, "nothing received")
		-- client 2 comes close: snapshot
		s.move(2, CFrame.new(20, 3, 0))
		s.frame(40)
		T.eq(s.cts[2].get(s.view(2, npc), "Hp"), 10, "snapshot on entering")
		T.eq(#hits[2], 1, "the recent hit replayed once")
		-- client 1 leaves, misses changes, comes back within StateReplay
		s.move(1, CFrame.new(-2000, 3, 0))
		s.frame(20)
		Tide.set(npc, "Hp", 20)
		Tide.fire(npc, "Hit", 2)
		s.frame(2)
		Tide.set(npc, "Hp", 30)
		s.frame(10)
		T.eq(s.cts[1].get(s.view(1, npc), "Hp"), 10, "culled again")
		s.move(1, CFrame.new(15, 3, 0))
		s.frame(40)
		T.eq(s.cts[1].get(s.view(1, npc), "Hp"), 30)
		T.eq(#hits[1], 2, "hit 1 (before) and hit 2 (missed): once each")
		T.eq(hits[1][1], 1)
		T.eq(hits[1][2], 2)
		T.eq(table.concat(hps[1], ","), "10,20,30", "missed changes replayed in order")
		-- away longer than StateReplay: the base brings the value, old events are not replayed
		s.move(1, CFrame.new(-2000, 3, 0))
		s.frame(20)
		Tide.set(npc, "Hp", 40)
		Tide.fire(npc, "Hit", 3)
		s.frame(120)
		s.move(1, CFrame.new(15, 3, 0))
		s.frame(40)
		T.eq(s.cts[1].get(s.view(1, npc), "Hp"), 40, "base after a long absence")
		T.eq(#hits[1], 2, "an event older than StateReplay is not replayed")
		T.eq(s.cts[2].get(s.view(2, npc), "Hp"), 40)
		T.eq(#hits[2], 3, "client 2 stayed in range: every hit once")
	end)

	T.test("mirror: attributes set on the client when a change applies; changed signal in that frame; refs by name", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				Tide.state("Player", {
					Shielding = { type = "bool", mirror = "Shielding" },
					Holding = { type = "bool", mirror = "Holding", mirrorOn = "player" },
					Target = { type = "ref", mirror = "TargetName", mirrorNil = "" },
					Mode = { type = "enum", values = { "a", "b" }, mirror = "Mode" },
				})
			end,
		})
		local world = s.world
		local char = s.chars[1]
		local view = s.view(2, char)
		local attrAt, changedAt = nil, nil
		view:GetAttributeChangedSignal("Shielding"):Connect(function()
			attrAt = world.now
		end)
		s.cts[2].changed(view, "Shielding", function()
			changedAt = world.now
		end)
		s.Tide.set(char, "Shielding", true)
		s.Tide.set(char, "Target", s.chars[2])
		s.Tide.set(char, "Mode", "b")
		s.Tide.set(char, "Holding", true)
		s.frame(30)
		T.eq(view:GetAttribute("Shielding"), true)
		T.check(attrAt ~= nil and attrAt == changedAt, "attribute changed in the apply frame")
		T.eq(view:GetAttribute("TargetName"), "Player2", "ref mirrored as the model's name")
		T.eq(view:GetAttribute("Mode"), "b")
		T.eq(s.cts[2].get(view, "Target"), s.view(2, s.chars[2]), "ref resolves to the local model")
		T.eq(world.players[1]:GetAttribute("Holding"), true, "mirrorOn = player")
		T.eq(char:GetAttribute("Shielding"), nil, "the server never writes the attribute")
		s.Tide.set(char, "Target", nil)
		s.Tide.set(char, "Shielding", false)
		s.frame(30)
		T.eq(view:GetAttribute("TargetName"), "", "mirrorNil")
		T.eq(view:GetAttribute("Shielding"), false)
	end)

	T.test("state-only entity (motion = false) with a game-supplied clock; monotonic; no samples", function()
		local s = setup({
			players = 3,
			schema = function(Tide)
				Tide.kind("Ball", { motion = false, buffer = 0.1 })
				Tide.state("Ball", { Owner = { type = "ref", mirror = "Owner", mirrorNil = "" }, Spin = "i16" })
			end,
		})
		local world = s.world
		local Tide = s.Tide
		local ball = Mock.newInstance("Part", "Ball")
		ball.CFrame = CFrame.new(0, 2, 0)
		ball.Parent = world.server.Workspace
		Tide.add(ball, "Ball")
		s.frame(10)
		local lead = -0.25
		local v2 = s.view(2, ball)
		s.cts[2].clock(v2, function(now)
			return now + lead
		end)
		local applied = {}
		for i = 1, 3 do
			applied[i] = {}
			s.cts[i].changed(s.view(i, ball), "Owner", function(value, _old, t)
				table.insert(applied[i], { value = value, t = t, now = world.now })
			end)
		end
		local tSet = world.now
		Tide.set(ball, "Owner", s.chars[1])
		local window = false
		for _ = 1, 40 do
			s.frame()
			if s.cts[2].peek(v2, "Owner") == s.view(2, s.chars[1]) and s.cts[2].get(v2, "Owner") == nil then
				window = true
			end
		end
		T.check(window, "peek: received, not yet applied")
		local a2, a3 = applied[2][1], applied[3][1]
		T.check(a2 ~= nil and a3 ~= nil, "applied")
		T.check(a2.now - 0.25 >= q(tSet) - 1e-9 and a2.now - 0.25 < q(tSet) + DT + 1e-6, `custom clock ({a2.now - tSet})`)
		T.check(a3.now - 0.1 >= q(tSet) - 1e-9 and a3.now - 0.1 < q(tSet) + DT + 1e-6, `kind.buffer fallback ({a3.now - tSet})`)
		T.eq(s.cts[2].get(v2, "Owner"), s.view(2, s.chars[1]))
		T.eq(v2:GetAttribute("Owner"), "Player1", "mirror by name")
		T.eq(s.cts[3].get(s.view(3, ball), "Owner"), s.view(3, s.chars[1]))
		-- the clock never goes back: a slower clock holds until it passes the last time
		local before = s.cts[2].timeOf(v2)
		lead = -1.0
		T.near(s.cts[2].timeOf(v2), before, DT, "held")
		Tide.set(ball, "Owner", s.chars[2])
		s.frame(20)
		T.eq(s.cts[2].get(v2, "Owner"), s.view(2, s.chars[1]), "not applied before the clock reaches it")
		s.frame(60)
		T.eq(s.cts[2].get(v2, "Owner"), s.view(2, s.chars[2]))
		-- a broken clock falls back (counted)
		s.cts[2].clock(v2, function()
			error("boom")
		end)
		s.cts[2].timeOf(v2)
		T.check(s.cstate(2).counters.stateClockErrors > 0, "clock errors counted")
		-- no motion: no samples, nothing drawn, the part is left alone, no rewind pose
		local slot = s.SState.bySlotModel[ball]
		T.eq(s.SState.hist[slot].last, s.SState.relayed[slot], "no samples relayed")
		T.eq(s.cts[3].drawn(s.view(3, ball)), nil)
		T.eq(s.view(3, ball).Anchored, false, "client does not anchor it")
		T.eq(Tide.at(ball, world.now), nil)
		T.eq(s.Tide.stats().owner, 0)
		-- owned by a client: no uploads, its state on arrival
		Tide.handle(ball):setOwner(world.players[3])
		s.frame(10)
		local tOwn = world.now
		Tide.set(ball, "Spin", -5)
		local got = nil
		for _ = 1, 10 do
			s.frame()
			if got == nil and s.cts[3].get(s.view(3, ball), "Spin") == -5 then
				got = world.now
			end
		end
		T.check(got ~= nil and got <= tOwn + world.latency + world.jitter + 2 * DT + 1e-9, "owner applies on arrival")
		T.eq(s.cstate(3).counters.uploads > 0, true)
		T.eq(s.Tide.stats().owner, 0, "no samples uploaded for the ball")
	end)

	T.test("refs: handles and models, removed entities read nil (server, history, clients)", function()
		local s = setup({
			players = 3,
			schema = function(Tide)
				Tide.kind("Ball", { motion = false })
				Tide.state("Ball", { Owner = { type = "ref", mirror = "Owner", mirrorNil = "" } })
			end,
		})
		local world = s.world
		local Tide = s.Tide
		local ball = Mock.newInstance("Part", "Ball")
		ball.Parent = world.server.Workspace
		Tide.add(ball, "Ball")
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		local botHandle = Tide.add(bot, "Bot")
		s.frame(10)
		Tide.set(ball, "Owner", botHandle) -- a handle works too
		T.eq(Tide.get(ball, "Owner"), bot)
		s.frame(30)
		T.eq(s.cts[1].get(s.view(1, ball), "Owner"), s.view(1, bot))
		T.eq(s.view(1, ball):GetAttribute("Owner"), "bot")
		Tide.set(ball, "Owner", s.chars[2])
		local tOwned = world.now
		s.frame(30)
		T.eq(s.cts[1].get(s.view(1, ball), "Owner"), s.view(1, s.chars[2]))
		-- player 2 leaves: its character entity goes, the ref is cleared
		world:removePlayer(world.players[2])
		s.frame(1)
		T.eq(Tide.get(ball, "Owner"), nil, "server: cleared")
		T.eq(Tide.stateAt(ball, "Owner", tOwned + 0.01), nil, "history: a removed entity reads nil")
		T.eq(Tide.stateAt(ball, "Owner", tOwned - 0.01), bot, "older history: still there")
		s.frame(30)
		T.eq(s.cts[1].get(s.view(1, ball), "Owner"), nil, "client: nil")
		T.eq(s.view(1, ball):GetAttribute("Owner"), "")
		-- refs must be Tide entities
		local stray = world:spawnModel("stray", CFrame.new(), true)
		T.check(not pcall(Tide.set, ball, "Owner", stray), "not an entity: error")
		-- setting state on something that is not an entity is ignored (counted)
		local n0 = Tide.stats().stateNoEntity
		Tide.set(stray, "Owner", nil)
		T.eq(Tide.stats().stateNoEntity, n0 + 1)
		T.eq(Tide.get(stray, "Owner"), nil)
	end)

	T.test("event fields: fire at render time with payloads; get / stateAt give the latest fire", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				Tide.state("Bot", {
					Trail = { type = "event", mirror = "TrailAt" },
					Skill = { type = "event", payload = "u16" },
					Cue = { type = "event", payload = "enum", values = { "Kick", "Save" } },
					Who = { type = "event", payload = "ref" },
				})
			end,
		})
		local world = s.world
		local Tide = s.Tide
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		Tide.add(bot, "Bot")
		s.frame(20)
		local view = s.view(2, bot)
		local log = {}
		for _, name in { "Trail", "Skill", "Cue", "Who" } do
			s.cts[2].changed(view, name, function(payload, old, t)
				table.insert(log, { name = name, payload = payload, old = old, t = t, rt = world.now - s.cts[2].delay(view) })
			end)
		end
		local t1 = world.now
		Tide.fire(bot, "Trail")
		Tide.fire(bot, "Skill", 513)
		Tide.fire(bot, "Cue", "Save")
		Tide.fire(bot, "Who", s.chars[1])
		Tide.fire(bot, "Skill", 7) -- twice in a frame: both fire
		s.frame(30)
		T.eq(s.cstate(2).counters.stateBad, 0)
		T.eq(#log, 5)
		for _, e in log do
			T.check(e.rt >= e.t - 1e-9, "at render time")
			T.eq(e.old, nil)
		end
		T.eq(log[1].payload, nil)
		T.eq(log[2].payload, 513)
		T.eq(log[3].payload, "Save")
		T.eq(log[4].payload, s.view(2, s.chars[1]))
		T.eq(log[5].payload, 7)
		local t, payload = s.cts[2].get(view, "Skill")
		T.near(t, t1, 0.00051)
		T.eq(payload, 7)
		T.near(view:GetAttribute("TrailAt"), t1, 0.00051, "event mirror = its time")
		local st, sp = Tide.stateAt(bot, "Skill", t1 + 0.001)
		T.near(st, t1, 0.00051)
		T.eq(sp, 7)
		T.eq(Tide.stateAt(bot, "Skill", t1 - 0.01), nil)
		T.check(not pcall(Tide.set, bot, "Trail", 1), "set on an event field")
		T.check(not pcall(Tide.fire, bot, "Trail", 1), "payload on an event without one")
		T.check(not pcall(Tide.fire, bot, "Skill", -1), "payload type")
	end)

	T.test("garbage: clients never send state; malformed messages never throw on clients", function()
		local s = setup({
			players = 2,
			schema = function(Tide)
				Tide.state("Player", { A = "u8", B = "time", C = { type = "enum", values = { "x" } }, D = "pos", E = "yaw" })
			end,
		})
		local world = s.world
		local remote2 = world:replica(2, world.tideModule:FindFirstChild("TideR"))
		local errors0 = s.Tide.stats().errors
		for _, tag in { 30, 31, 32 } do
			local b = buffer.create(16)
			buffer.writeu8(b, 0, tag)
			buffer.writeu16(b, 9, 1)
			remote2:FireServer(b)
		end
		s.frame(5)
		T.eq(s.Tide.stats().stateRejected, 3, "client state messages rejected")
		T.check(table.find(s.suspicious, "stateFromClient") ~= nil, "reported")
		T.eq(s.Tide.get(s.chars[1], "A"), 0, "nothing changed")
		T.eq(s.Tide.stats().errors, errors0)
		-- client: random and truncated state messages
		s.Tide.set(s.chars[1], "D", Vector3.new(1.5, 2, 3))
		s.Tide.set(s.chars[1], "E", Vector3.new(0, 0, 1))
		s.frame(30)
		local CState = s.cstate(1)
		local rep = world:replica(1, world.tideModule:FindFirstChild("TideR"))
		math.randomseed(17)
		local slot = s.SState.bySlotModel[s.chars[2]]
		for k = 1, 600 do
			local n = math.random(1, 48)
			local b = buffer.create(n)
			for j = 0, n - 1 do
				buffer.writeu8(b, j, math.random(0, 255))
			end
			buffer.writeu8(b, 0, 30 + k % 2)
			if k % 3 == 0 and n > 16 then
				-- plausible headers (a known slot, a sane time), then garbage
				if k % 2 == 0 then
					buffer.writef64(b, 1, world.now)
					buffer.writeu16(b, 9, 1)
					buffer.writeu16(b, 11, slot)
					buffer.writei16(b, 13, 0)
				else
					buffer.writeu16(b, 1, slot)
					buffer.writef64(b, 3, world.now - 1)
				end
			end
			rep.OnClientEvent:_fire(b, {})
		end
		T.check(CState.counters.stateBad > 0, "counted")
		-- truncated schema messages: rejected, never thrown
		local w = T.clientModule(world, 1, "Shared", "Control").writer(64)
		buffer.writeu8(w.b, 0, 32)
		buffer.writeu8(w.b, 1, 1)
		buffer.writeu8(w.b, 2, 99) -- kind id
		for n = 1, 9 do
			local b = buffer.create(n)
			buffer.copy(b, 0, w.b, 0, n)
			rep.OnClientEvent:_fire(b, {})
		end
		s.frame(30)
		T.eq(s.cts[1].timeOf(s.view(1, s.chars[2])) > 0, true, "still running")
		-- the real state still arrives
		s.Tide.set(s.chars[2], "A", 9)
		s.frame(30)
		T.eq(s.cts[1].get(s.view(1, s.chars[2]), "A"), 9)
		local d = s.cts[2].get(s.view(2, s.chars[1]), "D")
		T.check(d ~= nil and math.abs(d.X - 1.5) < 1e-6 and math.abs(d.Z - 3) < 1e-6, "pos")
		local e = s.cts[2].get(s.view(2, s.chars[1]), "E")
		T.check(e ~= nil and math.abs(e.Z - 1) < 1e-4 and math.abs(e.X) < 1e-4, "yaw direction")
	end)

	T.test("declaration errors; a client's differing declaration is warned and the server's used", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		T.check(not pcall(Tide.state, "Player", { A = { type = "nope" } }), "unknown type")
		T.check(not pcall(Tide.state, "Player", { A = { type = "u8", bogus = 1 } }), "unknown option")
		T.check(not pcall(Tide.state, "Player", { A = { type = "enum" } }), "enum without values")
		T.check(not pcall(Tide.state, "Player", { A = { type = "u8", to = "nobody" } }), "bad to")
		T.check(not pcall(Tide.state, "Player", { A = { type = "u8", apply = "later" } }), "bad apply")
		T.check(not pcall(Tide.state, "Player", { A = { type = "ref", default = 1 } }), "ref default")
		Tide.state("Player", { A = { type = "u8", default = 3 }, B = "bool" })
		Tide.start({ players = true })
		local p = world:addPlayer()
		local char = world:spawnCharacter(p, CFrame.new(0, 3, 0))
		world:addPlayer()
		local ct1 = T.clientTide(world, 1)
		ct1.state("Player", { A = "u8" }) -- stale client code
		ct1.start()
		local ct2 = T.clientTide(world, 2)
		ct2.start() -- no declaration at all
		for _ = 1, 20 do
			world:frame(DT)
		end
		T.eq(Tide.get(char, "A"), 3, "declared default")
		T.eq(ct2.get(world:replica(2, char), "A"), 3, "default from the server's schema")
		local warned = false
		for _, w in world.warnings do
			if string.find(w, "differs from the server", 1, true) then
				warned = true
			end
		end
		T.check(warned, "mismatch warned")
		Tide.set(char, "B", true)
		for _ = 1, 30 do
			world:frame(DT)
		end
		T.eq(ct2.get(world:replica(2, char), "B"), true, "decodes with the server's schema")
		-- declared after start: sent to everyone
		Tide.state("Bot", { Hp = "u8" })
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		Tide.add(bot, "Bot")
		Tide.set(bot, "Hp", 9)
		for _ = 1, 30 do
			world:frame(DT)
		end
		T.eq(ct1.get(world:replica(1, bot), "Hp"), 9)
		T.check(not pcall(Tide.state, "Bot", { Hp = "u16" }), "kind with state already set: error")
	end)

	T.test("schema round trip: every type and option reaches clients as declared", function()
		local decl = {
			B = { type = "bool", default = true, mirror = "B", mirrorNil = false },
			U8 = { type = "u8", default = 7, to = "owner", apply = "arrival" },
			U16 = { type = "u16", to = "others", mirror = "U16", mirrorOn = "player" },
			I16 = { type = "i16", default = -3, to = "server" },
			F32 = { type = "f32", default = 0.5 },
			F64 = { type = "f64", default = 1e9 + 0.25, mirrorNil = 2.5 },
			Tm = { type = "time", default = 12.5, mirror = "Tm", mirrorNil = 0 },
			R = { type = "ref", mirror = "R", mirrorNil = "" },
			E = { type = "enum", values = { "x", "y", "z" }, default = "y" },
			Ev = { type = "event", mirror = "EvAt" },
			EvP = { type = "event", payload = "enum", values = { "p", "q" } },
			EvR = { type = "event", payload = "ref" },
			Y = { type = "yaw", default = Vector3.new(1, 0, 0) },
			P = { type = "pos", default = Vector3.new(1, 2, 3), history = 5 },
		}
		local s = setup({
			players = 1,
			schema = function(Tide)
				Tide.state("Player", decl)
			end,
		})
		local server = T.module(s.world, "Shared", "StateSchema").byKind.Player
		local StateApply = T.clientModule(s.world, 1, "Client", "StateApply")
		local Kinds = T.clientModule(s.world, 1, "Shared", "Kinds")
		local got = StateApply.schemas[Kinds.byName.Player.id]
		T.check(got ~= nil, "client has the server's schema")
		T.eq(got.checksum, server.checksum)
		T.eq(#got.fields, #server.fields)
		for i, f in server.fields do
			local g = got.fields[i]
			for _, key in { "id", "name", "type", "code", "to", "arrival", "mirror", "mirrorOn", "mirrorNil", "payload", "event" } do
				T.eq(g[key], f[key], `{f.name}.{key}`)
			end
			if type(f.default) == "number" then
				T.near(g.default, f.default, 1e-6, `{f.name}.default`)
			else
				T.eq(g.default, f.default, `{f.name}.default`)
			end
			T.eq(g.values and table.concat(g.values, ","), f.values and table.concat(f.values, ","), `{f.name}.values`)
		end
		for _, w in s.world.warnings do
			T.check(not string.find(w, "differs", 1, true), "same declaration: no warning")
		end
		local view = s.view(1, s.chars[1])
		T.eq(s.cts[1].get(view, "E"), "y", "enum default")
		T.eq(s.cts[1].get(view, "B"), true, "bool default")
		T.eq(s.Tide.get(s.chars[1], "I16"), -3)
	end)

	T.test("one reliable message per receiver per frame: animation events and state merged", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		local folder = Mock.newInstance("Folder", "Animations")
		folder.Parent = world.server.ReplicatedStorage
		local kick = world:animation("rbxassetid://103", "Kick", 1.2, false, folder)
		Tide.state("Bot", { Hp = "u8" })
		Tide.start({ players = true, animations = true, animationFolder = folder })
		for i = 1, 2 do
			local p = world:addPlayer()
			world:spawnCharacter(p, CFrame.new(i * 5, 3, 0))
		end
		for i = 1, 2 do
			T.clientTide(world, i).start()
		end
		local bot = world:spawnModel("bot", CFrame.new(0, 3, 9), true)
		world:addAnimator(bot)
		Tide.add(bot, "Bot")
		for _ = 1, 30 do
			world:frame(DT)
		end
		local msgs = { {}, {} }
		for i = 1, 2 do
			world:replica(i, world.tideModule:FindFirstChild("TideR")).OnClientEvent:Connect(function(b)
				table.insert(msgs[i], b)
			end)
		end
		Tide.play(bot, kick, 0.1)
		Tide.set(bot, "Hp", 77)
		world.server:step(DT) -- one server frame: the watch step sees the play, the flush sends both
		world.now += 0.1
		world:pump()
		for i = 1, 2 do
			T.eq(#msgs[i], 1, `receiver {i}: one message`)
			local b = msgs[i][1]
			T.eq(buffer.readu8(b, 0), 21, "ANIM first")
			local count = buffer.readu16(b, 9)
			T.eq(count, 1)
			T.eq(buffer.readu8(b, 11 + 15), 30, "then STATE")
		end
		for _ = 1, 30 do
			world:frame(DT)
		end
		T.eq(T.clientTide(world, 1).get(world:replica(1, bot), "Hp"), 77)
	end)

	T.test("no schema: v0.2 bytes and behaviour (only the version byte differs)", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local msgs = {}
		for i = 1, 2 do
			local p = world:addPlayer()
			world:spawnCharacter(p, CFrame.new(i * 5, 3, 0))
		end
		for i = 1, 2 do
			world:replica(i, world.tideModule:FindFirstChild("TideR")).OnClientEvent:Connect(function(b)
				table.insert(msgs, b)
			end)
			T.clientTide(world, i).start()
		end
		local bot = world:spawnModel("bot", CFrame.new(0, 3, 9), true)
		Tide.add(bot, "Bot")
		for _ = 1, 60 do
			world:frame(DT)
		end
		for _, b in msgs do
			local tag = buffer.readu8(b, 0)
			T.check(tag ~= 30 and tag ~= 31 and tag ~= 32, "no state messages")
			if tag == 14 then
				T.eq(buffer.readu8(b, 1), 4, "protocol version 4")
			end
		end
		local st = Tide.stats()
		T.eq(st.stateSets + st.stateRelayBytes + st.stateSnaps, 0)
		T.check(not pcall(Tide.set, bot, "Hp", 1), "a kind without state: error")
		T.eq(T.clientTide(world, 1).get(world:replica(1, bot), "Hp"), nil, "client: nil, no schema")
	end)

	T.test("zero allocations: set + flush + receive + apply (steady state), idle apply step", function()
		local s = setup({
			players = 4,
			schema = function(Tide)
				Tide.state("Bot", { Hp = "u8", Until = "time", Flag = "bool", Target = "ref", Pulse = "event" })
			end,
		})
		local world = s.world
		local Tide = s.Tide
		local bots = {}
		for k = 1, 6 do
			bots[k] = world:spawnModel("bot" .. k, CFrame.new(k * 3, 3, 9), true)
			Tide.add(bots[k], "Bot")
		end
		s.frame(30)
		local Server = T.module(world, "Server", "Server")
		local SState = s.SState
		local StateApply = T.clientModule(world, 1, "Client", "StateApply")
		local CState = s.cstate(1)
		-- the server's remote: hand each message straight to client 1's decoder
		local sent = 0
		local fake = {}
		function fake.FireClient(_self, player, b, _insts)
			sent += 1
			if player == world.players[1] then
				local n = buffer.len(b)
				local pos = 0
				while pos < n do
					local tag = buffer.readu8(b, pos)
					pos += 1
					if tag == 30 then
						pos = StateApply.readState(b, pos, n)
					elseif tag == 31 then
						pos = StateApply.readSnap(b, pos, n)
					else
						error("unexpected tag " .. tag)
					end
					assert(pos >= 0, "malformed")
				end
			end
		end
		local t = world.now
		local k = 0
		local function step()
			t += DT
			k += 1
			world.now = t
			for b = 1, #bots do
				local bot = bots[b]
				Tide.set(bot, "Hp", (k + b) % 200)
				Tide.set(bot, "Until", t + 0.25)
				Tide.set(bot, "Flag", k % 2 == 0)
				Tide.set(bot, "Target", bots[(k + b) % #bots + 1])
				Tide.fire(bot, "Pulse")
			end
			Server.flushReliable(t, fake)
			StateApply.step(t)
		end
		for _ = 1, 120 do
			step()
		end
		local applied = CState.counters.stateApplied
		local function allocs(fn)
			local before = __alloc_count()
			fn()
			return __alloc_count() - before
		end
		local best = math.huge
		for _ = 1, 4 do
			best = math.min(
				best,
				allocs(function()
					for _ = 1, 240 do
						step()
					end
				end)
			)
			if best == 0 then
				break
			end
		end
		T.check(CState.counters.stateApplied > applied + 1000, "changes applied while measuring")
		T.eq(SState.counters.stateSets > 0, true)
		T.eq(best, 0, "set + flush + receive + apply, 240 frames x 6 entities x 5 fields")
		-- idle: nothing queued
		local idle = allocs(function()
			for _ = 1, 240 do
				t += DT
				StateApply.step(t)
			end
		end)
		T.eq(idle, 0, "idle apply step")
	end)
end
