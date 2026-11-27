--!strict
--!native
--!optimize 2
-- Velocity from an entity's history (server): newest sample against the first
-- sample at least WINDOW older, never across a teleport or an idle/long gap.
-- Zero when the newest sample repeats the previous pose (the entity stopped).
-- Numbers only (no allocation); Tide.velocity and the lock use it.
-- Entities of a kind with velocity = true (v0.5) carry their velocity in every sample: the
-- newest sample's is returned as it is.

local Shared = script.Parent.Parent.Shared
local Interp = require(Shared.Interp)
local State = require(script.Parent.State)

local Motion = {}

local WINDOW = 0.05 -- seconds of history the velocity spans (smooths 60 Hz upload jitter)

local hist = State.hist
local tpVel = State.tpVel
local acos = math.acos
local sqrt = math.sqrt

-- Linear velocity vx, vy, vz and angular velocity wx, wy, wz (world frame; only
-- for full-rotation entities, else 0). A teleport sample as the newest gives the
-- teleport's velocity (or 0).
function Motion.velocity(slot: number): (number, number, number, number, number, number)
	local h = hist[slot]
	if h == nil or h.n == 0 then
		return 0, 0, 0, 0, 0, 0
	end
	local cap = h.cap
	local last = h.last
	local p = last % cap + 1
	if h.vel then
		-- kinds with velocity = true: the newest sample's own velocity and spin
		return h.vx[p], h.vy[p], h.vz[p], h.wx[p], h.wy[p], h.wz[p]
	end
	local ts, fls = h.t, h.fl
	if fls[p] % 2 == 1 then
		local v = tpVel[slot]
		if v ~= nil then
			return v.X, v.Y, v.Z, 0, 0, 0
		end
		return 0, 0, 0, 0, 0, 0
	end
	local xs, ys, zs, yaws = h.x, h.y, h.z, h.yaw
	if h.n >= 2 then
		-- idle: the newest sample repeats the previous pose (stop sample, keep-alive)
		local q = (last - 1) % cap + 1
		if xs[p] == xs[q] and ys[p] == ys[q] and zs[p] == zs[q] and yaws[p] == yaws[q] then
			if not h.full or (h.qx[p] == h.qx[q] and h.qy[p] == h.qy[q] and h.qz[p] == h.qz[q] and h.qw[p] == h.qw[q]) then
				return 0, 0, 0, 0, 0, 0
			end
		end
	end
	local tNew = ts[p]
	local maxGap = Interp.velocityGap
	local oldest = last - h.n + 1
	local base = last
	local i = last - 1
	while i >= oldest do
		local q = i % cap + 1
		local next = (i + 1) % cap + 1
		if fls[next] % 2 == 1 or ts[next] - ts[q] > maxGap then
			break -- the segment after i crosses a teleport or an idle gap
		end
		base = i
		if tNew - ts[q] >= WINDOW then
			break
		end
		i -= 1
	end
	if base == last then
		return 0, 0, 0, 0, 0, 0
	end
	local b = base % cap + 1
	local dt = tNew - ts[b]
	if dt <= 0 then
		return 0, 0, 0, 0, 0, 0
	end
	local vx = (xs[p] - xs[b]) / dt
	local vy = (ys[p] - ys[b]) / dt
	local vz = (zs[p] - zs[b]) / dt
	if not h.full then
		return vx, vy, vz, 0, 0, 0
	end
	-- rotation from base to newest: r = qNew * conj(qBase), as axis * angle / dt
	local ax, ay, az, aw = h.qx[p], h.qy[p], h.qz[p], h.qw[p]
	local bx, by, bz, bw = -h.qx[b], -h.qy[b], -h.qz[b], h.qw[b]
	local rw = aw * bw - ax * bx - ay * by - az * bz
	local rx = aw * bx + ax * bw + ay * bz - az * by
	local ry = aw * by - ax * bz + ay * bw + az * bx
	local rz = aw * bz + ax * by - ay * bx + az * bw
	if rw < 0 then
		rw, rx, ry, rz = -rw, -rx, -ry, -rz
	end
	local s = sqrt(rx * rx + ry * ry + rz * rz)
	if s < 1e-9 then
		return vx, vy, vz, 0, 0, 0
	end
	if rw > 1 then
		rw = 1
	end
	local k = 2 * acos(rw) / (s * dt)
	return vx, vy, vz, rx * k, ry * k, rz * k
end

return Motion
