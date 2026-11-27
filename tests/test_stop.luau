-- The lost stop, as a game measured it on v0.5: a ball rolling at 25 studs/s stops dead in one
-- frame and stays exactly still (a set-piece placement, a reset). On a lossy link the packet
-- with the stop is lost now and then, and a receiver that projects past its newest sample runs
-- on until the next word about the ball. restRepeats says that word again on the next ticks.
--
-- Two readers of the client's buffer, both against the server's truth at the time they draw:
--   "tide"  the time Tide draws the entity at (Tide.timeOf: the kind's buffer behind the newest
--           sample), projecting past the newest sample for at most 0.1 s
--   "tight" a game's own renderer one frame behind arrivals (drawn at server time minus one-way
--           latency, jitter and a frame; projecting for at most that plus 0.1 s), as in the
--           report this test answers
--
-- tests/run.sh test_stop prints the long table (more settings, 1000 stops a row).
return function(T)
	local DT = 1 / 60
	local SPEED = 25
	local JITTER = 0.005
	local WINDOW = 0.4
	local REST, ROLL = 30, 20 -- frames at rest, then frames of each roll before its stop

	local function ballKind(restRepeats: number?, keepAlive: number)
		return {
			velocity = true,
			rotation = "full",
			rate = 60,
			keepAlive = keepAlive,
			near = math.huge,
			farEvery = 1,
			apply = "none",
			buffer = 0.1,
			restRepeats = restRepeats,
		}
	end

	-- One world: rest, then `stops` times a roll that ends in a dead stop and a rest long enough
	-- for both readers to draw the 0.4 s after it. Returns, per reader, the worst error in those
	-- windows and the number of stops whose window passed 0.25 studs; and what the server sent
	-- (bytes, packets) while rolling and in `restFrames` of steady rest at the end.
	local function run(o: any)
		local world = T.world({ latency = o.latency, jitter = JITTER, loss = o.loss, seed = o.seed, start = 1.7e9 })
		local Tide = T.serverTide(world)
		Tide.kind("Ball", ballKind(o.restRepeats, o.keepAlive))
		Tide.start({ players = false })
		world:addPlayer()
		local ct = T.clientTide(world, 1)
		ct.start()
		local sent = { roll = 0, rollPackets = 0, rest = 0, restPackets = 0, rollFrames = 0 }
		local phase = ""
		local send = world._send
		world._send = function(self, remote, fromServer, target, ...)
			local b = ...
			if fromServer and rawget(remote, "ClassName") == "UnreliableRemoteEvent" and type(b) == "buffer" then
				if phase == "roll" then
					sent.roll += buffer.len(b)
					sent.rollPackets += 1
				elseif phase == "rest" then
					sent.rest += buffer.len(b)
					sent.restPackets += 1
				end
			end
			return send(self, remote, fromServer, target, ...)
		end
		local model = world:spawnModel("ball", CFrame.new(0, 3, 0), false)
		Tide.add(model, "Ball")
		local root = model.HumanoidRootPart
		for _ = 1, REST do
			world:frame(DT)
		end
		local view = world:replica(1, model)
		local tight = o.latency + JITTER + DT + 0.0015
		local res = { tide = 0, tight = 0, tideOver = 0, tightOver = 0, delay = 0, delayN = 0, stops = o.stops or 1 }
		local x = 0
		for _ = 1, res.stops do
			-- the roll: SPEED along X, turning about Z as a ball of radius 1 does
			phase = "roll"
			for k = 1, ROLL do
				x += SPEED * DT
				root.CFrame = CFrame.new(x, 3, 0) * CFrame.Angles(0, 0, -x)
				if k < ROLL then
					root.AssemblyLinearVelocity = Vector3.new(SPEED, 0, 0)
					root.AssemblyAngularVelocity = Vector3.new(0, 0, -SPEED)
				else
					-- the stop: this frame's step moved it here and took its velocity
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
				end
				world:frame(DT)
			end
			sent.rollFrames += ROLL
			phase = ""
			-- from here the truth is x, for as long as the readers draw the window
			local tStop = world.now
			local tide, tightWorst = 0, 0
			for _ = 1, 150 do
				world:frame(DT)
				local td = ct.timeOf(view)
				local td2 = world.now - tight
				if td >= tStop and td <= tStop + WINDOW then
					local cf = ct.at(view, td, 0.1)
					if cf then
						tide = math.max(tide, math.abs(cf.X - x))
					end
					res.delay += world.now - td
					res.delayN += 1
				end
				if td2 >= tStop and td2 <= tStop + WINDOW then
					local cf = ct.at(view, td2, tight + 0.1)
					if cf then
						tightWorst = math.max(tightWorst, math.abs(cf.X - x))
					end
				end
				if td > tStop + WINDOW and td2 > tStop + WINDOW then
					break
				end
			end
			res.tide = math.max(res.tide, tide)
			res.tight = math.max(res.tight, tightWorst)
			if tide > 0.25 then
				res.tideOver += 1
			end
			if tightWorst > 0.25 then
				res.tightOver += 1
			end
		end
		if o.restFrames then
			-- (the copies of the stop were sent in the window above: this is the steady rest)
			phase = "rest"
			for _ = 1, o.restFrames do
				world:frame(DT)
			end
			phase = ""
		end
		res.repeats = ct.stats().repeats
		res.sentRepeats = Tide.stats().restRepeats
		res.errors = Tide.stats().errors + ct.stats().badPacket + ct.stats().applyErrors
		return res, sent
	end

	-- `seeds` worlds of `stops` stops each
	local function pool(o: any, seeds: number, stops: number)
		local res = { tide = 0, tight = 0, tideOver = 0, tightOver = 0, delay = 0, delayN = 0, errors = 0, stops = seeds * stops }
		o.stops = stops
		for seed = 1, seeds do
			o.seed = seed
			local w = run(o)
			res.tide = math.max(res.tide, w.tide)
			res.tight = math.max(res.tight, w.tight)
			res.tideOver += w.tideOver
			res.tightOver += w.tightOver
			res.delay += w.delay
			res.delayN += w.delayN
			res.errors += w.errors
		end
		res.delay /= math.max(res.delayN, 1)
		return res
	end

	local LONG = T.filter ~= nil and string.find(T.filter, "test_stop", 1, true) ~= nil
	local SEEDS = 100
	local STOPS = if LONG then 10 else 3

	T.test("a ball that stops dead on a lossy link: with restRepeats = 2 and keepAlive = 1 the stop arrives (100 seeds, 60 and 200 ms)", function()
		print(`    worst error (studs) in the 0.4 s after a dead stop from 25 studs/s, 60 Hz; {SEEDS} seeds of {STOPS} stops;`)
		print("    in brackets the stops whose window passed 0.25 studs; delay = how far behind the server Tide draws")
		print("    latency loss  restRepeats keepAlive | drawn by Tide  (delay)   | one frame behind arrivals")
		local configs = if LONG then { { 0, 0.1 }, { 0, 1 }, { 1, 1 }, { 2, 1 }, { 4, 1 } } else { { 0, 1 }, { 2, 1 } }
		local rows = {}
		for _, latency in { 0.06, 0.2 } do
			for _, loss in { 0, 0.1, 0.3 } do
				for _, cfg in configs do
					local seeds = if loss == 0 then 3 else SEEDS
					local r = pool({ latency = latency, loss = loss, restRepeats = cfg[1], keepAlive = cfg[2] }, seeds, STOPS)
					rows[`{latency}/{loss}/{cfg[1]}/{cfg[2]}`] = r
					print(
						string.format(
							"    %3d ms  %3d %%  %d           %-4s      | %5.2f  (%3d of %4d) %3.0f ms | %5.2f  (%3d of %4d)",
							latency * 1000,
							loss * 100,
							cfg[1],
							tostring(cfg[2]),
							r.tide,
							r.tideOver,
							r.stops,
							r.delay * 1000,
							r.tight,
							r.tightOver,
							r.stops
						)
					)
					T.eq(r.errors, 0)
				end
			end
		end
		for _, latency in { 0.06, 0.2 } do
			-- no loss: the stop is exact whatever the settings
			for _, cfg in configs do
				local r = rows[`{latency}/0/{cfg[1]}/{cfg[2]}`]
				T.check(r.tide < 0.05 and r.tight < 0.05, "no loss")
			end
			local with, without = rows[`{latency}/0.1/2/1`], rows[`{latency}/0.1/0/1`]
			-- 10 % loss, at the time Tide draws: under 0.25 studs after every stop
			T.check(with.tide < 0.25, `restRepeats = 2 at {latency * 1000} ms, 10 % loss: {with.tide}`)
			T.eq(with.tideOver, 0)
			-- without the repeats the same link loses a stop now and then (both of its samples:
			-- one stop in a hundred), and the ball runs on for the 0.1 s it may be projected
			T.check(without.tide > 1, "restRepeats = 0: the lost stop is there to be fixed: " .. without.tide)
			T.check(without.tideOver >= 1)
			-- the reader one frame behind arrivals: no stop is lost; what is left is the one frame
			-- it draws after two packets in a row were lost, when it is past its newest sample
			-- whatever is sent later (a frame of travel and the link's jitter at most; the same
			-- in mid flight, where projecting is right)
			T.check(with.tight < SPEED * (DT + JITTER), "one frame behind arrivals: " .. with.tight)
			T.check(with.tight < without.tight / 4, "against a lost stop without the repeats: " .. without.tight)
			-- 30 % loss: four copies are all lost in about one stop of 120
			local with30, without30 = rows[`{latency}/0.3/2/1`], rows[`{latency}/0.3/0/1`]
			T.check(with30.tideOver * 4 < without30.tideOver, `30 % loss: {with30.tideOver} against {without30.tideOver}`)
		end
	end)

	T.test("bytes of that ball: rolling at 60 Hz and at rest, with the keep-alive the repeats make affordable", function()
		print("    server to one client, one ball, packet headers (10 B) included")
		print("    restRepeats keepAlive | rolling B/s (packets/s) | at rest B/s (packets/s) | repeats sent")
		local got = {}
		for _, cfg in { { 0, 0.1 }, { 0, 1 }, { 2, 1 } } do
			local restSeconds = 20
			local w, sent = run({ latency = 0.06, loss = 0, seed = 1, restRepeats = cfg[1], keepAlive = cfg[2], stops = 3, restFrames = restSeconds * 60 })
			local rollSeconds = sent.rollFrames * DT
			local roll = sent.roll / rollSeconds
			local rest = sent.rest / restSeconds
			got[`{cfg[1]}/{cfg[2]}`] = { roll = roll, rest = rest, repeats = w.sentRepeats, seen = w.repeats }
			print(
				string.format(
					"    %d           %-4s      | %6.0f (%2.0f)             | %5.1f (%4.1f)            | %d",
					cfg[1],
					tostring(cfg[2]),
					roll,
					sent.rollPackets / rollSeconds,
					rest,
					sent.restPackets / restSeconds,
					w.sentRepeats
				)
			)
		end
		local chosen, old, bare = got["2/1"], got["0/0.1"], got["0/1"]
		T.eq(chosen.roll, bare.roll, "rolling: the repeats cost nothing")
		T.eq(chosen.rest, bare.rest, "the steady rest: the keep-alive alone")
		T.check(chosen.rest < 30, "under 30 B/s at rest: " .. chosen.rest)
		T.check(old.rest > 5 * chosen.rest, "a tenth of a second of keep-alive costs several times that")
		T.eq(chosen.repeats, 2 + 3 * 2, "two copies of the stop after the add, two after each roll")
		T.check(chosen.seen >= 3 * 2, "the client dropped each copy it had the original of")
		T.eq(bare.repeats, 0)
	end)
end
