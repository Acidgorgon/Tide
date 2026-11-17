-- Lighthouse hooks: with a fake shared.Lighthouse installed, net() byte totals match the
-- buffers actually fired on each channel, and probes are balanced on both sides.
return function(T)
	local DT = 1 / 60

	local function fake()
		local lh = { nets = {}, probes = {}, depth = 0, misuse = 0, calls = 0 }
		function lh.probe(name: string)
			local p = lh.probes[name]
			if p == nil then
				p = { name = name, begins = 0, finishes = 0 }
				function p.begin(self)
					self.begins += 1
					lh.depth += 1
				end
				function p.finish(self)
					self.finishes += 1
					lh.depth -= 1
					if lh.depth < 0 or self.finishes > self.begins then
						lh.misuse += 1
					end
				end
				lh.probes[name] = p
			end
			return p
		end
		-- totals by "lib/channel/dir" and by player
		function lh.net(lib: string, channel: string, dir: string, bytes: number, player: any?)
			assert(type(bytes) == "number" and bytes > 0, "bytes")
			assert(dir == "in" or dir == "out", "dir")
			lh.calls += 1
			local key = lib .. "/" .. channel .. "/" .. dir
			local e = lh.nets[key]
			if e == nil then
				e = { bytes = 0, packets = 0, by = {} }
				lh.nets[key] = e
			end
			e.bytes += bytes
			e.packets += 1
			if player ~= nil then
				e.by[player] = (e.by[player] or 0) + bytes
			end
		end
		function lh.count() end
		function lh.gauge() end
		return lh
	end

	local function total(lh, key: string): number
		local e = lh.nets[key]
		return if e then e.bytes else 0
	end
	local function to(lh, key: string, player: any): number
		local e = lh.nets[key]
		return if e then e.by[player] or 0 else 0
	end

	local function setup()
		local world = T.world({ latency = 0.03, jitter = 0.005, seed = 3 })
		local Tide = T.serverTide(world)
		Tide.start({ players = true })
		local chars, cts = {}, {}
		for i = 1, 3 do
			local p = world:addPlayer()
			chars[i] = world:spawnCharacter(p, CFrame.new(i * 10, 3, 0))
		end
		local m = world:spawnModel("bot", CFrame.new(0, 3, 20), true)
		Tide.add(m, "Bot")
		for i = 1, 3 do
			cts[i] = T.clientTide(world, i)
			cts[i].start()
		end
		return world, Tide, chars, m
	end

	local function drive(world, chars, bot, frames)
		for _ = 1, frames do
			local t = world.now + DT
			for i = 1, #chars do
				local hrp = world:replica(i, chars[i].HumanoidRootPart)
				if hrp then
					hrp.CFrame = CFrame.new(i * 10 + math.sin(t * 2 + i) * 5, 3, math.cos(t + i) * 5)
				end
			end
			bot.HumanoidRootPart.CFrame = CFrame.new(math.sin(t) * 8, 3, 20)
			world:frame(DT)
		end
	end

	-- records every buffer the server fires, by remote name and player
	local function tap(world)
		local fired = { TideU = {}, TideR = {} }
		local root = world.tideModule
		for name, byPlayer in fired do
			local remote = root:FindFirstChild(name)
			local orig = rawget(remote, "FireClient")
			rawset(remote, "FireClient", function(self, player, b, ...)
				byPlayer[player] = (byPlayer[player] or 0) + buffer.len(b)
				return orig(self, player, b, ...)
			end)
		end
		return fired
	end

	T.test("net() totals match the bytes fired and received; probes balanced", function()
		local world, _, chars, bot = setup()
		local slh = fake()
		world.server.shared.Lighthouse = slh
		local clhs = {}
		for i = 1, 3 do
			clhs[i] = fake()
			world.clients[i].shared.Lighthouse = clhs[i]
		end
		local fired = tap(world)
		drive(world, chars, bot, 120)
		-- deliver everything in flight without new frames (handlers still see Lighthouse)
		world.now += 1
		world:pump()

		T.check(total(slh, "Tide/Relay/out") > 0, "server relayed bytes")
		for i = 1, 3 do
			local player = world.players[i]
			local clh = clhs[i]
			-- server out == what was fired, per player
			T.eq(to(slh, "Tide/Relay/out", player), fired.TideU[player] or 0, `relay out to {i}`)
			T.eq(to(slh, "Tide/Control/out", player), fired.TideR[player] or 0, `control out to {i}`)
			-- and what the client received
			T.eq(total(clh, "Tide/Relay/in"), to(slh, "Tide/Relay/out", player), `relay in at {i}`)
			T.eq(total(clh, "Tide/Control/in"), to(slh, "Tide/Control/out", player), `control in at {i}`)
			-- uploads: client out == server in == the client's own counter
			local up = total(clh, "Tide/Upload/out")
			T.check(up > 0, `client {i} uploaded`)
			T.eq(to(slh, "Tide/Upload/in", player), up, `upload in from {i}`)
			T.eq(up, T.clientTide(world, i).stats().uploadBytes, `upload counter {i}`)
			-- READY (1 byte) goes out before the client's first frame reads shared.Lighthouse
			T.eq(to(slh, "Tide/Control/in", player), total(clh, "Tide/Control/out") + 1, `control in from {i}`)
		end
		T.eq(slh.nets["Tide/Relay/out"].bytes, world.server:require(world.tideModule).stats().relayBytes, "relay counter")

		for _, lh in { slh, clhs[1], clhs[2], clhs[3] } do
			T.eq(lh.depth, 0, "probe depth")
			T.eq(lh.misuse, 0, "probe misuse")
			for name, p in lh.probes do
				T.eq(p.begins, p.finishes, name .. " balanced")
			end
		end
		for _, name in { "Tide.Sample", "Tide.Relay", "Tide.Receive" } do
			T.check(slh.probes[name] and slh.probes[name].begins > 0, "server probe " .. name)
		end
		for _, name in { "Tide.Upload", "Tide.Render", "Tide.Receive" } do
			T.check(clhs[1].probes[name] and clhs[1].probes[name].begins > 0, "client probe " .. name)
		end
	end)

	T.test("a new shared.Lighthouse is picked up; removing it stops reporting", function()
		local world, _, chars, bot = setup()
		local a = fake()
		world.server.shared.Lighthouse = a
		drive(world, chars, bot, 30)
		T.check(a.calls > 0 and a.probes["Tide.Relay"].begins > 0, "first instance used")
		local b = fake()
		world.server.shared.Lighthouse = b
		local before = a.calls
		drive(world, chars, bot, 30)
		T.check(b.calls > 0 and b.probes["Tide.Relay"].begins > 0, "second instance used")
		T.check(a.calls - before <= 3 * 4, "first instance retired after one frame")
		world.server.shared.Lighthouse = nil
		drive(world, chars, bot, 2)
		local n = b.calls
		drive(world, chars, bot, 30)
		T.eq(b.calls, n, "no calls once removed")
		T.eq(a.depth, 0, "a balanced")
		T.eq(b.depth, 0, "b balanced")
	end)
end
