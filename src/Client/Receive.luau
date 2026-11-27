--!strict
--!native
--!optimize 2
-- Relay packets -> per-entity rings (numbers only; no tables or CFrames here).
--
-- Buffer need is measured once per packet per entity, at its first MOVING record
-- (pose differs from the sample before it). Stop samples, keep-alives and rest
-- markers are not motion: an idle entity adds no need and is never a "stall".
--   own source (client-owned entity):  need = arrival - t(previous sample)
--   kind-shared source (server-owned): need = (arrival - t) + 1/rate + max(0, gap - expected)
-- where `expected` is the entity's own recent sample gap. A mid/far entity the
-- relay sends every farEvery-th sample thus needs what a near one needs, plus
-- its own jitter: near entities keep the near delay, far ones may extrapolate up
-- to (farEvery - 1)/rate between their samples (bounded by kind.extrapolate).
--
-- Velocity records (v0.5, kinds with velocity = true): a record that starts with slot 0 has a
-- header byte, then the usual record, then the velocity and spin the header describes
-- (Server/Relay, Codec.readMotion). Cut samples (Tide.bump) are kept out of the buffer need:
-- they are out of tick by design. A kind's onSample (client option) is called for each
-- accepted sample of its entities, as it is stored.
--
-- Copies (kind option restRepeats: the server sends a resting entity's last samples again): a
-- record whose time is within a quarter tick of a sample already held is that sample again
-- and is dropped before anything looks at it (no second onSample, no need, nothing stored).
-- Two copies decode from different packet times, so their times agree to rounding, not to
-- the bit. A copy that arrives first (the original was lost) is stored like any sample, in
-- its place in time (refused, and counted late, when it is older than everything held).

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local Ring = require(Shared.Ring)
local State = require(script.Parent.State)
local Buffer = require(script.Parent.Buffer)
local Rig = require(Shared.Rig)
local LH = require(Shared.Lighthouse)

local Receive = {}

local TAG_FRAME = 1
local HEADER = 10
local TICK = 0.0005

local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readf64 = buffer.readf64
local blen = buffer.len
local sizeAt = Codec.sizeAt
local read = Codec.read
local push = Ring.push
local setVel = Ring.setVel
local addNeed = Buffer.addNeed
local motionSize = Codec.motionSize
local readMotion = Codec.readMotion
local MOTION_MAX = Codec.MOTION_MAX
local MOTION_CUT = Codec.CUT
local RING_CUT = Ring.CUT
local find = Ring.find
local DUP = TICK * 0.25

local index = State.index
local mine = State.mine
local rings = State.ring
local srcs = State.src
local pkts = State.pkt
local dirtyFrom = State.dirtyFrom
local kinds = State.kind
local gapE = State.gapE
local counters = State.counters
local oxs, oys, ozs = State.ox, State.oy, State.oz
local models = State.model

local packetId = 0

-- kind.onSample for one stored sample (allocates its arguments; only kinds that ask).
local function emit(fn: any, slot: number, r: any, li: number, cut: boolean)
	local model = models[slot]
	if model == nil then
		return
	end
	local p = li % r.cap + 1
	local full = r.full
	local cf = Rig.cframe(
		r.x[p],
		r.y[p],
		r.z[p],
		r.yaw[p],
		full,
		if full then r.qx[p] else 0,
		if full then r.qy[p] else 0,
		if full then r.qz[p] else 0,
		if full then r.qw[p] else 1
	)
	local v, w
	if r.vel then
		v = Vector3.new(r.vx[p], r.vy[p], r.vz[p])
		w = Vector3.new(r.wx[p], r.wy[p], r.wz[p])
	end
	local ok = pcall(fn, model, r.t[p], cf, v, w, cut)
	if not ok then
		counters.applyErrors += 1
	end
end

function Receive.packet(payload: any, arrival: number)
	if typeof(payload) ~= "buffer" then
		counters.badPacket += 1
		return
	end
	local b: buffer = payload
	local n = blen(b)
	if n < HEADER or readu8(b, 0) ~= TAG_FRAME then
		counters.badPacket += 1
		return
	end
	counters.packets += 1
	packetId += 1
	local pkt = packetId
	local wide = readu8(b, 1) % 2 == 1
	local frameTime = readf64(b, 2)
	local needGapMax = Config.NeedGapMax
	local snapGap = Config.SnapGap
	local pos = HEADER
	local nvel = 0
	while pos < n do
		local slot
		if wide then
			if pos + 2 > n then
				break
			end
			slot = readu16(b, pos)
			pos += 2
		else
			slot = readu8(b, pos)
			pos += 1
		end
		local hdr = -1 -- velocity header, -1 for a plain record
		if slot == 0 then
			-- velocity record: header, then the real slot
			if pos + 1 > n then
				break
			end
			hdr = readu8(b, pos)
			pos += 1
			if hdr > MOTION_MAX then
				break -- bits this version does not know: the record's size is unknown
			end
			if wide then
				if pos + 2 > n then
					break
				end
				slot = readu16(b, pos)
				pos += 2
			else
				if pos + 1 > n then
					break
				end
				slot = readu8(b, pos)
				pos += 1
			end
			if slot == 0 then
				break
			end
		end
		if pos + 1 > n then
			break
		end
		local ticks = readu8(b, pos)
		pos += 1
		if ticks == 255 then
			if pos + 2 > n then
				break
			end
			ticks = readu16(b, pos)
			pos += 2
		end
		if pos + 8 > n then
			break
		end
		local size = sizeAt(b, pos)
		if pos + size > n then
			break
		end
		if hdr >= 0 and pos + size + motionSize(hdr) > n then
			break
		end
		local _, x, y, z, yaw, flags, qx, qy, qz, qw = read(b, pos, oxs[slot], oys[slot], ozs[slot])
		pos += size
		local vx, vy, vz, wx, wy, wz = 0, 0, 0, 0, 0, 0
		if hdr >= 0 then
			pos, vx, vy, vz, wx, wy, wz = readMotion(b, pos, hdr)
			nvel += 1
		end
		counters.records += 1

		if index[slot] == nil then
			counters.unknownSlot += 1 -- the reliable ADD has not arrived yet (or already removed)
			continue
		end
		if mine[slot] then
			continue
		end
		local t = frameTime - ticks * TICK
		local r = rings[slot]
		local newest = -math.huge
		if r.n > 0 then
			newest = r.t[r.last % r.cap + 1]
		end
		if t - newest < DUP then
			-- not past everything held: a copy of a held sample, or a late one
			local k = find(r, t + DUP)
			if k > r.last - r.n and r.t[k % r.cap + 1] > t - DUP then
				counters.repeats += 1
				continue
			end
		end
		local fl = flags % 2
		if r.n > 0 and t - newest > snapGap then
			fl = 1 -- long silence (cull, loss): do not sweep across it
		end
		local cut = hdr >= MOTION_CUT and r.vel
		if cut then
			fl += RING_CUT
		end
		local li = push(r, t, x, y, z, yaw, fl, qx, qy, qz, qw)
		if hdr >= 0 then
			setVel(r, li, vx, vy, vz, wx, wy, wz)
		end
		if li > 0 and li == r.last and fl == 0 and r.n >= 2 then
			local cap = r.cap
			local q = (li - 1) % cap + 1
			local tq = r.t[q]
			local gap = t - tq
			local moving = x ~= r.x[q] or y ~= r.y[q] or z ~= r.z[q] or yaw ~= r.yaw[q]
			if not moving and r.full then
				moving = qx ~= r.qx[q] or qy ~= r.qy[q] or qz ~= r.qz[q] or qw ~= r.qw[q]
			end
			if moving and gap < needGapMax then
				local src = srcs[slot]
				if src.shared then
					local interval = 1 / kinds[slot].rate
					local e = gapE[slot]
					if e < interval then
						e = interval
					end
					if pkts[slot] ~= pkt then
						pkts[slot] = pkt
						local need = arrival - t + interval
						if gap > e then
							need += gap - e
						end
						addNeed(src, need)
					end
					-- expected gap: rises fast (tier change to mid/far), falls slower
					if gap > e then
						gapE[slot] = e + (gap - e) * 0.5
					else
						gapE[slot] = e + (gap - e) * 0.25
					end
				elseif pkts[slot] ~= pkt then
					pkts[slot] = pkt
					addNeed(src, arrival - tq)
				end
			end
		end
		if li > 0 then
			-- Hermite on [t_i, t_i+1] uses samples i-1..i+2: times from t_(li-2) on may change
			local from = -math.huge
			if li - 2 >= r.last - r.n + 1 then
				from = r.t[(li - 2) % r.cap + 1]
			end
			if from < dirtyFrom[slot] then
				dirtyFrom[slot] = from
			end
			local fn = kinds[slot].onSample
			if fn then
				emit(fn, slot, r, li, cut)
			end
		else
			counters.late += 1
		end
	end
	if nvel > 0 then
		counters.velocityRecords += nvel
		local count = LH.counter
		if count then
			count("Tide.Velocity.samples", nvel)
		end
	end
	if pos ~= n then
		counters.badPacket += 1
	end
end

return Receive
