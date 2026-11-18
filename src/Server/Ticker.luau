--!strict
--!native
--!optimize 2
-- Server-owned entities: sampled at kind.rate with an accumulator (no drift).
-- Idle: the first unchanged sample is still pushed (a "stop" sample: receivers
-- see zero velocity and do not extrapolate), later unchanged ticks are skipped
-- with a keep-alive every kind.keepAlive. When the entity moves again, the last
-- unchanged tick is pushed first (rest marker) so receivers do not smear the
-- start of the motion across the idle gap. Client uploads follow the same rules.
-- Teleport flag (receivers snap, no sweep): after handle:teleport, after handle:markTeleport
-- (at once, or on the first sample near its target), and on a jump longer than the kind's
-- teleportDistance between two samples.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Kinds = require(Shared.Kinds)
local Codec = require(Shared.Codec)
local Ring = require(Shared.Ring)
local Rig = require(Shared.Rig)
local State = require(script.Parent.State)

local Ticker = {}

local active = State.active
local owner = State.owner
local hist = State.hist
local kinds = State.kind
local models = State.model
local roots = State.root
local sentT = State.sentT
local heldT = State.heldT
local forceTele = State.forceTele
local still = State.still
local markUntil = State.markUntil
local oxs, oys, ozs = State.ox, State.oy, State.oz
local markX, markY, markZ = State.markX, State.markY, State.markZ
local counters = State.counters

local quantize = Codec.quantize
local read = Rig.read
local push = Ring.push

-- Samples one server-owned entity now. Exposed for teleports and tests.
function Ticker.sample(slot: number, now: number)
	local kind = kinds[slot]
	local h = hist[slot]
	local full = h.full -- the ring's own layout (a kind's rotation may change later)
	local model = models[slot]
	local root = roots[slot]
	if root ~= nil and root.Parent == nil then
		root = nil
	end
	local x, y, z, yaw, qx, qy, qz, qw = read(model, root, full)
	local _fl
	x, y, z, yaw, _fl, qx, qy, qz, qw = quantize(x, y, z, yaw, if full then 2 else 0, qx, qy, qz, qw, oxs[slot], oys[slot], ozs[slot])
	local p = h.last % h.cap + 1
	local lastT = h.t[p]
	if now <= lastT then
		return
	end
	local tele = forceTele[slot] == true
	local mark = markUntil[slot]
	if mark ~= nil then
		if now > mark then
			markUntil[slot] = nil
		else
			local dx, dy, dz = x - markX[slot], y - markY[slot], z - markZ[slot]
			local r = Config.TeleportGrantRadius
			if dx * dx + dy * dy + dz * dz <= r * r and (x ~= h.x[p] or y ~= h.y[p] or z ~= h.z[p]) then
				-- at the target, and moved there since the last sample
				markUntil[slot] = nil
				if not tele then
					tele = true
					counters.teleportFlagged += 1
				end
			end
		end
	end
	if not tele then
		local limit = kind.teleportDistance
		if limit < math.huge then
			local dx, dy, dz = x - h.x[p], y - h.y[p], z - h.z[p]
			if dx * dx + dy * dy + dz * dz > limit * limit then
				tele = true
				counters.teleportFlagged += 1
			end
		end
	end
	local same = not tele
		and x == h.x[p]
		and y == h.y[p]
		and z == h.z[p]
		and yaw == h.yaw[p]
		and (not full or (qx == h.qx[p] and qy == h.qy[p] and qz == h.qz[p] and qw == h.qw[p]))
	if same then
		if not still[slot] then
			still[slot] = true
			push(h, now, x, y, z, yaw, 0, qx, qy, qz, qw)
			sentT[slot] = now
			heldT[slot] = 0
		elseif now - sentT[slot] >= kind.keepAlive then
			push(h, now, x, y, z, yaw, 0, qx, qy, qz, qw)
			sentT[slot] = now
			heldT[slot] = 0
		else
			heldT[slot] = now
		end
		return
	end
	local held = heldT[slot]
	if held > lastT and not tele then
		-- rest marker: still at the old pose at the last unchanged tick
		push(h, held, h.x[p], h.y[p], h.z[p], h.yaw[p], 0, if full then h.qx[p] else 0, if full then h.qy[p] else 0, if full then h.qz[p] else 0, if full then h.qw[p] else 1)
	end
	heldT[slot] = 0
	still[slot] = false
	forceTele[slot] = false
	push(h, now, x, y, z, yaw, if tele then 1 else 0, qx, qy, qz, qw)
	sentT[slot] = now
end

function Ticker.step(now: number, dt: number)
	for _, kind in Kinds.list do
		if kind.motion == false then
			kind.tick = false -- state-only kind: nothing to sample
			continue
		end
		local interval = 1 / kind.rate
		local acc = kind.acc + dt
		if acc >= interval then
			-- one sample per frame at most; drop whole missed ticks, keep the phase
			acc -= (acc // interval) * interval
			kind.tick = true
		else
			kind.tick = false
		end
		kind.acc = acc
	end
	for k = 1, State.count do
		local slot = active[k]
		if owner[slot] == false and kinds[slot].tick then
			Ticker.sample(slot, now)
		end
	end
end

return Ticker
