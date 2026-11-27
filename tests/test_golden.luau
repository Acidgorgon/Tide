-- Byte compatibility: a game that uses none of the v0.5 features (velocity kinds, Tide.bump,
-- kind lock, cframe / struct state) sends exactly the bytes v0.4.2 sent. The scenario below was
-- run on v0.4.2 (4e94683) and every buffer fired on TideU and TideR, in both directions, was
-- hashed (FNV-1a over direction, remote class, length and bytes, in send order). The numbers
-- are that run's; they must only change when the wire format of an existing feature changes on
-- purpose.
return function(T)
	local DT = 1 / 60

	local GOLDEN = {
		calls = 2229,
		bytes = 88292,
		hash = 681985072,
	}

	local function run()
		local world = T.world({ latency = 0.035, jitter = 0.012, loss = 0.02, seed = 11, start = 1.7e9 })
		local calls, bytes, hash = 0, 0, 2166136261
		local function mix(v: number)
			hash = bit32.bxor(hash, v)
			hash = (hash * 16777619) % 4294967296
		end
		local send = world._send
		world._send = function(self, remote, fromServer, target, ...)
			for i = 1, select("#", ...) do
				local a = select(i, ...)
				if type(a) == "buffer" then
					calls += 1
					local n = buffer.len(a)
					bytes += n
					mix(if fromServer then 1 else 2)
					mix(if rawget(remote, "ClassName") == "UnreliableRemoteEvent" then 3 else 4)
					mix(n % 256)
					mix(n // 256)
					for k = 0, n - 1 do
						mix(buffer.readu8(a, k))
					end
				end
			end
			return send(self, remote, fromServer, target, ...)
		end

		local Tide = T.serverTide(world)
		Tide.kind("Guard", { rate = 20, rotation = "full", near = 40, far = 90, cull = 200, teleportDistance = 30 })
		Tide.kind("Flag", { motion = false, buffer = 0.1 })
		local fields = {
			Score = "u16",
			Until = "time",
			Target = "ref",
			Mode = { type = "enum", values = { "idle", "run", "shoot" } },
			Aim = "pos",
			Heading = "yaw",
			Hit = { type = "event", payload = "f32" },
			Ping = "event",
			Secret = { type = "bool", to = "owner" },
		}
		Tide.state("Player", fields)
		Tide.state("Guard", fields)
		Tide.state("Bot", fields)
		Tide.state("Flag", { Holder = "ref", Taken = { type = "event", payload = "pos" } })
		Tide.start({ players = true, ownerEase = true, ownerStart = "server" })

		local chars, cts = {}, {}
		for i = 1, 4 do
			local p = world:addPlayer()
			chars[i] = world:spawnCharacter(p, CFrame.new(i * 15, 3, 0))
		end
		for i = 1, 4 do
			cts[i] = T.clientTide(world, i)
			cts[i].state("Player", fields)
			cts[i].start()
		end
		local bots, handles = {}, {}
		for k = 1, 6 do
			bots[k] = world:spawnModel("bot" .. k, CFrame.new(k * 9, 3, 25), true)
			handles[k] = Tide.add(bots[k], if k % 2 == 0 then "Guard" else "Bot")
		end
		local npc = world:spawnModel("npc", CFrame.new(300, 3, 300), true)
		Tide.add(npc, "Npc")
		local flag = world:spawnModel("flag", CFrame.new(0, 3, 0), true)
		Tide.add(flag, "Flag")
		handles[2]:setOrigin(Vector3.new(4000, 0, 0))

		for f = 1, 240 do
			local t = world.now + DT
			for i = 1, 4 do
				local hrp = world:replica(i, chars[i].HumanoidRootPart)
				if hrp then
					hrp.CFrame = CFrame.new(i * 15 + 9 * math.sin(t * 1.1 + i), 3 + math.abs(math.sin(t * 2 + i)), 14 * math.cos(t * 0.8 + i))
						* CFrame.Angles(0, t + i, 0)
				end
			end
			for k = 1, 6 do
				if f < 100 or f > 150 or k > 3 then -- bots 1..3 rest for a while
					local bx = if k == 2 then 4000 else 0
					bots[k].HumanoidRootPart.CFrame = CFrame.new(bx + k * 9 + 5 * math.sin(t + k), 3, 25 + 60 * math.sin(t * 0.3 + k))
						* CFrame.Angles(0.2 * k, t * 0.5, 0.1)
				end
			end
			npc.HumanoidRootPart.CFrame = CFrame.new(300 + f * 0.05, 3, 300)
			if f % 7 == 0 then
				Tide.set(chars[1 + f % 4], "Score", f)
				Tide.set(bots[1 + f % 6], "Mode", ({ "idle", "run", "shoot" })[1 + f % 3])
			end
			if f % 11 == 0 then
				Tide.set(chars[2], "Until", world.now + 0.75)
				Tide.set(chars[3], "Target", chars[1 + f % 2])
				Tide.fire(chars[1], "Hit", f * 0.5, world.now - 0.03)
				Tide.fire(bots[4], "Ping")
				Tide.set(chars[4], "Secret", f % 2 == 0)
			end
			if f % 13 == 0 then
				Tide.set(bots[2], "Aim", Vector3.new(f, 1.5, -f))
				Tide.set(bots[3], "Heading", Vector3.new(math.cos(f), 0, math.sin(f)))
				Tide.set(flag, "Holder", chars[1 + f % 4])
				Tide.fire(flag, "Taken", Vector3.new(1, 2, f))
			end
			if f == 60 then
				handles[1]:teleport(CFrame.new(50, 3, 50))
			elseif f == 80 then
				Tide.handle(chars[2]):teleport(CFrame.new(-20, 3, 5), Vector3.new(1, 0, 0))
			elseif f == 120 then
				handles[5]:setOwner(world.players[1])
			elseif f == 170 then
				handles[5]:setOwner(nil)
			elseif f == 130 then
				handles[4]:markTeleport()
			elseif f == 140 then
				handles[6]:setAudience({ world.players[1], world.players[2] })
			elseif f == 190 then
				handles[6]:setAudience(nil)
				handles[3]:remove()
			elseif f == 200 then
				bots[6].HumanoidRootPart.CFrame = CFrame.new(900, 3, 900) -- culled for everyone, then back
			end
			if f >= 120 and f < 170 then
				local mine = world:replica(1, bots[5].HumanoidRootPart)
				if mine then
					mine.CFrame = CFrame.new(45 + math.sin(t * 2), 3, 25)
				end
			end
			world:frame(DT)
		end
		return calls, bytes, hash
	end

	T.test("no v0.5 feature in use: every byte on TideU and TideR is v0.4.2's", function()
		local calls, bytes, hash = run()
		if GOLDEN.calls == 0 then
			error(string.format("golden not recorded: calls = %d, bytes = %d, hash = %d", calls, bytes, hash))
		end
		T.eq(calls, GOLDEN.calls, "remote calls")
		T.eq(bytes, GOLDEN.bytes, "payload bytes")
		T.eq(hash, GOLDEN.hash, "hash of every payload")
	end)
end
