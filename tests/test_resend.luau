-- v0.4.1: models a client does not have yet (streaming) must not starve behind entities the
-- server will not answer for it. A client asks again (RESEND) for at most 64 entities at a time;
-- v0.4.0 always asked for the first 64 in the same order, and the server does not answer for
-- entities outside the receiver's audience, so a viewer cutting to a venue registered after
-- others could wait forever. Now the server sends the ADD again when a receiver comes back into
-- an entity's audience, and the client's window moves on with each ask.
return function(T)
	local DT = 1 / 60
	local BODIES = 22

	-- `venues` venues of 22 bodies, each with an audience (players whose "Venue" attribute is
	-- its number) and one viewer; one more player (the hub) watches none and has every body
	-- streamed out (its ADDs arrive without the model, as for a Roblox client far away).
	local function venues(count: number)
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({ players = false })
		local players = {}
		for v = 1, count + 1 do
			players[v] = world:addPlayer()
			players[v]:SetAttribute("Venue", if v <= count then v else 0)
			T.clientTide(world, v).start()
		end
		local hub = count + 1
		local s = { world = world, Tide = Tide, players = players, hub = hub, ct = T.clientTide(world, hub), bodies = {} }
		for v = 1, count do
			local function watching(player)
				return player:GetAttribute("Venue") == v
			end
			s.bodies[v] = {}
			for k = 1, BODIES do
				local m = world:spawnModel(`B{v}_{k}`, CFrame.new(v * 1600 + k * 4, 3, 0), true)
				world:streamOut(hub, m)
				Tide.add(m, "Bot"):setAudience(watching)
				s.bodies[v][k] = m
			end
		end
		function s.step(seconds: number)
			for _ = 1, math.floor(seconds / DT + 0.5) do
				for v, list in s.bodies do
					for k, m in list do
						m.HumanoidRootPart.CFrame = CFrame.new(v * 1600 + k * 4, 3, math.sin(world.now + k) * 5)
					end
				end
				world:frame(DT)
			end
		end
		-- the hub player starts watching venue v (game code); its models stream in now or later
		function s.cut(v: number, streamIn: boolean)
			players[hub]:SetAttribute("Venue", v)
			Tide.focus(players[hub], Vector3.new(v * 1600, 3, 0))
			if streamIn then
				s.streamIn(v)
			end
		end
		function s.streamIn(v: number)
			for _, m in s.bodies[v] do
				world:streamOut(hub, m, false)
			end
		end
		function s.drawn(v: number): number
			local n = 0
			for _, m in s.bodies[v] do
				if s.ct.drawn(world:replica(hub, m)) ~= nil then
					n += 1
				end
			end
			return n
		end
		return s
	end

	T.test("a viewer cutting to the newest of 5 venues draws all 22 bodies (v0.4.0: 0, forever)", function()
		local s = venues(5)
		s.step(1.5)
		T.eq(s.drawn(5), 0, "nothing of a venue it does not watch")
		local adds = s.Tide.stats().audienceAdds
		s.cut(5, true)
		s.step(0.5) -- well before the client's next RESEND (Config.ModelRetry 1 s)
		T.eq(s.drawn(5), BODIES, "bound from the ADD sent on entering the audience")
		T.eq(s.Tide.stats().audienceAdds - adds, BODIES, "one ADD per body of the venue, to the hub player only")
		s.step(1)
		T.eq(s.drawn(5), BODIES)
		T.eq(s.drawn(1), 0, "the other venues are still not for it")
	end)

	T.test("models that stream in after the cut are found by the moving RESEND window", function()
		local s = venues(5)
		s.step(1.5)
		s.cut(5, false) -- the entering ADDs arrive without the models
		s.step(0.5)
		T.eq(s.drawn(5), 0)
		s.streamIn(5)
		-- 110 models missing on the hub client, 88 of them never answered: two asks cover them all
		s.step(3)
		T.eq(s.drawn(5), BODIES, "every body bound by a RESEND answer")
		-- and cutting again, to a venue registered earlier, works the same
		s.cut(2, true)
		s.step(0.5)
		T.eq(s.drawn(2), BODIES)
	end)

	T.test("without audiences: more than 64 missing models are all asked for, 64 per ask", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({ players = false })
		world:addPlayer()
		local ct = T.clientTide(world, 1)
		ct.start()
		local asks = {}
		world.tideModule:FindFirstChild("TideR").OnServerEvent:Connect(function(_player, b)
			if buffer.readu8(b, 0) == 16 then
				local slots = {}
				for i = 1, buffer.readu8(b, 1) do
					slots[i] = buffer.readu16(b, i * 2)
				end
				table.insert(asks, slots)
			end
		end)
		local models = {}
		for k = 1, 100 do
			local m = world:spawnModel(`far{k}`, CFrame.new(k * 3, 3, 0), true)
			world:streamOut(1, m)
			Tide.add(m, "Bot")
			models[k] = m
		end
		local function step(n)
			for _ = 1, n do
				for k, m in models do
					m.HumanoidRootPart.CFrame = CFrame.new(k * 3, 3, math.sin(world.now + k) * 5)
				end
				world:frame(DT)
			end
		end
		step(150)
		T.check(#asks >= 2, "asked twice")
		local seen = {}
		for _, slots in asks do
			T.check(#slots <= 64, "at most 64 per ask")
			for _, slot in slots do
				seen[slot] = true
			end
		end
		local State = T.module(world, "Server", "State")
		for _, m in models do
			T.check(seen[State.bySlotModel[m]], "every missing model asked for")
		end
		-- the last ones registered stream in: bound by the next asks
		for k = 81, 100 do
			world:streamOut(1, models[k], false)
		end
		step(180)
		for k = 81, 100 do
			T.check(ct.drawn(world:replica(1, models[k])) ~= nil, "bound " .. k)
		end
		T.eq(Tide.stats().audienceAdds, 0, "no audience: no extra ADD")
	end)

	T.test("up to 64 missing models: the RESEND is as in v0.4.0 (all of them, in list order)", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({ players = false })
		world:addPlayer()
		T.clientTide(world, 1).start()
		local asks = {}
		world.tideModule:FindFirstChild("TideR").OnServerEvent:Connect(function(_player, b)
			if buffer.readu8(b, 0) == 16 then
				table.insert(asks, buffer.tostring(b))
			end
		end)
		for k = 1, 10 do
			local m = world:spawnModel(`far{k}`, CFrame.new(k * 3, 3, 0), true)
			world:streamOut(1, m)
			Tide.add(m, "Bot")
		end
		for _ = 1, 200 do
			world:frame(DT)
		end
		local CState = T.clientModule(world, 1, "Client", "State")
		local expect = buffer.create(2 + 10 * 2)
		buffer.writeu8(expect, 0, 16)
		buffer.writeu8(expect, 1, 10)
		for k = 1, CState.count do
			buffer.writeu16(expect, k * 2, CState.active[k])
		end
		T.check(#asks >= 3, "asked every Config.ModelRetry")
		for _, ask in asks do
			T.eq(ask, buffer.tostring(expect), "same bytes each time")
		end
	end)

	T.test("an entering ADD without the model leaves a model the client already drives", function()
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({ players = false })
		world:addPlayer()
		local ct = T.clientTide(world, 1)
		local removed = 0
		ct.removed(function()
			removed += 1
		end)
		ct.start()
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), true)
		local h = Tide.add(m, "Bot")
		local function step(n)
			for _ = 1, n do
				m.HumanoidRootPart.CFrame = CFrame.new(math.sin(world.now) * 5, 3, 0)
				world:frame(DT)
			end
		end
		step(60)
		local view = world:replica(1, m)
		T.check(ct.drawn(view) ~= nil, "drawn")
		h:setAudience({})
		step(30)
		world:streamOut(1, m) -- the server's reference now resolves to nil on this client
		h:setAudience(nil)
		step(30)
		T.eq(Tide.stats().audienceAdds, 1, "ADD sent on entering")
		T.eq(removed, 0, "not removed")
		T.check(ct.drawn(view) ~= nil, "still drives the model it had")
	end)
end
