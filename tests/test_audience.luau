-- v0.4 interest: Tide.focus (receivers without a character entity) and per-entity audiences
-- (handle:setAudience): tiers, what each receiver gets, state on entering, bytes per player.
return function(T)
	local DT = 1 / 60

	local function setup(opts)
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.start(opts or { players = false })
		local State = T.module(world, "Server", "State")
		local s = { world = world, Tide = Tide, State = State, cts = {}, players = {}, counts = {} }
		local remote = world.tideModule:FindFirstChild("TideU")
		-- receiver i: count relay records per slot
		function s.addPlayer()
			local i = #world.players + 1
			s.players[i] = world:addPlayer()
			local counts = {}
			s.counts[i] = counts
			world:replica(i, remote).OnClientEvent:Connect(function(b)
				local n = buffer.len(b)
				local pos = 10
				local Codec = T.module(world, "Shared", "Codec")
				local wide = buffer.readu8(b, 1) % 2 == 1
				while pos < n do
					local slot
					if wide then
						slot = buffer.readu16(b, pos)
						pos += 2
					else
						slot = buffer.readu8(b, pos)
						pos += 1
					end
					pos = Codec.readDt(b, pos)
					pos += Codec.sizeAt(b, pos)
					counts[slot] = (counts[slot] or 0) + 1
				end
			end)
			s.cts[i] = T.clientTide(world, i)
			s.cts[i].start()
			return i
		end
		function s.step(n, each)
			for f = 1, n or 1 do
				if each then
					each(f)
				end
				world:frame(DT)
			end
		end
		return s
	end

	T.test("focus: a receiver without a character gets tiers around its focus (point, part, cleared)", function()
		local s = setup()
		s.addPlayer()
		local rx = s.State.rx[s.players[1]]
		local near = s.world:spawnModel("near", CFrame.new(1000, 3, 0), true)
		local far = s.world:spawnModel("far", CFrame.new(2000, 3, 0), true)
		s.Tide.add(near, "Npc")
		s.Tide.add(far, "Npc")
		s.step(10)
		local sn, sf = s.State.bySlotModel[near], s.State.bySlotModel[far]
		T.eq(rx.tier[sn], 3, "no position: far (v0.3)")
		T.eq(rx.tier[sf], 3)
		s.Tide.focus(s.players[1], Vector3.new(1010, 3, 0))
		T.eq(rx.tier[sn], 1, "near the focus point at once")
		T.eq(rx.tier[sf], 4, "beyond the Npc cull from the focus")
		-- a part: followed as it moves
		local ball = T.Mock.newInstance("Part", "Ball")
		ball.CFrame = CFrame.new(1990, 3, 0)
		ball.Parent = s.world.server.Workspace
		s.Tide.focus(s.players[1], ball)
		T.eq(rx.tier[sf], 1)
		T.eq(rx.tier[sn], 4)
		ball.CFrame = CFrame.new(1150, 3, 0)
		s.step(10)
		T.eq(rx.tier[sn], 2, "follows the part (mid)")
		-- the part is destroyed: its last position stays the centre
		ball.Parent = nil
		s.step(10)
		T.eq(rx.tier[sn], 2)
		-- a character entity wins over the focus
		local char = s.world:spawnCharacter(s.players[1], CFrame.new(2005, 3, 0))
		s.Tide.add(char, "Player", s.players[1])
		s.step(10)
		T.eq(rx.tier[sf], 1, "near its character")
		T.eq(rx.tier[sn], 4)
		s.Tide.remove(char)
		s.Tide.focus(s.players[1], nil)
		s.step(10)
		T.eq(rx.tier[sf], 1, "no focus: the character's last position (v0.3)")
		local ok = pcall(s.Tide.focus, s.players[1], "nowhere")
		T.check(not ok, "bad focus target rejected")
	end)

	T.test("audience: receivers outside get nothing; list, set, function, nil; owner unaffected", function()
		local s = setup()
		for i = 1, 3 do
			s.addPlayer()
			s.Tide.focus(s.players[i], Vector3.new(0, 3, 0)) -- near: every sample
		end
		local m = s.world:spawnModel("bot", CFrame.new(0, 3, 0), true)
		local h = s.Tide.add(m, "Bot")
		local slot = s.State.bySlotModel[m]
		local function moving(f)
			m.HumanoidRootPart.CFrame = CFrame.new(f * 0.1, 3, 0)
		end
		s.step(30, moving)
		for i = 1, 3 do
			T.check((s.counts[i][slot] or 0) > 10, "everyone by default")
		end
		local function window(n)
			local before = {}
			for i = 1, 3 do
				before[i] = s.counts[i][slot] or 0
			end
			s.step(n, moving)
			local got = {}
			for i = 1, 3 do
				got[i] = (s.counts[i][slot] or 0) - before[i]
			end
			return got
		end
		h:setAudience({ s.players[1], s.players[3] })
		s.step(5, moving)
		local got = window(30)
		T.check(got[1] >= 14 and got[3] >= 14, "in the list")
		T.eq(got[2], 0, "outside the list: nothing")
		T.eq(s.State.rx[s.players[2]].tier[slot], 4, "culled for player 2")
		T.eq(s.cts[2].drawn(s.world:replica(2, m)) ~= nil, true, "player 2 holds its last drawn pose")
		-- a set
		h:setAudience({ [s.players[2]] = true })
		s.step(5, moving)
		got = window(30)
		T.eq(got[1], 0)
		T.check(got[2] >= 14, "set member")
		-- a function, re-asked every InterestEvery
		for i = 1, 3 do
			s.players[i]:SetAttribute("Venue", if i == 3 then "A" else "B")
		end
		local calls = 0
		local function inVenueA(player)
			calls += 1
			return player:GetAttribute("Venue") == "A"
		end
		h:setAudience(inVenueA)
		s.step(5, moving)
		got = window(30)
		T.eq(got[1] + got[2], 0, "function says no")
		T.check(got[3] >= 14, "function says yes")
		s.players[1]:SetAttribute("Venue", "A")
		s.step(12, moving)
		got = window(30)
		T.check(got[1] >= 14, "picked up within InterestEvery")
		-- shared by many entities: one call per receiver per recompute, not one per entity
		for k = 1, 10 do
			local other = s.world:spawnModel("o" .. k, CFrame.new(k, 3, 5), true)
			s.Tide.add(other, "Bot"):setAudience(inVenueA)
		end
		s.step(2)
		calls = 0
		s.step(6) -- one recompute
		T.check(calls <= 3 * 2, "audience function called per receiver, not per entity: " .. calls)
		-- nil: everyone again
		h:setAudience(nil)
		s.step(5, moving)
		got = window(30)
		for i = 1, 3 do
			T.check(got[i] >= 14, "everyone again " .. i)
		end
		-- errors in the function count as outside
		local errors = s.Tide.stats().errors
		h:setAudience(function()
			error("boom")
		end)
		s.step(12, moving)
		T.check(s.Tide.stats().errors > errors, "counted")
		T.eq(s.State.rx[s.players[1]].tier[slot], 4)
		T.check(not pcall(h.setAudience, h, { "x" }), "a list of non-players is rejected")
		T.check(not pcall(h.setAudience, h, 5), "a number is rejected")
		-- an owner outside the audience still owns and uploads it; the others follow it
		h:setAudience({ s.players[3] })
		h:setOwner(s.players[1])
		s.step(5)
		local before = s.counts[3][slot] or 0
		local rep = s.world:replica(1, m).HumanoidRootPart
		s.step(30, function(f)
			rep.CFrame = CFrame.new(10 + f * 0.1, 3, 0)
		end)
		T.check((s.counts[3][slot] or 0) - before >= 14, "audience member gets the owner's samples")
		T.check(s.Tide.latest(m).X > 10, "owner's uploads accepted")
	end)

	T.test("audience: state and animations follow it (snapshot when a receiver enters)", function()
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		local function schema(tide)
			tide.state("Bot", { Mode = { type = "enum", values = { "idle", "run" } } })
		end
		schema(Tide)
		Tide.start({ players = false })
		local players, cts = {}, {}
		for i = 1, 2 do
			players[i] = world:addPlayer()
			cts[i] = T.clientTide(world, i)
			schema(cts[i])
			cts[i].start()
		end
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), true)
		local h = Tide.add(m, "Bot")
		h:setAudience({ players[1] })
		for _ = 1, 10 do
			world:frame(DT)
		end
		Tide.set(m, "Mode", "run")
		for _ = 1, 30 do
			world:frame(DT)
		end
		T.eq(cts[1].get(world:replica(1, m), "Mode"), "run", "member applied it")
		T.check(cts[2].get(world:replica(2, m), "Mode") ~= "run", "outside: nothing")
		h:setAudience({ players[1], players[2] })
		for _ = 1, 30 do
			world:frame(DT)
		end
		T.eq(cts[2].get(world:replica(2, m), "Mode"), "run", "snapshot on entering")
	end)

	T.test("bytes: 4 matches x 22 bodies, 8 viewers each; audiences cut each player's relay to its match", function()
		local function run(withAudience)
			local world = T.world({ latency = 0.02 })
			local Tide = T.serverTide(world)
			Tide.kind("Body", { rate = 30, rotation = "full", farEvery = 1, buffer = 0.12 })
			Tide.start({ players = false, ReceiverBytesPerSecond = 1e9 })
			local players = {}
			for i = 1, 8 do
				players[i] = world:addPlayer()
				players[i]:SetAttribute("Venue", (i - 1) % 4 + 1)
				T.clientTide(world, i).start()
			end
			local bodies = {}
			for v = 1, 4 do
				local function watching(player)
					return player:GetAttribute("Venue") == v
				end
				local ball = T.Mock.newInstance("Part", "Ball" .. v)
				ball.CFrame = CFrame.new(v * 1600, 3, 0)
				ball.Parent = world.server.Workspace
				for k = 1, 22 do
					local m = world:spawnModel("b", CFrame.new(v * 1600 + k * 3, 3, 0), true)
					local h = Tide.add(m, "Body")
					if withAudience then
						h:setAudience(watching)
					end
					table.insert(bodies, m)
				end
				if withAudience then
					for i = 1, 8 do
						if players[i]:GetAttribute("Venue") == v then
							Tide.focus(players[i], ball)
						end
					end
				end
			end
			for _ = 1, 10 do
				world:frame(DT)
			end
			local before = world.stats.s2cBytes
			for f = 1, 120 do
				for k, m in bodies do
					local p = m.HumanoidRootPart.CFrame
					m.HumanoidRootPart.CFrame = CFrame.new(p.X, 3, math.sin(f * 0.1 + k) * 5)
				end
				world:frame(DT)
			end
			return (world.stats.s2cBytes - before) / 8 / 2 -- per player per second
		end
		local all = run(false)
		local each = run(true)
		print(string.format("    relay per player: everyone %.0f B/s, audiences %.0f B/s", all, each))
		T.check(each < all * 0.3, `audiences cut the bytes ({each} vs {all})`)
		T.check(each > 22 * 30 * 14 * 0.8, "a viewer still gets its 22 bodies at 30 Hz")
	end)
end
