-- Timeline state, v0.5: "vector" and "cframe" values, and event payloads with named members
-- (a kick carrying its position, velocity, kicker, kind and a time).
return function(T)
	local DT = 1 / 60

	local KICK = {
		Position = "pos",
		Velocity = "vector",
		By = "ref",
		Kind = { type = "enum", values = { "pass", "shot", "header" } },
		PressAt = "time",
		Power = "f32",
		Curve = "i16",
		First = "bool",
		Pose = "cframe",
	}

	local function declare(Tide)
		Tide.state("Ball", {
			Kick = { type = "event", payload = KICK },
			Spin = "vector",
			Rest = "cframe",
			Hit = { type = "event", payload = "vector" },
			Placed = { type = "event", payload = "cframe" },
		})
	end

	-- a server, `players` clients (shared declaration unless clientSchema = false), a state-only
	-- ball; frames move nothing
	local function setup(opts: any?)
		opts = opts or {}
		local world = T.world({ latency = 0.04, jitter = 0, seed = 3 })
		local Tide = T.serverTide(world)
		Tide.kind("Ball", { motion = false, buffer = 0.05 })
		local decl = opts.declare or declare
		decl(Tide)
		Tide.start({ players = true })
		local chars, cts = {}, {}
		for i = 1, opts.players or 2 do
			chars[i] = world:spawnCharacter(world:addPlayer(), CFrame.new(i * 10, 3, 0))
		end
		for i = 1, opts.players or 2 do
			cts[i] = T.clientTide(world, i)
			if opts.clientSchema ~= false then
				decl(cts[i])
			end
			cts[i].start()
		end
		local ball = world:spawnModel("ball", CFrame.new(0, 3, 0), true)
		Tide.add(ball, "Ball")
		local function frame(n)
			for _ = 1, n or 1 do
				world:frame(DT)
			end
		end
		frame(30)
		return world, Tide, ball, chars, cts, frame
	end

	local function f32(v: number): number
		local b = buffer.create(4)
		buffer.writef32(b, 0, v)
		return buffer.readf32(b, 0)
	end

	local function sameCF(a, b, tolPos, tolRot): boolean
		if T.dist(a.Position, b.Position) > tolPos then
			return false
		end
		local la, lb = a.LookVector, b.LookVector
		local ua, ub = a.UpVector, b.UpVector
		return T.dist(la, lb) < tolRot and T.dist(ua, ub) < tolRot
	end

	T.test("vector and cframe fields and payloads: set, fire, get as drawn, history, peek", function()
		local world, Tide, ball, _, cts, frame = setup()
		local view = world:replica(1, ball)
		local log = {}
		for _, name in { "Spin", "Rest", "Hit", "Placed" } do
			cts[1].changed(view, name, function(value, old, t)
				table.insert(log, { name = name, value = value, old = old, t = t })
			end)
		end
		local spin = Vector3.new(12.125, -300.5, 0.333)
		local rest = CFrame.new(10.25, 1.5, -77.125) * CFrame.Angles(0.3, -1.2, 2.0)
		local t1 = world.now
		Tide.set(ball, "Spin", spin)
		Tide.set(ball, "Rest", rest)
		Tide.fire(ball, "Hit", Vector3.new(-1, 2.5, 1e6))
		Tide.fire(ball, "Placed", rest)
		-- the server keeps what clients decode
		local sSpin = Tide.get(ball, "Spin")
		T.check(sSpin.X == f32(12.125) and sSpin.Y == f32(-300.5) and sSpin.Z == f32(0.333), "vector on the f32 grid")
		local sRest = Tide.get(ball, "Rest")
		T.check(sameCF(sRest, rest, 1e-4, 0.004), "cframe within the packed rotation's precision")
		frame(30)
		local cSpin = cts[1].get(view, "Spin")
		T.check(cSpin == sSpin, "client vector = server vector")
		local cRest = cts[1].get(view, "Rest")
		T.check(sameCF(cRest, sRest, 1e-9, 1e-9), "client cframe = server cframe (same quantization)")
		local ht, hit = cts[1].get(view, "Hit")
		T.near(ht, t1, 0.00051)
		T.check(hit.X == -1 and hit.Y == 2.5 and hit.Z == 1e6, "vector payload")
		local _, placed = cts[1].get(view, "Placed")
		T.check(sameCF(placed, sRest, 1e-9, 1e-9), "cframe payload")
		T.eq(#log, 4, "one change each")
		for _, e in log do
			T.near(e.t, t1, 0.00051)
		end
		-- back to nil; history on the server
		local t2 = world.now
		Tide.set(ball, "Rest", nil)
		Tide.set(ball, "Spin", nil)
		frame(30)
		T.eq(cts[1].get(view, "Rest"), nil)
		T.eq(cts[1].get(view, "Spin"), nil)
		T.check(sameCF(Tide.stateAt(ball, "Rest", t2 - 0.01), sRest, 1e-9, 1e-9), "stateAt before the reset")
		T.eq(Tide.stateAt(ball, "Rest", t2 + 0.01), nil)
		-- validation
		T.check(not pcall(Tide.set, ball, "Spin", 5), "a vector must be a Vector3")
		T.check(not pcall(Tide.set, ball, "Spin", Vector3.new(0 / 0, 0, 0)), "no NaN")
		T.check(not pcall(Tide.set, ball, "Rest", Vector3.new(1, 2, 3)), "a cframe must be a CFrame")
		T.check(not pcall(Tide.fire, ball, "Placed"), "a cframe payload is required")
		T.check(not pcall(Tide.state, "X", { A = { type = "cframe", default = CFrame.new() } }), "cframe fields have no default")
		T.eq(cts[1].stats().stateBad, 0)
	end)

	T.test("\"vector\" and \"pos\" are one type: same checksum, same bytes", function()
		local world = T.world()
		local Schema = T.module(world, "Shared", "StateSchema")
		local a = Schema.build("K", { V = "vector", E = { type = "event", payload = "vector" } })
		local b = Schema.build("K", { V = "pos", E = { type = "event", payload = "pos" } })
		T.eq(a.checksum, b.checksum)
		T.eq(a.fields[2].code, b.fields[2].code)
		T.eq(a.fields[2].type, "pos")
	end)

	T.test("a kick: one event with position, velocity, kicker, kind, time; frozen table at the body's time", function()
		local world, Tide, ball, chars, cts, frame = setup()
		local view = world:replica(2, ball)
		local got = {}
		cts[2].changed(view, "Kick", function(payload, old, t)
			table.insert(got, { payload = payload, t = t, clock = cts[2].timeOf(view), old = old })
		end)
		local stamp = world.now - 0.02
		local pose = CFrame.new(1, 2, 3) * CFrame.Angles(0, 1, 0)
		Tide.fire(ball, "Kick", {
			Position = Vector3.new(10.5, 1, -3.25),
			Velocity = Vector3.new(80, 22, -5.5),
			By = chars[1],
			Kind = "shot",
			PressAt = stamp - 0.12,
			Power = 0.75,
			Curve = -300,
			First = true,
			Pose = pose,
		}, stamp)
		-- the server's own copy: frozen, refs as models
		local st, sp = Tide.get(ball, "Kick")
		T.near(st, stamp, 0.00051)
		T.check(table.isfrozen(sp), "frozen on the server")
		T.eq(sp.By, chars[1])
		T.eq(sp.Kind, "shot")
		T.near(sp.PressAt, stamp - 0.12, 0.00051, "time member on the 0.5 ms grid of the fire's stamp")
		frame(30)
		T.eq(#got, 1, "fired once")
		local e = got[1]
		local p = e.payload
		T.check(table.isfrozen(p), "frozen on the client")
		T.eq(e.old, nil)
		T.near(e.t, stamp, 0.00051)
		T.check(e.clock >= e.t - 1e-9, "applied when the ball's clock reached the stamp")
		T.check(p.Position == Vector3.new(10.5, 1, -3.25), "position")
		T.check(p.Velocity == Vector3.new(80, 22, -5.5), "velocity")
		T.eq(p.By, world:replica(2, chars[1]), "the kicker, as this client's model")
		T.eq(p.Kind, "shot")
		T.near(p.PressAt, sp.PressAt, 1e-9, "the server's time")
		T.eq(p.Power, 0.75)
		T.eq(p.Curve, -300)
		T.eq(p.First, true)
		T.check(sameCF(p.Pose, sp.Pose, 1e-9, 1e-9), "cframe member")
		-- get: the latest fire
		local gt, gp = cts[2].get(view, "Kick")
		T.near(gt, stamp, 0.00051)
		T.eq(gp.Kind, "shot")
		T.eq(gp.By, world:replica(2, chars[1]))
		-- members left out are their type's default (false, 0, nil)
		Tide.fire(ball, "Kick", { Kind = "pass" })
		frame(30)
		T.eq(#got, 2)
		p = got[2].payload
		T.eq(p.Kind, "pass")
		T.eq(p.Position, nil)
		T.eq(p.By, nil)
		T.eq(p.PressAt, nil, "a time left out is nil")
		T.eq(p.Power, 0)
		T.eq(p.First, false)
		T.eq(p.Pose, nil)
		-- server history of fires
		local ht, hp = Tide.stateAt(ball, "Kick", stamp + 0.001)
		T.near(ht, stamp, 0.00051)
		T.eq(hp.Kind, "shot")
		-- bad payloads
		T.check(not pcall(Tide.fire, ball, "Kick"), "a members payload is required")
		T.check(not pcall(Tide.fire, ball, "Kick", 5), "not a table")
		T.check(not pcall(Tide.fire, ball, "Kick", { Nope = 1 }), "unknown member")
		T.check(not pcall(Tide.fire, ball, "Kick", { Kind = "volley" }), "enum member value")
		T.check(not pcall(Tide.fire, ball, "Kick", { Curve = 1e6 }), "i16 member range")
		T.check(not pcall(Tide.fire, ball, "Kick", { By = world:spawnModel("x", CFrame.new()) }), "ref member must be an entity")
		T.check(not pcall(Tide.fire, ball, "Kick", { Position = 3 }), "pos member type")
		frame(10)
		T.eq(#got, 2, "nothing fired by the bad calls")
		T.eq(cts[2].stats().stateBad, 0)
		T.eq(Tide.stats().errors, 0)
	end)

	T.test("ref members: an entity that goes reads nil (server, queued and applied on clients); slot reuse stays nil", function()
		local world, Tide, ball, chars, cts, frame = setup({ players = 3 })
		local view = world:replica(1, ball)
		local bot = world:spawnModel("bot", CFrame.new(5, 3, 5), true)
		local handle = Tide.add(bot, "Bot")
		frame(20)
		local got = {}
		cts[1].changed(view, "Kick", function(payload)
			table.insert(got, payload)
		end)
		Tide.fire(ball, "Kick", { By = handle, Kind = "pass" }) -- a handle works as a ref
		frame(30)
		T.eq(got[1].By, world:replica(1, bot), "applied with the model")
		handle:remove()
		frame(10)
		local _, sp = Tide.get(ball, "Kick")
		T.eq(sp.By, nil, "server: the removed entity reads nil")
		T.eq(sp.Kind, "pass", "the other members stay")
		T.check(table.isfrozen(sp))
		local _, cp = cts[1].get(view, "Kick")
		T.eq(cp.By, nil, "client: nil once the entity is gone")
		T.eq(cp.Kind, "pass")
		-- the slot is reused by another entity: the old ref does not point at it
		local bot2 = world:spawnModel("bot2", CFrame.new(6, 3, 6), true)
		Tide.add(bot2, "Bot")
		frame(40)
		_, cp = cts[1].get(view, "Kick")
		T.eq(cp.By, nil, "still nil after the slot was reused")
		-- removed while the change is still queued on the client (stamped ahead of its clock)
		local bot3 = world:spawnModel("bot3", CFrame.new(7, 3, 7), true)
		local h3 = Tide.add(bot3, "Bot")
		frame(20)
		cts[1].clock(view, function(now)
			return now - 0.5 -- this client draws the ball half a second behind: changes wait in its queue
		end)
		frame(40)
		local fired = #got
		Tide.fire(ball, "Kick", { By = bot3, Kind = "shot" })
		frame(10) -- arrived, queued
		T.eq(#got, fired, "still queued")
		h3:remove()
		frame(40)
		T.eq(#got, fired + 1, "fired when the clock reached it")
		T.eq(got[#got].Kind, "shot", "the queued kick still fired")
		T.eq(got[#got].By, nil, "without the entity that left meanwhile")
		-- a player kicker, on a third client
		Tide.fire(ball, "Kick", { By = chars[2], Kind = "header" })
		frame(30)
		local _, p3 = cts[3].get(world:replica(3, ball), "Kick")
		T.eq(p3.By, world:replica(3, chars[2]))
		T.eq(cts[1].stats().stateBad + cts[3].stats().stateBad, 0)
	end)

	T.test("schema round trip: members reach a client that declared nothing; 9 and 17 members widen the presence bits", function()
		local big = {}
		for i = 1, 17 do
			big[string.format("M%02d", i)] = if i % 2 == 0 then "u8" else "pos"
		end
		local nine = {}
		for i = 1, 9 do
			nine["N" .. i] = "u16"
		end
		local function decl(Tide)
			Tide.state("Ball", {
				Kick = { type = "event", payload = KICK },
				Big = { type = "event", payload = big },
				Nine = { type = "event", payload = nine },
				One = { type = "event", payload = { Only = "bool" } },
			})
		end
		local world, Tide, ball, chars, cts, frame = setup({ declare = decl, clientSchema = false })
		local server = T.module(world, "Shared", "StateSchema").byKind.Ball
		local StateApply = T.clientModule(world, 1, "Client", "StateApply")
		local Kinds = T.clientModule(world, 1, "Shared", "Kinds")
		local got = StateApply.schemas[Kinds.byName.Ball.id]
		T.check(got ~= nil, "the client has the server's schema")
		T.eq(got.checksum, server.checksum)
		for i, f in server.fields do
			local g = got.fields[i]
			T.eq(g.name, f.name)
			T.eq(g.payload, f.payload)
			local fm, gm = f.payloadField.members, g.payloadField.members
			T.eq(#gm, #fm, f.name .. " member count")
			for k, m in fm do
				T.eq(gm[k].name, m.name)
				T.eq(gm[k].code, m.code)
				T.eq(gm[k].values and table.concat(gm[k].values, ","), m.values and table.concat(m.values, ","))
			end
			T.eq(g.payloadField.refMembers ~= nil, f.payloadField.refMembers ~= nil)
		end
		local view = world:replica(1, ball)
		local payload = {}
		for i = 1, 17 do
			if i % 3 ~= 0 then
				payload[string.format("M%02d", i)] = if i % 2 == 0 then i else Vector3.new(i, 0, -i)
			end
		end
		Tide.fire(ball, "Big", payload)
		Tide.fire(ball, "Nine", { N9 = 65535, N1 = 1 })
		Tide.fire(ball, "One", { Only = true })
		Tide.fire(ball, "Kick", { By = chars[2], Velocity = Vector3.new(1, 2, 3), Kind = "header" })
		frame(30)
		local _, b = cts[1].get(view, "Big")
		for i = 1, 17 do
			local name = string.format("M%02d", i)
			if i % 2 == 0 then
				T.eq(b[name], if i % 3 ~= 0 then i else 0, name)
			elseif i % 3 ~= 0 then
				T.check(b[name] == Vector3.new(i, 0, -i), name)
			else
				T.eq(b[name], nil, name)
			end
		end
		local _, n = cts[1].get(view, "Nine")
		T.eq(n.N9, 65535)
		T.eq(n.N1, 1)
		T.eq(n.N5, 0)
		local _, o = cts[1].get(view, "One")
		T.eq(o.Only, true)
		local _, k = cts[1].get(view, "Kick")
		T.eq(k.By, world:replica(1, chars[2]))
		T.eq(k.Kind, "header")
		T.eq(cts[1].stats().stateBad, 0)
		for _, w in world.warnings do
			T.check(not string.find(w, "differs", 1, true), "no declaration on the client: nothing to warn about")
		end
	end)

	T.test("declaration errors for members; a differing member list is a differing declaration", function()
		local world = T.world()
		local Tide = T.serverTide(world)
		local function bad(payload, why)
			T.check(not pcall(Tide.state, "K", { E = { type = "event", payload = payload } }), why)
		end
		bad({}, "no members")
		bad({ A = "nope" }, "unknown member type")
		bad({ A = "event" }, "an event is not a value")
		bad({ A = { type = "enum" } }, "enum member without values")
		bad({ A = { type = "u8", values = { "x" } } }, "values on a non-enum member")
		bad({ A = { type = "u8", default = 1 } }, "unknown member option")
		bad({ [1] = "u8" }, "member names are strings")
		bad({ A = { type = "event", payload = { B = "u8" } } }, "no nesting")
		local many = {}
		for i = 1, 33 do
			many["M" .. i] = "bool"
		end
		bad(many, "more than 32 members")
		T.check(not pcall(Tide.state, "K", { F = { type = "u8", payload = { A = "u8" } } }), "payload on a non-event field")
		T.check(not pcall(Tide.state, "K", { F = "struct" }), "members are for payloads only")
		local Schema = T.module(world, "Shared", "StateSchema")
		local a = Schema.build("K", { E = { type = "event", payload = { A = "u8", B = "pos" } } })
		local b = Schema.build("K", { E = { type = "event", payload = { A = "u8", B = "vector" } } })
		local c = Schema.build("K", { E = { type = "event", payload = { A = "u8", C = "pos" } } })
		local d = Schema.build("K", { E = { type = "event", payload = { A = "u16", B = "pos" } } })
		T.eq(a.checksum, b.checksum, "pos = vector")
		T.check(a.checksum ~= c.checksum, "another member name")
		T.check(a.checksum ~= d.checksum, "another member type")
	end)

	T.test("garbage: truncated and random member payloads and schemas never throw on clients", function()
		local world, Tide, ball, chars, cts, frame = setup()
		local view = world:replica(1, ball)
		local rep = world:replica(1, world.tideModule:FindFirstChild("TideR"))
		local CState = T.clientModule(world, 1, "Client", "State")
		local SState = T.module(world, "Server", "State")
		-- capture a real kick message and a real schema message, then replay every truncation
		local captured = {}
		local send = world._send
		world._send = function(self, remote, fromServer, target, ...)
			local a = ...
			if fromServer and rawget(remote, "ClassName") == "RemoteEvent" and type(a) == "buffer" then
				table.insert(captured, a)
			end
			return send(self, remote, fromServer, target, ...)
		end
		Tide.fire(ball, "Kick", {
			Position = Vector3.new(1, 2, 3),
			Velocity = Vector3.new(4, 5, 6),
			By = chars[2],
			Kind = "shot",
			PressAt = world.now,
			Pose = CFrame.new(1, 2, 3),
		})
		Tide.set(ball, "Rest", CFrame.new(9, 9, 9))
		frame(2)
		world._send = send
		T.check(#captured > 0, "captured the state message")
		local bad0 = CState.counters.stateBad
		for _, msg in captured do
			for n = 1, buffer.len(msg) - 1 do
				local cut = buffer.create(n)
				buffer.copy(cut, 0, msg, 0, n)
				rep.OnClientEvent:_fire(cut, {})
			end
		end
		T.check(CState.counters.stateBad > bad0, "truncations counted")
		-- random bytes behind plausible STATE headers for the ball
		math.randomseed(41)
		local slot = SState.bySlotModel[ball]
		for _ = 1, 500 do
			local n = math.random(16, 64)
			local b = buffer.create(n)
			for j = 0, n - 1 do
				buffer.writeu8(b, j, math.random(0, 255))
			end
			buffer.writeu8(b, 0, 30)
			buffer.writef64(b, 1, world.now)
			buffer.writeu16(b, 9, 1)
			buffer.writeu16(b, 11, slot)
			buffer.writei16(b, 13, 0)
			rep.OnClientEvent:_fire(b, {})
		end
		-- a schema whose member list is cut short or has bad types
		local Control = T.clientModule(world, 1, "Shared", "Control")
		local Schema = T.module(world, "Shared", "StateSchema")
		local w = Control.writer(256)
		Control.u8(w, 32)
		Control.u8(w, 1)
		Schema.writeSchema(w, Control.ensure, 99, Schema.build("K", { E = { type = "event", payload = KICK } }))
		local whole = Control.take(w)
		for n = 1, buffer.len(whole) - 1 do
			local cut = buffer.create(n)
			buffer.copy(cut, 0, whole, 0, n)
			rep.OnClientEvent:_fire(cut, {})
		end
		for at = 8, buffer.len(whole) - 1 do
			local mangled = buffer.create(buffer.len(whole))
			buffer.copy(mangled, 0, whole, 0)
			buffer.writeu8(mangled, at, 14) -- "members" where a member or field type goes: never nested
			rep.OnClientEvent:_fire(mangled, {})
			buffer.writeu8(mangled, at, 200)
			rep.OnClientEvent:_fire(mangled, {})
		end
		frame(30)
		-- the real state is intact and still flows
		Tide.fire(ball, "Kick", { Kind = "pass", By = chars[1] })
		frame(30)
		local _, p = cts[1].get(view, "Kick")
		T.eq(p.Kind, "pass")
		T.eq(p.By, world:replica(1, chars[1]))
		T.check(cts[1].get(view, "Rest") ~= nil)
		T.eq(Tide.stats().errors, 0)
	end)

	T.test("late joiner: the latest kick and a cframe field arrive with the snapshot", function()
		local world, Tide, ball, chars, _, frame = setup()
		Tide.fire(ball, "Kick", { Kind = "shot", By = chars[1], Velocity = Vector3.new(3, 2, 1) })
		Tide.set(ball, "Rest", CFrame.new(4, 5, 6))
		frame(30)
		world:spawnCharacter(world:addPlayer(), CFrame.new(40, 3, 0))
		local ct3 = T.clientTide(world, 3)
		declare(ct3)
		ct3.start()
		frame(40)
		local view = world:replica(3, ball)
		local rest = ct3.get(view, "Rest")
		T.check(rest ~= nil and T.dist(rest.Position, Vector3.new(4, 5, 6)) < 1e-6, "cframe field in the snapshot")
		T.eq(ct3.stats().stateBad, 0)
	end)
end
