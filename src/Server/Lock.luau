--!strict
-- Lock (client-owned entities): stops Roblox from replicating the character's
-- position so the only position stream is Tide's, and keeps the server's copy
-- on the newest accepted sample (server-side hit boxes / touches see Tide's timeline).
--
-- Config.lockMode
--   "root" (default): a Camera is parented INSIDE the root part (a Camera's
--     children never replicate) holding an unanchored, near-massless "locker"
--     part with RootPriority 126, welded to the root. The non-replicated locker
--     becomes the assembly root, so Roblox stops replicating the assembly while
--     the owning client keeps simulating its own copy (it never sees the locker).
--     Moved by setting the locker's CFrame each frame; its AssemblyLinearVelocity
--     (and AssemblyAngularVelocity for full-rotation kinds) is set from the
--     newest samples (Motion.velocity), so server physics and touch/velocity
--     reads see the player's real motion.
--   "anchored": an anchored locker under workspace.CurrentCamera welded to the
--     root, moved with one BulkMoveTo. Simpler, but anchoring the assembly likely
--     takes network ownership away from the owner (player frozen). Fallback only.
-- Config.lockHumanoidStates: optional list of Enum.HumanoidStateType disabled on
--   the SERVER's Humanoid while locked (SetStateEnabled does not replicate). Only
--   if the server Humanoid is seen fighting the lock. Never use PlatformStand:
--   it replicates and would freeze the owner's character.
--
-- VERIFY IN STUDIO (two-client Play test, character moving and jumping):
--   1. "root": the owner still moves freely (keeps network ownership), other
--      clients see no native position updates (only Tide's), and the server
--      character follows the locker without jitter or falling.
--   2. "root": no TideLock Camera / locker / weld appears on any client.
--   3. Server Humanoid state while locked (Physics/FallingDown/Freefall flapping?);
--      if it fights, try lockHumanoidStates = { Enum.HumanoidStateType.FallingDown, ... }.
--   4. Server-side touches / hit boxes against the locked character still work.
--   5. Death and respawn: the lock is removed with the old character, the new
--      character is locked, no leftover parts.
--   6. "anchored": whether the owner loses network ownership (expected) and
--      whether the welded character follows BulkMoveTo of the anchored locker.
--   7. Tide.teleport of a locked player moves it everywhere (the server holds the
--      target until the owner's flagged upload arrives; resent every TeleportRetry).
--   8. Config.teleportOnWrite: `root.CFrame = cf` AND `character:PivotTo(cf)` on the
--      server both fire root:GetPropertyChangedSignal("CFrame") (PivotTo is the one
--      to check), while the lock's own locker moves and physics do not turn into
--      teleports (they are filtered as no-op writes anyway).
--   9. Locker velocity: server-side root.AssemblyLinearVelocity of a locked running
--      player matches Tide.velocity(character).
--
-- OPEN ITEM (not built): death relay. Under the lock the server Humanoid does not
-- simulate the owner's character, so a death the OWNER detects (e.g. fell out of
-- the world, Health set locally) is not seen by the server. Games that rely on
-- client-side deaths need a small reliable "I died" message validated on the
-- server; Tide does not provide one yet.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Rig = require(Shared.Rig)
local State = require(script.Parent.State)
local Motion = require(script.Parent.Motion)

local Lock = {}

-- True while the lock writes CFrames (immediate-mode signal handlers can ignore
-- those writes; deferred handlers rely on the no-op check instead).
Lock.writing = false

local active = State.active
local hist = State.hist
local kinds = State.kind
local locker = State.locker
local weld = State.weld

local lockedIndex = {} :: { [number]: number } -- history index the locker was last moved to
local holder = {} :: { [number]: any } -- "root" mode: the Camera inside the root
local anchoredMode = {} :: { [number]: boolean }
local disabledStates = {} :: { [number]: { any } }
local parts = {} :: { any }
local cframes = {} :: { any }

local function serverCamera(): any
	local camera = workspace.CurrentCamera
	if camera == nil then
		camera = Instance.new("Camera")
		camera.Name = "TideCamera"
		camera.Parent = workspace
		workspace.CurrentCamera = camera
	end
	return camera
end

local function newLocker(root: any, anchored: boolean): any
	local part = Instance.new("Part")
	part.Name = "TideLocker"
	part.Anchored = anchored
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	if anchored then
		part.Size = Vector3.new(0.2, 0.2, 0.2)
	else
		part.Size = Vector3.new(0, 0, 0)
		part.Massless = false
		part.RootPriority = 126
		part.CustomPhysicalProperties = PhysicalProperties.new(0.0001, 0, 0, 0, 0)
	end
	part.CFrame = root.CFrame
	return part
end

function Lock.lock(slot: number)
	local root = State.root[slot]
	if root == nil or locker[slot] ~= nil then
		return
	end
	local anchored = Config.lockMode == "anchored"
	local part = newLocker(root, anchored)
	local w = Instance.new("Weld")
	w.Name = "TideWeld"
	w.Part0 = part
	w.Part1 = root
	if anchored then
		part.Parent = serverCamera()
		w.Parent = part
	else
		local camera = Instance.new("Camera")
		camera.Name = "TideLock"
		camera.Archivable = false
		camera.Parent = root
		part.Parent = camera
		w.Parent = camera
		holder[slot] = camera
	end
	locker[slot] = part
	weld[slot] = w
	anchoredMode[slot] = anchored
	lockedIndex[slot] = 0

	local states = Config.lockHumanoidStates
	local model = State.model[slot]
	if type(states) == "table" and model ~= nil then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			local off = {}
			for _, state in states do
				if humanoid:GetStateEnabled(state) then
					humanoid:SetStateEnabled(state, false)
					table.insert(off, state)
				end
			end
			disabledStates[slot] = off
		end
	end
end

function Lock.unlock(slot: number)
	local w = weld[slot]
	local part = locker[slot]
	local camera = holder[slot]
	weld[slot] = nil
	locker[slot] = nil
	holder[slot] = nil
	anchoredMode[slot] = nil
	lockedIndex[slot] = nil
	if w ~= nil then
		w:Destroy()
	end
	if part ~= nil then
		part:Destroy()
	end
	if camera ~= nil then
		camera:Destroy()
	end
	local off = disabledStates[slot]
	disabledStates[slot] = nil
	local model = State.model[slot]
	if off ~= nil and model ~= nil then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			for _, state in off do
				humanoid:SetStateEnabled(state, true)
			end
		end
	end
end

-- Moves every locker whose entity got a new sample ("root": CFrame set;
-- "anchored": one BulkMoveTo).
function Lock.step()
	local n = 0
	for k = 1, State.count do
		local slot = active[k]
		local part = locker[slot]
		if part ~= nil then
			local h = hist[slot]
			if h.last ~= lockedIndex[slot] then
				lockedIndex[slot] = h.last
				local p = h.last % h.cap + 1
				local full = h.full
				local cf = Rig.cframe(
					h.x[p],
					h.y[p],
					h.z[p],
					h.yaw[p],
					full,
					if full then h.qx[p] else 0,
					if full then h.qy[p] else 0,
					if full then h.qz[p] else 0,
					if full then h.qw[p] else 1
				)
				if anchoredMode[slot] then
					n += 1
					parts[n] = part
					cframes[n] = cf
				else
					Lock.writing = true
					part.CFrame = cf
					local vx, vy, vz, wx, wy, wz = Motion.velocity(slot)
					part.AssemblyLinearVelocity = Vector3.new(vx, vy, vz)
					if full then
						part.AssemblyAngularVelocity = Vector3.new(wx, wy, wz)
					end
					Lock.writing = false
				end
			end
		end
	end
	if n > 0 then
		Lock.writing = true
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		Lock.writing = false
		table.clear(parts)
		table.clear(cframes)
	end
end

return Lock
