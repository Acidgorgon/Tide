--!strict
--!native
--!optimize 2
-- Sample codec. A sample is a packed 64-bit core
--   lo u32 = x:17 | y(low 15):15
--   hi u32 = y(high 2):2 | z:17 | yaw:10 | flags:3
-- x/y/z: 1/64 stud around Config.origin, offset binary (q + 65536), +-1024 studs.
-- yaw:   1024 steps per turn.
-- flags: bit0 TELEPORT, bit1 FULL (a 4 B smallest-three quaternion follows),
--        bit2 ABS (core xyz bits are zero; 3 x f32 absolute position follows the quaternion).
--
-- Packing uses plain float arithmetic on whole numbers below 2^32 (exact in f64),
-- which benchmarked faster than bit32 calls and buffer.writebits (tests/bench_codec.luau).

local Codec = {}

Codec.TELEPORT = 1
Codec.FULL = 2
Codec.ABS = 4

local SCALE = 64
local INV_SCALE = 1 / 64
local LIMIT = 65536 -- quanta each side of the origin
local YAW_TO_Q = 1024 / (2 * math.pi)
local Q_TO_YAW = (2 * math.pi) / 1024
local SQRT2 = math.sqrt(2)
local INV_SQRT2 = 1 / SQRT2

local round = math.round
local sqrt = math.sqrt
local abs = math.abs
local writeu32 = buffer.writeu32
local readu32 = buffer.readu32
local writef32 = buffer.writef32
local readf32 = buffer.readf32
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local writeu16 = buffer.writeu16
local readu16 = buffer.readu16

local ox, oy, oz = 0, 0, 0

function Codec.setOrigin(x: number, y: number, z: number)
	ox, oy, oz = x, y, z
end

function Codec.getOrigin(): (number, number, number)
	return ox, oy, oz
end

-- Bytes taken by the sample whose core starts at `off` (reads only the flags).
function Codec.sizeAt(b: buffer, off: number): number
	local flags = readu8(b, off + 7) // 32
	local size = 8
	if flags % 4 >= 2 then
		size += 4
	end
	if flags >= 4 then
		size += 12
	end
	return size
end

-- Size of a sample with these flags (FULL / ABS bits).
function Codec.size(flags: number): number
	local size = 8
	if flags % 4 >= 2 then
		size += 4
	end
	if flags >= 4 then
		size += 12
	end
	return size
end

-- Smallest-three quaternion -> u32 (2 bits largest index + 3 x 10 bits).
local function packQuat(qx: number, qy: number, qz: number, qw: number): number
	local n = qx * qx + qy * qy + qz * qz + qw * qw
	if not (n > 1e-12) or n ~= n then
		-- degenerate or NaN: identity (w largest, others zero)
		return 3 + 512 * 4 + 512 * 4096 + 512 * 4194304
	end
	local inv = 1 / sqrt(n)
	local ax, ay, az, aw = abs(qx), abs(qy), abs(qz), abs(qw)
	local i, s, a, b, c = 0, qx, qy, qz, qw
	local m = ax
	if ay > m then
		m, i, s, a, b, c = ay, 1, qy, qx, qz, qw
	end
	if az > m then
		m, i, s, a, b, c = az, 2, qz, qx, qy, qw
	end
	if aw > m then
		i, s, a, b, c = 3, qw, qx, qy, qz
	end
	if s < 0 then
		inv = -inv
	end
	-- [-1/sqrt2, 1/sqrt2] -> [0, 1023]
	local qa = round((a * inv * SQRT2 + 1) * 511.5)
	local qb = round((b * inv * SQRT2 + 1) * 511.5)
	local qc = round((c * inv * SQRT2 + 1) * 511.5)
	if qa < 0 then
		qa = 0
	elseif qa > 1023 then
		qa = 1023
	end
	if qb < 0 then
		qb = 0
	elseif qb > 1023 then
		qb = 1023
	end
	if qc < 0 then
		qc = 0
	elseif qc > 1023 then
		qc = 1023
	end
	return i + qa * 4 + qb * 4096 + qc * 4194304
end

local function unpackQuat(u: number): (number, number, number, number)
	local i = u % 4
	local a = ((u // 4) % 1024 / 511.5 - 1) * INV_SQRT2
	local b = ((u // 4096) % 1024 / 511.5 - 1) * INV_SQRT2
	local c = ((u // 4194304) % 1024 / 511.5 - 1) * INV_SQRT2
	local r = 1 - a * a - b * b - c * c
	local s = if r > 0 then sqrt(r) else 0
	if i == 0 then
		return s, a, b, c
	elseif i == 1 then
		return a, s, b, c
	elseif i == 2 then
		return a, b, s, c
	end
	return a, b, c, s
end

Codec.packQuat = packQuat
Codec.unpackQuat = unpackQuat

-- Writes one sample at `off`; returns the offset after it.
-- `flags` carries TELEPORT and FULL; ABS is decided here (out of range or non-finite).
function Codec.write(
	b: buffer,
	off: number,
	x: number,
	y: number,
	z: number,
	yaw: number,
	flags: number,
	qx: number,
	qy: number,
	qz: number,
	qw: number
): number
	flags = flags % 4 -- callers never set ABS themselves
	local fx = round((x - ox) * SCALE)
	local fy = round((y - oy) * SCALE)
	local fz = round((z - oz) * SCALE)
	local isAbs = false
	-- (NaN fails every comparison and so lands in the absolute form)
	if fx >= -LIMIT and fx < LIMIT and fy >= -LIMIT and fy < LIMIT and fz >= -LIMIT and fz < LIMIT then
		fx += LIMIT
		fy += LIMIT
		fz += LIMIT
	else
		isAbs = true
		fx, fy, fz = 0, 0, 0
		flags += 4
	end
	local yq = round(yaw * YAW_TO_Q) % 1024
	if yq ~= yq then
		yq = 0
	end
	writeu32(b, off, fx + (fy % 32768) * 131072)
	writeu32(b, off + 4, fy // 32768 + fz * 4 + yq * 524288 + flags * 536870912)
	off += 8
	if flags % 4 >= 2 then
		writeu32(b, off, packQuat(qx, qy, qz, qw))
		off += 4
	end
	if isAbs then
		writef32(b, off, x)
		writef32(b, off + 4, y)
		writef32(b, off + 8, z)
		off += 12
	end
	return off
end

-- Reads one sample at `off` (caller checked the length with sizeAt).
-- Returns offset after it, x, y, z, yaw (-pi, pi], flags, and the quaternion
-- (identity placeholders when the FULL flag is not set).
function Codec.read(
	b: buffer,
	off: number
): (number, number, number, number, number, number, number, number, number, number)
	local lo = readu32(b, off)
	local hi = readu32(b, off + 4)
	local flags = hi // 536870912
	local yq = (hi // 524288) % 1024
	if yq > 512 then
		yq -= 1024
	end
	local yaw = yq * Q_TO_YAW
	off += 8
	local qx, qy, qz, qw = 0, 0, 0, 1
	if flags % 4 >= 2 then
		qx, qy, qz, qw = unpackQuat(readu32(b, off))
		off += 4
	end
	local x, y, z
	if flags >= 4 then
		x = readf32(b, off)
		y = readf32(b, off + 4)
		z = readf32(b, off + 8)
		off += 12
	else
		x = (lo % 131072 - LIMIT) * INV_SCALE + ox
		y = (lo // 131072 + (hi % 4) * 32768 - LIMIT) * INV_SCALE + oy
		z = ((hi // 4) % 131072 - LIMIT) * INV_SCALE + oz
	end
	return off, x, y, z, yaw, flags, qx, qy, qz, qw
end

-- Scratch for f32 rounding and quantize round trips.
local scratch = buffer.create(32)

-- Returns what a receiver decodes for this sample (server keeps exactly that).
function Codec.quantize(
	x: number,
	y: number,
	z: number,
	yaw: number,
	flags: number,
	qx: number,
	qy: number,
	qz: number,
	qw: number
): (number, number, number, number, number, number, number, number, number)
	Codec.write(scratch, 0, x, y, z, yaw, flags, qx, qy, qz, qw)
	local _, rx, ry, rz, ryaw, rflags, rqx, rqy, rqz, rqw = Codec.read(scratch, 0)
	return rx, ry, rz, ryaw, rflags, rqx, rqy, rqz, rqw
end

-- Sample-age field of relay records, in 0.5 ms ticks: u8 0..254, or 255 + u16.
function Codec.writeDt(b: buffer, off: number, ticks: number): number
	if ticks < 255 then
		writeu8(b, off, ticks)
		return off + 1
	end
	writeu8(b, off, 255)
	writeu16(b, off + 1, if ticks > 65535 then 65535 else ticks)
	return off + 3
end

function Codec.readDt(b: buffer, off: number): (number, number)
	local v = readu8(b, off)
	if v < 255 then
		return off + 1, v
	end
	return off + 3, readu16(b, off + 1)
end

-- Yaw from a rotation matrix's R02 / R22 (rotation about +Y of the look vector).
function Codec.yawOf(r02: number, r22: number): number
	return math.atan2(r02, r22)
end

-- Quaternion from rotation matrix components (CFrame:GetComponents order).
function Codec.matrixToQuat(
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number
): (number, number, number, number)
	local trace = r00 + r11 + r22
	if trace > 0 then
		local s = sqrt(1 + trace) * 2
		return (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, 0.25 * s
	elseif r00 > r11 and r00 > r22 then
		local s = sqrt(1 + r00 - r11 - r22) * 2
		return 0.25 * s, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s
	elseif r11 > r22 then
		local s = sqrt(1 + r11 - r00 - r22) * 2
		return (r01 + r10) / s, 0.25 * s, (r12 + r21) / s, (r02 - r20) / s
	end
	local s = sqrt(1 + r22 - r00 - r11) * 2
	return (r02 + r20) / s, (r12 + r21) / s, 0.25 * s, (r10 - r01) / s
end

return Codec
