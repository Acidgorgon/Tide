--!strict
--!native
--!optimize 2
-- Watches the Animator of an entity on the side that owns it (the owner client
-- for players, the server for bots) and turns what game code does to its tracks
-- into animation events, without game code changes:
--   AnimationPlayed            -> PLAY (fade estimated, sent one watch step later)
--   Stopped / IsPlaying false / WeightTarget 0 -> STOP (fade estimated)
--   Speed change               -> SPEED
--   WeightTarget change > 0.02 -> WEIGHT (fade estimated)
--     (both coalesced per track: a change of SPEED_JUMP / WEIGHT_JUMP or more goes
--     out at once, smaller ones at most every BLEND_EVERY, so the Animate script's
--     per-frame AdjustSpeed / AdjustWeight blending stays a few events a second)
--   TimePosition off the expected advance by > 0.05 s (loop-aware) -> SEEK
--   Priority change            -> PRIORITY
-- AnimationTrack does not expose fade times. A PLAY's fade comes from the weight
-- ramp over the first observed step: WeightCurrent rises linearly from where it
-- was to WeightTarget, so fade = elapsed * (target - start) / (current - start),
-- with `elapsed` the animation time since Play (from TimePosition when it agrees
-- with the clock, so a TimePosition write right after Play does not skew it).
-- STOP and WEIGHT fades use the same rule; Config.animationFade when there is
-- nothing to measure. Tide.play / Tide.stop pass exact fades (markPlay/markStop).
-- Event times never go backwards per watch (an event is never stamped before
-- the previous one), and a track whose AnimationId has no id yet holds its
-- events until it gets one.
-- Steps allocate nothing; per-track state is a table made when the track first plays.

local Config = require(script.Parent.Config)
local AnimCodec = require(script.Parent.AnimCodec)

local AnimWatch = {}

local PLAY, STOP, SPEED, WEIGHT, SEEK, PRIORITY =
	AnimCodec.PLAY, AnimCodec.STOP, AnimCodec.SPEED, AnimCodec.WEIGHT, AnimCodec.SEEK, AnimCodec.PRIORITY
local qSpeed = AnimCodec.qSpeed
local priorityIndex = AnimCodec.priorityIndex
local abs = math.abs

local SEEK_MIN = 0.05 -- seconds of TimePosition mismatch that count as a seek
local WEIGHT_MIN = 0.02
local SPEED_JUMP = 0.05
local WEIGHT_JUMP = 0.1
local BLEND_EVERY = 0.2 -- seconds between small speed / weight updates per track
local WAIT_MAX = 0.25 -- seconds to wait for a weight ramp before using Config.animationFade
local FRAME_SLACK = 0.034 -- animation time vs clock time disagreement still trusted (about two frames)

export type Sink = (
	key: number,
	t: number,
	op: number,
	id: number,
	fade: number,
	weight: number,
	speed: number,
	timePos: number,
	prio: number,
	looped: boolean
) -> ()

export type TrackState = {
	track: any,
	str: string,
	id: number, -- 0 = no id yet
	stage: number, -- 0 PLAY not sent yet, 1 playing (PLAY sent), 2 STOP sent
	t0: number, -- clock time of Play
	tp0: number, -- TimePosition at Play
	wc0: number, -- WeightCurrent at Play
	exact: number, -- exact PLAY fade (-1: estimate)
	speedQ: number, -- last sent speed, quantized
	speedSent: number,
	speedT: number, -- time of the last SPEED
	lastSpeed: number, -- speed at the last step
	weight: number, -- last sent weight
	weightT: number, -- time of the last WEIGHT
	lastWt: number, -- WeightTarget at the last step
	prio: number,
	lastTp: number,
	lastT: number,
	lastWc: number,
	stopping: boolean, -- stopped, STOP not sent yet
	stopT: number,
	stopTp: number,
	stopWc: number,
	stopExact: number,
	conn: any,
}

export type Watch = {
	key: number,
	animator: any,
	played: any,
	list: { TrackState },
	n: number,
	byTrack: { [any]: TrackState },
	lastT: number,
	alive: boolean,
}

local clock: () -> number = os.clock
local resolve: (s: string) -> number = function(_s: string): number
	return 0
end
local sink: Sink = function() end

local exactPlay = setmetatable({} :: { [any]: number }, { __mode = "k" })
local exactStop = setmetatable({} :: { [any]: number }, { __mode = "k" })
local loaded = setmetatable({} :: { [any]: { [any]: any } }, { __mode = "k" })

-- clockFn: server time now; resolveFn: AnimationId -> id (0 = none yet);
-- sinkFn receives every event (key = the watch's key, usually the slot).
function AnimWatch.configure(clockFn: () -> number, resolveFn: (s: string) -> number, sinkFn: Sink)
	clock = clockFn
	resolve = resolveFn
	sink = sinkFn
end

--------------------------------------------------------------------------------
-- Model helpers
--------------------------------------------------------------------------------

-- The Humanoid or AnimationController of a model.
function AnimWatch.controller(model: any): any
	if model == nil then
		return nil
	end
	return model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildOfClass("AnimationController")
end

function AnimWatch.animator(model: any): any
	local controller = AnimWatch.controller(model)
	return if controller ~= nil then controller:FindFirstChildOfClass("Animator") else nil
end

-- A track for `animation` on `animator`, loaded once per animator.
function AnimWatch.load(animator: any, animation: any): any
	local cache = loaded[animator]
	if cache == nil then
		cache = setmetatable({}, { __mode = "k" }) :: any
		loaded[animator] = cache
	end
	local track = cache[animation]
	if track == nil then
		track = animator:LoadAnimation(animation)
		cache[animation] = track
	end
	return track
end

-- Plays with an exact fade: the watcher sends this fade instead of estimating one.
function AnimWatch.play(animator: any, animation: any, fade: number?, weight: number?, speed: number?): any
	local f = fade or 0.1
	local track = AnimWatch.load(animator, animation)
	exactPlay[track] = f
	track:Play(f, weight or 1, speed or 1)
	return track
end

-- Stops every playing track of `animation` on `animator` with an exact fade.
function AnimWatch.stop(animator: any, animation: any, fade: number?): number
	local f = fade or 0.1
	local id = animation.AnimationId
	local count = 0
	for _, track in animator:GetPlayingAnimationTracks() do
		local a = track.Animation
		if a == animation or (a ~= nil and a.AnimationId == id) then
			exactStop[track] = f
			track:Stop(f)
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Watching
--------------------------------------------------------------------------------

-- Animation time since a reference: from TimePosition when it agrees with the
-- clock (it advances in the same animation step as the weight ramp), else clock time.
local function elapsed(track: any, tpFrom: number, tpNow: number, speed: number, wall: number): number
	if speed > 0.05 or speed < -0.05 then
		local d = tpNow - tpFrom
		local len = track.Length
		if len > 0 and track.Looped then
			if speed > 0 and d < 0 then
				d += len
			elseif speed < 0 and d > 0 then
				d -= len
			end
		end
		local e = d / speed
		if e >= 0 and abs(e - wall) <= FRAME_SLACK then
			return e
		end
	end
	return wall
end

local function wrapTime(track: any, tp: number, looped: boolean): number
	local len = track.Length
	if len > 0 then
		if looped then
			return tp % len
		elseif tp > len then
			return len
		end
	end
	if tp < 0 then
		return 0
	end
	return tp
end

local function clampFade(f: number): number
	if f ~= f or f < 0 then
		return 0
	elseif f > 1 then
		return 1
	end
	return f
end

local function stampOf(w: Watch, t: number): number
	if t < w.lastT then
		t = w.lastT
	end
	w.lastT = t
	return t
end

-- Sends the PLAY of a track once its fade can be told (or `force`). Returns false while waiting.
local function tryPlay(w: Watch, st: TrackState, now: number, force: boolean): boolean
	if st.id == 0 then
		st.id = resolve(st.str)
		if st.id == 0 then
			return false
		end
	end
	local track = st.track
	local wc = track.WeightCurrent
	local wt = track.WeightTarget
	local tp = track.TimePosition
	local speed = track.Speed
	local wall = now - st.t0
	local e = elapsed(track, st.tp0, tp, speed, wall)
	local fade = st.exact
	if fade < 0 then
		local span = wt - st.wc0
		if span <= 0.001 or wc >= wt - 0.001 then
			fade = 0 -- already at its weight (Play with fade 0, or a restart at full weight)
		elseif wc - st.wc0 <= 0.0001 then
			if wall < WAIT_MAX and not force then
				return false -- not stepped yet
			end
			fade = Config.animationFade
		else
			fade = e * span / (wc - st.wc0)
		end
		fade = clampFade(fade)
	end
	local t = stampOf(w, st.t0)
	local back = e - (t - st.t0) -- animation time from the stamp to now
	if back < 0 then
		back = 0
	end
	local looped = track.Looped
	local prio = priorityIndex(track.Priority)
	sink(w.key, t, PLAY, st.id, fade, wt, speed, wrapTime(track, tp - back * speed, looped), prio, looped)
	st.stage = 1
	st.speedQ = qSpeed(speed)
	st.speedSent = speed
	st.speedT = now
	st.lastSpeed = speed
	st.weight = wt
	st.weightT = now
	st.lastWt = wt
	st.prio = prio
	st.lastTp = tp
	st.lastT = now
	st.lastWc = wc
	return true
end

local function tryStop(w: Watch, st: TrackState, now: number, force: boolean): boolean
	local track = st.track
	local fade = st.stopExact
	if fade < 0 then
		local wc = track.WeightCurrent
		local w0 = st.stopWc
		local wall = now - st.stopT
		if w0 <= 0.001 or wc <= 0.0001 then
			fade = 0
		elseif w0 - wc <= 0.0001 then
			if wall < WAIT_MAX and not force then
				return false
			end
			fade = Config.animationFade
		else
			fade = elapsed(track, st.stopTp, track.TimePosition, track.Speed, wall) * w0 / (w0 - wc)
		end
		fade = clampFade(fade)
	end
	sink(w.key, stampOf(w, st.stopT), STOP, st.id, fade, 0, 0, 0, 0, false)
	st.stage = 2
	st.stopping = false
	return true
end

local function diff(w: Watch, st: TrackState, now: number)
	local track = st.track
	local tp = track.TimePosition
	local speed = track.Speed
	local wt = track.WeightTarget
	local wc = track.WeightCurrent
	local dt = now - st.lastT
	local id = st.id
	local sq = qSpeed(speed)
	if sq ~= st.speedQ and (abs(speed - st.speedSent) >= SPEED_JUMP or now - st.speedT >= BLEND_EVERY) then
		sink(w.key, stampOf(w, now), SPEED, id, 0, 0, speed, 0, 0, false)
		st.speedQ = sq
		st.speedSent = speed
		st.speedT = now
	end
	if speed == st.lastSpeed then
		local expect = st.lastTp + dt * speed
		local d = tp - expect
		local len = track.Length
		local looped = track.Looped
		if len > 0 then
			if looped then
				d = (d + len * 0.5) % len - len * 0.5
			elseif expect > len then
				d = tp - len
			end
		end
		if d > SEEK_MIN or d < -SEEK_MIN then
			sink(w.key, stampOf(w, now), SEEK, id, 0, 0, 0, wrapTime(track, tp, looped), 0, false)
		end
	end
	local dw = abs(wt - st.weight)
	if dw > WEIGHT_MIN and (dw >= WEIGHT_JUMP or now - st.weightT >= BLEND_EVERY) then
		local from = st.lastWc
		local fade
		if abs(wt - wc) <= 0.001 then
			fade = 0
		elseif wt ~= st.lastWt and abs(wc - from) > 0.0001 then
			fade = clampFade(dt * abs(wt - from) / abs(wc - from)) -- changed during this step
		else
			fade = Config.animationFade
		end
		sink(w.key, stampOf(w, now), WEIGHT, id, fade, wt, 0, 0, 0, false)
		st.weight = wt
		st.weightT = now
	end
	local prio = priorityIndex(track.Priority)
	if prio ~= st.prio then
		sink(w.key, stampOf(w, now), PRIORITY, id, 0, 0, 0, 0, prio, false)
		st.prio = prio
	end
	st.lastTp = tp
	st.lastT = now
	st.lastWc = wc
	st.lastSpeed = speed
	st.lastWt = wt
end

local function removeAt(w: Watch, i: number)
	local list = w.list
	local st = list[i]
	if st.conn ~= nil then
		st.conn:Disconnect()
		st.conn = nil
	end
	w.byTrack[st.track] = nil
	list[i] = list[w.n]
	list[w.n] = nil
	w.n -= 1
end

local function onStopped(w: Watch, st: TrackState)
	if not w.alive or st.stopping or st.stage == 2 then
		return
	end
	local track = st.track
	st.stopping = true
	st.stopT = clock()
	st.stopTp = track.TimePosition
	st.stopWc = track.WeightCurrent
	local exact = exactStop[track]
	if exact ~= nil then
		exactStop[track] = nil
		st.stopExact = exact
	else
		st.stopExact = -1
	end
	if st.stage == 1 and st.stopExact >= 0 then
		tryStop(w, st, st.stopT, true)
	end
end

local function onPlayed(w: Watch, track: any)
	if not w.alive then
		return
	end
	local now = clock()
	local st = w.byTrack[track]
	if st == nil then
		st = {
			track = track,
			str = "",
			id = 0,
			stage = 0,
			t0 = now,
			tp0 = 0,
			wc0 = 0,
			exact = -1,
			speedQ = 0,
			speedSent = 0,
			speedT = 0,
			lastSpeed = 0,
			weight = 0,
			weightT = 0,
			lastWt = 0,
			prio = 0,
			lastTp = 0,
			lastT = now,
			lastWc = 0,
			stopping = false,
			stopT = 0,
			stopTp = 0,
			stopWc = 0,
			stopExact = -1,
			conn = nil,
		}
		local state: TrackState = st :: any
		w.byTrack[track] = state
		w.n += 1
		w.list[w.n] = state
		state.conn = track.Stopped:Connect(function()
			onStopped(w, state)
		end)
	end
	local s: TrackState = st :: any
	local anim = track.Animation
	s.str = if anim ~= nil then anim.AnimationId else ""
	s.id = if s.str ~= "" then resolve(s.str) else 0
	s.stage = 0
	s.t0 = now
	s.tp0 = track.TimePosition
	s.wc0 = track.WeightCurrent
	s.stopping = false
	local exact = exactPlay[track]
	if exact ~= nil then
		exactPlay[track] = nil
		s.exact = exact
		tryPlay(w, s, now, false)
	else
		s.exact = -1
	end
end

-- Starts watching an animator. Tracks already playing are sent at once (fade 0).
function AnimWatch.new(key: number, animator: any): Watch
	local w: Watch = {
		key = key,
		animator = animator,
		played = nil,
		list = {},
		n = 0,
		byTrack = {},
		lastT = -math.huge,
		alive = true,
	}
	w.played = animator.AnimationPlayed:Connect(function(track)
		onPlayed(w, track)
	end)
	for _, track in animator:GetPlayingAnimationTracks() do
		exactPlay[track] = 0
		onPlayed(w, track)
	end
	return w
end

function AnimWatch.stopWatching(w: Watch)
	w.alive = false
	if w.played ~= nil then
		w.played:Disconnect()
		w.played = nil
	end
	for i = w.n, 1, -1 do
		removeAt(w, i)
	end
end

-- One watch step (the caller keeps it at 60 Hz or less).
function AnimWatch.step(w: Watch, now: number)
	local list = w.list
	local i = 1
	while i <= w.n do
		local st = list[i]
		local track = st.track
		local stage = st.stage
		if stage == 0 then
			local ended = st.stopping or not track.IsPlaying
			if not tryPlay(w, st, now, ended) then
				if st.id == 0 and ended then
					removeAt(w, i) -- never got an id: nothing was sent
					continue
				end
				i += 1
				continue
			end
			stage = 1
		end
		if stage == 1 then
			if not st.stopping and (not track.IsPlaying or track.WeightTarget <= 0.001) then
				-- stopped without a Stopped event (or weight 0): sometime since the last step
				st.stopping = true
				st.stopT = st.lastT
				st.stopTp = st.lastTp
				st.stopWc = st.lastWc
				st.stopExact = -1
			end
			if st.stopping then
				tryStop(w, st, now, false)
			else
				diff(w, st, now)
			end
		elseif not st.stopping and track.IsPlaying and track.WeightTarget > 0.001 then
			-- playing again without AnimationPlayed (weight raised after weight 0): a new PLAY
			st.stage = 0
			st.t0 = now
			st.tp0 = track.TimePosition
			st.wc0 = track.WeightCurrent
			st.exact = -1
		elseif not track.IsPlaying and track.WeightCurrent <= 0.0001 then
			removeAt(w, i)
			continue
		end
		i += 1
	end
end

-- What the watched animator is playing (owner side of Tide.playing).
function AnimWatch.describe(w: Watch, nameOf: (id: number) -> string): { [string]: any }
	local out = {}
	for i = 1, w.n do
		local st = w.list[i]
		local track = st.track
		if st.stage == 1 and not st.stopping then
			local name = if st.id ~= 0 then nameOf(st.id) else st.str
			out[name] = {
				id = st.id,
				name = name,
				since = st.t0,
				timePosition = track.TimePosition,
				speed = track.Speed,
				weight = track.WeightTarget,
				priority = track.Priority,
				looped = track.Looped,
				track = track,
			}
		end
	end
	return out
end

return AnimWatch
