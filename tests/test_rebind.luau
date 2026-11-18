-- v0.4 Config.rebindStreamed: a client model whose Parent became nil (streamed out) is dropped
-- and asked for again; the re-streamed model (a new instance) is bound to the same entity
-- without restarting its stream.
return function(T)
	local DT = 1 / 60

	local function setup(rebind)
		local world = T.world({ latency = 0.03 })
		local Tide = T.serverTide(world)
		Tide.start({ players = false, rebindStreamed = rebind })
		world:addPlayer()
		local ct = T.clientTide(world, 1)
		local s = { world = world, Tide = Tide, ct = ct, added = {}, removed = {} }
		ct.added(function(model)
			table.insert(s.added, model)
		end)
		ct.removed(function(model)
			table.insert(s.removed, model)
		end)
		ct.start()
		local m = world:spawnModel("bot", CFrame.new(0, 3, 0), true)
		s.m = m
		s.handle = Tide.add(m, "Bot")
		function s.step(seconds)
			for _ = 1, math.floor(seconds / DT + 0.5) do
				m.HumanoidRootPart.CFrame = CFrame.new(math.sin(world.now) * 5, 3, 0)
				world:frame(DT)
			end
		end
		-- streams the model out of client 1 the way Roblox does: the client's instance leaves
		-- the DataModel (Parent nil); while out, the server's references resolve to nil
		function s.streamOut()
			local old = world:replica(1, m)
			world:streamOut(1, m)
			rawset(old, "_parent", nil)
			return old
		end
		return s
	end

	T.test("a streamed-out model is dropped; the re-streamed instance is bound, stream kept", function()
		local s = setup(true)
		s.step(1)
		local old = s.world:replica(1, s.m)
		T.check(s.ct.drawn(old) ~= nil, "drawn")
		local info = s.ct.sampleInfo(old)
		local count = info.count
		s.streamOut()
		s.step(0.5)
		T.eq(s.ct.drawn(old), nil, "the detached model is no longer driven")
		T.eq(s.removed[#s.removed], old, "removed fired for it")
		T.eq(s.ct.stats().modelsLost, 1)
		local resendsBefore = s.world.stats.c2sCalls
		s.step(1.5)
		T.check(s.world.stats.c2sCalls > resendsBefore, "asked again (RESEND)")
		s.world:streamOut(1, s.m, false) -- streams back in: a new instance
		s.step(1.5)
		local new = s.world:replica(1, s.m)
		T.check(new ~= old, "a new instance")
		T.check(s.ct.drawn(new) ~= nil, "drawn on the new instance")
		T.check(new.HumanoidRootPart.Anchored, "anchored")
		T.eq(s.added[#s.added], new, "added fired for it")
		T.eq(s.ct.stats().modelsRebound, 1)
		T.check(s.ct.sampleInfo(new).count > count, "same stream: samples kept counting (no reset)")
	end)

	T.test("an entity removed while its model is streamed out fires removed once, never with a nil model", function()
		-- FM 2-player Studio test 2026-11-18: removeEntity fired removed(nil, kind) for slots whose model had already
		-- been dropped, so a listener doing bodies[model] = nil threw "table index is nil".
		local s = setup(true)
		s.removed = {}
		local nils = 0
		s.ct.removed(function(model)
			if model == nil then
				nils += 1
			end
		end)
		s.step(1)
		local old = s.streamOut()
		s.step(0.5)
		T.eq(#s.removed, 1, "removed fired at stream-out")
		T.eq(s.removed[1], old)
		s.handle:remove()
		s.step(1)
		T.eq(nils, 0, "no removed(nil)")
		T.eq(#s.removed, 1, "not fired again for the entity that had no model")
	end)

	T.test("control (v0.3 default): the old reference is kept and the new instance never drawn", function()
		local s = setup(false)
		s.step(1)
		local old = s.world:replica(1, s.m)
		s.streamOut()
		s.step(1)
		s.world:streamOut(1, s.m, false)
		s.step(2)
		local new = s.world:replica(1, s.m)
		T.check(s.ct.drawn(old) ~= nil, "still drives the detached model")
		T.eq(s.ct.drawn(new), nil, "the new instance is not drawn")
	end)

	T.test("a model parented back by the game itself (same instance) is bound again locally", function()
		local s = setup(true)
		s.step(1)
		local view = s.world:replica(1, s.m)
		local parent = view.Parent
		rawset(view, "_parent", nil)
		s.step(0.5)
		T.eq(s.ct.drawn(view), nil, "dropped while out")
		rawset(view, "_parent", parent)
		s.step(0.5)
		T.check(s.ct.drawn(view) ~= nil, "bound again")
	end)

	T.test("RESEND is not answered for entities outside the receiver's audience", function()
		local s = setup(true)
		s.step(1)
		s.handle:setAudience({})
		s.step(0.5)
		local old = s.streamOut()
		s.world:streamOut(1, s.m, false)
		local before = s.world.stats.s2cBytes
		s.step(3)
		-- nothing but the empty frames: no ADD reply to the client's asks
		T.eq(s.ct.drawn(s.world:replica(1, s.m)), nil, "not bound: no answer")
		T.check(s.world.stats.s2cBytes - before < 200, "no replies: " .. (s.world.stats.s2cBytes - before))
		local _ = old
		s.handle:setAudience(nil)
		s.step(1.5)
		T.check(s.ct.drawn(s.world:replica(1, s.m)) ~= nil, "bound once back in the audience")
	end)
end
