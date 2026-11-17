--!strict
--!native
--!optimize 2
-- Animation channel encoding (reliable "TideR", see Control). One event:
--   u16 slot, i16 dt (0.5 ms steps relative to the message's baseTime), u8 op, u16 animId, then by op:
--     PLAY(1)     u8 fade (10 ms), u8 weight (1/100), i16 speed (1/256), u16 timePos (ms), u8 priority, u8 flags (bit0 looped)
--     STOP(2)     u8 fade
--     SPEED(3)    i16 speed
--     WEIGHT(4)   u8 weight, u8 fade
--     SEEK(5)     u16 timePos
--     PRIORITY(6) u8 priority
-- Snapshot state (ANIMSNAP, the state at the message's baseTime):
--   u16 animId, u8 weight, i16 speed, f32 timePos (seconds, not wrapped: the server does not know
--   track lengths), u8 priority, u8 flags (bit0 looped)
-- Priority is an index: 0 Core, 1 Idle, 2 Movement, 3 Action, 4 Action2, 5 Action3, 6 Action4.

local Control = require(script.Parent.Control)

local AnimCodec = {}

AnimCodec.PLAY = 1
AnimCodec.STOP = 2
AnimCodec.SPEED = 3
AnimCodec.WEIGHT = 4
AnimCodec.SEEK = 5
AnimCodec.PRIORITY = 6
AnimCodec.OP_NAMES = table.freeze({ "play", "stop", "speed", "weight", "seek", "priority" })

AnimCodec.HEADER = 7 -- slot, dt, op, id
AnimCodec.STATE = 11 -- one snapshot state
AnimCodec.TICK = 0.0005
AnimCodec.MAX_PRIORITY = 6

local SIZE = { 8, 1, 2, 2, 2, 1 }

local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readi16 = buffer.readi16
local readf32 = buffer.readf32
local round = math.round

local PRIORITY_NAMES = { "Core", "Idle", "Movement", "Action", "Action2", "Action3", "Action4" }
local prioItems: { [number]: any }? = nil
local prioIndex: { [any]: number } = {}

local function buildPriorities(): { [number]: any }
	local items = {}
	local enum = (Enum :: any).AnimationPriority
	for i, name in PRIORITY_NAMES do
		local item = enum[name]
		items[i - 1] = item
		prioIndex[item] = i - 1
	end
	prioItems = items
	return items
end

-- Enum.AnimationPriority item -> wire index (unknown items count as Core).
function AnimCodec.priorityIndex(item: any): number
	if prioItems == nil then
		buildPriorities()
	end
	return prioIndex[item] or 0
end

-- Wire index -> Enum.AnimationPriority item.
function AnimCodec.priority(index: number): any
	local items = prioItems or buildPriorities()
	return items[index] or items[0]
end

local function clampRound(v: number, lo: number, hi: number): number
	if v ~= v then
		return lo
	end
	local q = round(v)
	if q < lo then
		return lo
	elseif q > hi then
		return hi
	end
	return q
end

-- Quantizers (wire units). The watcher compares these to decide what changed.
function AnimCodec.qFade(s: number): number
	return clampRound(s * 100, 0, 255)
end

function AnimCodec.qWeight(w: number): number
	return clampRound(w * 100, 0, 255)
end

function AnimCodec.qSpeed(s: number): number
	return clampRound(s * 256, -32768, 32767)
end

function AnimCodec.qTime(s: number): number
	return clampRound(s * 1000, 0, 65535)
end

function AnimCodec.qDt(s: number): number
	return clampRound(s / 0.0005, -32768, 32767)
end

local qFade, qWeight, qSpeed, qTime = AnimCodec.qFade, AnimCodec.qWeight, AnimCodec.qSpeed, AnimCodec.qTime

-- Appends one event. Values in seconds / plain units; dt already in 0.5 ms steps.
function AnimCodec.write(
	w: Control.Writer,
	slot: number,
	dt: number,
	op: number,
	id: number,
	fade: number,
	weight: number,
	speed: number,
	timePos: number,
	prio: number,
	looped: boolean
)
	Control.u16(w, slot)
	Control.i16(w, dt)
	Control.u8(w, op)
	Control.u16(w, id)
	if op == 1 then
		Control.u8(w, qFade(fade))
		Control.u8(w, qWeight(weight))
		Control.i16(w, qSpeed(speed))
		Control.u16(w, qTime(timePos))
		Control.u8(w, prio)
		Control.u8(w, if looped then 1 else 0)
	elseif op == 2 then
		Control.u8(w, qFade(fade))
	elseif op == 3 then
		Control.i16(w, qSpeed(speed))
	elseif op == 4 then
		Control.u8(w, qWeight(weight))
		Control.u8(w, qFade(fade))
	elseif op == 5 then
		Control.u16(w, qTime(timePos))
	else
		Control.u8(w, prio)
	end
end

-- Reads one event at pos (n = buffer length). Returns the position after it, or
-- -1 when the event is cut short or the op is unknown (the rest of the message
-- cannot be parsed). Fields an op does not carry are 0 / false.
function AnimCodec.read(
	b: buffer,
	pos: number,
	n: number
): (number, number, number, number, number, number, number, number, number, number, boolean)
	if pos + 7 > n then
		return -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, false
	end
	local slot = readu16(b, pos)
	local dt = readi16(b, pos + 2)
	local op = readu8(b, pos + 4)
	local id = readu16(b, pos + 5)
	local size = SIZE[op]
	if size == nil or pos + 7 + size > n then
		return -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, false
	end
	local p = pos + 7
	local fade, weight, speed, timePos, prio, looped = 0, 0, 0, 0, 0, false
	if op == 1 then
		fade = readu8(b, p) / 100
		weight = readu8(b, p + 1) / 100
		speed = readi16(b, p + 2) / 256
		timePos = readu16(b, p + 4) / 1000
		prio = readu8(b, p + 6)
		looped = readu8(b, p + 7) % 2 == 1
	elseif op == 2 then
		fade = readu8(b, p) / 100
	elseif op == 3 then
		speed = readi16(b, p) / 256
	elseif op == 4 then
		weight = readu8(b, p) / 100
		fade = readu8(b, p + 1) / 100
	elseif op == 5 then
		timePos = readu16(b, p) / 1000
	else
		prio = readu8(b, p)
	end
	return p + size, slot, dt, op, id, fade, weight, speed, timePos, prio, looped
end

-- Appends one snapshot state.
function AnimCodec.writeState(
	w: Control.Writer,
	id: number,
	weight: number,
	speed: number,
	timePos: number,
	prio: number,
	looped: boolean
)
	Control.u16(w, id)
	Control.u8(w, qWeight(weight))
	Control.i16(w, qSpeed(speed))
	Control.f32(w, timePos)
	Control.u8(w, prio)
	Control.u8(w, if looped then 1 else 0)
end

-- Reads one snapshot state (caller checks the length): id, weight, speed, timePos, prio, looped.
function AnimCodec.readState(b: buffer, pos: number): (number, number, number, number, number, boolean)
	return readu16(b, pos),
		readu8(b, pos + 2) / 100,
		readi16(b, pos + 3) / 256,
		readf32(b, pos + 5),
		readu8(b, pos + 9),
		readu8(b, pos + 10) % 2 == 1
end

return AnimCodec
