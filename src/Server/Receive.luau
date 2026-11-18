--!strict
--!native
--!optimize 2
-- Upload validation: client -> server samples on "TideU".
--   u8 tag = 2 | u8 count | count x (u16 slot, f64 stamp, sample)
-- Never throws on bad input (the caller also wraps this in pcall). Every
-- accepted sample lands in the entity's history ring, quantized exactly as
-- receivers will decode it.
--
-- Speed rules (per entity, against the last accepted sample):
--   * spacing: a stamp must be at least half an upload interval (0.5 / kind.rate)
--     after the previous one, so samples cannot be packed to flush history or
--     fake velocities;
--   * the time a move may use is the stamp gap, but at most the server time
--     since the last accepted arrival plus a jitter credit (STAMP_SLACK, spent
--     and refilled, never per record), and at most max(2 * keepAlive, MaxBackdate):
--     silence and back-dated stamps bank no movement;
--   * horizontal distance <= maxSpeed * dt, rise <= maxRise * dt, fall <= maxFall * dt,
--     plus a tolerance bucket (SLACK studs, refilled at SLACK_RATE studs/s) instead
--     of a fixed per-record allowance.
-- Rejected moves for Config.SpeedResync seconds in a row teleport the owner back.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local Ring = require(Shared.Ring)
local State = require(script.Parent.State)

local Receive = {}

local TAG_UPLOAD = 2
local HEADER = 2
local RECORD_MIN = 2 + 8 + 8

local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readf64 = buffer.readf64
local len = buffer.len
local sizeAt = Codec.sizeAt
local read = Codec.read
local push = Ring.push
local sin = math.sin
local cos = math.cos

local owner = State.owner
local oxs, oys, ozs = State.ox, State.oy, State.oz
local quantize = Codec.quantize
local hist = State.hist
local kinds = State.kind
local index = State.index
local tpPending, tpX, tpY, tpZ = State.tpPending, State.tpX, State.tpY, State.tpZ
local lastArr, stampBank, slackH, slackV, speedSince =
	State.lastArr, State.stampBank, State.slackH, State.slackV, State.speedSince
local counters = State.counters

local INF = math.huge
local STAMP_SLACK = 0.25 -- seconds stamps may run ahead of arrivals (network jitter)
local SLACK = 0.5 -- studs of speed tolerance (quantization, physics noise), per axis group
local SLACK_RATE = 2 -- studs/s the tolerance refills at (the most it adds to a sustained speed)
local sqrt = math.sqrt

-- Fresh validation state for a slot (add, owner change, server teleport ack).
function Receive.reset(slot: number, now: number)
	lastArr[slot] = now
	stampBank[slot] = STAMP_SLACK
	slackH[slot] = SLACK
	slackV[slot] = SLACK
	speedSince[slot] = nil
end

local function rejectSpeed(player: any, slot: number, now: number)
	counters.speed += 1
	State.suspicious(player, "speed")
	local since = speedSince[slot]
	if since == nil then
		speedSince[slot] = now
	else
		local resync = Config.SpeedResync
		if resync > 0 and now - since >= resync then
			speedSince[slot] = nil
			local hook = State.onResync
			if hook then
				hook(slot)
			end
		end
	end
end

-- Per-player upload limiter fields live on the receiver record:
--   upTokens, upT (last refill time), upFrame, upFrameBytes
function Receive.handle(player: any, rx: any, payload: any, now: number, frame: number)
	if typeof(payload) ~= "buffer" then
		counters.badPacket += 1
		State.suspicious(player, "badPacket")
		return
	end
	local b: buffer = payload
	local n = len(b)

	-- byte caps (token bucket per second, plus a per-frame cap)
	local rate = Config.PlayerBytesPerSecond
	local tokens = rx.upTokens + (now - rx.upT) * rate
	if tokens > rate then
		tokens = rate
	end
	rx.upT = now
	if rx.upFrame ~= frame then
		rx.upFrame = frame
		rx.upFrameBytes = 0
	end
	if n > tokens or rx.upFrameBytes + n > Config.PlayerBytesPerFrame then
		rx.upTokens = tokens
		counters.rate += 1
		return
	end
	rx.upTokens = tokens - n
	rx.upFrameBytes += n

	if n < HEADER + RECORD_MIN or readu8(b, 0) ~= TAG_UPLOAD then
		counters.badPacket += 1
		State.suspicious(player, "badPacket")
		return
	end
	local count = readu8(b, 1)
	if count == 0 or count > Config.MaxUploadCount then
		counters.badPacket += 1
		State.suspicious(player, "badPacket")
		return
	end
	counters.packets += 1

	local lo = now - Config.MaxBackdate
	local hi = now + Config.MaxAhead
	local pos = HEADER
	for _ = 1, count do
		if pos + RECORD_MIN > n then
			counters.badPacket += 1
			State.suspicious(player, "badPacket")
			return
		end
		local slot = readu16(b, pos)
		local stamp = readf64(b, pos + 2)
		local size = sizeAt(b, pos + 10)
		if pos + 10 + size > n then
			counters.badPacket += 1
			State.suspicious(player, "badPacket")
			return
		end
		local _, x, y, z, yaw, flags, qx, qy, qz, qw = read(b, pos + 10)
		pos += 10 + size

		if owner[slot] ~= player or index[slot] == nil or kinds[slot].motion == false then
			counters.owner += 1 -- not theirs, or a state-only entity (no samples)
			continue
		end
		-- NaN / inf (abs positions are f32 and may carry either)
		if
			stamp ~= stamp
			or x ~= x
			or y ~= y
			or z ~= z
			or x == INF
			or x == -INF
			or y == INF
			or y == -INF
			or z == INF
			or z == -INF
			or qx ~= qx
			or qy ~= qy
			or qz ~= qz
			or qw ~= qw
		then
			counters.nan += 1
			State.suspicious(player, "nan")
			continue
		end
		if stamp < lo then
			stamp = lo
		elseif stamp > hi then
			stamp = hi
		end
		local h = hist[slot]
		local cap = h.cap
		local p = h.last % cap + 1
		local lastT = h.t[p]
		if stamp <= lastT then
			counters.stamp += 1
			continue
		end
		local kind = kinds[slot]
		local full = h.full
		if full and flags % 4 < 2 then
			-- yaw-only sample for a full-rotation kind: rotation from yaw
			local half = yaw * 0.5
			qx, qy, qz, qw = 0, sin(half), 0, cos(half)
		end

		if tpPending[slot] then
			-- after a server teleport: only the owner's flagged sample near the target
			-- counts (the target is already in history, flagged); everything else is
			-- a pre-teleport sample still in flight, or the owner ignoring the teleport
			local near = false
			if flags % 2 == 1 then
				local dx, dy, dz = x - tpX[slot], y - tpY[slot], z - tpZ[slot]
				local r = Config.TeleportGrantRadius
				near = dx * dx + dy * dy + dz * dz <= r * r
			end
			if not near then
				counters.teleportWait += 1
				continue
			end
			State.endTeleport(slot)
			Receive.reset(slot, now)
		else
			local gap = stamp - lastT
			if gap < 0.5 / kind.rate then
				counters.spacing += 1
				continue
			end
			-- time this move may use (see the header)
			local elapsed = now - lastArr[slot]
			if elapsed < 0 then
				elapsed = 0
			end
			local avail = stampBank[slot] + elapsed
			local dt = gap
			if dt > avail then
				dt = avail
			end
			local cap = 2 * kind.keepAlive
			if cap < Config.MaxBackdate then
				cap = Config.MaxBackdate
			end
			if dt > cap then
				dt = cap
			end
			local refill = elapsed * SLACK_RATE
			local sh = slackH[slot] + refill
			if sh > SLACK then
				sh = SLACK
			end
			local sv = slackV[slot] + refill
			if sv > SLACK then
				sv = SLACK
			end
			local dx, dz = x - h.x[p], z - h.z[p]
			local overH = sqrt(dx * dx + dz * dz) - kind.maxSpeed * dt
			local dy = y - h.y[p]
			local overV = if dy >= 0 then dy - kind.maxRise * dt else -dy - kind.maxFall * dt
			if overH > sh or overV > sv then
				rejectSpeed(player, slot, now)
				continue
			end
			if overH > 0 then
				sh -= overH
			end
			if overV > 0 then
				sv -= overV
			end
			slackH[slot] = sh
			slackV[slot] = sv
			local bank = avail - dt
			stampBank[slot] = if bank > STAMP_SLACK then STAMP_SLACK else bank
			lastArr[slot] = now
			speedSince[slot] = nil
		end
		local cx = oxs[slot]
		if cx ~= nil then
			-- the entity has its own origin: keep what receivers will decode (relayed relative to it)
			local _fl
			x, y, z, yaw, _fl, qx, qy, qz, qw = quantize(x, y, z, yaw, if full then 2 else 0, qx, qy, qz, qw, cx, oys[slot], ozs[slot])
		end
		push(h, stamp, x, y, z, yaw, 0, qx, qy, qz, qw)
		counters.samples += 1
	end
	if pos ~= n then
		counters.badPacket += 1
		State.suspicious(player, "badPacket")
	end
end

return Receive
