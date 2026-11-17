--!strict
-- Animation channel, server side (Config.animations = true):
--   * receives owners' events (20 ANIM) and id requests (22 REGISTER), validates them:
--     owner check, op / id / priority range, stamp clamp (MaxBackdate / MaxAhead) and
--     monotonic per entity (equal allowed), Config.AnimEventsPerSecond per player
--     (burst ANIM_BURST), REGISTER: REGISTER_PER_MINUTE requests per player (known ids
--     too: each answer is a remote call), valid asset URL, MaxAnimIds / 8 new ids per
--     player over the server's life, Config.MaxAnimIds in total. Drops are counted and
--     reported to onSuspicious (not events from a player that owned the entity until
--     OWNER_GRACE ago: they were in flight when the owner changed or it was removed);
--   * watches the Animators of server-owned entities (bots, NPCs) itself;
--   * keeps what each entity plays (AnimSet) for snapshots and Tide.playing;
--   * relays every event once per frame to each receiver that currently gets the
--     entity (not culled, never its owner), and sends a snapshot (24 ANIMSNAP) when
--     a receiver starts getting an entity: late join, back in cull range, owner change.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Control = require(Shared.Control)
local AnimCodec = require(Shared.AnimCodec)
local AnimRegistry = require(Shared.AnimRegistry)
local AnimSet = require(Shared.AnimSet)
local AnimWatch = require(Shared.AnimWatch)
local Signal = require(Shared.Signal)
local State = require(script.Parent.State)

local Anim = {}

Anim.active = false
Anim.animatedSignal = Signal.new()

local ANIM_BURST = 30 -- events a player may send at once
local REGISTER_PER_MINUTE = 64
local FULL_TABLE_EVERY = 5 -- seconds between full id table requests per player
local WATCH_STEP = 1 / 60
local ATTACH_EVERY = 0.5 -- seconds between looks for bot Animators that appeared or changed
local KEEP_STOPPED = 1.0 -- seconds stopped entries stay queryable (Tide.playing at a past t)
local OWNER_GRACE = 2.0 -- seconds an old owner's in-flight events are dropped without onSuspicious

local STOP = AnimCodec.STOP
local OP_NAMES = AnimCodec.OP_NAMES
local TICK = AnimCodec.TICK
local qDt = AnimCodec.qDt
local INF = math.huge

local owner = State.owner
local index = State.index
local active = State.active
local counters = State.counters

local remote: any = nil
local bcast: Control.Writer = nil :: any
local sets = {} :: { [number]: AnimSet.Set }
local lastT = {} :: { [number]: number }
local watches = {} :: { [number]: AnimWatch.Watch }
-- who owned a slot until an owner change / removal, and when (in-flight events are not suspicious)
local prevOwner = {} :: { [number]: any }
local prevOwnerT = {} :: { [number]: number }
-- runtime ids registered per player (UserId), over the server's life: one player may
-- not use up Config.MaxAnimIds for everyone
local registered = {} :: { [number]: number }

-- events accepted this frame (relayed in Anim.flush)
local evSlot = {} :: { number }
local evT = {} :: { number }
local evOp = {} :: { number }
local evId = {} :: { number }
local evFade = {} :: { number }
local evWeight = {} :: { number }
local evSpeed = {} :: { number }
local evTp = {} :: { number }
local evPrio = {} :: { number }
local evLooped = {} :: { boolean }
local nev = 0
local snapsPending = false

local out = Control.writer(512)
local watchAcc = 0
local attachAcc = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function writeAnimId(w: Control.Writer, id: number, s: string)
	Control.u8(w, Control.ANIMID)
	Control.u16(w, id)
	Control.str(w, s)
end

local function accept(
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
	local set = sets[slot]
	if set == nil then
		return
	end
	AnimSet.prune(set, t - KEEP_STOPPED)
	AnimSet.apply(set, t, op, id, fade, weight, speed, timePos, prio, looped)
	lastT[slot] = t
	nev += 1
	evSlot[nev] = slot
	evT[nev] = t
	evOp[nev] = op
	evId[nev] = id
	evFade[nev] = fade
	evWeight[nev] = weight
	evSpeed[nev] = speed
	evTp[nev] = timePos
	evPrio[nev] = prio
	evLooped[nev] = looped
	counters.animEvents += 1
	if #Anim.animatedSignal.fns > 0 then
		local name = AnimRegistry.name(id)
		Signal.fire(Anim.animatedSignal, State.model[slot], OP_NAMES[op], name, {
			id = id,
			name = name,
			time = t,
			fade = fade,
			weight = weight,
			speed = speed,
			timePosition = timePos,
			priority = AnimCodec.priority(prio),
			looped = looped,
		})
	end
end

-- Id for a server-side watcher (bots): assigned on first sight and announced.
local function resolveServer(s: string): number
	local id = AnimRegistry.id(s)
	if id ~= nil then
		return id
	end
	if #s > 255 then
		return 0
	end
	id = AnimRegistry.assign(s)
	if id == nil then
		counters.animIdsFull += 1
		return 0
	end
	writeAnimId(bcast, id, s)
	return id
end

local function sinkServer(
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
	if owner[slot] == false then
		accept(slot, t, op, id, fade, weight, speed, timePos, prio, looped)
	end
end

function Anim.init(remoteR: any, broadcast: Control.Writer)
	remote = remoteR
	bcast = broadcast
	Anim.active = Config.animations
	if not Anim.active then
		return
	end
	AnimRegistry.seed(Config.animationFolder)
	AnimWatch.configure(now, resolveServer, sinkServer)
end

--------------------------------------------------------------------------------
-- Entities
--------------------------------------------------------------------------------

local function detach(slot: number)
	local w = watches[slot]
	if w ~= nil then
		AnimWatch.stopWatching(w)
		watches[slot] = nil
	end
end

local function attach(slot: number)
	local animator = AnimWatch.animator(State.model[slot])
	if animator ~= nil then
		watches[slot] = AnimWatch.new(slot, animator)
	end
end

local function queueSnap(rx: any, slot: number)
	local snaps = rx.animSnap
	if snaps == nil then
		snaps = {}
		rx.animSnap = snaps
	end
	if table.find(snaps, slot) == nil then
		table.insert(snaps, slot)
	end
	snapsPending = true
end

local function setPrevOwner(slot: number, player: any)
	if player then
		prevOwner[slot] = player
		prevOwnerT[slot] = now()
	else
		prevOwner[slot] = nil
		prevOwnerT[slot] = nil
	end
end

function Anim.onAdd(slot: number)
	if not Anim.active then
		return
	end
	setPrevOwner(slot, nil)
	detach(slot)
	if State.kind[slot].animations == false then
		sets[slot] = nil
		return
	end
	local set = sets[slot]
	if set == nil then
		sets[slot] = AnimSet.new()
	else
		AnimSet.clear(set)
	end
	lastT[slot] = -INF
	if owner[slot] == false then
		attach(slot)
	end
end

function Anim.onRemove(slot: number)
	if not Anim.active then
		return
	end
	setPrevOwner(slot, owner[slot])
	detach(slot)
	sets[slot] = nil
	lastT[slot] = nil
end

-- Owner changed: what the old owner played is void; receivers get an empty
-- snapshot and the new owner's watcher sends what is playing now.
function Anim.onOwner(slot: number, old: any)
	if not Anim.active then
		return
	end
	setPrevOwner(slot, old)
	local set = sets[slot]
	if set == nil then
		return
	end
	detach(slot)
	AnimSet.clear(set)
	lastT[slot] = -INF
	for _, rx in State.rxList do
		if owner[slot] ~= rx.player and rx.tier[slot] ~= 4 then
			queueSnap(rx, slot)
		end
	end
	if owner[slot] == false then
		attach(slot)
	end
end

-- Relay hook: a receiver starts getting an entity again (back inside its cull range).
function Anim.onEnter(rx: any, slot: number)
	if sets[slot] ~= nil and owner[slot] ~= rx.player then
		queueSnap(rx, slot)
	end
end

-- Hello extras for a joining receiver: ids assigned at runtime.
function Anim.helloIds(w: Control.Writer)
	if not Anim.active then
		return
	end
	for id = AnimRegistry.seeded + 1, AnimRegistry.count do
		local s = AnimRegistry.string(id)
		if s ~= nil then
			writeAnimId(w, id, s)
		end
	end
end

-- A receiver became ready (tiers known): snapshots of everything it gets that plays.
function Anim.onReady(rx: any)
	if not Anim.active then
		return
	end
	for k = 1, State.count do
		local slot = active[k]
		local set = sets[slot]
		if set ~= nil and set.n > 0 and owner[slot] ~= rx.player and rx.tier[slot] ~= 4 then
			queueSnap(rx, slot)
		end
	end
end

--------------------------------------------------------------------------------
-- Receive
--------------------------------------------------------------------------------

-- 20 ANIM from a client: f64 baseTime, u8 count, count x event. Returns the next position.
function Anim.handleUp(player: any, rx: any, b: buffer, pos: number): number
	local n = buffer.len(b)
	if not Anim.active or pos + 9 > n then
		counters.animBad += 1
		State.suspicious(player, "badPacket")
		return n
	end
	local base = buffer.readf64(b, pos)
	local count = buffer.readu8(b, pos + 8)
	pos += 9
	if base ~= base or base == INF or base == -INF then
		counters.animBad += 1
		State.suspicious(player, "badPacket")
		return n
	end
	local t0 = now()
	local lo = t0 - Config.MaxBackdate
	local hi = t0 + Config.MaxAhead
	local rate = Config.AnimEventsPerSecond
	local burst = math.min(ANIM_BURST, rate)
	local tokens = (rx.animTokens or burst) + (t0 - (rx.animT or t0)) * rate
	if tokens > burst then
		tokens = burst
	end
	rx.animT = t0
	local overRate, notOwner = false, false
	local maxId = AnimRegistry.count
	for _ = 1, count do
		local np, slot, dt, op, id, fade, weight, speed, timePos, prio, looped = AnimCodec.read(b, pos, n)
		if np < 0 then
			counters.animBad += 1
			State.suspicious(player, "badPacket")
			rx.animTokens = tokens
			return n
		end
		pos = np
		if tokens < 1 then
			counters.animRate += 1
			overRate = true
			continue
		end
		tokens -= 1
		if owner[slot] ~= player or index[slot] == nil then
			counters.animOwner += 1
			-- sent before the owner change / removal reached the client: not suspicious
			if prevOwner[slot] ~= player or t0 - prevOwnerT[slot] > OWNER_GRACE then
				notOwner = true
			end
			continue
		end
		if sets[slot] == nil then
			counters.animDropped += 1 -- kind opted out
			continue
		end
		if id < 1 or id > maxId or prio > AnimCodec.MAX_PRIORITY then
			counters.animUnknown += 1
			continue
		end
		local t = base + dt * TICK
		if t < lo then
			t = lo
		elseif t > hi then
			t = hi
		end
		if t < lastT[slot] then
			counters.animStamp += 1
			continue
		end
		accept(slot, t, op, id, fade, weight, speed, timePos, prio, looped)
	end
	rx.animTokens = tokens
	if overRate then
		State.suspicious(player, "animRate")
	end
	if notOwner then
		State.suspicious(player, "animOwner")
	end
	return pos
end

-- 22 REGISTER from a client: u8 length, AnimationId (length 0: send every id).
function Anim.handleRegister(player: any, rx: any, b: buffer, pos: number): number
	local n = buffer.len(b)
	if not Anim.active or pos + 1 > n then
		counters.animBad += 1
		return n
	end
	local len = buffer.readu8(b, pos)
	if pos + 1 + len > n then
		counters.animBad += 1
		State.suspicious(player, "badPacket")
		return n
	end
	local s = buffer.readstring(b, pos + 1, len)
	pos += 1 + len
	local t = now()
	if len == 0 then
		-- the client's folder differs from the server's: the whole table
		if t - (rx.animTableT or -INF) < FULL_TABLE_EVERY then
			return pos
		end
		rx.animTableT = t
		local w = Control.writer(1024)
		for id = 1, AnimRegistry.count do
			local str = AnimRegistry.string(id)
			if str ~= nil then
				writeAnimId(w, id, str)
			end
		end
		if w.pos > 0 then
			remote:FireClient(player, Control.take(w), {})
		end
		return pos
	end
	-- every single-id request (known or new) takes a token: a known id is answered
	-- with a remote call of its own, so unthrottled lookups would amplify
	local refill = REGISTER_PER_MINUTE / 60
	local tokens = (rx.regTokens or REGISTER_PER_MINUTE) + (t - (rx.regT or t)) * refill
	if tokens > REGISTER_PER_MINUTE then
		tokens = REGISTER_PER_MINUTE
	end
	rx.regT = t
	rx.regTokens = tokens
	if tokens < 1 then
		counters.animRegister += 1
		State.suspicious(player, "animRegister")
		return pos
	end
	local id = AnimRegistry.id(s)
	if id ~= nil then
		rx.regTokens = tokens - 1
		local w = Control.writer(8 + len)
		writeAnimId(w, id, s)
		remote:FireClient(player, Control.take(w), {})
		return pos
	end
	if not AnimRegistry.valid(s) then
		counters.animRegister += 1
		State.suspicious(player, "animRegister")
		return pos
	end
	-- one player may register a share of Config.MaxAnimIds over the server's life
	local user = player.UserId
	local mine = registered[user] or 0
	if mine >= math.max(16, Config.MaxAnimIds // 8) then
		counters.animRegister += 1
		State.suspicious(player, "animRegister")
		return pos
	end
	id = AnimRegistry.assign(s)
	if id == nil then
		counters.animIdsFull += 1
		State.suspicious(player, "animRegister")
		return pos
	end
	registered[user] = mine + 1
	rx.regTokens = tokens - 1
	writeAnimId(bcast, id, s) -- everyone, the requester included
	return pos
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

-- Bot watching: (re)attach now and then, step at most at 60 Hz.
function Anim.step(t: number, dt: number)
	if not Anim.active then
		return
	end
	attachAcc += dt
	if attachAcc >= ATTACH_EVERY then
		attachAcc = 0
		for k = 1, State.count do
			local slot = active[k]
			if sets[slot] ~= nil and owner[slot] == false then
				local w = watches[slot]
				if w == nil or w.animator.Parent == nil then
					detach(slot)
					attach(slot)
				end
			end
		end
	end
	watchAcc += dt
	if watchAcc >= WATCH_STEP * 0.9 then
		watchAcc = 0
		for _, w in watches do
			AnimWatch.step(w, t)
		end
	end
end

local function writeSnap(w: Control.Writer, slot: number, t: number)
	local set = sets[slot]
	AnimSet.prune(set, t - KEEP_STOPPED)
	Control.u8(w, Control.ANIMSNAP)
	Control.u16(w, slot)
	Control.f64(w, t)
	local countPos = w.pos
	Control.u8(w, 0)
	local c = 0
	for i = 1, set.n do
		local e = set.e[i]
		if e.stopT == INF then
			AnimCodec.writeState(w, e.id, e.weight, e.speed, AnimSet.timeAt(e, t), e.prio, e.looped)
			c += 1
		end
	end
	buffer.writeu8(w.b, countPos, c)
end

-- Sends this frame's events (and pending snapshots) to each receiver, after the
-- broadcast (ADD, ANIMID) went out.
function Anim.flush(t: number)
	if nev == 0 and not snapsPending then
		return
	end
	local w = out
	for _, rx in State.rxList do
		local me = rx.player
		local tiers = rx.tier
		local count = 0
		local countPos = 0
		for i = 1, nev do
			local slot = evSlot[i]
			if sets[slot] ~= nil and owner[slot] ~= me and tiers[slot] ~= 4 then
				if count == 0 then
					Control.u8(w, Control.ANIM)
					Control.f64(w, t)
					countPos = w.pos
					Control.u16(w, 0)
				end
				AnimCodec.write(
					w,
					slot,
					qDt(evT[i] - t),
					evOp[i],
					evId[i],
					evFade[i],
					evWeight[i],
					evSpeed[i],
					evTp[i],
					evPrio[i],
					evLooped[i]
				)
				count += 1
			end
		end
		if count > 0 then
			buffer.writeu16(w.b, countPos, count)
		end
		local snaps = rx.animSnap
		if snaps ~= nil and #snaps > 0 then
			for _, slot in snaps do
				if sets[slot] ~= nil and index[slot] ~= nil and owner[slot] ~= me then
					writeSnap(w, slot, t)
				end
			end
			table.clear(snaps)
		end
		if w.pos > 0 then
			local b, insts = Control.takeAll(w)
			remote:FireClient(me, b, insts)
			counters.animRelayBytes += buffer.len(b)
		end
	end
	nev = 0
	snapsPending = false
end

--------------------------------------------------------------------------------
-- Queries and explicit play
--------------------------------------------------------------------------------

-- What an entity plays at time t (default now): { [name] = info }; nil if not animated.
function Anim.playing(slot: number, t: number?): { [string]: any }?
	local set = sets[slot]
	if set == nil then
		return nil
	end
	local at = t or now()
	AnimSet.prune(set, now() - KEEP_STOPPED)
	return AnimSet.describe(set, at, AnimRegistry.name)
end

local function animatorOf(slot: number): any
	local w = watches[slot]
	if w ~= nil and w.animator.Parent ~= nil then
		return w.animator
	end
	return AnimWatch.animator(State.model[slot])
end

-- Server-owned entities only (a client-owned entity plays on its owner).
function Anim.play(slot: number, animation: any, fade: number?, weight: number?, speed: number?): any
	if owner[slot] ~= false then
		return nil
	end
	local animator = animatorOf(slot)
	if animator == nil then
		return nil
	end
	return AnimWatch.play(animator, animation, fade, weight, speed)
end

function Anim.stop(slot: number, animation: any, fade: number?): number
	if owner[slot] ~= false then
		return 0
	end
	local animator = animatorOf(slot)
	if animator == nil then
		return 0
	end
	return AnimWatch.stop(animator, animation, fade)
end

return Anim
