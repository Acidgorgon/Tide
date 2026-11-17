--!strict
--!native
--!optimize 2
-- Relay: every new history sample is encoded ONCE per frame into a shared
-- scratch buffer; each receiver then gets memcpy'd byte ranges in its packets.
--
-- Packet (server -> client, "TideU"):
--   u8 tag = 1 | u8 flags (bit0 wide slots) | f64 frameTime
--   records: slot u8|u16, dt u8 (255 -> u16) in 0.5 ms before frameTime, sample
--
-- Tiers per receiver and entity (recomputed every Config.InterestEvery):
--   1 near  (<= kind.near)  every sample
--   2 mid   (<= kind.far)   every kind.farEvery-th sample (teleports and idle markers always)
--   3 far   (<= kind.cull)  as mid, and dropped first when the receiver is over budget
--   4 culled                nothing
-- Boundaries have Config.Hysteresis studs of hysteresis.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local State = require(script.Parent.State)

local Relay = {}

local TAG_FRAME = 1
local HEADER = 10
local TICK = 0.0005

local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writef64 = buffer.writef64
local bcopy = buffer.copy
local bcreate = buffer.create
local blen = buffer.len
local round = math.round
local ceil = math.ceil
local write = Codec.write
local writeDt = Codec.writeDt

local active = State.active
local owner = State.owner
local hist = State.hist
local kinds = State.kind
local relayed = State.relayed
local counters = State.counters

-- frame scratch
local scratch = bcreate(16384)
local recOff = table.create(1024, 0) :: { number } -- byte offset of record r (recOff[n+1] = end)
local recKeep = table.create(1024, false) :: { boolean } -- kept for reduced tiers
local entFirst = {} :: { [number]: number }
local entLast = {} :: { [number]: number }
local dirty = table.create(256, 0) :: { number }
local ndirty = 0

-- packet assembly
local out = bcreate(1024)
local outPos = HEADER
local exact = {} :: { [number]: buffer } -- exact-size send buffers by length (Fire copies at the call)
local remote: any = nil
local curPlayer: any = nil
local sentBytes = 0
local sentPackets = 0

local interestAcc = 0

function Relay.init(unreliable: any)
	remote = unreliable
	if blen(out) < Config.MaxPacket then
		out = bcreate(Config.MaxPacket)
	end
end

-- Tier for distance d with hysteresis around the current tier.
local function band(kind: any, d: number): number
	if d <= kind.near then
		return 1
	elseif d <= kind.far then
		return 2
	elseif d <= kind.cull then
		return 3
	end
	return 4
end

local function tierFor(kind: any, d: number, cur: number?): number
	local hys = Config.Hysteresis
	local lo = band(kind, d - hys)
	local hi = band(kind, d + hys)
	if cur == nil then
		return band(kind, d)
	elseif cur < lo then
		return lo
	elseif cur > hi then
		return hi
	end
	return cur
end
Relay.tierFor = tierFor

-- Receiver position: newest sample of the receiver's own character entity, or
-- where it last was (dead, respawning). A receiver that never had a character
-- gets everything as "far" (thinned and within its byte budget).
local function rxPosition(rx: any): (boolean, number, number, number)
	local slot = State.charSlot[rx.player]
	if slot == nil or State.index[slot] == nil then
		local lx = rx.lastX
		if lx ~= nil then
			return true, lx, rx.lastY, rx.lastZ
		end
		return false, 0, 0, 0
	end
	local h = hist[slot]
	local p = h.last % h.cap + 1
	local x, y, z = h.x[p], h.y[p], h.z[p]
	rx.lastX, rx.lastY, rx.lastZ = x, y, z
	return true, x, y, z
end

local function computeTier(rx: any, slot: number, has: boolean, px: number, py: number, pz: number)
	local tiers = rx.tier
	if not has then
		tiers[slot] = 3
		return
	end
	local h = hist[slot]
	local p = h.last % h.cap + 1
	local dx, dy, dz = h.x[p] - px, h.y[p] - py, h.z[p] - pz
	tiers[slot] = tierFor(kinds[slot], math.sqrt(dx * dx + dy * dy + dz * dz), tiers[slot])
end

-- New entity: fresh tiers for every receiver (slots are reused).
function Relay.onAdd(slot: number)
	for _, rx in State.rxList do
		rx.tier[slot] = nil
		local has, px, py, pz = rxPosition(rx)
		computeTier(rx, slot, has, px, py, pz)
	end
end

-- Receiver became ready: tiers for everything.
function Relay.onReady(rx: any)
	table.clear(rx.tier)
	local has, px, py, pz = rxPosition(rx)
	for k = 1, State.count do
		computeTier(rx, active[k], has, px, py, pz)
	end
end

local function recomputeInterest()
	local count = State.count
	for _, rx in State.rxList do
		local has, px, py, pz = rxPosition(rx)
		local me = rx.player
		for k = 1, count do
			local slot = active[k]
			if owner[slot] ~= me then
				computeTier(rx, slot, has, px, py, pz)
			end
		end
	end
end

local function flush()
	local n = outPos
	if n <= HEADER then
		return
	end
	local b = exact[n]
	if b == nil then
		b = bcreate(n)
		exact[n] = b
	end
	bcopy(b, 0, out, 0, n)
	remote:FireClient(curPlayer, b)
	sentBytes += n
	sentPackets += 1
	outPos = HEADER
end

-- Copies records rFirst..rLast (contiguous in scratch) with as few copies as
-- possible, splitting at MaxPacket on record boundaries.
local function copyRecords(rFirst: number, rLast: number, maxPacket: number)
	local r = rFirst
	local stop = recOff[rLast + 1]
	while r <= rLast do
		local a = recOff[r]
		local room = maxPacket - outPos
		if stop - a <= room then
			bcopy(out, outPos, scratch, a, stop - a)
			outPos += stop - a
			return
		end
		local e = r
		while e <= rLast and recOff[e + 1] - a <= room do
			e += 1
		end
		if e == r and outPos == HEADER then
			e = r + 1 -- a record larger than an empty packet (tiny MaxPacket): send it alone
		end
		if e > r then
			local bytes = recOff[e] - a
			bcopy(out, outPos, scratch, a, bytes)
			outPos += bytes
		end
		flush()
		r = e
	end
end

local function copyKept(rFirst: number, rLast: number, maxPacket: number): number
	local bytes = 0
	for r = rFirst, rLast do
		if recKeep[r] then
			local ra = recOff[r]
			local rb = recOff[r + 1] - ra
			if outPos + rb > maxPacket then
				flush()
			end
			bcopy(out, outPos, scratch, ra, rb)
			outPos += rb
			bytes += rb
		end
	end
	return bytes
end

local function ensureScratch(need: number)
	local size = blen(scratch)
	if need <= size then
		return
	end
	while size < need do
		size *= 2
	end
	local nb = bcreate(size)
	bcopy(nb, 0, scratch, 0, blen(scratch))
	scratch = nb
end

function Relay.step(now: number, dt: number)
	local count = State.count

	-- 1. which entities have new samples; frame time = max(now, newest sample) on the 0.5 ms grid
	ndirty = 0
	local frameTime = now
	for k = 1, count do
		local slot = active[k]
		local h = hist[slot]
		if h.last > relayed[slot] then
			ndirty += 1
			dirty[ndirty] = slot
			local t = h.t[h.last % h.cap + 1]
			if t > frameTime then
				frameTime = t
			end
		end
	end

	interestAcc += dt
	if interestAcc >= Config.InterestEvery then
		interestAcc = 0
		recomputeInterest()
	end

	if ndirty == 0 then
		return
	end
	frameTime = ceil(frameTime / TICK) * TICK
	local wide = State.maxSlot > 255

	-- 2. encode every new sample once
	local pos = 0
	local nrec = 0
	for d = 1, ndirty do
		local slot = dirty[d]
		local h = hist[slot]
		local cap = h.cap
		local last = h.last
		local from = relayed[slot] + 1
		local oldest = last - h.n + 1
		if from < oldest then
			from = oldest
		end
		local kind = kinds[slot]
		local farEvery = kind.farEvery
		local fullBit = if h.full then 2 else 0 -- the ring's own layout (a kind's rotation may change later)
		local ts, xs, ys, zs, yaws, fls = h.t, h.x, h.y, h.z, h.yaw, h.fl
		entFirst[slot] = nrec + 1
		ensureScratch(pos + (last - from + 1) * 32)
		for li = from, last do
			local p = li % cap + 1
			nrec += 1
			recOff[nrec] = pos
			if wide then
				writeu16(scratch, pos, slot)
				pos += 2
			else
				writeu8(scratch, pos, slot)
				pos += 1
			end
			pos = writeDt(scratch, pos, round((frameTime - ts[p]) / TICK))
			local fl = fls[p]
			if fullBit == 2 then
				pos = write(scratch, pos, xs[p], ys[p], zs[p], yaws[p], fl + 2, h.qx[p], h.qy[p], h.qz[p], h.qw[p])
			else
				pos = write(scratch, pos, xs[p], ys[p], zs[p], yaws[p], fl, 0, 0, 0, 1)
			end
			local keep = fl % 2 == 1 or li % farEvery == 0
			if not keep and li > oldest then
				-- idle markers (stop sample, keep-alive, rest marker: same pose as the
				-- previous sample) always go to mid/far too, or those receivers would
				-- see long silences and keep the last motion going
				local q = (li - 1) % cap + 1
				keep = xs[p] == xs[q] and ys[p] == ys[q] and zs[p] == zs[q] and yaws[p] == yaws[q]
					and (fullBit == 0 or (h.qx[p] == h.qx[q] and h.qy[p] == h.qy[q] and h.qz[p] == h.qz[q] and h.qw[p] == h.qw[q]))
			end
			recKeep[nrec] = keep
		end
		entLast[slot] = nrec
		relayed[slot] = last
	end
	recOff[nrec + 1] = pos

	-- 3. per receiver: memcpy ranges, split at MaxPacket, budget for mid/far
	local maxPacket = Config.MaxPacket
	writeu8(out, 0, TAG_FRAME)
	writeu8(out, 1, if wide then 1 else 0)
	writef64(out, 2, frameTime)
	local budget = Config.ReceiverBytesPerSecond
	local burst = budget * 0.5
	for _, rx in State.rxList do
		local me = rx.player
		curPlayer = me
		outPos = HEADER
		sentBytes = 0
		sentPackets = 0
		local tokens = rx.tokens + budget * dt
		if tokens > burst then
			tokens = burst
		end
		local tiers = rx.tier
		local defer = rx.defer
		local nd = 0
		-- near entities: coalesce runs that are contiguous in scratch into one copy
		local runFirst, runLast = 1, 0
		for d = 1, ndirty do
			local slot = dirty[d]
			if owner[slot] == me then
				continue
			end
			local tier = tiers[slot] or 1
			if tier == 1 then
				local ef = entFirst[slot]
				if ef ~= runLast + 1 then
					if runLast >= runFirst then
						copyRecords(runFirst, runLast, maxPacket)
					end
					runFirst = ef
				end
				runLast = entLast[slot]
			elseif tier < 4 then
				nd += 1
				defer[nd] = slot
			end
		end
		if runLast >= runFirst then
			copyRecords(runFirst, runLast, maxPacket)
		end
		if nd > 0 then
			-- mid first, then far, while the budget lasts
			for pass = 2, 3 do
				for i = 1, nd do
					local slot = defer[i]
					if tiers[slot] == pass then
						if sentBytes + outPos < tokens then
							copyKept(entFirst[slot], entLast[slot], maxPacket)
						else
							counters.budgetDropped += 1
						end
					end
				end
			end
		end
		flush()
		tokens -= sentBytes
		if tokens < -budget then
			tokens = -budget
		end
		rx.tokens = tokens
		counters.relayBytes += sentBytes
		counters.relayPackets += sentPackets
	end
	curPlayer = nil
end

return Relay
