--!optimize 2
-- Deterministic ground-truth trajectories for the scenarios, integrated at 480 Hz and sampled
-- with linear interpolation. Positions are HumanoidRootPart positions (y = 3 on flat ground);
-- yaw follows Roblox's convention (CFrame.fromOrientation(0, yaw, 0), LookVector =
-- (-sin yaw, 0, -cos yaw)).

local Motion = {}
local HZ = 480
Motion.HZ = HZ
local GROUND_Y = 3
local PI, TAU = math.pi, 2 * math.pi
local sqrt, sin, cos, atan2, abs, floor = math.sqrt, math.sin, math.cos, math.atan2, math.abs, math.floor

local function rng(seed: number)
	local s = bit32.band(math.floor(seed * 2654435761) + 0x6d2b79f5, 0xffffffff)
	if s == 0 then
		s = 1
	end
	return function(): number
		s = bit32.bxor(s, bit32.lshift(s, 13))
		s = bit32.bxor(s, bit32.rshift(s, 17))
		s = bit32.bxor(s, bit32.lshift(s, 5))
		return s / 4294967296
	end
end
Motion.rng = rng

local function wrapAngle(a: number): number
	a = (a + PI) % TAU
	return a - PI
end
Motion.wrapAngle = wrapAngle

local function newTrack(n: number)
	return { n = n, x = table.create(n, 0), y = table.create(n, GROUND_Y), z = table.create(n, 0), yaw = table.create(n, 0) }
end

-- Samples a track at time t (seconds since start): x, y, z, yaw.
function Motion.sample(track, t: number): (number, number, number, number)
	local f = t * HZ
	if f <= 0 then
		return track.x[1], track.y[1], track.z[1], track.yaw[1]
	end
	local i = floor(f)
	local n = track.n
	if i >= n - 1 then
		return track.x[n], track.y[n], track.z[n], track.yaw[n]
	end
	local a = f - i
	i += 1
	local x, y, z = track.x, track.y, track.z
	local y0, y1 = track.yaw[i], track.yaw[i + 1]
	local dy = wrapAngle(y1 - y0)
	return x[i] + (x[i + 1] - x[i]) * a, y[i] + (y[i + 1] - y[i]) * a, z[i] + (z[i + 1] - z[i]) * a, y0 + dy * a
end

function Motion.static(x: number, z: number, yaw: number, duration: number)
	local n = 2
	local tr = newTrack(n)
	for i = 1, n do
		tr.x[i], tr.z[i], tr.yaw[i] = x, z, yaw
	end
	tr.n = n
	return tr
end

local function yawOf(vx: number, vz: number): number
	return atan2(-vx, -vz)
end

-- Football players on a 360 x 230 stud pitch.
-- A "ball" point moves around the pitch (passes and dribbles). Each player keeps a role offset
-- from the ball: the near group (around the ball), a mid group (50-90 studs away) and a far group
-- (keepers/defenders, 110-220 studs away). Players re-decide every 0.3-1.2 s: sprint (25-30
-- studs/s) when far from their spot, jog (12-17) or walk/idle when close, and 30% of decisions
-- start a cut (90-150 degree direction change at sprint speed for 0.3-0.6 s). Acceleration is
-- capped (80 studs/s^2 up, 140 down), yaw turns at up to 900 deg/s, and ~3% of decisions jump.
-- groups: list of "near" | "mid" | "far" per player.
function Motion.football(groups: { string }, duration: number, seed: number)
	local HX, HZ_ = 180, 115
	local n = math.ceil(duration * HZ) + 2
	local dt = 1 / HZ
	local r = rng(seed)
	local count = #groups
	local tracks = {}

	-- ball path
	local bx, bz = 0, 0
	local btx, btz, bspeed = 0, 0, 20
	local bnext = 0
	local ballX, ballZ = table.create(n), table.create(n)
	for i = 1, n do
		local t = (i - 1) * dt
		if t >= bnext then
			btx = (r() * 2 - 1) * (HX - 20)
			btz = (r() * 2 - 1) * (HZ_ - 15)
			bspeed = if r() < 0.5 then 30 + r() * 15 else 12 + r() * 8
			bnext = t + 1.5 + r() * 2.5
		end
		local dx, dz = btx - bx, btz - bz
		local d = sqrt(dx * dx + dz * dz)
		if d > 0.05 then
			local step = math.min(d, bspeed * dt)
			bx += dx / d * step
			bz += dz / d * step
		end
		ballX[i], ballZ[i] = bx, bz
	end

	for p = 1, count do
		local group = groups[p]
		local tr = newTrack(n)
		-- role offset from the ball
		local ang = r() * TAU
		local radius = if group == "near" then 4 + r() * 22 elseif group == "mid" then 50 + r() * 40 else 110 + r() * 110
		local ox, oz = cos(ang) * radius, sin(ang) * radius
		local x = math.clamp(ballX[1] + ox, -HX, HX)
		local z = math.clamp(ballZ[1] + oz, -HZ_, HZ_)
		local vx, vz = 0, 0
		local yaw = r() * TAU - PI
		local tx, tz, speed = x, z, 0
		local nextDecision = r() * 0.5
		local cutUntil = -1
		local cutDx, cutDz = 0, 0
		local jumpStart, jumpLen = -10, 0.55
		for i = 1, n do
			local t = (i - 1) * dt
			if t >= nextDecision then
				nextDecision = t + 0.3 + r() * 0.9
				local ax, az = ballX[i] + ox, ballZ[i] + oz
				if group == "far" then
					-- far players drift with the ball much less
					ax, az = ballX[i] * 0.3 + ox, ballZ[i] * 0.3 + oz
				end
				tx = math.clamp(ax + (r() * 2 - 1) * 12, -HX + 2, HX - 2)
				tz = math.clamp(az + (r() * 2 - 1) * 12, -HZ_ + 2, HZ_ - 2)
				local dx, dz = tx - x, tz - z
				local d = sqrt(dx * dx + dz * dz)
				if d > 25 then
					speed = 25 + r() * 5
				elseif d > 8 then
					speed = 12 + r() * 5
				elseif r() < 0.5 then
					speed = 4 + r() * 4
				else
					speed = 0
				end
				if r() < 0.3 and t > cutUntil + 0.5 then
					-- cut: sharp turn relative to current heading
					local h = atan2(vz, vx)
					local turn = (90 + r() * 60) * PI / 180 * (if r() < 0.5 then -1 else 1)
					cutDx, cutDz = cos(h + turn), sin(h + turn)
					cutUntil = t + 0.3 + r() * 0.3
				end
				if r() < 0.03 and t > jumpStart + 1 then
					jumpStart = t
				end
			end
			-- desired velocity
			local dvx, dvz
			if t < cutUntil then
				local s = 25 + 3 * sin(t * 7)
				dvx, dvz = cutDx * s, cutDz * s
			else
				local dx, dz = tx - x, tz - z
				local d = sqrt(dx * dx + dz * dz)
				local s = speed
				if d < 3 then
					s = math.min(s, d * 2)
				end
				if d > 0.01 then
					dvx, dvz = dx / d * s, dz / d * s
				else
					dvx, dvz = 0, 0
				end
			end
			local ex, ez = dvx - vx, dvz - vz
			local e = sqrt(ex * ex + ez * ez)
			if e > 0 then
				local accel = if dvx * dvx + dvz * dvz >= vx * vx + vz * vz then 80 else 140
				local step = math.min(e, accel * dt)
				vx += ex / e * step
				vz += ez / e * step
			end
			x += vx * dt
			z += vz * dt
			if x < -HX or x > HX then
				x = math.clamp(x, -HX, HX)
				vx = -vx * 0.3
				cutUntil = -1
			end
			if z < -HZ_ or z > HZ_ then
				z = math.clamp(z, -HZ_, HZ_)
				vz = -vz * 0.3
				cutUntil = -1
			end
			local sp = sqrt(vx * vx + vz * vz)
			if sp > 1 then
				local want = yawOf(vx, vz)
				local dy = wrapAngle(want - yaw)
				local maxTurn = 900 * PI / 180 * dt
				yaw = wrapAngle(yaw + math.clamp(dy, -maxTurn, maxTurn))
			end
			local y = GROUND_Y
			local jt = t - jumpStart
			if jt >= 0 and jt < jumpLen then
				local u = jt / jumpLen
				y += 4.5 * 4 * u * (1 - u)
			end
			tr.x[i], tr.y[i], tr.z[i], tr.yaw[i] = x, y, z, yaw
		end
		tracks[p] = tr
	end
	return tracks
end

-- NPC walkers in a box: 3-8 studs/s, smooth heading changes (turn rate 60 deg/s), stops of
-- 1-3 s now and then, reflecting off the box edges.
function Motion.walkers(count: number, halfX: number, halfZ: number, duration: number, seed: number)
	local n = math.ceil(duration * HZ) + 2
	local dt = 1 / HZ
	local r = rng(seed)
	local tracks = {}
	for p = 1, count do
		local tr = newTrack(n)
		local x, z = (r() * 2 - 1) * halfX, (r() * 2 - 1) * halfZ
		local heading = r() * TAU
		local want = heading
		local speed = 3 + r() * 5
		local nextDecision = r() * 3
		local stopUntil = -1
		for i = 1, n do
			local t = (i - 1) * dt
			if t >= nextDecision then
				nextDecision = t + 2 + r() * 4
				want = heading + (r() * 2 - 1) * 2.1
				speed = 3 + r() * 5
				if r() < 0.15 then
					stopUntil = t + 1 + r() * 2
				end
			end
			local dh = wrapAngle(want - heading)
			local maxTurn = 60 * PI / 180 * dt
			heading += math.clamp(dh, -maxTurn, maxTurn)
			local s = if t < stopUntil then 0 else speed
			local vx, vz = cos(heading) * s, sin(heading) * s
			x += vx * dt
			z += vz * dt
			if abs(x) > halfX then
				x = math.clamp(x, -halfX, halfX)
				heading = PI - heading
				want = heading
			end
			if abs(z) > halfZ then
				z = math.clamp(z, -halfZ, halfZ)
				heading = -heading
				want = heading
			end
			tr.x[i], tr.z[i] = x, z
			tr.yaw[i] = yawOf(cos(heading), sin(heading))
		end
		tracks[p] = tr
	end
	return tracks
end

return Motion
