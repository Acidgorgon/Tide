--!optimize 2
-- Roblox value types for the benchmark mock: CFrame (real math), Vector3 members (through the
-- vector metatable the host installs), Vector2, Color3, Enum, Random, PhysicalProperties.
--
-- CFrame is a 12-slot array table {x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22}
-- (row-major rotation, like CFrame.new's 12-number form). In Roblox a CFrame is one ~72 B
-- userdata; here it is a table header + 12-slot array (2 allocations, ~250 B). The harness counts
-- CFrames created (R.cframes) so it can report Roblox-adjusted allocation figures.

local R = {}
R.cframes = 0 -- CFrames constructed so far (any machine)

local sqrt, sin, cos, atan2, asin, abs = math.sqrt, math.sin, math.cos, math.atan2, math.asin, math.abs
local vcreate = vector.create

local CFMT = { __robloxtype = "CFrame" }
local GET = {}
local M = {}

local function mk(x, y, z, a, b, c, d, e, f, g, h, i)
	R.cframes += 1
	return setmetatable({ x, y, z, a, b, c, d, e, f, g, h, i }, CFMT)
end
R.mkCFrame = mk

local function isCF(v)
	return type(v) == "table" and getmetatable(v) == CFMT
end
R.isCFrame = isCF

function CFMT.__index(cf, k)
	local g = GET[k]
	if g then
		return g(cf)
	end
	local m = M[k]
	if m then
		return m
	end
	error(`{tostring(k)} is not a valid member of CFrame`, 2)
end

function CFMT.__newindex()
	error("CFrame is immutable", 2)
end

function CFMT.__eq(a, b)
	for i = 1, 12 do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

function CFMT.__tostring(cf)
	return table.concat(cf, ", ")
end

local function mul(a, b)
	local a4, a5, a6, a7, a8, a9, a10, a11, a12 = a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]
	if type(b) == "vector" then
		local bx, by, bz = b.x, b.y, b.z
		return vcreate(
			a[1] + a4 * bx + a5 * by + a6 * bz,
			a[2] + a7 * bx + a8 * by + a9 * bz,
			a[3] + a10 * bx + a11 * by + a12 * bz
		)
	end
	local b1, b2, b3 = b[1], b[2], b[3]
	local b4, b5, b6, b7, b8, b9, b10, b11, b12 = b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12]
	return mk(
		a[1] + a4 * b1 + a5 * b2 + a6 * b3,
		a[2] + a7 * b1 + a8 * b2 + a9 * b3,
		a[3] + a10 * b1 + a11 * b2 + a12 * b3,
		a4 * b4 + a5 * b7 + a6 * b10,
		a4 * b5 + a5 * b8 + a6 * b11,
		a4 * b6 + a5 * b9 + a6 * b12,
		a7 * b4 + a8 * b7 + a9 * b10,
		a7 * b5 + a8 * b8 + a9 * b11,
		a7 * b6 + a8 * b9 + a9 * b12,
		a10 * b4 + a11 * b7 + a12 * b10,
		a10 * b5 + a11 * b8 + a12 * b11,
		a10 * b6 + a11 * b9 + a12 * b12
	)
end
CFMT.__mul = mul

function CFMT.__add(a, v)
	return mk(a[1] + v.x, a[2] + v.y, a[3] + v.z, a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
end

function CFMT.__sub(a, v)
	return mk(a[1] - v.x, a[2] - v.y, a[3] - v.z, a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
end

local function inverse(a)
	local x, y, z = a[1], a[2], a[3]
	local a4, a5, a6, a7, a8, a9, a10, a11, a12 = a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]
	-- R^T, -R^T p
	return mk(
		-(a4 * x + a7 * y + a10 * z),
		-(a5 * x + a8 * y + a11 * z),
		-(a6 * x + a9 * y + a12 * z),
		a4,
		a7,
		a10,
		a5,
		a8,
		a11,
		a6,
		a9,
		a12
	)
end

GET.X = function(cf)
	return cf[1]
end
GET.Y = function(cf)
	return cf[2]
end
GET.Z = function(cf)
	return cf[3]
end
GET.x, GET.y, GET.z = GET.X, GET.Y, GET.Z
GET.Position = function(cf)
	return vcreate(cf[1], cf[2], cf[3])
end
GET.p = GET.Position
GET.Rotation = function(cf)
	return mk(0, 0, 0, cf[4], cf[5], cf[6], cf[7], cf[8], cf[9], cf[10], cf[11], cf[12])
end
GET.LookVector = function(cf)
	return vcreate(-cf[6], -cf[9], -cf[12])
end
GET.RightVector = function(cf)
	return vcreate(cf[4], cf[7], cf[10])
end
GET.UpVector = function(cf)
	return vcreate(cf[5], cf[8], cf[11])
end
GET.XVector = function(cf)
	return vcreate(cf[4], cf[7], cf[10])
end
GET.YVector = function(cf)
	return vcreate(cf[5], cf[8], cf[11])
end
GET.ZVector = function(cf)
	return vcreate(cf[6], cf[9], cf[12])
end
GET.lookVector = GET.LookVector

function M.GetComponents(cf)
	return cf[1], cf[2], cf[3], cf[4], cf[5], cf[6], cf[7], cf[8], cf[9], cf[10], cf[11], cf[12]
end
M.components = M.GetComponents

function M.Inverse(cf)
	return inverse(cf)
end
M.inverse = M.Inverse

function M.ToWorldSpace(cf, other)
	return mul(cf, other)
end

function M.ToObjectSpace(cf, other)
	return mul(inverse(cf), other)
end

function M.PointToWorldSpace(cf, v)
	return mul(cf, v)
end

function M.PointToObjectSpace(cf, v)
	local dx, dy, dz = v.x - cf[1], v.y - cf[2], v.z - cf[3]
	return vcreate(
		cf[4] * dx + cf[7] * dy + cf[10] * dz,
		cf[5] * dx + cf[8] * dy + cf[11] * dz,
		cf[6] * dx + cf[9] * dy + cf[12] * dz
	)
end

function M.VectorToWorldSpace(cf, v)
	local x, y, z = v.x, v.y, v.z
	return vcreate(
		cf[4] * x + cf[5] * y + cf[6] * z,
		cf[7] * x + cf[8] * y + cf[9] * z,
		cf[10] * x + cf[11] * y + cf[12] * z
	)
end

function M.VectorToObjectSpace(cf, v)
	local x, y, z = v.x, v.y, v.z
	return vcreate(
		cf[4] * x + cf[7] * y + cf[10] * z,
		cf[5] * x + cf[8] * y + cf[11] * z,
		cf[6] * x + cf[9] * y + cf[12] * z
	)
end

local function clamp1(v)
	return if v > 1 then 1 elseif v < -1 then -1 else v
end

-- YXZ: R = Ry(ry) * Rx(rx) * Rz(rz)
function M.ToOrientation(cf)
	local rx = asin(-clamp1(cf[9]))
	local ry = atan2(cf[6], cf[12])
	local rz = atan2(cf[7], cf[8])
	return rx, ry, rz
end
M.ToEulerAnglesYXZ = M.ToOrientation

-- XYZ: R = Rx(rx) * Ry(ry) * Rz(rz)
function M.ToEulerAnglesXYZ(cf)
	local ry = asin(clamp1(cf[6]))
	local rx = atan2(-cf[9], cf[12])
	local rz = atan2(-cf[5], cf[4])
	return rx, ry, rz
end
M.toEulerAnglesXYZ = M.ToEulerAnglesXYZ

function M.FuzzyEq(a, b, eps)
	eps = eps or 1e-5
	for i = 1, 12 do
		if abs(a[i] - b[i]) > eps then
			return false
		end
	end
	return true
end

function M.Orthonormalize(cf)
	return cf
end

-- quaternion helpers (w, x, y, z)
local function toQuat(cf)
	local m00, m01, m02, m10, m11, m12, m20, m21, m22 = cf[4], cf[5], cf[6], cf[7], cf[8], cf[9], cf[10], cf[11], cf[12]
	local tr = m00 + m11 + m22
	if tr > 0 then
		local s = sqrt(tr + 1) * 2
		return 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = sqrt(1 + m00 - m11 - m22) * 2
		return (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = sqrt(1 + m11 - m00 - m22) * 2
		return (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
	else
		local s = sqrt(1 + m22 - m00 - m11) * 2
		return (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
	end
end
R.toQuat = toQuat

local function fromQuat(px, py, pz, w, x, y, z)
	local n = sqrt(w * w + x * x + y * y + z * z)
	if n == 0 then
		return mk(px, py, pz, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	w, x, y, z = w / n, x / n, y / n, z / n
	return mk(
		px,
		py,
		pz,
		1 - 2 * (y * y + z * z),
		2 * (x * y - z * w),
		2 * (x * z + y * w),
		2 * (x * y + z * w),
		1 - 2 * (x * x + z * z),
		2 * (y * z - x * w),
		2 * (x * z - y * w),
		2 * (y * z + x * w),
		1 - 2 * (x * x + y * y)
	)
end

function M.Lerp(a, b, t)
	local px = a[1] + (b[1] - a[1]) * t
	local py = a[2] + (b[2] - a[2]) * t
	local pz = a[3] + (b[3] - a[3]) * t
	local aw, ax, ay, az = toQuat(a)
	local bw, bx, by, bz = toQuat(b)
	local d = aw * bw + ax * bx + ay * by + az * bz
	if d < 0 then
		bw, bx, by, bz, d = -bw, -bx, -by, -bz, -d
	end
	local s0, s1
	if d > 0.9995 then
		s0, s1 = 1 - t, t
	else
		local theta = math.acos(d)
		local st = sin(theta)
		s0, s1 = sin((1 - t) * theta) / st, sin(t * theta) / st
	end
	return fromQuat(px, py, pz, aw * s0 + bw * s1, ax * s0 + bx * s1, ay * s0 + by * s1, az * s0 + bz * s1)
end

function M.ToAxisAngle(cf)
	local w, x, y, z = toQuat(cf)
	local angle = 2 * math.acos(math.clamp(w, -1, 1))
	local s = sqrt(1 - w * w)
	if s < 1e-6 then
		return vcreate(1, 0, 0), 0
	end
	return vcreate(x / s, y / s, z / s), angle
end

local function fromYXZ(px, py, pz, rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = cos(rx), sin(rx), cos(ry), sin(ry), cos(rz), sin(rz)
	return mk(
		px,
		py,
		pz,
		cy * cz + sy * sx * sz,
		-cy * sz + sy * sx * cz,
		sy * cx,
		cx * sz,
		cx * cz,
		-sx,
		-sy * cz + cy * sx * sz,
		sy * sz + cy * sx * cz,
		cy * cx
	)
end

local function fromXYZ(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = cos(rx), sin(rx), cos(ry), sin(ry), cos(rz), sin(rz)
	return mk(
		0,
		0,
		0,
		cy * cz,
		-cy * sz,
		sy,
		sx * sy * cz + cx * sz,
		-sx * sy * sz + cx * cz,
		-sx * cy,
		-cx * sy * cz + sx * sz,
		cx * sy * sz + sx * cz,
		cx * cy
	)
end

local function lookAt(at, target, up)
	up = up or vcreate(0, 1, 0)
	local look = target - at
	local m = vector.magnitude(look)
	if m < 1e-9 then
		return mk(at.x, at.y, at.z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	look = look / m
	local right = vector.cross(look, up)
	local rm = vector.magnitude(right)
	if rm < 1e-9 then
		right = vcreate(1, 0, 0)
	else
		right = right / rm
	end
	local u = vector.cross(right, look)
	return mk(at.x, at.y, at.z, right.x, u.x, -look.x, right.y, u.y, -look.y, right.z, u.z, -look.z)
end

local CFrame = {}
CFrame.identity = setmetatable({ 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, CFMT)

function CFrame.new(...)
	local n = select("#", ...)
	if n == 0 then
		return mk(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	local a, b, c = ...
	if type(a) == "vector" then
		if b ~= nil then
			return lookAt(a, b)
		end
		return mk(a.x, a.y, a.z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	if n == 3 then
		return mk(a, b, c, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 7 then
		local _, _, _, qx, qy, qz, qw = ...
		return fromQuat(a, b, c, qw, qx, qy, qz)
	elseif n == 12 then
		return mk(...)
	end
	error("CFrame.new: unsupported arguments", 2)
end

function CFrame.fromOrientation(rx, ry, rz)
	return fromYXZ(0, 0, 0, rx, ry, rz)
end
CFrame.fromEulerAnglesYXZ = CFrame.fromOrientation
CFrame.Angles = fromXYZ
CFrame.fromEulerAnglesXYZ = fromXYZ
function CFrame.fromEulerAngles(rx, ry, rz, order)
	if order == nil or order == R.Enum.RotationOrder.XYZ then
		return fromXYZ(rx, ry, rz)
	end
	return fromYXZ(0, 0, 0, rx, ry, rz)
end
CFrame.lookAt = lookAt
function CFrame.lookAlong(at, dir, up)
	return lookAt(at, at + dir, up)
end
function CFrame.fromMatrix(p, vx, vy, vz)
	vz = vz or vector.cross(vx, vy)
	return mk(p.x, p.y, p.z, vx.x, vy.x, vz.x, vx.y, vy.y, vz.y, vx.z, vy.z, vz.z)
end
function CFrame.fromAxisAngle(axis, angle)
	local u = vector.normalize(axis)
	local h = angle / 2
	local s = sin(h)
	return fromQuat(0, 0, 0, cos(h), u.x * s, u.y * s, u.z * s)
end
R.CFrame = table.freeze(CFrame)
R.CFMT = CFMT

--------------------------------------------------------------------------------
-- Vector3: native vectors + a metatable for Roblox members (installed by run_scenario
-- through the host's __setvectormt). .X/.Y/.Z stay VM fast paths.
--------------------------------------------------------------------------------

local VGET = {
	Magnitude = vector.magnitude,
	magnitude = vector.magnitude,
	Unit = function(v)
		local m = vector.magnitude(v)
		return if m == 0 then v else v / m
	end,
}
VGET.unit = VGET.Unit
local VM = {
	Lerp = function(a, b, t)
		return a + (b - a) * t
	end,
	Dot = vector.dot,
	Cross = vector.cross,
	Abs = vector.abs,
	Floor = vector.floor,
	Ceil = vector.ceil,
	Sign = vector.sign,
	Max = vector.max,
	Min = vector.min,
	FuzzyEq = function(a, b, eps)
		eps = eps or 1e-5
		return abs(a.x - b.x) <= eps and abs(a.y - b.y) <= eps and abs(a.z - b.z) <= eps
	end,
	Angle = function(a, b)
		return vector.angle(a, b)
	end,
}
VM.lerp = VM.Lerp
VM.Dot = vector.dot
R.vectorMT = {
	__index = function(v, k)
		local g = VGET[k]
		if g then
			return g(v)
		end
		local m = VM[k]
		if m then
			return m
		end
		error(`{tostring(k)} is not a valid member of Vector3`, 2)
	end,
}

local Vector3 = {
	new = function(x, y, z)
		return vcreate(x or 0, y or 0, z or 0)
	end,
	zero = vector.zero,
	one = vector.one,
	xAxis = vcreate(1, 0, 0),
	yAxis = vcreate(0, 1, 0),
	zAxis = vcreate(0, 0, 1),
}
R.Vector3 = table.freeze(Vector3)

local V2MT = { __robloxtype = "Vector2" }
V2MT.__index = function(v, k)
	if k == "Magnitude" then
		return sqrt(v.X * v.X + v.Y * v.Y)
	end
	return nil
end
R.Vector2 = table.freeze({
	new = function(x, y)
		return setmetatable({ X = x or 0, Y = y or 0 }, V2MT)
	end,
	zero = setmetatable({ X = 0, Y = 0 }, V2MT),
})

local C3MT = { __robloxtype = "Color3" }
R.Color3 = table.freeze({
	new = function(r, g, b)
		return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3MT)
	end,
	fromRGB = function(r, g, b)
		return setmetatable({ R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255 }, C3MT)
	end,
})

local PPMT = { __robloxtype = "PhysicalProperties" }
R.PhysicalProperties = table.freeze({
	new = function(...)
		return setmetatable({ ... }, PPMT)
	end,
})

-- Random: xorshift-based, deterministic per seed.
local RandomMT = { __robloxtype = "Random" }
RandomMT.__index = RandomMT
function RandomMT.NextNumber(self, lo, hi)
	local s = self._s
	s = bit32.bxor(s, bit32.lshift(s, 13))
	s = bit32.bxor(s, bit32.rshift(s, 17))
	s = bit32.bxor(s, bit32.lshift(s, 5))
	self._s = s
	local u = s / 4294967296
	lo, hi = lo or 0, hi or 1
	return lo + (hi - lo) * u
end
function RandomMT.NextInteger(self, lo, hi)
	return math.floor(RandomMT.NextNumber(self, lo, hi + 1))
end
R.Random = table.freeze({
	new = function(seed)
		local s = bit32.band(math.floor(seed or 12345), 0xffffffff)
		if s == 0 then
			s = 0x9e3779b9
		end
		return setmetatable({ _s = s }, RandomMT)
	end,
})

--------------------------------------------------------------------------------
-- Enum: explicit items for the enums the libraries inspect, lazy placeholders otherwise.
--------------------------------------------------------------------------------

local itemMT = { __robloxtype = "EnumItem" }
itemMT.__index = {
	IsA = function(item, name)
		return item.EnumType.Name == name
	end,
}
itemMT.__tostring = function(item)
	return `Enum.{item.EnumType.Name}.{item.Name}`
end
local typeMT = { __robloxtype = "Enum" }
function typeMT.__index(enumType, itemName)
	if itemName == "GetEnumItems" then
		return function(self)
			local out = {}
			for _, item in rawget(self, "_items") do
				table.insert(out, item)
			end
			table.sort(out, function(a, b)
				return a.Value < b.Value
			end)
			return out
		end
	elseif itemName == "FromName" then
		return function(self, name)
			return self[name]
		end
	elseif itemName == "FromValue" then
		return function(self, value)
			for _, item in rawget(self, "_items") do
				if item.Value == value then
					return item
				end
			end
			return nil
		end
	end
	local items = rawget(enumType, "_items")
	local item = setmetatable({ Name = itemName, Value = 1000 + #items, EnumType = enumType }, itemMT)
	table.insert(items, item)
	rawset(enumType, itemName, item)
	return item
end
local function enumType(name, list)
	local t = setmetatable({ Name = name, _items = {} }, typeMT)
	for itemName, value in list or {} do
		local item = setmetatable({ Name = itemName, Value = value, EnumType = t }, itemMT)
		table.insert(rawget(t, "_items"), item)
		rawset(t, itemName, item)
	end
	return t
end
local Enum = setmetatable({}, {
	__index = function(enums, typeName)
		local t = enumType(typeName)
		rawset(enums, typeName, t)
		return t
	end,
})
rawset(
	Enum,
	"HumanoidStateType",
	enumType("HumanoidStateType", {
		FallingDown = 0,
		Ragdoll = 1,
		GettingUp = 2,
		Jumping = 3,
		Swimming = 4,
		Freefall = 5,
		Flying = 6,
		Landed = 7,
		Running = 8,
		RunningNoPhysics = 10,
		StrafingNoPhysics = 11,
		Climbing = 12,
		Seated = 13,
		PlatformStanding = 14,
		Dead = 15,
		Physics = 16,
		None = 18,
	})
)
rawset(Enum, "HumanoidRigType", enumType("HumanoidRigType", { R6 = 0, R15 = 1 }))
rawset(Enum, "BulkMoveMode", enumType("BulkMoveMode", { FireAllEvents = 0, FireCFrameChanged = 1 }))
rawset(Enum, "RotationOrder", enumType("RotationOrder", { XYZ = 0, XZY = 1, YZX = 2, YXZ = 3, ZXY = 4, ZYX = 5 }))
rawset(Enum, "PartType", enumType("PartType", { Ball = 0, Block = 1, Cylinder = 2 }))
rawset(Enum, "NormalId", enumType("NormalId", { Right = 0, Top = 1, Back = 2, Left = 3, Bottom = 4, Front = 5 }))
R.Enum = Enum

return R
