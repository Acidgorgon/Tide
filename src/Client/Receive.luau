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

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local Ring = require(Shared.Ring)
local State = require(script.Parent.State)
local Buffer = require(script.Parent.Buffer)

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
local addNeed = Buffer.addNeed

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

local packetId = 0

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
		local _, x, y, z, yaw, flags, qx, qy, qz, qw = read(b, pos, oxs[slot], oys[slot], ozs[slot])
		pos += size
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
		local fl = flags % 2
		if r.n > 0 and t - newest > snapGap then
			fl = 1 -- long silence (cull, loss): do not sweep across it
		end
		local li = push(r, t, x, y, z, yaw, fl, qx, qy, qz, qw)
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
		else
			counters.late += 1
		end
	end
	if pos ~= n then
		counters.badPacket += 1
	end
end

return Receive
