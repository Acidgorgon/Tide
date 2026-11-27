--!strict
--!native
--!optimize 2
-- Sampling a ring at a time: cubic Hermite between the two bracketing samples
-- (finite-difference tangents), bounded linear extrapolation past the newest,
-- hold before the oldest. Shared by the client renderer and server rewind
-- (Tide.at) so both see the same path.
--
-- Velocity rings (kinds with velocity = true, v0.5): the tangents are the samples' own
-- velocities, so a path is right between samples and a kick is a corner, not a curve:
--   * a segment that ends in a CUT sample (Tide.bump) arrives with constant acceleration from
--     its start velocity; the cut sample's velocity (the new one) only shapes what follows;
--   * velocities that do not explain the segment (an anchored or carried body moved by
--     CFrame, a bounce nobody flagged, a lost cut sample) are not used: that segment falls
--     back to the tangents from positions above, so it never overshoots or stutters;
--   * past the newest sample the path continues with that sample's velocity (bounded).
-- After a sample() of a velocity ring, Interp.motion holds the linear velocity and the spin at
-- that time: vx, vy, vz, wx, wy, wz. Between two samples whose velocities explain the segment
-- both are blended between the samples' own (exact under constant acceleration); otherwise (a
-- cut, a fallback segment) the velocity is the drawn path's derivative, which carries the
-- positions' quantization (up to (1/32 stud) / segment length per axis at the segment's end:
-- 0.94 studs/s at 30 Hz). A cut closer than 12.5 ms behind a sample holds that sample's
-- velocity instead.

local Ring = require(script.Parent.Ring)

type Ring = Ring.Ring

local Interp = {}

-- Gaps longer than this are not interpolated across (hold, then snap).
Interp.snapGap = 1.0
-- Velocity for extrapolation only from samples closer than this.
Interp.velocityGap = 0.25

-- Velocity and spin at the time of the last sample() of a velocity ring.
Interp.motion = table.create(6, 0) :: { number }
local motion = Interp.motion

-- A velocity ring's tangents are used when they explain the segment's displacement within
-- TOL + a share of its length (studs): position quantization and the simulation's own
-- integration error stay far below, a body moved without velocity far above.
local TOL = 0.06
local TOL_REL = 0.125
local TOL_REL_CUT = 0.5
-- A segment that ends in a cut and is shorter than this (seconds) reports its start velocity
-- instead of the path's slope: the slope's error is (1/32 stud) / length per axis, holding
-- the velocity costs acceleration * length (gravity: the two meet near 12 ms).
local CUT_HOLD = 0.0125

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
		if r.vel then
			motion[1], motion[2], motion[3] = r.vx[p], r.vy[p], r.vz[p]
			motion[4], motion[5], motion[6] = r.wx[p], r.wy[p], r.wz[p]
		end
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
		if r.vel then
			-- the sample's own velocity (the server's: no clamp)
			local vx, vy, vz = r.vx[p], r.vy[p], r.vz[p]
			motion[1], motion[2], motion[3] = vx, vy, vz
			motion[4], motion[5], motion[6] = r.wx[p], r.wy[p], r.wz[p]
			if e > 0 then
				x += vx * e
				y += vy * e
				z += vz * e
			end
		elseif e > 0 and n >= 2 and fls[p] % 2 == 0 then
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
		if r.vel then
			motion[1], motion[2], motion[3] = 0, 0, 0
			motion[4], motion[5], motion[6] = r.wx[p0], r.wy[p0], r.wz[p0]
		end
		if full then
			return xs[p0], ys[p0], zs[p0], yaws[p0], r.qx[p0], r.qy[p0], r.qz[p0], r.qw[p0], STATE_INTERP
		end
		return xs[p0], ys[p0], zs[p0], yaws[p0], 0, 0, 0, 1, STATE_INTERP
	end
	local s = (t - t0) / h
	local x0, y0, z0 = xs[p0], ys[p0], zs[p0]
	local x1, y1, z1 = xs[p1], ys[p1], zs[p1]
	local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0

	-- tangents (scaled by h)
	local m0x, m0y, m0z = dx, dy, dz
	local m1x, m1y, m1z = dx, dy, dz
	local vel = r.vel
	local fromVelocity = false
	if vel then
		local vxs, vys, vzs = r.vx, r.vy, r.vz
		local ax, ay, az = vxs[p0] * h, vys[p0] * h, vzs[p0] * h
		local len = sqrt(dx * dx + dy * dy + dz * dz)
		if fls[p1] >= 8 then
			-- the motion changes at p1 (a cut): arrive with constant acceleration from p0's
			-- velocity; when that does not explain the displacement, a straight line
			local ex, ey, ez = ax - dx, ay - dy, az - dz
			local tol = TOL + TOL_REL_CUT * len
			if ex * ex + ey * ey + ez * ez <= tol * tol then
				m0x, m0y, m0z = ax, ay, az
				m1x, m1y, m1z = 2 * dx - ax, 2 * dy - ay, 2 * dz - az
			end
			fromVelocity = true
		else
			local bx, by, bz = vxs[p1] * h, vys[p1] * h, vzs[p1] * h
			local ex, ey, ez = (ax + bx) * 0.5 - dx, (ay + by) * 0.5 - dy, (az + bz) * 0.5 - dz
			local tol = TOL + TOL_REL * len
			if ex * ex + ey * ey + ez * ez <= tol * tol then
				m0x, m0y, m0z = ax, ay, az
				m1x, m1y, m1z = bx, by, bz
				fromVelocity = true
			end
		end
	end
	if not fromVelocity then
		-- central differences where the neighbours are usable (never across a teleport or a cut)
		if i > oldest and fls[p0] == 0 then
			local pp = (i - 1) % cap + 1
			local tp = ts[pp]
			if t0 - tp <= Interp.snapGap and t1 - tp > 0 then
				local k = h / (t1 - tp)
				m0x, m0y, m0z = (x1 - xs[pp]) * k, (y1 - ys[pp]) * k, (z1 - zs[pp]) * k
			end
		end
		if i + 1 < last then
			local pn = (i + 2) % cap + 1
			local tn = ts[pn]
			if fls[pn] % 2 == 0 and tn - t1 <= Interp.snapGap and tn - t0 > 0 then
				local k = h / (tn - t0)
				m1x, m1y, m1z = (xs[pn] - x0) * k, (ys[pn] - y0) * k, (zs[pn] - z0) * k
			end
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
	if vel then
		local cut = fls[p1] >= 8
		if cut and h < CUT_HOLD then
			-- a cut right behind a sample (a bump in the frame the entity was sampled in): the
			-- old velocity holds up to it; the slope of so short a segment is quantization noise
			motion[1], motion[2], motion[3] = r.vx[p0], r.vy[p0], r.vz[p0]
		elseif fromVelocity and not cut then
			-- the two samples' velocities explain the segment: blended between them (exact
			-- under constant acceleration, and free of the positions' quantization)
			local vxs, vys, vzs = r.vx, r.vy, r.vz
			motion[1] = vxs[p0] + (vxs[p1] - vxs[p0]) * s
			motion[2] = vys[p0] + (vys[p1] - vys[p0]) * s
			motion[3] = vzs[p0] + (vzs[p1] - vzs[p0]) * s
		else
			-- the path's own velocity (the curve's derivative)
			local d00 = (6 * s2 - 6 * s) / h
			local d10 = (3 * s2 - 4 * s + 1) / h
			local d11 = (3 * s2 - 2 * s) / h
			motion[1] = d00 * (x0 - x1) + d10 * m0x + d11 * m1x
			motion[2] = d00 * (y0 - y1) + d10 * m0y + d11 * m1y
			motion[3] = d00 * (z0 - z1) + d10 * m0z + d11 * m1z
		end
		-- the spin between the two samples (a cut changes it at p1, not before)
		local wxs, wys, wzs = r.wx, r.wy, r.wz
		local k = if cut then 0 else s
		motion[4] = wxs[p0] + (wxs[p1] - wxs[p0]) * k
		motion[5] = wys[p0] + (wys[p1] - wys[p0]) * k
		motion[6] = wzs[p0] + (wzs[p1] - wzs[p0]) * k
	end

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
