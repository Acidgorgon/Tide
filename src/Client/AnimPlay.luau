--!strict
--!native
--!optimize 2
-- Animation channel, receiving side: replays other entities' animation events at
-- the time Tide draws their bodies.
--   * Each animated remote entity gets this client's OWN Animator under its
--     Humanoid / AnimationController (client-created, so it never replicates);
--     Roblox's replicated Animator is destroyed locally, so tracks Roblox
--     replicates on its own clock no longer show. Tracks are loaded once per
--     entity per animation id.
--   * Events wait in a per-entity queue (QCAP; when full the oldest is applied
--     early) and are applied once the entity's render time (now - delay, the time
--     its body is drawn at) reaches their stamp: PLAY = Play(fade, weight, speed)
--     then TimePosition caught up to the render time; STOP, SPEED, WEIGHT, SEEK,
--     PRIORITY likewise. At most Config.AnimApplyPerFrame events per frame.
--   * A snapshot (late join, back in range, owner change) replaces the entity's
--     state: queued events it already covers are dropped, tracks not in it stop,
--     the rest play with fade 0 at the caught-up time position.
--   * Without a model or controller yet (streaming), events still update the
--     entity's state; it is applied like a snapshot once the Animator is in place.
--   * Tracks follow the render clock: when an entity's delay changes (the body's
--     clock eases to it), a track more than DRIFT_MAX off its state at the render
--     time is put back (checked every DRIFT_EVERY).
-- No events and nothing to attach: the step allocates nothing.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local AnimCodec = require(Shared.AnimCodec)
local AnimRegistry = require(Shared.AnimRegistry)
local AnimSet = require(Shared.AnimSet)
local AnimWatch = require(Shared.AnimWatch)
local Signal = require(Shared.Signal)
local State = require(script.Parent.State)

local AnimPlay = {}

AnimPlay.active = false
AnimPlay.animatedSignal = Signal.new()

local QCAP = 64
local ATTACH_EVERY = 0.25
local DRIFT_EVERY = 0.25
local DRIFT_MAX = 0.05 -- seconds of time position
local INF = math.huge

local PLAY, STOP, SPEED, WEIGHT, SEEK = AnimCodec.PLAY, AnimCodec.STOP, AnimCodec.SPEED, AnimCodec.WEIGHT, AnimCodec.SEEK
local OP_NAMES = AnimCodec.OP_NAMES
local priority = AnimCodec.priority

type Queue = {
	t: { number },
	op: { number },
	id: { number },
	fade: { number },
	weight: { number },
	speed: { number },
	tp: { number },
	prio: { number },
	looped: { boolean },
	head: number,
	n: number,
}

local active = State.active
local index = State.index
local mine = State.mine
local models = State.model
local kinds = State.kind
local srcs = State.src
local lags = State.lag
local counters = State.counters

local wanted = {} :: { [number]: boolean } -- animated remote entities
local queues = {} :: { [number]: Queue }
local sets = {} :: { [number]: AnimSet.Set }
local animators = {} :: { [number]: any } -- this client's Animator per entity
local controllers = {} :: { [number]: any }
local tracks = {} :: { [number]: { [number]: any } } -- slot -> anim id -> track
local guards = {} :: { [number]: any } -- ChildAdded connection on the controller
local ours = setmetatable({} :: { [any]: boolean }, { __mode = "k" })
local queued = 0
local idsBound = false -- ANIMIDs arrived: states may name ids that had no track yet
local attachAcc = 0
local driftAcc = 0

local function newQueue(): Queue
	return {
		t = table.create(QCAP, 0),
		op = table.create(QCAP, 0),
		id = table.create(QCAP, 0),
		fade = table.create(QCAP, 0),
		weight = table.create(QCAP, 0),
		speed = table.create(QCAP, 0),
		tp = table.create(QCAP, 0),
		prio = table.create(QCAP, 0),
		looped = table.create(QCAP, false),
		head = 1,
		n = 0,
	}
end

local function setTime(track: any, tp: number, looped: boolean)
	local len = track.Length
	if len > 0 then
		if looped then
			tp %= len
		elseif tp > len then
			tp = len
		end
	end
	if tp < 0 then
		tp = 0
	end
	track.TimePosition = tp
end

local function trackFor(slot: number, id: number): any
	local ts = tracks[slot]
	local track = ts[id]
	if track == nil then
		local anim = AnimRegistry.animation(id)
		if anim == nil then
			counters.animUnknown += 1
			return nil
		end
		-- the engine throws when the Animator is not in the DataModel (model streamed
		-- out or destroyed before Tide's REMOVE): not cached, tried again later
		local animator = animators[slot]
		local ok, loaded = pcall(animator.LoadAnimation, animator, anim)
		if not ok then
			counters.applyErrors += 1
			return nil
		end
		track = loaded
		ts[id] = track
	end
	return track
end

local function attached(slot: number): boolean
	local animator = animators[slot]
	if animator == nil then
		return false
	end
	local controller = controllers[slot]
	return animator.Parent == controller and controller.Parent == models[slot]
end

-- Brings the local tracks to the entity's state at render time rt (fade 0).
local function resync(slot: number, rt: number)
	local set = sets[slot]
	local ts = tracks[slot]
	for id, track in ts do
		local i = AnimSet.find(set, id)
		if (i == 0 or set.e[i].stopT < INF) and track.IsPlaying then
			track:Stop(Config.animationFade)
		end
	end
	for i = 1, set.n do
		local e = set.e[i]
		if e.stopT == INF then
			local track = trackFor(slot, e.id)
			if track ~= nil then
				track.Priority = priority(e.prio)
				track.Looped = e.looped
				if track.IsPlaying then
					track:AdjustSpeed(e.speed)
					track:AdjustWeight(e.weight, 0)
				else
					track:Play(0, e.weight, e.speed)
				end
				setTime(track, AnimSet.timeAt(e, rt), e.looped)
			end
		end
	end
end

local function destroyLater(child: any)
	if child.Parent ~= nil then
		child:Destroy()
	end
end

local function renderTime(slot: number, now: number): number
	local src = srcs[slot]
	return if src ~= nil then now - (lags[slot] or src.delay) else now
end

-- Puts this client's Animator under the entity's controller (replacing Roblox's).
local function attach(slot: number, now: number): boolean
	if attached(slot) then
		return true
	end
	local model = models[slot]
	if model == nil then
		return false
	end
	local controller = AnimWatch.controller(model)
	if controller == nil then
		return false
	end
	local guard = guards[slot]
	if guard ~= nil then
		guard:Disconnect()
	end
	tracks[slot] = {} -- tracks of an earlier Animator went with it
	local animator = nil
	for _, child in controller:GetChildren() do
		if child:IsA("Animator") then
			if ours[child] and animator == nil then
				animator = child
			else
				child:Destroy() -- Roblox's replicated Animator: its tracks stop showing here
			end
		end
	end
	if animator == nil then
		animator = Instance.new("Animator")
		ours[animator] = true
		animator.Parent = controller
	end
	animators[slot] = animator
	controllers[slot] = controller
	guards[slot] = controller.ChildAdded:Connect(function(child)
		if child:IsA("Animator") and not ours[child] then
			task.defer(destroyLater, child)
		end
	end)
	resync(slot, renderTime(slot, now))
	return true
end

local function dropQueue(slot: number)
	local q = queues[slot]
	if q ~= nil then
		queued -= q.n
		q.n = 0
		q.head = 1
	end
end

-- Stops following an entity (removed, now ours, animations off for its kind).
function AnimPlay.release(slot: number)
	if not wanted[slot] then
		return
	end
	wanted[slot] = nil
	dropQueue(slot)
	sets[slot] = nil
	local ts = tracks[slot]
	if ts ~= nil then
		for _, track in ts do
			track:Stop(0)
			track:Destroy()
		end
	end
	tracks[slot] = nil
	local guard = guards[slot]
	if guard ~= nil then
		guard:Disconnect()
	end
	guards[slot] = nil
	-- this client's Animator stays: Roblox's is gone, and an owner may play on it
	animators[slot] = nil
	controllers[slot] = nil
end

-- (Re)decides whether an entity is played here; attaches when its model is in.
function AnimPlay.update(slot: number, now: number)
	local kind = kinds[slot]
	local want = AnimPlay.active and index[slot] ~= nil and not mine[slot] and kind ~= nil and kind.animations ~= false
	if not want then
		AnimPlay.release(slot)
		return
	end
	if not wanted[slot] then
		wanted[slot] = true
		sets[slot] = AnimSet.new()
		tracks[slot] = {}
		if queues[slot] == nil then
			queues[slot] = newQueue()
		end
	end
	attach(slot, now)
end

local function apply(
	slot: number,
	rt: number,
	t: number,
	op: number,
	id: number,
	fade: number,
	weight: number,
	speed: number,
	timePos: number,
	prio: number,
	looped: boolean
)
	local set = sets[slot]
	AnimSet.prune(set, rt)
	AnimSet.apply(set, t, op, id, fade, weight, speed, timePos, prio, looped)
	counters.animApplied += 1
	local track = nil
	if animators[slot] ~= nil then
		if op == PLAY then
			track = trackFor(slot, id)
			if track ~= nil then
				track.Priority = priority(prio)
				track.Looped = looped
				track:Play(fade, weight, speed)
				setTime(track, timePos + (rt - t) * speed, looped)
			end
		else
			track = tracks[slot][id]
			if track ~= nil then
				if op == STOP then
					track:Stop(fade)
				elseif op == SPEED then
					track:AdjustSpeed(speed)
				elseif op == WEIGHT then
					track:AdjustWeight(weight, fade)
				elseif op == SEEK then
					local i = AnimSet.find(set, id)
					local sp = if i > 0 then set.e[i].speed else track.Speed
					setTime(track, timePos + (rt - t) * sp, track.Looped)
				else
					track.Priority = priority(prio)
				end
			end
		end
	end
	if #AnimPlay.animatedSignal.fns > 0 then
		local name = AnimRegistry.name(id)
		Signal.fire(AnimPlay.animatedSignal, models[slot], OP_NAMES[op], name, {
			id = id,
			name = name,
			time = t,
			fade = fade,
			weight = weight,
			speed = speed,
			timePosition = timePos,
			priority = priority(prio),
			looped = looped,
			track = track,
		})
	end
end

-- Takes the head off before applying it: an engine error on one event (counted)
-- must not leave it at the head, failing again every frame and stalling the rest.
local function applyHead(slot: number, q: Queue, rt: number)
	local h = q.head
	q.head = h % QCAP + 1
	q.n -= 1
	queued -= 1
	local ok = pcall(apply, slot, rt, q.t[h], q.op[h], q.id[h], q.fade[h], q.weight[h], q.speed[h], q.tp[h], q.prio[h], q.looped[h])
	if not ok then
		counters.applyErrors += 1
	end
end

-- One relayed event (21 ANIM).
function AnimPlay.event(
	slot: number,
	t: number,
	op: number,
	id: number,
	fade: number,
	weight: number,
	speed: number,
	timePos: number,
	prio: number,
	looped: boolean
)
	if not wanted[slot] then
		counters.animIgnored += 1
		return
	end
	local q = queues[slot]
	if q.n >= QCAP then
		counters.animOverflow += 1
		applyHead(slot, q, q.t[q.head]) -- the oldest goes early rather than lost
	end
	local p = (q.head + q.n - 1) % QCAP + 1
	q.t[p] = t
	q.op[p] = op
	q.id[p] = id
	q.fade[p] = fade
	q.weight[p] = weight
	q.speed[p] = speed
	q.tp[p] = timePos
	q.prio[p] = prio
	q.looped[p] = looped
	q.n += 1
	queued += 1
end

-- One snapshot (24 ANIMSNAP): count states at b[pos..] describing the entity at `base`.
function AnimPlay.snapshot(slot: number, base: number, b: buffer, pos: number, count: number, now: number)
	if not wanted[slot] then
		counters.animIgnored += 1
		return
	end
	counters.animSnaps += 1
	local q = queues[slot]
	while q.n > 0 and q.t[q.head] <= base do
		q.head = q.head % QCAP + 1
		q.n -= 1
		queued -= 1
	end
	local set = sets[slot]
	AnimSet.clear(set)
	-- The state is the entity's at `base` (the server's now), ahead of where its body
	-- is drawn. A track that had not reached time position 0 by the render time
	-- started after it: it is queued as a PLAY at its start instead of playing now.
	local rt = renderTime(slot, now)
	local later: { number }? = nil
	for k = 0, count - 1 do
		local p = pos + k * AnimCodec.STATE
		local id, weight, speed, timePos, prio, looped = AnimCodec.readState(b, p)
		if prio <= AnimCodec.MAX_PRIORITY and timePos == timePos then
			if speed > 0 and timePos >= 0 and base - timePos / speed > rt then
				later = later or {}
				table.insert(later :: { number }, p)
			else
				AnimSet.apply(set, base, PLAY, id, 0, weight, speed, timePos, prio, looped)
			end
		end
	end
	if later ~= nil then
		-- newest start first: each goes in front of the queue (the queue keeps time order,
		-- what is left in it is later than `base`)
		table.sort(later, function(x, y)
			local _, _, sx, tx = AnimCodec.readState(b, x)
			local _, _, sy, ty = AnimCodec.readState(b, y)
			return base - tx / sx > base - ty / sy
		end)
		for _, p in later do
			local id, weight, speed, timePos, prio, looped = AnimCodec.readState(b, p)
			local start = base - timePos / speed
			if q.n < QCAP then
				local h = (q.head - 2) % QCAP + 1
				q.head = h
				q.t[h] = start
				q.op[h] = PLAY
				q.id[h] = id
				q.fade[h] = 0
				q.weight[h] = weight
				q.speed[h] = speed
				q.tp[h] = 0
				q.prio[h] = prio
				q.looped[h] = looped
				q.n += 1
				queued += 1
			else
				AnimSet.apply(set, base, PLAY, id, 0, weight, speed, timePos, prio, looped)
			end
		end
	end
	if animators[slot] ~= nil then
		resync(slot, renderTime(slot, now))
	end
end

-- Puts tracks that drifted off the entity's render clock back on it.
local function fixDrift(slot: number, rt: number)
	local set = sets[slot]
	local ts = tracks[slot]
	for i = 1, set.n do
		local e = set.e[i]
		if e.stopT == INF then
			local track = ts[e.id]
			if track ~= nil and track.IsPlaying then
				local want = AnimSet.timeAt(e, rt)
				local d = track.TimePosition - want
				local len = track.Length
				if len > 0 then
					if e.looped then
						d = (d + len * 0.5) % len - len * 0.5
					elseif want >= len or want <= 0 then
						d = 0 -- at an end: nothing to line up
					end
				end
				if d > DRIFT_MAX or d < -DRIFT_MAX then
					setTime(track, want, e.looped)
					counters.animDrift += 1
				end
			end
		end
	end
end

-- ANIMIDs arrived (id table after a folder mismatch, runtime ids): entities whose
-- state names an id that could not be loaded yet get their tracks at the next step.
function AnimPlay.idsBound()
	idsBound = true
end

local function missingTrack(slot: number): boolean
	local set = sets[slot]
	local ts = tracks[slot]
	for i = 1, set.n do
		local e = set.e[i]
		if e.stopT == INF and ts[e.id] == nil then
			return true
		end
	end
	return false
end

-- Render step (after Render.step, so delays are this frame's).
function AnimPlay.step(now: number, dt: number)
	if not AnimPlay.active then
		return
	end
	if idsBound then
		idsBound = false
		for slot in wanted do
			if animators[slot] ~= nil and missingTrack(slot) then
				resync(slot, renderTime(slot, now))
			end
		end
	end
	attachAcc += dt
	if attachAcc >= ATTACH_EVERY then
		attachAcc = 0
		for slot in wanted do
			if not attached(slot) then
				attach(slot, now)
			end
		end
	end
	driftAcc += dt
	if driftAcc >= DRIFT_EVERY then
		driftAcc = 0
		for slot in wanted do
			if animators[slot] ~= nil then
				fixDrift(slot, now - (lags[slot] or srcs[slot].delay))
			end
		end
	end
	if queued == 0 then
		return
	end
	local budget = Config.AnimApplyPerFrame
	for k = 1, State.count do
		local slot = active[k]
		local q = queues[slot]
		if q ~= nil and q.n > 0 and wanted[slot] then
			local rt = now - (lags[slot] or srcs[slot].delay)
			while q.n > 0 and q.t[q.head] <= rt do
				if budget <= 0 then
					return
				end
				applyHead(slot, q, rt)
				budget -= 1
			end
		end
	end
end

-- What Tide plays for a remote entity at its render time.
function AnimPlay.playing(slot: number, now: number): { [string]: any }?
	local set = sets[slot]
	if set == nil then
		return nil
	end
	local rt = renderTime(slot, now)
	local out = AnimSet.describe(set, rt, AnimRegistry.name)
	local ts = tracks[slot]
	for _, info in out do
		info.track = ts and ts[info.id]
	end
	return out
end

-- This client's Animator for an entity (tests, debugging).
function AnimPlay.animatorOf(slot: number): any
	return animators[slot]
end

return AnimPlay
