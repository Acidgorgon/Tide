--!strict
--!native
--!optimize 2
-- Heartbeat: sample the entities this client owns on a steady schedule
-- (next += 1/rate, lag capped to one interval, at most one sample per frame)
-- and upload them in one packet:
--   u8 tag = 2 | u8 count | count x (u16 slot, f64 stamp, sample)
-- Idle (same quantized pose as the last upload): the first unchanged sample still
-- goes out (a "stop" sample: receivers see zero velocity), then unchanged samples
-- are skipped with a keep-alive every kind.keepAlive. When the entity moves again
-- a rest marker (the last upload re-sent with the last skipped time) goes first.
-- After a server teleport, samples are flagged for Config.TeleportAckTime and
-- never skipped.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local Rig = require(Shared.Rig)
local State = require(script.Parent.State)
local LH = require(Shared.Lighthouse)

local Upload = {}

local TAG_UPLOAD = 2
local RECORD_MAX = 2 + 8 + 8 + 4 + 12

local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writef64 = buffer.writef64
local bcopy = buffer.copy
local bcreate = buffer.create
local write = Codec.write
local quantize = Codec.quantize
local read = Rig.read

local active = State.active
local mine = State.mine
local kinds = State.kind
local models = State.model
local roots = State.root
local nextT = State.nextT
local teleUntil = State.teleUntil
local lastRec = State.lastRec
local lastLen = State.lastLen
local upStill = State.upStill
local upHeldT = State.upHeldT
local upSentT = State.upSentT
local tickT = State.upTickT
local upX, upY, upZ, upYaw = State.upX, State.upY, State.upZ, State.upYaw
local upQX, upQY, upQZ, upQW = State.upQX, State.upQY, State.upQZ, State.upQW
local counters = State.counters

local MAX_RECORDS = 16
local out = bcreate(2 + MAX_RECORDS * RECORD_MAX)
local exact = {} :: { [number]: buffer }
local remote: any = nil

function Upload.init(unreliable: any)
	remote = unreliable
end

local pos = 2
local count = 0

local function send()
	if count == 0 then
		return
	end
	writeu8(out, 0, TAG_UPLOAD)
	writeu8(out, 1, count)
	local b = exact[pos]
	if b == nil then
		b = bcreate(pos)
		exact[pos] = b
	end
	bcopy(b, 0, out, 0, pos)
	remote:FireServer(b)
	local lh = LH.api
	if lh then
		lh.net("Tide", "Upload", "out", pos)
	end
	counters.uploads += 1
	counters.uploadBytes += pos
	pos = 2
	count = 0
end

-- Re-sends the last uploaded record of `slot` (redundancy), optionally with a new stamp (rest marker).
local function copyLast(slot: number, stamp: number?)
	local len = lastLen[slot]
	if count >= MAX_RECORDS then
		send()
	end
	bcopy(out, pos, lastRec[slot], 0, len)
	if stamp ~= nil then
		writef64(out, pos + 2, stamp)
	end
	pos += len
	count += 1
end

local function addRecord(slot: number, now: number, kind: any)
	local model = models[slot]
	if model == nil then
		return
	end
	local root = roots[slot]
	local full = kind.full
	local x, y, z, yaw, qx, qy, qz, qw = read(model, root, full)
	local flags = if full then 2 else 0
	local tele = now <= teleUntil[slot]
	if tele then
		flags += 1
	end
	local _fl
	x, y, z, yaw, _fl, qx, qy, qz, qw = quantize(x, y, z, yaw, flags, qx, qy, qz, qw)
	local plen = lastLen[slot]
	local rest = 0
	if
		not tele
		and plen > 0
		and x == upX[slot]
		and y == upY[slot]
		and z == upZ[slot]
		and yaw == upYaw[slot]
		and (not full or (qx == upQX[slot] and qy == upQY[slot] and qz == upQZ[slot] and qw == upQW[slot]))
	then
		if upStill[slot] and now - upSentT[slot] < kind.keepAlive then
			upHeldT[slot] = now
			counters.uploadSkipped += 1
			return
		end
		upStill[slot] = true -- stop sample, or keep-alive
	else
		if upStill[slot] and not tele then
			rest = upHeldT[slot]
		end
		upStill[slot] = false
	end
	upHeldT[slot] = 0

	if rest > 0 then
		copyLast(slot, rest)
	elseif Config.UploadRedundancy >= 2 and plen > 0 then
		copyLast(slot, nil)
	end
	if count >= MAX_RECORDS then
		send()
	end
	local start = pos
	writeu16(out, pos, slot)
	writef64(out, pos + 2, now)
	pos = write(out, pos + 10, x, y, z, yaw, flags, qx, qy, qz, qw)
	count += 1
	local rec = lastRec[slot]
	if rec == nil then
		rec = bcreate(RECORD_MAX)
		lastRec[slot] = rec
	end
	bcopy(rec, 0, out, start, pos - start)
	lastLen[slot] = pos - start
	upSentT[slot] = now
	upX[slot], upY[slot], upZ[slot], upYaw[slot] = x, y, z, yaw
	upQX[slot], upQY[slot], upQZ[slot], upQW[slot] = qx, qy, qz, qw
end

function Upload.step(now: number)
	if remote == nil then
		return
	end
	for k = 1, State.count do
		local slot = active[k]
		if mine[slot] then
			local kind = kinds[slot]
			local due = nextT[slot]
			local interval = 1 / kind.rate
			-- a little early is fine (frame jitter); the schedule itself never drifts.
			-- Samples stay at least 0.6 interval apart (the server drops < 0.5).
			if now >= due - 0.2 * interval and now - tickT[slot] >= 0.6 * interval then
				tickT[slot] = now
				due += interval
				if due < now - interval then
					due = now - interval
				end
				nextT[slot] = due
				addRecord(slot, now, kind)
			end
		end
	end
	send()
end

-- After a server teleport: the next sample goes out on the next Heartbeat, and
-- samples are flagged for Config.TeleportAckTime (one may be lost or arrive
-- stamped before the server's teleport sample).
function Upload.flagTeleport(slot: number, now: number)
	teleUntil[slot] = now + Config.TeleportAckTime
	nextT[slot] = now
end

-- Resets the upload state of a slot this client now owns.
function Upload.reset(slot: number, now: number)
	nextT[slot] = now
	teleUntil[slot] = -math.huge
	lastLen[slot] = 0
	upStill[slot] = false
	upHeldT[slot] = 0
	upSentT[slot] = now
	tickT[slot] = -math.huge
end

return Upload
