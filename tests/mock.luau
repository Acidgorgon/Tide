--!optimize 2
-- Roblox mock for Tide tests under the luau-bench host (Luau 0.700).
-- Derived from Ripple's bench mock (instance model, header injection, replicas)
-- and extended for Tide:
--   * virtual clock (world.now); workspace:GetServerTimeNow() = world.now (+ per-client offset)
--   * network with per-client latency, jitter and loss: reliable RemoteEvent stays ordered,
--     UnreliableRemoteEvent may drop and reorder; arguments are copied at Fire time
--   * CFrame (real math), Part/Model/Weld/Camera, BulkMoveTo, Destroying, PivotTo
--   * Player.CharacterAdded / CharacterRemoving, Players:GetPlayerByUserId
--   * streaming simulation: world:streamOut(clientIndex, serverInstance) maps it to nil
--   * Animator / Animation / AnimationTrack (see "Animation" below); a client may Destroy a
--     replica locally (it then disappears from that client's view only)
--
-- Modules are compiled with one injected line after their `--!` directives:
--     local game, workspace, Instance, task, warn, typeof, _G, shared, script, require = ...
-- so the global environment stays safe (fastcalls and native codegen keep working).

local Mock = {}

--------------------------------------------------------------------------------
-- CFrame
--------------------------------------------------------------------------------

local CFrameMT = { __robloxtype = "CFrame" }
local CFrameLib = {}

local function cfRaw(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return setmetatable({ x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }, CFrameMT)
end

local function fromQuat(x, y, z, qx, qy, qz, qw)
	local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
	if n == 0 then
		qx, qy, qz, qw = 0, 0, 0, 1
	else
		qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
	end
	return cfRaw(
		x,
		y,
		z,
		1 - 2 * (qy * qy + qz * qz),
		2 * (qx * qy - qz * qw),
		2 * (qx * qz + qy * qw),
		2 * (qx * qy + qz * qw),
		1 - 2 * (qx * qx + qz * qz),
		2 * (qy * qz - qx * qw),
		2 * (qx * qz - qy * qw),
		2 * (qy * qz + qx * qw),
		1 - 2 * (qx * qx + qy * qy)
	)
end

function CFrameLib.new(...)
	local n = select("#", ...)
	if n == 0 then
		return cfRaw(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 1 then
		local v = ...
		return cfRaw(v.X, v.Y, v.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 3 then
		local x, y, z = ...
		return cfRaw(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 7 then
		return fromQuat(...)
	elseif n == 12 then
		return cfRaw(...)
	end
	error("mock CFrame.new: unsupported argument count " .. n)
end

local function rotX(a)
	local c, s = math.cos(a), math.sin(a)
	return cfRaw(0, 0, 0, 1, 0, 0, 0, c, -s, 0, s, c)
end
local function rotY(a)
	local c, s = math.cos(a), math.sin(a)
	return cfRaw(0, 0, 0, c, 0, s, 0, 1, 0, -s, 0, c)
end
local function rotZ(a)
	local c, s = math.cos(a), math.sin(a)
	return cfRaw(0, 0, 0, c, -s, 0, s, c, 0, 0, 0, 1)
end

local function mul(a, b)
	local ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22 = table.unpack(a, 1, 12)
	local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 = table.unpack(b, 1, 12)
	return cfRaw(
		a00 * bx + a01 * by + a02 * bz + ax,
		a10 * bx + a11 * by + a12 * bz + ay,
		a20 * bx + a21 * by + a22 * bz + az,
		a00 * b00 + a01 * b10 + a02 * b20,
		a00 * b01 + a01 * b11 + a02 * b21,
		a00 * b02 + a01 * b12 + a02 * b22,
		a10 * b00 + a11 * b10 + a12 * b20,
		a10 * b01 + a11 * b11 + a12 * b21,
		a10 * b02 + a11 * b12 + a12 * b22,
		a20 * b00 + a21 * b10 + a22 * b20,
		a20 * b01 + a21 * b11 + a22 * b21,
		a20 * b02 + a21 * b12 + a22 * b22
	)
end

local function inverse(a)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = table.unpack(a, 1, 12)
	-- transpose rotation, -R^T p
	return cfRaw(
		-(r00 * x + r10 * y + r20 * z),
		-(r01 * x + r11 * y + r21 * z),
		-(r02 * x + r12 * y + r22 * z),
		r00,
		r10,
		r20,
		r01,
		r11,
		r21,
		r02,
		r12,
		r22
	)
end

function CFrameLib.Angles(rx, ry, rz)
	return mul(mul(rotX(rx), rotY(ry)), rotZ(rz))
end
CFrameLib.fromEulerAnglesXYZ = CFrameLib.Angles

function CFrameLib.fromEulerAnglesYXZ(rx, ry, rz)
	return mul(mul(rotY(ry), rotX(rx)), rotZ(rz))
end

CFrameLib.identity = CFrameLib.new()

local cfMethods = {}
function cfMethods.GetComponents(self)
	return table.unpack(self, 1, 12)
end
cfMethods.components = cfMethods.GetComponents
function cfMethods.Inverse(self)
	return inverse(self)
end
function cfMethods.ToObjectSpace(self, other)
	return mul(inverse(self), other)
end
function cfMethods.ToWorldSpace(self, other)
	return mul(self, other)
end
function cfMethods.PointToWorldSpace(self, v)
	local r = mul(self, cfRaw(v.X, v.Y, v.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1))
	return vector.create(r[1], r[2], r[3])
end

function CFrameMT.__index(self, key)
	if key == "Position" or key == "p" then
		return vector.create(self[1], self[2], self[3])
	elseif key == "X" then
		return self[1]
	elseif key == "Y" then
		return self[2]
	elseif key == "Z" then
		return self[3]
	elseif key == "LookVector" then
		return vector.create(-self[6], -self[9], -self[12])
	elseif key == "RightVector" then
		return vector.create(self[4], self[7], self[10])
	elseif key == "UpVector" then
		return vector.create(self[5], self[8], self[11])
	end
	return cfMethods[key]
end

function CFrameMT.__mul(a, b)
	if type(b) == "vector" then
		return cfMethods.PointToWorldSpace(a, b)
	end
	return mul(a, b)
end

function CFrameMT.__add(a, v)
	return cfRaw(a[1] + v.X, a[2] + v.Y, a[3] + v.Z, table.unpack(a, 4, 12))
end

function CFrameMT.__tostring(a)
	return string.format("CFrame(%.3f, %.3f, %.3f)", a[1], a[2], a[3])
end

Mock.CFrame = CFrameLib

-- Yaw of a CFrame (rotation about +Y of the look direction), for tests.
function Mock.yawOf(cf)
	return math.atan2(cf[6], cf[12])
end

--------------------------------------------------------------------------------
-- SharedTable (v0.4 links): one Lua table per SharedTable, shared by reference between the
-- envs of a world (the "VMs"). Keys: strings or numbers; values: nil, booleans, numbers,
-- strings, vectors or SharedTables (SharedTable.new converts nested tables, assignment does
-- not). No parallel phases here: atomicity is trivially true.
--------------------------------------------------------------------------------

local stStore = setmetatable({}, { __mode = "k" })
local STMeta = { __robloxtype = "SharedTable" }

local function stKey(k)
	local t = type(k)
	if t ~= "string" and t ~= "number" then
		error(`SharedTable: invalid key type {t}`, 3)
	end
end

local function stValue(v)
	local t = type(v)
	if t == "nil" or t == "boolean" or t == "number" or t == "string" or t == "vector" then
		return
	end
	if t == "table" and getmetatable(v) == STMeta then
		return
	end
	error(`SharedTable: invalid value type {t}`, 3)
end

STMeta.__index = function(st, k)
	stKey(k)
	return stStore[st][k]
end
STMeta.__newindex = function(st, k, v)
	stKey(k)
	stValue(v)
	stStore[st][k] = v
end
STMeta.__iter = function(st)
	return next, stStore[st]
end

local SharedTableLib = {}

function SharedTableLib.new(t)
	local st = setmetatable({}, STMeta)
	stStore[st] = {}
	if t ~= nil then
		for k, v in t do
			if type(v) == "table" and getmetatable(v) ~= STMeta then
				v = SharedTableLib.new(v)
			end
			st[k] = v
		end
	end
	return st
end

function SharedTableLib.increment(st, k, delta)
	local old = st[k]
	if type(old) ~= "number" then
		error("SharedTable.increment: the element is not a number", 2)
	end
	st[k] = old + delta
	return old
end

function SharedTableLib.update(st, k, fn)
	st[k] = fn(st[k])
end

function SharedTableLib.size(st)
	local n = 0
	for _ in stStore[st] do
		n += 1
	end
	return n
end

function SharedTableLib.clear(st)
	table.clear(stStore[st])
end

function SharedTableLib.clone(st)
	local c = SharedTableLib.new()
	for k, v in stStore[st] do
		stStore[c][k] = v
	end
	return c
end

Mock.SharedTable = SharedTableLib

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

function Mock.installGlobals()
	Vector3 = table.freeze({
		new = vector.create,
		zero = vector.zero,
		one = vector.one,
	})
	CFrame = CFrameLib
	SharedTable = SharedTableLib
	tick = os.clock
	time = os.clock
	Enum = {
		BulkMoveMode = { FireCFrameChanged = "FireCFrameChanged", FireAllEvents = "FireAllEvents" },
		HumanoidStateType = { FallingDown = "FallingDown", Ragdoll = "Ragdoll", Physics = "Physics", Freefall = "Freefall" },
		AnimationPriority = Mock.AnimationPriority,
	}
	PhysicalProperties = {
		new = function(density, friction, elasticity, frictionWeight, elasticityWeight)
			return table.freeze({
				Density = density,
				Friction = friction,
				Elasticity = elasticity,
				FrictionWeight = frictionWeight,
				ElasticityWeight = elasticityWeight,
			})
		end,
	}
end

--------------------------------------------------------------------------------
-- Signal
--------------------------------------------------------------------------------

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local fns = self._signal._fns
	local index = table.find(fns, self._fn)
	if index then
		table.remove(fns, index)
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _fns = {} }, Signal)
end

function Signal:Connect(fn)
	table.insert(self._fns, fn)
	return setmetatable({ Connected = true, _signal = self, _fn = fn }, Connection)
end

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Wait()
	error("Signal:Wait() is not supported by the mock")
end

function Signal:_fire(...)
	if #self._fns == 0 then
		return
	end
	for _, fn in table.clone(self._fns) do
		fn(...)
	end
end

Mock.Signal = Signal

--------------------------------------------------------------------------------
-- typeof
--------------------------------------------------------------------------------

local rawtypeof = typeof

local function robloxTypeof(value: any): string
	local t = rawtypeof(value)
	if t == "vector" then
		return "Vector3"
	elseif t == "table" then
		local mt = getmetatable(value)
		if type(mt) == "table" and rawget(mt, "__robloxtype") then
			return rawget(mt, "__robloxtype")
		end
	end
	return t
end

Mock.typeof = robloxTypeof

--------------------------------------------------------------------------------
-- task
--------------------------------------------------------------------------------

local function newTaskLib()
	local deferred = {}
	local lib = {}
	local function resume(co, ...)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			error(debug.traceback(co, tostring(err)), 0)
		end
	end
	function lib.spawn(fnOrThread, ...)
		local co = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
		resume(co, ...)
		return co
	end
	function lib.defer(fnOrThread, ...)
		local co = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
		table.insert(deferred, table.pack(co, ...))
		return co
	end
	function lib.cancel(thread)
		coroutine.close(thread)
	end
	function lib.wait()
		error("task.wait is not supported by the mock")
	end
	function lib.delay(_s, fnOrThread)
		return if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	end
	function lib._runDeferred()
		local i = 1
		while i <= #deferred do
			local rec = deferred[i]
			deferred[i] = nil
			resume(rec[1], table.unpack(rec, 2, rec.n))
			i += 1
		end
		table.clear(deferred)
	end
	return lib
end

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

local Instance = {}
local InstanceMT = { __robloxtype = "Instance" }

local IS_A = {
	RemoteEvent = { BaseRemoteEvent = true },
	UnreliableRemoteEvent = { BaseRemoteEvent = true },
	ModuleScript = { LuaSourceContainer = true },
	Part = { BasePart = true, PVInstance = true },
	MeshPart = { BasePart = true, PVInstance = true },
	Model = { PVInstance = true },
	Weld = { JointInstance = true },
}

local LAZY_SIGNALS = { Changed = true, AttributeChanged = true, Destroying = true, AncestryChanged = true, ChildAdded = true }

function InstanceMT.__index(self, key)
	if key == "Parent" then
		return rawget(self, "_parent")
	end
	local shadow = rawget(self, "_shadow")
	if shadow ~= nil then
		local v = shadow[key]
		if v ~= nil then
			return v
		end
	end
	if key == "Position" then
		local cf = rawget(self, "CFrame")
		if cf == nil and shadow ~= nil then
			cf = shadow.CFrame
		end
		if type(cf) == "table" and getmetatable(cf) == CFrameMT then
			return cf.Position
		end
	end
	local method = Instance[key]
	if method ~= nil then
		return method
	end
	if LAZY_SIGNALS[key] then
		local signal = Signal.new()
		rawset(self, key, signal)
		return signal
	end
	local server = rawget(self, "_server")
	if server ~= nil and type(key) == "string" and string.sub(key, 1, 1) ~= "_" then
		local value = rawget(server, key)
		if value == nil then
			local serverShadow = rawget(server, "_shadow")
			value = serverShadow and serverShadow[key]
		end
		if value ~= nil and type(value) ~= "function" then
			if type(value) == "table" and getmetatable(value) == InstanceMT then
				return rawget(self, "_map")(value)
			end
			return value
		end
	end
	return Instance.FindFirstChild(self, key)
end

function InstanceMT.__newindex(self, key, value)
	if key == "Parent" then
		local old = rawget(self, "_parent")
		if old == value then
			return
		end
		if old ~= nil then
			local siblings = rawget(old, "_children")
			local index = table.find(siblings, self)
			if index then
				table.remove(siblings, index)
			end
		end
		rawset(self, "_parent", value)
		if value ~= nil then
			table.insert(rawget(value, "_children"), self)
			local added = rawget(value, "ChildAdded")
			if added ~= nil then
				added:_fire(self)
			end
		end
		return
	end
	local signals = rawget(self, "_propSignals")
	local signal = signals and signals[key]
	if signal ~= nil then
		rawget(self, "_shadow")[key] = value
		signal:_fire()
		return
	end
	rawset(self, key, value)
end

-- Engine-side property write: no change signal (physics, welds).
local function setQuiet(inst, key, value)
	local shadow = rawget(inst, "_shadow")
	if shadow ~= nil and shadow[key] ~= nil then
		shadow[key] = value
	else
		rawset(inst, key, value)
	end
end
Mock.setQuiet = setQuiet

function InstanceMT.__tostring(self)
	return rawget(self, "Name")
end

local function newInstance(className: string, name: string?)
	local inst = setmetatable({
		ClassName = className,
		Name = name or className,
		_children = {},
		_attributes = {},
	}, InstanceMT)
	if IS_A[className] and IS_A[className].BasePart then
		rawset(inst, "CFrame", CFrameLib.new())
		rawset(inst, "Anchored", false)
		rawset(inst, "CanCollide", true)
		rawset(inst, "CanQuery", true)
		rawset(inst, "CanTouch", true)
		rawset(inst, "Transparency", 0)
		rawset(inst, "Size", vector.create(2, 2, 1))
	elseif className == "Weld" then
		rawset(inst, "C0", CFrameLib.new())
		rawset(inst, "C1", CFrameLib.new())
	elseif className == "Animation" then
		rawset(inst, "AnimationId", "")
	end
	return inst
end

Mock.newInstance = newInstance

function Mock.isInstance(v): boolean
	return type(v) == "table" and getmetatable(v) == InstanceMT
end

function Instance.GetChildren(self)
	local resolve = rawget(self, "_resolveChildren")
	if resolve then
		return resolve(self)
	end
	return table.clone(rawget(self, "_children"))
end

function Instance.FindFirstChild(self, name: string, recursive: boolean?)
	local children = Instance.GetChildren(self)
	for _, child in children do
		if rawget(child, "Name") == name then
			return child
		end
	end
	if recursive then
		for _, child in children do
			local found = Instance.FindFirstChild(child, name, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function Instance.FindFirstChildOfClass(self, className: string)
	for _, child in Instance.GetChildren(self) do
		if rawget(child, "ClassName") == className then
			return child
		end
	end
	return nil
end

function Instance.WaitForChild(self, name: string, timeout: number?)
	local child = Instance.FindFirstChild(self, name)
	if child == nil then
		if timeout ~= nil then
			return nil -- the mock cannot yield: a timed wait gives up at once
		end
		error(`WaitForChild("{name}") on {rawget(self, "Name")} would yield forever`)
	end
	return child
end

function Instance.GetDescendants(self)
	local out = {}
	local function walk(inst)
		for _, child in Instance.GetChildren(inst) do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function Instance.IsA(self, className: string): boolean
	local cls = rawget(self, "ClassName")
	if cls == className or className == "Instance" then
		return true
	end
	local set = IS_A[cls]
	return set ~= nil and set[className] == true
end

function Instance.IsDescendantOf(self, ancestor): boolean
	local p = self.Parent
	while p ~= nil do
		if p == ancestor then
			return true
		end
		p = p.Parent
	end
	return false
end

function Instance.GetFullName(self)
	local parts = {}
	local p = self
	while p ~= nil and rawget(p, "ClassName") ~= "DataModel" do
		table.insert(parts, 1, rawget(p, "Name"))
		p = p.Parent
	end
	return table.concat(parts, ".")
end

function Instance.Destroy(self)
	rawset(self, "_destroyed", true)
	local signal = rawget(self, "Destroying")
	if signal then
		signal:_fire()
	end
	for _, child in table.clone(rawget(self, "_children")) do
		Instance.Destroy(child)
	end
	self.Parent = nil
end

function Instance.GetAttribute(self, name: string)
	return rawget(self, "_attributes")[name]
end

function Instance.SetAttribute(self, name: string, value: any)
	local attributes = rawget(self, "_attributes")
	local old = attributes[name]
	attributes[name] = value
	if old ~= value then
		local signals = rawget(self, "_attrSignals")
		local signal = signals and signals[name]
		if signal ~= nil then
			signal:_fire()
		end
		local changed = rawget(self, "AttributeChanged")
		if changed ~= nil then
			changed:_fire(name)
		end
	end
end

function Instance.GetAttributeChangedSignal(self, name: string)
	local signals = rawget(self, "_attrSignals")
	if signals == nil then
		signals = {}
		rawset(self, "_attrSignals", signals)
	end
	local signal = signals[name]
	if signal == nil then
		signal = Signal.new()
		signals[name] = signal
	end
	return signal
end

-- Fires (synchronously) on every script write of the property, like
-- GetPropertyChangedSignal with immediate signal behaviour. Engine-side moves
-- (welds in World:solveWelds) use setQuiet and do not fire. The watched
-- property moves into a shadow table so writes reach __newindex.
function Instance.GetPropertyChangedSignal(self, prop: string)
	local signals = rawget(self, "_propSignals")
	if signals == nil then
		signals = {}
		rawset(self, "_propSignals", signals)
		rawset(self, "_shadow", {})
	end
	local signal = signals[prop]
	if signal == nil then
		signal = Signal.new()
		signals[prop] = signal
		local current = self[prop]
		rawset(self, prop, nil)
		rawget(self, "_shadow")[prop] = current
	end
	return signal
end

local function basePartsOf(model)
	local parts = {}
	for _, d in Instance.GetDescendants(model) do
		if Instance.IsA(d, "BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

function Instance.GetPivot(self)
	if Instance.IsA(self, "BasePart") then
		return self.CFrame
	end
	local primary = self.PrimaryPart
	if primary then
		return primary.CFrame
	end
	local parts = basePartsOf(self)
	if parts[1] then
		return parts[1].CFrame
	end
	return CFrameLib.new()
end

function Instance.PivotTo(self, cf)
	if Instance.IsA(self, "BasePart") then
		self.CFrame = cf
		return
	end
	local pivot = Instance.GetPivot(self)
	local delta = mul(cf, inverse(pivot))
	for _, part in basePartsOf(self) do
		part.CFrame = mul(delta, part.CFrame)
	end
end

--------------------------------------------------------------------------------
-- Animation
--------------------------------------------------------------------------------
-- Animator: LoadAnimation, AnimationPlayed, GetPlayingAnimationTracks. Tracks advance in
-- their environment's step right after PreAnimation (where the engine animates):
-- WeightCurrent ramps linearly to WeightTarget over the fade, TimePosition += dt * Speed
-- (wrapping at Length when Looped; a non-looped track stops at its end). Stop() fires
-- Stopped at once and fades out (the track keeps advancing until faded); Ended fires
-- when it is gone. `_replicates`: true for a server-created Animator and its client
-- replicas, false for one a client created (Roblox does not replicate those).
-- Track Length: the Animation's "Length" attribute, else Mock.animLength. Looped: the
-- Animation's "Looped" attribute, else false.

local PRIORITY = {}
for i, name in { "Core", "Idle", "Movement", "Action", "Action2", "Action3", "Action4" } do
	PRIORITY[name] = table.freeze(setmetatable({ Name = name, Value = if name == "Core" then 1000 else i - 2 }, {
		__robloxtype = "EnumItem",
		__tostring = function()
			return "Enum.AnimationPriority." .. name
		end,
	}))
end
Mock.AnimationPriority = table.freeze(PRIORITY)
Mock.animLength = 1

local function setRamp(track, to: number, fade: number)
	rawset(track, "_wFrom", rawget(track, "WeightCurrent"))
	rawset(track, "_wTo", to)
	rawset(track, "_wFade", fade)
	rawset(track, "_wT", 0)
	rawset(track, "WeightTarget", to)
	if fade <= 0 then
		rawset(track, "WeightCurrent", to)
	end
end

local function activate(animator, track)
	if not rawget(track, "_active") then
		rawset(track, "_active", true)
		table.insert(rawget(animator, "_tracks"), track)
	end
end

local function newTrack(animator, animation)
	local track = newInstance("AnimationTrack")
	rawset(track, "Animation", animation)
	rawset(track, "Length", Instance.GetAttribute(animation, "Length") or Mock.animLength)
	rawset(track, "Looped", Instance.GetAttribute(animation, "Looped") == true)
	rawset(track, "Priority", PRIORITY.Core)
	rawset(track, "IsPlaying", false)
	rawset(track, "Speed", 1)
	rawset(track, "WeightTarget", 0)
	rawset(track, "WeightCurrent", 0)
	rawset(track, "TimePosition", 0)
	rawset(track, "Stopped", Signal.new())
	rawset(track, "Ended", Signal.new())
	rawset(track, "DidLoop", Signal.new())
	rawset(track, "_active", false)
	setRamp(track, 0, 0)
	rawset(track, "Play", function(self, fade, weight, speed)
		fade = fade or 0.1
		if not rawget(self, "IsPlaying") then
			rawset(self, "TimePosition", 0)
		end
		rawset(self, "IsPlaying", true)
		rawset(self, "Speed", speed or 1)
		setRamp(self, weight or 1, fade)
		activate(animator, self)
		rawget(animator, "AnimationPlayed"):_fire(self)
	end)
	rawset(track, "Stop", function(self, fade)
		if not rawget(self, "IsPlaying") then
			return
		end
		rawset(self, "IsPlaying", false)
		setRamp(self, 0, fade or 0.1)
		rawget(self, "Stopped"):_fire()
	end)
	rawset(track, "AdjustSpeed", function(self, speed)
		rawset(self, "Speed", speed or 1)
	end)
	rawset(track, "AdjustWeight", function(self, weight, fade)
		setRamp(self, weight or 1, fade or 0.1)
	end)
	return track
end

local function advanceTrack(track, dt: number): boolean
	local wT = rawget(track, "_wT") + dt
	rawset(track, "_wT", wT)
	local from, to, fade = rawget(track, "_wFrom"), rawget(track, "_wTo"), rawget(track, "_wFade")
	rawset(track, "WeightCurrent", if fade <= 0 or wT >= fade then to else from + (to - from) * wT / fade)
	local tp = rawget(track, "TimePosition") + dt * rawget(track, "Speed")
	local len = rawget(track, "Length")
	if len > 0 then
		if rawget(track, "Looped") then
			if tp >= len or tp < 0 then
				tp %= len
				rawget(track, "DidLoop"):_fire()
			end
		elseif tp >= len then
			tp = len
			if rawget(track, "IsPlaying") then
				rawset(track, "IsPlaying", false)
				setRamp(track, 0, 0)
				rawset(track, "TimePosition", tp)
				rawget(track, "Stopped"):_fire()
			end
		elseif tp < 0 then
			tp = 0
		end
	end
	rawset(track, "TimePosition", tp)
	if not rawget(track, "IsPlaying") and rawget(track, "WeightCurrent") <= 0 then
		rawset(track, "_active", false)
		rawget(track, "Ended"):_fire()
		return false
	end
	return true
end

-- Gives an instance Animator behaviour, owned (stepped) by env.
function Mock.makeAnimator(animator, env, replicates: boolean)
	rawset(animator, "_replicates", replicates)
	rawset(animator, "_tracks", {})
	rawset(animator, "AnimationPlayed", Signal.new())
	rawset(animator, "LoadAnimation", function(self, animation)
		assert(animation ~= nil, "LoadAnimation: animation is nil")
		return newTrack(self, animation)
	end)
	rawset(animator, "GetPlayingAnimationTracks", function(self)
		local out = {}
		for _, track in rawget(self, "_tracks") do
			if rawget(track, "IsPlaying") then
				table.insert(out, track)
			end
		end
		return out
	end)
	table.insert(env.animators, animator)
	return animator
end

-- True for an Animator a client created (one Roblox would not replicate).
function Mock.isClientCreated(animator): boolean
	return rawget(animator, "_replicates") == false
end

local function stepAnimators(env, dt: number)
	local list = env.animators
	local i = 1
	while i <= #list do
		local animator = list[i]
		if rawget(animator, "_destroyed") then
			table.remove(list, i)
		else
			local tracks = rawget(animator, "_tracks")
			local k = 1
			while k <= #tracks do
				if advanceTrack(tracks[k], dt) then
					k += 1
				else
					table.remove(tracks, k)
				end
			end
			i += 1
		end
	end
end

Mock.stepAnimators = stepAnimators

--------------------------------------------------------------------------------
-- Argument copying
--------------------------------------------------------------------------------

local function wireSize(v: any): number
	local t = type(v)
	if t == "buffer" then
		return 2 + buffer.len(v)
	elseif t == "string" then
		return 2 + #v
	elseif t == "number" then
		return 9
	elseif t == "table" then
		if getmetatable(v) == InstanceMT then
			return 5
		end
		local size = 2
		for _, item in v do
			size += wireSize(item)
		end
		return size
	end
	return 1
end
Mock.wireSize = wireSize

-- Copy at fire time: buffers and plain tables are copied, instances kept (mapped at delivery).
local function snapshot(v: any): any
	local t = type(v)
	if t == "buffer" then
		local copy = buffer.create(buffer.len(v))
		buffer.copy(copy, 0, v, 0, buffer.len(v))
		return copy
	elseif t == "table" and getmetatable(v) ~= InstanceMT and getmetatable(v) ~= CFrameMT then
		local copy = {}
		for k, item in v do
			copy[k] = snapshot(item)
		end
		return copy
	end
	return v
end

local function mapArg(v: any, map): any
	if type(v) == "table" then
		if getmetatable(v) == InstanceMT then
			return map(v)
		elseif getmetatable(v) == CFrameMT then
			return v
		end
		local copy = {}
		for k, item in v do
			copy[k] = mapArg(item, map)
		end
		return copy
	end
	return v
end

--------------------------------------------------------------------------------
-- Modules
--------------------------------------------------------------------------------

local HEADER = "local game, workspace, Instance, task, warn, typeof, _G, shared, script, require = ...\n"

local function injectHeader(src: string): string
	local pos = 1
	while string.sub(src, pos, pos + 2) == "--!" do
		local nl = string.find(src, "\n", pos, true)
		if nl == nil then
			return src .. "\n" .. HEADER
		end
		pos = nl + 1
	end
	return string.sub(src, 1, pos - 1) .. HEADER .. string.sub(src, pos)
end

local chunkCache = {}

function Mock.compileFile(path: string)
	local chunk = chunkCache[path]
	if chunk then
		return chunk
	end
	local src = readfile(path) or error(`cannot read module {path}`)
	local fn, err = loadstring(injectHeader(src), "@" .. path)
	if not fn then
		error(`failed to compile {path}: {err}`)
	end
	chunkCache[path] = fn
	return fn
end

local function fileExists(path: string): boolean
	return readfile(path) ~= nil
end

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------

local World = {}
World.__index = World

local Env = {}
Env.__index = Env

function Mock.newWorld(opts: any?)
	opts = opts or {}
	local self = setmetatable({}, World)
	self.task = newTaskLib()
	self.now = opts.start or 1000
	self.players = {}
	self.clients = {}
	self.clientByPlayer = {}
	self.inflight = {} -- messages on the wire
	self.seq = 0
	self.latency = opts.latency or 0.03 -- one-way seconds
	self.jitter = opts.jitter or 0 -- extra uniform [0, jitter] one-way
	self.loss = opts.loss or 0 -- unreliable drop probability
	self.rng = Random and Random.new(opts.seed or 1) or nil
	self.randomSeed = opts.seed or 1
	math.randomseed(self.randomSeed)
	self.stats = { s2cCalls = 0, s2cBytes = 0, c2sCalls = 0, c2sBytes = 0, dropped = 0, oversize = 0 }
	self.warnings = {}
	self.streamedOut = {} -- [clientIndex] = { [serverInstance] = true }
	self.sharedTables = {} -- SharedTableRegistry of the server's VMs
	self.server = self:_newEnv(true, nil)
	return self
end

function World:_newEnv(isServer: boolean, clientIndex: number?)
	local world = self
	local env = setmetatable({
		world = world,
		isServer = isServer,
		index = clientIndex,
		G = {},
		shared = {},
		modules = {},
		loading = {},
		scripts = {},
		clockOffset = 0,
		animators = {},
	}, Env)

	local game = newInstance("DataModel", "Game")
	env.game = game
	rawset(game, "GetService", function(_self, name)
		local service = Instance.FindFirstChild(game, name)
		if service == nil then
			error(`mock game:GetService: unknown service "{name}"`)
		end
		return service
	end)
	local function service(className: string)
		local s = newInstance(className)
		s.Parent = game
		return s
	end

	local RunService = service("RunService")
	for _, name in { "Heartbeat", "PostSimulation", "Stepped", "PreSimulation", "RenderStepped", "PreRender", "PreAnimation" } do
		rawset(RunService, name, Signal.new())
	end
	rawset(RunService, "IsServer", function()
		return isServer
	end)
	rawset(RunService, "IsClient", function()
		return not isServer
	end)
	env.RunService = RunService

	local Players = service("Players")
	rawset(Players, "PlayerAdded", Signal.new())
	rawset(Players, "PlayerRemoving", Signal.new())
	rawset(Players, "GetPlayers", function()
		return table.clone(world.players)
	end)
	rawset(Players, "GetPlayerByUserId", function(_self, id)
		for _, p in world.players do
			if rawget(p, "UserId") == id then
				return p
			end
		end
		return nil
	end)
	env.Players = Players

	env.ReplicatedStorage = service("ReplicatedStorage")
	local Workspace = service("Workspace")
	Workspace.Name = "Workspace"
	env.Workspace = Workspace
	rawset(Workspace, "GetServerTimeNow", function()
		return world.now + env.clockOffset
	end)
	env.bulkMoves = 0
	rawset(Workspace, "BulkMoveTo", function(_self, parts, cframes, _mode)
		for i = 1, #parts do
			parts[i].CFrame = cframes[i]
		end
		env.bulkMoves += #parts
	end)
	local camera = newInstance("Camera")
	camera.Parent = Workspace
	rawset(Workspace, "CurrentCamera", camera)
	if isServer then
		env.ServerStorage = service("ServerStorage")
	end
	-- every server env (VM) of a world shares one registry; each client has its own
	local tables = if isServer then world.sharedTables else {}
	local Registry = service("SharedTableRegistry")
	rawset(Registry, "GetSharedTable", function(_self, name)
		local st = tables[name]
		if st == nil then
			st = SharedTableLib.new()
			tables[name] = st
		end
		return st
	end)
	rawset(Registry, "SetSharedTable", function(_self, name, st)
		tables[name] = st
	end)

	env.InstanceLib = {
		new = function(className: string, parent)
			local inst
			if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
				if not isServer then
					error(`mock: creating a {className} on the client is not supported`)
				end
				inst = world:_newServerRemote(className)
			else
				inst = newInstance(className)
				if className == "Animator" then
					Mock.makeAnimator(inst, env, isServer)
				end
			end
			if parent then
				inst.Parent = parent
			end
			return inst
		end,
	}
	env.warn = function(...)
		local parts = table.pack(...)
		for i = 1, parts.n do
			parts[i] = tostring(parts[i])
		end
		table.insert(world.warnings, table.concat(parts, " ", 1, parts.n))
	end
	return env
end

function Env:_makeRequire(path: string?)
	return function(target)
		local file = type(target) == "table" and rawget(target, "_path")
		if not file and type(target) == "table" then
			local server = rawget(target, "_server")
			file = server and rawget(server, "_path")
		end
		if not file then
			error(`require: {tostring(target)} is not a ModuleScript backed by a file`)
		end
		return self:requireFile(file, target)
	end
end

function Env:requireFile(path: string, scriptInst)
	local cached = self.modules[path]
	if cached ~= nil then
		return cached
	end
	if self.loading[path] then
		error(`cyclic require of {path}`)
	end
	self.loading[path] = true
	if scriptInst == nil then
		scriptInst = self.scripts[path] or newInstance("ModuleScript", string.match(path, "([^/]+)%.luau?$"))
		rawset(scriptInst, "_path", path)
	end
	self.scripts[path] = scriptInst
	local chunk = Mock.compileFile(path)
	local result = chunk(
		self.game,
		self.Workspace,
		self.InstanceLib,
		self.world.task,
		self.warn,
		robloxTypeof,
		self.G,
		self.shared,
		scriptInst,
		self:_makeRequire(path)
	)
	self.loading[path] = nil
	self.modules[path] = result
	return result
end

-- Mounts a Rojo-layout directory as ModuleScript/Folder instances.
function Env:mountTree(diskPath: string, parent, name: string?)
	local inst
	if listdir(diskPath) ~= nil then
		local init = nil
		for _, candidate in { "/init.luau", "/init.lua" } do
			if fileExists(diskPath .. candidate) then
				init = diskPath .. candidate
			end
		end
		inst = newInstance(if init then "ModuleScript" else "Folder", name or string.match(diskPath, "([^/]+)$"))
		if init then
			rawset(inst, "_path", init)
			self.scripts[init] = inst
		end
		for _, entry in listdir(diskPath) do
			if entry.dir or (string.match(entry.name, "%.luau?$") and not string.match(entry.name, "^init%.luau?$")) then
				self:mountTree(`{diskPath}/{entry.name}`, inst)
			end
		end
	else
		inst = newInstance("ModuleScript", name or string.match(diskPath, "([^/]+)%.luau?$"))
		rawset(inst, "_path", diskPath)
		self.scripts[diskPath] = inst
	end
	inst.Parent = parent
	return inst
end

-- Requires a ModuleScript instance (works on replicas too).
function Env:require(moduleScript)
	return self:_makeRequire(nil)(moduleScript)
end

function Env:now()
	return self.world.now + self.clockOffset
end

function Env:step(dt: number)
	local rs = self.RunService
	if not self.isServer then
		rs.PreRender:_fire(dt)
		rs.RenderStepped:_fire(dt)
	end
	rs.PreAnimation:_fire(dt)
	stepAnimators(self, dt)
	rs.PreSimulation:_fire(dt)
	rs.Stepped:_fire(0, dt)
	rs.PostSimulation:_fire(dt)
	rs.Heartbeat:_fire(dt)
	self.world.task._runDeferred()
end

--------------------------------------------------------------------------------
-- Remotes and network
--------------------------------------------------------------------------------

local ALL = newproxy()

function World:_send(remote, fromServer: boolean, target, ...)
	local n = select("#", ...)
	local args = table.create(n)
	for i = 1, n do
		args[i] = snapshot((select(i, ...)))
	end
	local unreliable = rawget(remote, "ClassName") == "UnreliableRemoteEvent"
	local bytes = 0
	for i = 1, n do
		bytes += wireSize(args[i])
	end
	if unreliable and bytes > 1000 then
		self.stats.oversize += 1
	end
	local targets = {}
	if fromServer then
		if target == ALL then
			for _, c in self.clients do
				table.insert(targets, c)
			end
		else
			table.insert(targets, self.clientByPlayer[target] or error("FireClient: unknown player"))
		end
	end
	local function schedule(client, player)
		local lat = self.latency
		if type(lat) == "table" then
			lat = lat[client.index] or lat[1]
		end
		local at = self.now + lat + math.random() * self.jitter
		if unreliable then
			if (fromServer and self.blockS2C) or (self.loss > 0 and math.random() < self.loss) then
				self.stats.dropped += 1
				return
			end
		else
			local key = if fromServer then "lastS2C" else "lastC2S"
			local last = client[key] or 0
			if at < last then
				at = last
			end
			client[key] = at
		end
		self.seq += 1
		table.insert(self.inflight, {
			at = at,
			seq = self.seq,
			remote = remote,
			fromServer = fromServer,
			client = client,
			player = player,
			args = args,
			n = n,
		})
		if fromServer then
			self.stats.s2cCalls += 1
			self.stats.s2cBytes += bytes
		else
			self.stats.c2sCalls += 1
			self.stats.c2sBytes += bytes
		end
	end
	if fromServer then
		for _, c in targets do
			schedule(c, nil)
		end
	else
		schedule(target, target.player)
	end
end

function World:_newServerRemote(className: string)
	local world = self
	local remote = newInstance(className)
	rawset(remote, "OnServerEvent", Signal.new())
	rawset(remote, "OnClientEvent", Signal.new())
	rawset(remote, "FireClient", function(_self, player, ...)
		world:_send(remote, true, player, ...)
	end)
	rawset(remote, "FireAllClients", function(_self, ...)
		world:_send(remote, true, ALL, ...)
	end)
	rawset(remote, "FireServer", function()
		error("FireServer can only be called from the client")
	end)
	return remote
end

-- Delivers every message due by world.now, in arrival order.
function World:pump()
	local due = {}
	local keep = {}
	for _, m in self.inflight do
		if m.at <= self.now then
			table.insert(due, m)
		else
			table.insert(keep, m)
		end
	end
	self.inflight = keep
	table.sort(due, function(a, b)
		if a.at == b.at then
			return a.seq < b.seq
		end
		return a.at < b.at
	end)
	for _, m in due do
		if m.fromServer then
			local client = m.client
			local endpoint = self:_replicaOf(client, m.remote)
			if endpoint ~= nil then
				local function map(inst)
					return self:_replicaOf(client, inst)
				end
				local args = table.create(m.n)
				for i = 1, m.n do
					args[i] = mapArg(m.args[i], map)
				end
				rawget(endpoint, "OnClientEvent"):_fire(table.unpack(args, 1, m.n))
			end
		else
			local function toServer(inst)
				return rawget(inst, "_server") or inst
			end
			local args = table.create(m.n)
			for i = 1, m.n do
				args[i] = mapArg(m.args[i], toServer)
			end
			rawget(m.remote, "OnServerEvent"):_fire(m.player, table.unpack(args, 1, m.n))
		end
	end
	self.task._runDeferred()
end

--------------------------------------------------------------------------------
-- Replication
--------------------------------------------------------------------------------

function World:_replicaOf(client, inst)
	if inst == nil then
		return nil
	end
	local replica = client.replicas[inst]
	if replica then
		if rawget(inst, "_parent") == nil and inst ~= self.server.ReplicatedStorage and inst ~= self.server.Workspace then
			return nil -- destroyed on the server
		end
		return replica
	end
	local cls = rawget(inst, "ClassName")
	if cls == "Player" then
		return inst
	elseif inst == self.server.ReplicatedStorage then
		return client.ReplicatedStorage
	elseif inst == self.server.Workspace then
		return client.Workspace
	end
	if cls == "Camera" then
		return nil -- cameras (and their children) do not replicate
	end
	local streamed = self.streamedOut[client.index]
	if streamed and streamed[inst] then
		return nil
	end
	local parentReplica = self:_replicaOf(client, rawget(inst, "_parent"))
	if parentReplica == nil then
		return nil
	end
	local world = self
	replica = setmetatable({
		ClassName = cls,
		Name = rawget(inst, "Name"),
		_children = {},
		_attributes = table.clone(rawget(inst, "_attributes")),
		_server = inst,
		_parent = parentReplica,
		_path = rawget(inst, "_path"),
		_map = function(v)
			return world:_replicaOf(client, v)
		end,
		_resolveChildren = function(r)
			return world:_replicaChildren(client, r)
		end,
	}, InstanceMT)
	if cls == "RemoteEvent" or cls == "UnreliableRemoteEvent" then
		rawset(replica, "OnClientEvent", Signal.new())
		rawset(replica, "OnServerEvent", Signal.new())
		rawset(replica, "FireServer", function(_self, ...)
			world:_send(inst, false, client, ...)
		end)
	end
	if cls == "Animator" then
		Mock.makeAnimator(replica, client, true)
	end
	client.replicas[inst] = replica
	return replica
end

function World:_replicaChildren(client, r)
	local server = rawget(r, "_server")
	local out = {}
	if server then
		for _, child in rawget(server, "_children") do
			local rep = self:_replicaOf(client, child)
			if rep and not rawget(rep, "_destroyed") then
				table.insert(out, rep)
			end
		end
	end
	for _, child in rawget(r, "_children") do
		table.insert(out, child)
	end
	return out
end

-- Client view of a server instance.
function World:replica(index: number, inst)
	return self:_replicaOf(self.clients[index], inst)
end

function World:streamOut(index: number, inst, out: boolean?)
	self.streamedOut[index] = self.streamedOut[index] or {}
	self.streamedOut[index][inst] = if out == false then nil else true
	if out == false then
		return
	end
	self.clients[index].replicas[inst] = nil
end

function World:addPlayer()
	local index = #self.players + 1
	local player = newInstance("Player", `Player{index}`)
	rawset(player, "UserId", 1000 + index)
	rawset(player, "CharacterAdded", Signal.new())
	rawset(player, "CharacterRemoving", Signal.new())
	player.Parent = self.server.Players
	table.insert(self.players, player)

	local client = self:_newEnv(false, index)
	client.player = player
	client.replicas = {}
	local world = self
	for _, name in { "ReplicatedStorage", "Workspace" } do
		local container = client[name]
		rawset(container, "_server", self.server[name])
		rawset(container, "_map", function(v)
			return world:_replicaOf(client, v)
		end)
		rawset(container, "_resolveChildren", function(r)
			return world:_replicaChildren(client, r)
		end)
	end
	-- the client's own camera stays local
	rawset(client.Workspace, "CurrentCamera", rawget(client.Workspace, "CurrentCamera"))
	rawset(client.Players, "LocalPlayer", player)
	self.clients[index] = client
	self.clientByPlayer[player] = client
	for _, fn in table.clone(self.server.Players.PlayerAdded._fns) do
		self.task.spawn(fn, player)
	end
	return player, client
end

function World:removePlayer(player)
	local character = rawget(player, "Character")
	if character then
		player.CharacterRemoving:_fire(character)
		Instance.Destroy(character)
	end
	for _, fn in table.clone(self.server.Players.PlayerRemoving._fns) do
		self.task.spawn(fn, player)
	end
	local i = table.find(self.players, player)
	if i then
		table.remove(self.players, i)
	end
	player.Parent = nil
end

-- Server-side character: Model with a HumanoidRootPart primary part.
function World:spawnCharacter(player, cf)
	local model = newInstance("Model", rawget(player, "Name"))
	local hrp = newInstance("Part", "HumanoidRootPart")
	hrp.CFrame = cf or CFrameLib.new(0, 3, 0)
	hrp.Parent = model
	rawset(model, "PrimaryPart", hrp)
	local humanoid = newInstance("Humanoid")
	local enabled = {}
	rawset(humanoid, "GetStateEnabled", function(_self, state)
		return enabled[state] ~= false
	end)
	rawset(humanoid, "SetStateEnabled", function(_self, state, on)
		enabled[state] = on
	end)
	humanoid.Parent = model
	Mock.makeAnimator(newInstance("Animator"), self.server, true).Parent = humanoid
	model.Parent = self.server.Workspace
	rawset(player, "Character", model)
	player.CharacterAdded:_fire(model)
	self.task._runDeferred()
	return model
end

-- Server-side NPC/bot model.
function World:spawnModel(name: string, cf, anchored: boolean?)
	local model = newInstance("Model", name)
	local root = newInstance("Part", "HumanoidRootPart")
	root.CFrame = cf or CFrameLib.new()
	root.Anchored = anchored == true
	root.Parent = model
	rawset(model, "PrimaryPart", root)
	model.Parent = self.server.Workspace
	return model
end

-- Gives a server model a Humanoid (or `controller` class) with a server-created Animator.
function World:addAnimator(model, controller: string?)
	local holder = newInstance(controller or "Humanoid")
	holder.Parent = model
	local animator = Mock.makeAnimator(newInstance("Animator"), self.server, true)
	animator.Parent = holder
	return animator, holder
end

-- A server Animation instance (Length / Looped as attributes).
function World:animation(id: string, name: string?, length: number?, looped: boolean?, parent: any?)
	local anim = newInstance("Animation", name or "Animation")
	rawset(anim, "AnimationId", id)
	if length ~= nil then
		Instance.SetAttribute(anim, "Length", length)
	end
	if looped ~= nil then
		Instance.SetAttribute(anim, "Looped", looped)
	end
	if parent ~= nil then
		anim.Parent = parent
	end
	return anim
end

-- Welds (server): Part1 follows Part0 * C0 * C1^-1.
function World:solveWelds()
	for _, d in Instance.GetDescendants(self.server.Workspace) do
		if rawget(d, "ClassName") == "Weld" then
			local p0, p1 = rawget(d, "Part0"), rawget(d, "Part1")
			if p0 and p1 then
				setQuiet(p1, "CFrame", mul(mul(p0.CFrame, rawget(d, "C0")), inverse(rawget(d, "C1"))))
			end
		end
	end
end

-- One frame for everyone: advance the clock, deliver due messages, run the server
-- then each client.
function World:frame(dt: number)
	self.now += dt
	self:pump()
	self.server:step(dt)
	self:solveWelds()
	for i, client in self.clients do
		if not client.paused then
			client:step(dt)
		end
		local _ = i
	end
end

return Mock
