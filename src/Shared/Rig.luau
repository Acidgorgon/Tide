--!strict
-- Model helpers: which part drives an entity, reading its pose as numbers,
-- building the CFrame for a pose.

local Codec = require(script.Parent.Codec)

local Rig = {}

local matrixToQuat = Codec.matrixToQuat
local atan2 = math.atan2
local sin = math.sin
local cos = math.cos

-- The part whose CFrame is the entity's pose: the model itself if it is a part,
-- else PrimaryPart, else a HumanoidRootPart child. nil means "use the pivot".
function Rig.root(model: any): any
	if model == nil then
		return nil
	end
	if model:IsA("BasePart") then
		return model
	end
	local primary = model.PrimaryPart
	if primary ~= nil then
		return primary
	end
	return model:FindFirstChild("HumanoidRootPart")
end

-- Pose as numbers: x, y, z, yaw, qx, qy, qz, qw (quaternion only when `full`).
function Rig.read(model: any, root: any, full: boolean): (number, number, number, number, number, number, number, number)
	local cf = if root ~= nil then root.CFrame else model:GetPivot()
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local yaw = atan2(r02, r22)
	if full then
		local qx, qy, qz, qw = matrixToQuat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
		return x, y, z, yaw, qx, qy, qz, qw
	end
	return x, y, z, yaw, 0, 0, 0, 1
end

-- Linear velocity (studs/s) and angular velocity (rad/s, world frame) of the root's assembly.
-- Zero without a root part (pivot-only models).
function Rig.readMotion(root: any): (number, number, number, number, number, number)
	if root == nil then
		return 0, 0, 0, 0, 0, 0
	end
	local v = root.AssemblyLinearVelocity
	local w = root.AssemblyAngularVelocity
	local vx, vy, vz, wx, wy, wz = 0, 0, 0, 0, 0, 0
	if v ~= nil then
		vx, vy, vz = v.X, v.Y, v.Z
	end
	if w ~= nil then
		wx, wy, wz = w.X, w.Y, w.Z
	end
	return vx, vy, vz, wx, wy, wz
end

-- Pose of a CFrame as numbers (same layout as Rig.read).
function Rig.fromCFrame(cf: CFrame, full: boolean): (number, number, number, number, number, number, number, number)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local yaw = atan2(r02, r22)
	if full then
		local qx, qy, qz, qw = matrixToQuat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
		return x, y, z, yaw, qx, qy, qz, qw
	end
	return x, y, z, yaw, 0, 0, 0, 1
end

-- CFrame for a pose. Yaw-only kinds rotate about +Y.
function Rig.cframe(x: number, y: number, z: number, yaw: number, full: boolean, qx: number, qy: number, qz: number, qw: number): CFrame
	if full then
		return CFrame.new(x, y, z, qx, qy, qz, qw)
	end
	local h = yaw * 0.5
	return CFrame.new(x, y, z, 0, sin(h), 0, cos(h))
end

return Rig
