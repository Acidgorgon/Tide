--!strict
--!native
--!optimize 2
-- Sampling a ring at a time: cubic Hermite between the two bracketing samples
-- (finite-difference tangents), bounded linear extrapolation past the newest,
-- hold before the oldest. Shared by the client renderer and server rewind
-- (Tide.at) so both see the same path.

local Ring = require(script.Parent.Ring)

type Ring = Ring.Ring

local Interp = {}

-- Gaps longer than this are not interpolated across (hold, then snap).
Interp.snapGap = 1.0
-- Velocity for extrapolation only from samples closer than this.
Interp.velocityGap = 0.25

local PI = math.pi
local TAU = 2 * math.pi
local find = Ring.find
local sqrt = math.sqrt

local STATE_INTERP = 0
local STATE_EXTRAP = 1
local STATE_HOLD = 2
local STATE_EARLY = 3
local STATE_EMPTY = -1

Interp.STATE_INTERP = STATE_INTERP
Interp.STATE_EXTRAP = STATE_EXTRAP
Interp.STATE_HOLD = STATE_HOLD
Interp.STATE_EARLY = STATE_EARLY
Interp.STATE_EMPTY = STATE_EMPTY

local function wrapAngle(a: number): number
	return (a + PI) % TAU - PI
end
Interp.wrapAngle = wrapAngle

-- Returns x, y, z, yaw, qx, qy, qz, qw, state.
-- Extrapolation (client) takes its velocity from the last two samples only if
-- they are at least `minGap` apart, and clamps it to `maxSpeed` horizontally,
-- `maxRise` up and `maxFall` down (a forged near-duplicate pair cannot fling
-- the drawn entity).
function Interp.sample(
	r: Ring,
	t: number,
	extrapolate: number,
	minGap: number?,
	maxSpeed: number?,
	maxRise: number?,
	maxFall: number?
): (number, number, number, number, number, number, number, number, number)
	local n = r.n
	if n == 0 then
		return 0, 0, 0, 0, 0, 0, 0, 1, STATE_EMPTY
	end
	local cap = r.cap
	local ts, xs, ys, zs, yaws, fls = r.t, r.x, r.y, r.z, r.yaw, r.fl
	local full = r.full
	local last = r.last
	local oldest = last - n + 1
	local i = find(r, t)

	if i < oldest then
		local p = oldest % cap + 1
		if full then
			return xs[p], ys[p], zs[p], yaws[p], r.qx[p], r.qy[p], r.qz[p], r.qw[p], STATE_EARLY
		end
		return xs[p], ys[p], zs[p], yaws[p], 0, 0, 0, 1, STATE_EARLY
	end

	if i >= last then
		-- at or past the newest sample: bounded extrapolation with the last velocity
		local p = last % cap + 1
		local e = t - ts[p]
		local state = STATE_EXTRAP
		if e > extrapolate then
			e = extrapolate
			state = STATE_HOLD
		end
		local x, y, z = xs[p], ys[p], zs[p]
		if e > 0 and n >= 2 and fls[p] % 2 == 0 then
			local q = (last - 1) % cap + 1
			local h = ts[p] - ts[q]
			if h > 0 and h <= Interp.velocityGap and h >= (minGap or 0) then
				local vx = (x - xs[q]) / h
				local vy = (y - ys[q]) / h
				local vz = (z - zs[q]) / h
				if maxSpeed ~= nil then
					local sp2 = vx * vx + vz * vz
					if sp2 > maxSpeed * maxSpeed then
						local k = maxSpeed / sqrt(sp2)
						vx *= k
						vz *= k
					end
				end
				if maxRise ~= nil and vy > maxRise then
					vy = maxRise
				elseif maxFall ~= nil and vy < -maxFall then
					vy = -maxFall
				end
				x += vx * e
				y += vy * e
				z += vz * e
			end
		end
		if e <= 0 then
			state = STATE_INTERP
		end
		if full then
			return x, y, z, yaws[p], r.qx[p], r.qy[p], r.qz[p], r.qw[p], state
		end
		return x, y, z, yaws[p], 0, 0, 0, 1, state
	end

	-- oldest <= i < last: Hermite between i and i + 1
	local p0 = i % cap + 1
	local p1 = (i + 1) % cap + 1
	local t0, t1 = ts[p0], ts[p1]
	local h = t1 - t0
	if fls[p1] % 2 == 1 or h > Interp.snapGap or h <= 0 then
		-- the next sample is a teleport (or a long gap): hold until it is reached
		if full then
			return xs[p0], ys[p0], zs[p0], yaws[p0], r.qx[p0], r.qy[p0], r.qz[p0], r.qw[p0], STATE_INTERP
		end
		return xs[p0], ys[p0], zs[p0], yaws[p0], 0, 0, 0, 1, STATE_INTERP
	end
	local s = (t - t0) / h
	local x0, y0, z0 = xs[p0], ys[p0], zs[p0]
	local x1, y1, z1 = xs[p1], ys[p1], zs[p1]
	local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0

	-- tangents (scaled by h): central differences where the neighbours are usable
	local m0x, m0y, m0z = dx, dy, dz
	if i > oldest and fls[p0] % 2 == 0 then
		local pp = (i - 1) % cap + 1
		local tp = ts[pp]
		if t0 - tp <= Interp.snapGap and t1 - tp > 0 then
			local k = h / (t1 - tp)
			m0x, m0y, m0z = (x1 - xs[pp]) * k, (y1 - ys[pp]) * k, (z1 - zs[pp]) * k
		end
	end
	local m1x, m1y, m1z = dx, dy, dz
	if i + 1 < last then
		local pn = (i + 2) % cap + 1
		local tn = ts[pn]
		if fls[pn] % 2 == 0 and tn - t1 <= Interp.snapGap and tn - t0 > 0 then
			local k = h / (tn - t0)
			m1x, m1y, m1z = (xs[pn] - x0) * k, (ys[pn] - y0) * k, (zs[pn] - z0) * k
		end
	end

	local s2 = s * s
	local s3 = s2 * s
	local h00 = 2 * s3 - 3 * s2 + 1
	local h10 = s3 - 2 * s2 + s
	local h01 = -2 * s3 + 3 * s2
	local h11 = s3 - s2
	local x = h00 * x0 + h10 * m0x + h01 * x1 + h11 * m1x
	local y = h00 * y0 + h10 * m0y + h01 * y1 + h11 * m1y
	local z = h00 * z0 + h10 * m0z + h01 * z1 + h11 * m1z

	local yaw0 = yaws[p0]
	local yaw = wrapAngle(yaw0 + wrapAngle(yaws[p1] - yaw0) * s)

	if full then
		-- nlerp on the short arc
		local ax, ay, az, aw = r.qx[p0], r.qy[p0], r.qz[p0], r.qw[p0]
		local bx, by, bz, bw = r.qx[p1], r.qy[p1], r.qz[p1], r.qw[p1]
		if ax * bx + ay * by + az * bz + aw * bw < 0 then
			bx, by, bz, bw = -bx, -by, -bz, -bw
		end
		local qx = ax + (bx - ax) * s
		local qy = ay + (by - ay) * s
		local qz = az + (bz - az) * s
		local qw = aw + (bw - aw) * s
		local len = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
		if len > 0 then
			qx, qy, qz, qw = qx / len, qy / len, qz / len, qw / len
		end
		return x, y, z, yaw, qx, qy, qz, qw, STATE_INTERP
	end
	return x, y, z, yaw, 0, 0, 0, 1, STATE_INTERP
end

return Interp
