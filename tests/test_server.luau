-- Server receive validation: bad packets never throw; owner, stamp, NaN/inf, speed, byte caps, teleport grants.
return function(T)
	local DT = 1 / 60

	local function setup(nPlayers)
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local State = T.module(world, "Server", "State")
		local Codec = T.module(world, "Shared", "Codec")
		local players, chars = {}, {}
		for i = 1, nPlayers do
			players[i] = world:addPlayer()
			chars[i] = world:spawnCharacter(players[i], CFrame.new(i * 10, 3, 0))
		end
		local remote = world.tideModule:FindFirstChild("TideU")
		local function send(i, b)
			world:replica(i, remote):FireServer(b)
		end
		local suspicious = {}
		Tide.onSuspicious(function(player, reason)
			table.insert(suspicious, { player = player, reason = reason })
		end)
		-- builds an upload: records = { {slot, stamp, x, y, z, yaw, flags} }
		local function upload(records)
			local b = buffer.create(2 + #records * 40)
			buffer.writeu8(b, 0, 2)
			buffer.writeu8(b, 1, #records)
			local pos = 2
			for _, r in records do
				buffer.writeu16(b, pos, r[1])
				buffer.writef64(b, pos + 2, r[2])
				pos = Codec.write(b, pos + 10, r[3], r[4], r[5], r[6] or 0, r[7] or 0, 0, 0, 0, 1)
			end
			local out = buffer.create(pos)
			buffer.copy(out, 0, b, 0, pos)
			return out
		end
		local function slotOf(model)
			return State.bySlotModel[model]
		end
		local function newest(model)
			local h = State.hist[slotOf(model)]
			local p = h.last % h.cap + 1
			return h.t[p], h.x[p], h.y[p], h.z[p], h.last
		end
		local function step(n)
			for _ = 1, n or 1 do
				world:frame(DT)
			end
		end
		return {
			world = world,
			Tide = Tide,
			State = State,
			players = players,
			chars = chars,
			send = send,
			upload = upload,
			slotOf = slotOf,
			newest = newest,
			step = step,
			suspicious = suspicious,
		}
	end

	T.test("garbage never throws and is counted", function()
		local s = setup(1)
		local remote = s.world.tideModule:FindFirstChild("TideU")
		local rep = s.world:replica(1, remote)
		math.randomseed(3)
		local junk = { nil, "hello", 42, true, {}, { 1, 2, 3 }, buffer.create(0), buffer.create(1) }
		for _, v in junk do
			rep:FireServer(v)
		end
		-- random buffers of random sizes, many with a valid tag
		for _ = 1, 300 do
			local n = math.random(0, 120)
			local b = buffer.create(n)
			for k = 0, n - 1 do
				buffer.writeu8(b, k, math.random(0, 255))
			end
			if n > 0 and math.random() < 0.6 then
				buffer.writeu8(b, 0, 2)
			end
			if n > 3 and math.random() < 0.5 then
				buffer.writeu16(b, 2, s.slotOf(s.chars[1]))
			end
			rep:FireServer(b)
			s.step(1)
		end
		-- a valid header with a lying count, and a truncated sample
		local good = s.upload({ { s.slotOf(s.chars[1]), s.world.now, 10, 3, 0 } })
		local lying = buffer.create(buffer.len(good))
		buffer.copy(lying, 0, good, 0, buffer.len(good))
		buffer.writeu8(lying, 1, 5)
		rep:FireServer(lying)
		local truncated = buffer.create(buffer.len(good) - 3)
		buffer.copy(truncated, 0, good, 0, buffer.len(truncated))
		rep:FireServer(truncated)
		-- control remote too
		local ctrl = s.world:replica(1, s.world.tideModule:FindFirstChild("TideR"))
		ctrl:FireServer(buffer.create(3))
		ctrl:FireServer("x")
		ctrl:FireServer(buffer.create(1000))
		s.step(3)
		local stats = s.Tide.stats()
		T.eq(stats.errors, 0, "handler never errored")
		T.check(stats.badPacket > 50, "bad packets counted: " .. stats.badPacket)
	end)

	T.test("owner check: a player cannot move someone else's entity", function()
		local s = setup(2)
		s.step(2)
		local victim = s.slotOf(s.chars[2])
		local beforeT, bx, _, _, beforeLast = s.newest(s.chars[2])
		s.send(1, s.upload({ { victim, s.world.now, 500, 3, 500 } }))
		s.step(3)
		local _, ax, _, _, afterLast = s.newest(s.chars[2])
		T.eq(afterLast, beforeLast, "no sample added")
		T.eq(ax, bx)
		T.check(s.Tide.stats().owner >= 1, "owner counter")
		local _ = beforeT
	end)

	T.test("stamp clamp and monotonic order", function()
		local s = setup(1)
		local slot = s.slotOf(s.chars[1])
		local Config = T.module(s.world, "Shared", "Config")
		-- far future -> clamped to arrival + MaxAhead
		local sendT = s.world.now
		s.send(1, s.upload({ { slot, sendT + 100, 10.5, 3, 0 } }))
		s.step(2)
		local t1, x1 = s.newest(s.chars[1])
		T.near(x1, 10.5, 1e-9)
		local arrival = sendT + 0.02 + DT -- delivered at the first frame at/after latency
		T.check(t1 <= arrival + Config.MaxAhead + DT + 1e-9 and t1 > sendT, "future stamp clamped, got " .. (t1 - sendT))
		-- older than newest -> dropped
		local before = s.Tide.stats().stamp
		s.send(1, s.upload({ { slot, t1 - 0.001, 10.6, 3, 0 } }))
		s.step(3)
		local t2, x2 = s.newest(s.chars[1])
		T.eq(t2, t1)
		T.eq(x2, x1)
		T.eq(s.Tide.stats().stamp, before + 1, "monotonic drop counted")
		-- far past -> clamped to arrival - MaxBackdate, which is still older than newest -> dropped
		s.send(1, s.upload({ { slot, s.world.now - 50, 10.7, 3, 0 } }))
		s.step(3)
		local t3 = s.newest(s.chars[1])
		T.eq(t3, t1, "backdated stamp dropped")
		-- normal increasing stamps accepted, several per packet (at least half an interval apart)
		local now = s.world.now
		s.send(1, s.upload({ { slot, now - 0.02, 10.8, 3, 0 }, { slot, now, 10.9, 3, 0 } }))
		s.step(3)
		local t4, x4 = s.newest(s.chars[1])
		T.near(t4, now, 1e-9)
		T.near(x4, 10.90625, 1e-9) -- quantized to 1/64
		-- closer than half an upload interval: dropped
		local before2 = s.Tide.stats().spacing
		s.send(1, s.upload({ { slot, now + 0.004, 10.95, 3, 0 } }))
		s.step(2)
		T.eq(s.newest(s.chars[1]), t4, "too close to the previous sample")
		T.eq(s.Tide.stats().spacing, before2 + 1)
	end)

	T.test("NaN / inf positions and NaN stamps are dropped", function()
		local s = setup(1)
		local slot = s.slotOf(s.chars[1])
		s.step(2)
		local _, _, _, _, last0 = s.newest(s.chars[1])
		local now = s.world.now
		s.send(1, s.upload({ { slot, now, 0 / 0, 3, 0 } }))
		s.send(1, s.upload({ { slot, now + 0.001, math.huge, 3, 0 } }))
		s.send(1, s.upload({ { slot, now + 0.002, 1, -math.huge, 0 } }))
		s.send(1, s.upload({ { slot, 0 / 0, 10, 3, 0 } }))
		s.step(3)
		local _, _, _, _, last1 = s.newest(s.chars[1])
		T.eq(last1, last0, "nothing accepted")
		T.eq(s.Tide.stats().nan, 4)
	end)

	T.test("speed check drops jumps, rises and falls; persistent rejection resyncs the owner", function()
		local s = setup(1)
		local slot = s.slotOf(s.chars[1])
		s.step(2)
		-- legit: 20 studs/s, one sample per frame
		local x = 10
		for _ = 1, 10 do
			x += 20 * DT
			s.send(1, s.upload({ { slot, s.world.now, x, 3, 0 } }))
			s.step(1)
		end
		s.step(3)
		local _, x1 = s.newest(s.chars[1])
		T.near(x1, x, 1 / 64)
		T.eq(s.Tide.stats().speed, 0, "legit motion accepted")
		-- 200 studs in one frame
		s.send(1, s.upload({ { slot, s.world.now, x + 200, 3, 0, 0, 1 } })) -- teleport flag without a server teleport
		s.step(2)
		local _, x2 = s.newest(s.chars[1])
		T.near(x2, x1, 1 / 64, "jump dropped")
		T.eq(s.Tide.stats().speed, 1)
		T.check(#s.suspicious >= 1 and s.suspicious[1].reason == "speed", "hook called")
		-- vertical: falling 4 studs is fine, rising 4 studs within one frame
		-- (240 studs/s > maxRise 60) is not
		s.step(1)
		local t3 = s.world.now
		s.send(1, s.upload({ { slot, t3, x1, 3 - 4, 0 } }))
		s.step(3)
		local _, _, y3 = s.newest(s.chars[1])
		T.near(y3, -1, 1 / 64, "fall accepted")
		s.send(1, s.upload({ { slot, t3 + DT, x1, -1 + 4, 0 } }))
		s.step(3)
		local _, _, y4 = s.newest(s.chars[1])
		T.near(y4, -1, 1 / 64, "rise dropped")
		-- a client that keeps uploading an unreachable position is teleported back
		-- to the server's pose after Config.SpeedResync (no permanent lock-out)
		local Config = T.module(s.world, "Shared", "Config")
		for _ = 1, math.ceil(Config.SpeedResync * 60) + 5 do
			s.send(1, s.upload({ { slot, s.world.now, x1 + 500, 3, 0 } }))
			s.step(1)
		end
		T.check(s.State.tpPending[slot], "resync teleport sent")
		local h = s.State.hist[slot]
		T.eq(h.fl[h.last % h.cap + 1], 1, "server pose re-sent as a teleport")
		T.near(h.x[h.last % h.cap + 1], x1, 1 / 64)
	end)

	T.test("server teleport: target held; only the owner's flagged sample near it is accepted", function()
		local s = setup(1)
		local slot = s.slotOf(s.chars[1])
		s.step(2)
		local handle = s.Tide.handle(s.chars[1])
		handle:teleport(CFrame.new(400, 3, 400))
		-- the target is in history right away, flagged (receivers snap, the lock holds it)
		local t0, x0, _, z0 = s.newest(s.chars[1])
		T.near(x0, 400, 1e-9)
		T.near(z0, 400, 1e-9)
		local h = s.State.hist[slot]
		T.eq(h.fl[h.last % h.cap + 1], 1, "target stored as teleport")
		s.step(1)
		local now = s.world.now
		-- pre-teleport sample still in flight: dropped
		s.send(1, s.upload({ { slot, now, 10.2, 3, 0 } }))
		-- unflagged sample at the target: dropped
		s.send(1, s.upload({ { slot, now + 0.001, 400, 3, 400, 0, 0 } }))
		-- flagged, but far from the target: dropped
		s.send(1, s.upload({ { slot, now + 0.002, 300, 3, 400, 0, 1 } }))
		s.step(3)
		local t1, x1 = s.newest(s.chars[1])
		T.eq(t1, t0, "nothing accepted while unacknowledged")
		T.near(x1, 400, 1e-9)
		T.eq(s.Tide.stats().teleportWait, 3, "counted as teleportWait")
		T.eq(s.Tide.stats().speed, 0, "not speed violations")
		-- flagged sample near the target: accepted (no speed check), stored unflagged
		now = s.world.now
		s.send(1, s.upload({ { slot, now, 401, 3, 401, 0, 1 } }))
		s.step(3)
		local _, x2 = s.newest(s.chars[1])
		T.near(x2, 401, 1e-9)
		T.eq(h.fl[h.last % h.cap + 1], 0, "ack stored as a normal sample")
		T.check(not s.State.tpPending[slot], "teleport acknowledged")
		-- the acknowledgement is consumed: another flagged jump is speed checked
		now = s.world.now
		s.send(1, s.upload({ { slot, now, 900, 3, 900, 0, 1 } }))
		s.step(3)
		local _, x3 = s.newest(s.chars[1])
		T.near(x3, 401, 1e-9)
		T.eq(s.Tide.stats().speed, 1)
		-- server velocity: a teleport sample as newest reports the teleport velocity
		handle:teleport(CFrame.new(0, 3, 0), Vector3.new(5, 0, -2))
		local v = s.Tide.velocity(s.chars[1])
		T.near(v.X, 5, 1e-9)
		T.near(v.Z, -2, 1e-9)
	end)

	T.test("ignored teleport: resent every TeleportRetry, onSuspicious after TeleportTries, target held", function()
		local s = setup(1)
		local slot = s.slotOf(s.chars[1])
		local Config = T.module(s.world, "Shared", "Config")
		s.step(2)
		-- count TELEPORT messages reaching the (never started) client
		local remoteR = s.world.tideModule:FindFirstChild("TideR")
		local rep = s.world:replica(1, remoteR)
		local sends, withVel = 0, 0
		rep.OnClientEvent:Connect(function(b)
			if buffer.len(b) > 0 and buffer.readu8(b, 0) == 13 then
				sends += 1
				T.near(buffer.readf32(b, 3), 50, 1e-4)
				if buffer.readu8(b, 31) == 1 then
					withVel += 1
					T.near(buffer.readf32(b, 32), 7, 1e-4)
				end
			end
		end)
		s.Tide.handle(s.chars[1]):teleport(CFrame.new(50, 3, 0), Vector3.new(7, 0, 0))
		local retries = Config.TeleportTries + 1
		for _ = 1, math.ceil(retries * Config.TeleportRetry * 60) + 5 do
			-- the owner keeps uploading its old position
			s.send(1, s.upload({ { slot, s.world.now, 10, 3, 0 } }))
			s.step(1)
		end
		T.check(sends >= Config.TeleportTries + 1, "resent: " .. sends)
		T.eq(withVel, sends, "velocity in every send")
		local reasons = {}
		for _, e in s.suspicious do
			reasons[e.reason] = (reasons[e.reason] or 0) + 1
		end
		T.eq(reasons.teleportIgnored, 1, "reported once")
		T.eq(s.Tide.stats().teleportIgnored, 1)
		local _, x = s.newest(s.chars[1])
		T.near(x, 50, 1e-9, "server copy held at the target")
		-- the locker (root mode) holds the server character there too
		T.near(s.chars[1].HumanoidRootPart.CFrame.X, 50, 1e-6)
		-- a late acknowledgement still ends it
		s.send(1, s.upload({ { slot, s.world.now, 50, 3, 0, 0, 1 } }))
		s.step(2)
		T.check(not s.State.tpPending[slot], "acknowledged late")
		T.eq(s.State.tpCount, 0)
	end)

	T.test("per-player byte caps (per second and per frame)", function()
		local s = setup(1)
		local slot = s.slotOf(s.chars[1])
		s.step(1)
		local Config = T.module(s.world, "Shared", "Config")
		-- one frame: 4 packets of 16 records (~290 B each) > 1024 B per frame
		local now = s.world.now
		local k = 0
		for _ = 1, 4 do
			local recs = {}
			for _ = 1, 16 do
				k += 1
				table.insert(recs, { slot, now - 0.5 + k * 0.001, 10, 3, 0 })
			end
			s.send(1, s.upload(recs))
		end
		s.step(2)
		T.check(s.Tide.stats().rate >= 1, "per-frame cap hit")
		-- sustained flood beyond 8 KB/s
		local before = s.Tide.stats().rate
		for f = 1, 60 do
			for _ = 1, 3 do
				local recs = {}
				for _ = 1, 16 do
					k += 1
					table.insert(recs, { slot, s.world.now - 0.4 + k * 0.0001, 10, 3, 0 })
				end
				s.send(1, s.upload(recs))
			end
			s.step(1)
			local _ = f
		end
		local stats = s.Tide.stats()
		T.check(stats.rate > before + 30, "per-second cap hit: " .. (stats.rate - before))
		local _ = Config
	end)

	T.test("removing a player removes the character and its slot is quarantined", function()
		local s = setup(2)
		s.step(2)
		local slot = s.slotOf(s.chars[1])
		s.world:removePlayer(s.players[1])
		s.step(1)
		T.eq(s.State.index[slot], nil, "slot freed")
		T.eq(s.Tide.latest(s.chars[1]), nil)
		-- a new entity does not reuse the slot right away
		local m = s.world:spawnModel("Npc", CFrame.new(0, 3, 0), true)
		s.Tide.add(m, "Npc")
		T.check(s.slotOf(m) ~= slot, "quarantined slot not reused")
		-- destroying a model removes its entity
		m:Destroy()
		T.eq(s.slotOf(m), nil, "Destroying removes the entity")
	end)
end
