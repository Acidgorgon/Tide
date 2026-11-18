-- v0.4 owner changes: Tide.owner / Tide.isMine / handle:owner; Config.ownerEase (a receiver
-- keeps its render clock across owner changes) and Config.ownerStart (where the new owner's
-- copy starts), measured on a body running at 20 studs/s whose owner flips every 0.75 s.
return function(T)
	local DT = 1 / 60
	local SPEED = 20

	T.test("Tide.owner / Tide.isMine / handle:owner on both sides", function()
		local world = T.world({ latency = 0.02 })
		local Tide = T.serverTide(world)
		Tide.start({ players = false })
		local p1 = world:addPlayer()
		world:addPlayer()
		local c1, c2 = T.clientTide(world, 1), T.clientTide(world, 2)
		c1.start()
		c2.start()
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), true)
		local h = Tide.add(m, "Bot")
		for _ = 1, 10 do
			world:frame(DT)
		end
		T.eq(Tide.isMine(m), true, "server-owned: the server's")
		T.eq(Tide.owner(m), nil)
		T.eq(h:owner(), nil)
		T.eq(c1.isMine(world:replica(1, m)), false)
		T.eq(c1.owner(world:replica(1, m)), nil)
		h:setOwner(p1)
		for _ = 1, 10 do
			world:frame(DT)
		end
		T.eq(Tide.isMine(m), false)
		T.eq(Tide.owner(m), p1)
		T.eq(h:owner(), p1)
		T.eq(c1.isMine(world:replica(1, m)), true, "client 1 owns it")
		T.eq(c2.isMine(world:replica(2, m)), false)
		T.eq(c2.owner(world:replica(2, m)), p1, "client 2 knows who")
		T.eq(c1.isMine(workspace), false, "unknown model")
		T.eq(Tide.isMine(workspace), false)
		h:remove()
		T.eq(h:owner(), nil)
	end)

	-- One body runs along +x at SPEED; its owner flips server <-> client 1 every 0.75 s; client
	-- 2 watches. `start` = where client 1's copy starts at a grant: "server" (the server's pose at
	-- that instant: only the render clock is measured), or "own" (wherever Tide left the copy:
	-- the drawn pose, or where Config.ownerStart moved it). At a hand back the server's copy is
	-- one-way latency behind (engine replication). Returns the worst one-frame step error on
	-- client 2 after grants and after hand backs, and the worst step back in server history.
	local function flip(latency: number, config: { [string]: any }, start: string)
		local world = T.world({ latency = latency, jitter = 0.005, seed = 3, start = 1.7e9 })
		local Tide = T.serverTide(world)
		Tide.kind("Body", {
			rate = 30,
			rotation = "full",
			farEvery = 1,
			buffer = 0.12,
			extrapolate = 0.1,
			maxSpeed = 240,
		})
		local cfg = {
			players = false,
			origin = Vector3.new(6800, 0, 0),
			lockPlayers = false,
			teleportOnWrite = false,
			SpeedResync = 0,
		}
		for k, v in config do
			cfg[k] = v
		end
		Tide.start(cfg)
		local players, cts = {}, {}
		for i = 1, 2 do
			players[i] = world:addPlayer()
			cts[i] = T.clientTide(world, i)
			cts[i].start()
		end
		world:frame(DT)
		world:frame(DT)
		local m = world:spawnModel("P", CFrame.new(6000, 3, 0))
		local h = Tide.add(m, "Body")
		local x = 6000
		local owned = false
		local hist, frames = {}, 0
		local rep = world:replica(1, m)
		local function each()
			if owned then
				local root = rep.HumanoidRootPart
				if start ~= "own" then
					x += SPEED * DT
					root.CFrame = CFrame.new(x, 3, 0)
				elseif cts[1].isMine(rep) then
					x = root.CFrame.X + SPEED * DT -- the owner's physics carries on from its copy
					root.CFrame = CFrame.new(x, 3, 0)
				else
					x += SPEED * DT -- (the OWNER message is on its way; Tide still draws the copy)
				end
			else
				x += SPEED * DT
				m.PrimaryPart.CFrame = CFrame.new(x, 3, 0)
			end
			frames += 1
			hist[frames] = x
		end
		local worst = { grant = 0, back = 0 }
		local phase = "grant"
		local last = nil
		local lastLatest, srvBack = nil, 0
		local function measure()
			local cf = cts[2].drawn(world:replica(2, m))
			if cf and last then
				local dev = math.abs((cf.X - last) - SPEED * DT)
				if dev > worst[phase] then
					worst[phase] = dev
				end
			end
			last = cf and cf.X
			local l = Tide.latest(m).X
			if lastLatest and l < lastLatest - 0.01 then
				srvBack = math.max(srvBack, lastLatest - l)
			end
			lastLatest = l
		end
		for _ = 1, 60 do
			each()
			world:frame(DT)
		end
		for _ = 1, 6 do
			owned = not owned
			phase = if owned then "grant" else "back"
			if owned then
				if start == "server" then
					rep.HumanoidRootPart.CFrame = m.PrimaryPart.CFrame
				end
				h:setOwner(players[1])
			else
				local lag = math.floor(latency / DT + 0.5)
				x = hist[frames - lag]
				m.PrimaryPart.CFrame = CFrame.new(x, 3, 0) -- engine copy: one-way behind
				h:setOwner(nil)
			end
			for _ = 1, 45 do
				each()
				world:frame(DT)
				measure()
			end
		end
		T.eq(Tide.stats().speed, 0, "no speed rejections")
		return worst.grant, worst.back, srvBack
	end

	T.test("ownerEase: a third client's render clock is kept across owner flips (measured)", function()
		local rows = {}
		for _, latency in { 0.03, 0.06, 0.1 } do
			local g0, b0 = flip(latency, {}, "server")
			local g1, b1 = flip(latency, { ownerEase = true }, "server")
			table.insert(rows, string.format("%3d ms: v0.3 %.2f (grant %.2f, back %.2f) -> ownerEase %.2f (grant %.2f, back %.2f)", latency * 1000, math.max(g0, b0), g0, b0, math.max(g1, b1), g1, b1))
			T.check(math.max(g1, b1) < 0.5, `ownerEase keeps the step error small at {latency * 1000} ms: {math.max(g1, b1)}`)
			T.check(math.max(g1, b1) < math.max(g0, b0), "better than v0.3")
		end
		print("    worst one-frame step error on a third client (studs; a frame's own step is 0.33):")
		for _, row in rows do
			print("      " .. row)
		end
	end)

	T.test("ownerStart: the new owner's copy starts at the newest sample or the server's pose", function()
		local rows = {}
		for _, latency in { 0.03, 0.06, 0.1 } do
			local results = {}
			for _, mode in { "drawn", "latest", "server" } do
				local g, b, back = flip(latency, { ownerEase = true, ownerStart = mode }, "own")
				results[mode] = { g, b, back }
			end
			local row = string.format("%3d ms:", latency * 1000)
			for _, mode in { "drawn", "latest", "server" } do
				local r = results[mode]
				row ..= string.format("  %s: c2 grant %.2f back %.2f, server history back-step %.2f", mode, r[1], r[2], r[3])
			end
			table.insert(rows, row)
			-- drawn (v0.3): the copy restarts (delay - latency) x speed behind the server's last sample
			T.check(results.drawn[3] > 0.2, "drawn: the server history steps back at each grant")
			for _, mode in { "latest", "server" } do
				local r = results[mode]
				T.check(r[3] < 0.2, `{mode}: no back-step ({r[3]})`)
				-- at most about one held frame (a frame's own step is 0.33)
				T.check(r[1] < 0.4, `{mode}: a smooth grant on the third client ({r[1]})`)
			end
		end
		print("    owner start (with ownerEase):")
		for _, row in rows do
			print("      " .. row)
		end
	end)

	T.test("ownerEase: the old owner blends from its own pose instead of jumping back", function()
		local world = T.world({ latency = 0.06, seed = 3 })
		local Tide = T.serverTide(world)
		Tide.kind("Body", { rate = 30, farEvery = 1, buffer = 0.12 })
		Tide.start({ players = false, lockPlayers = false, teleportOnWrite = false, ownerEase = true })
		local p1 = world:addPlayer()
		local c1 = T.clientTide(world, 1)
		c1.start()
		world:frame(DT)
		local m = world:spawnModel("P", CFrame.new(0, 3, 0))
		local h = Tide.add(m, "Body")
		h:setOwner(p1)
		local rep = world:replica(1, m)
		local x = 0
		for _ = 1, 60 do
			x += SPEED * DT
			rep.HumanoidRootPart.CFrame = CFrame.new(x, 3, 0)
			world:frame(DT)
		end
		-- hand back: the server continues from the newest accepted sample
		m.PrimaryPart.CFrame = Tide.latest(m)
		x = Tide.latest(m).X
		h:setOwner(nil)
		local last, worst = rep.HumanoidRootPart.CFrame.X, 0
		for _ = 1, 60 do
			x += SPEED * DT
			m.PrimaryPart.CFrame = CFrame.new(x, 3, 0)
			world:frame(DT)
			local now = rep.HumanoidRootPart.CFrame.X
			worst = math.max(worst, last - now) -- backwards steps
			last = now
		end
		T.check(c1.drawn(rep) ~= nil, "drawn again")
		T.check(worst < 1, "no big jump back: " .. worst)
	end)
end
