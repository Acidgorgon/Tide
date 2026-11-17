--!optimize 2
-- Roblox mock for replication libraries: one server and N clients in one Luau VM, a virtual
-- clock, and a simulated network with per-link latency, jitter and drops.
--
-- Based on Ripple's bench mock (module injection, mountTree, JSON), restructured for
-- time-based replication:
--
--   Time      NOW is the true simulation time. Every machine has its own os.clock
--             (NOW + clockOffset, os.clock is replaced before any library is loaded),
--             workspace:GetServerTimeNow() (SERVER_EPOCH + NOW + syncError) and a frame rate
--             (server 60 Hz, clients 144 fps). Within one machine frame the clock is constant.
--   Instances Eagerly replicated: a server instance parented under Workspace, ReplicatedStorage
--             or Players gets a replica on every client at once (Camera subtrees never
--             replicate). Replicas read unset properties through to the server instance, so a
--             server-side property write is visible to clients immediately (no latency); the
--             observed properties (Parent, Name, CFrame, Position, PrimaryPart, Character,
--             Part0/Part1) go through setters that fire GetPropertyChangedSignal.
--             Welds are inert (no assembly movement); no physics.
--   Remotes   Fire* only queues (buffers are snapshotted at the call, like Roblox serialises at
--             fire time). After the machine's frame the queued calls become packets on the
--             link: arguments are deep-copied, bytes are estimated (payload + 12 B per call),
--             arrival = send + one-way latency + uniform(0, jitter), kept FIFO per link,
--             unreliable calls may be dropped (dropRate) and are dropped above 1000 B like
--             Roblox. A packet is handled at the receiver's first frame at or after arrival.
--             Events that arrive before any listener is connected are queued (like Roblox).
--   Signals   RunService and remote handlers run directly on the calling thread; engine
--             events (PlayerAdded, CharacterAdded, ...) run in new threads (task.spawn).
--   task      spawn/defer/delay/wait run on the virtual clock of the machine that scheduled
--             them (delayed threads resume after that machine's Heartbeat).

local Mock = {}

local R -- Roblox value types (lib/roblox.luau), set by Mock.init

--------------------------------------------------------------------------------
-- Clock
--------------------------------------------------------------------------------

local NOW = 0 -- true simulation time (s)
local CLOCK = 0 -- os.clock() of the current machine
local CUR = nil -- current machine
local SERVER_EPOCH = 1763000000

local function vclock()
	return CLOCK
end
Mock.vclock = vclock

local function setCurrent(env)
	CUR = env
	CLOCK = NOW + env.clockOffset
end
Mock.setCurrent = setCurrent

function Mock.setNow(t: number)
	NOW = t
	if CUR then
		CLOCK = NOW + CUR.clockOffset
	end
end

function Mock.now(): number
	return NOW
end

function Mock.current()
	return CUR
end

Mock.SERVER_EPOCH = SERVER_EPOCH

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------

local Connection = {}
Connection.__index = Connection
Connection.__robloxtype = "RBXScriptConnection"

function Connection:Disconnect()
	if self.Connected then
		self.Connected = false
		self._signal._dirty = true
	end
end

local Signal = {}
Signal.__index = Signal
Signal.__robloxtype = "RBXScriptSignal"

function Signal.new()
	return setmetatable({ _conns = {} }, Signal)
end
Mock.Signal = Signal

local TaskLib -- forward

local function compact(self)
	local conns = self._conns
	local j = 0
	local n = #conns
	for i = 1, n do
		local c = conns[i]
		if c.Connected then
			j += 1
			conns[j] = c
		end
	end
	for i = j + 1, n do
		conns[i] = nil
	end
	self._dirty = false
end

function Signal:Connect(fn)
	if self._dirty then
		compact(self)
	end
	local c = setmetatable({ Connected = true, _fn = fn, _signal = self }, Connection)
	table.insert(self._conns, c)
	local queued = self._queued
	if queued then
		-- Roblox delivers remote events queued before the first listener once one connects.
		self._queued = nil
		for _, args in queued do
			TaskLib.defer(fn, table.unpack(args, 1, args.n))
		end
	end
	return c
end
Signal.ConnectParallel = Signal.Connect

function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end

function Signal:Wait()
	local co = coroutine.running()
	if not coroutine.isyieldable() then
		error("Signal:Wait() outside a yieldable thread (mock)")
	end
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		TaskLib.spawn(co, ...)
	end)
	return coroutine.yield()
end

function Signal:_hasListeners(): boolean
	for _, c in self._conns do
		if c.Connected then
			return true
		end
	end
	return false
end

-- Runs handlers on the calling thread.
function Signal:_fire(...)
	local conns = self._conns
	local n = #conns
	if n == 1 then
		local c = conns[1]
		if c.Connected then
			c._fn(...)
		end
	else
		for i = 1, n do
			local c = conns[i]
			if c.Connected then
				c._fn(...)
			end
		end
	end
	if self._dirty then
		compact(self)
	end
end

-- Runs each handler in a new thread (engine events).
function Signal:_fireSpawn(...)
	local conns = self._conns
	local n = #conns
	for i = 1, n do
		local c = conns[i]
		if c.Connected then
			TaskLib.spawn(c._fn, ...)
		end
	end
	if self._dirty then
		compact(self)
	end
end

-- Remote delivery: queue when nobody listens yet.
function Signal:_fireRemote(...)
	if self._dirty then
		compact(self)
	end
	if #self._conns == 0 then
		local q = self._queued
		if q == nil then
			q = {}
			self._queued = q
		end
		table.insert(q, table.pack(...))
		return
	end
	self:_fire(...)
end

function Signal:DisconnectAll()
	for _, c in self._conns do
		c.Connected = false
	end
	table.clear(self._conns)
end

--------------------------------------------------------------------------------
-- task library (machine-aware, virtual time)
--------------------------------------------------------------------------------

local deferred = {} -- { {env, co, n, ...args} }
local timers = {} -- { {env, wake, co, n, ...args} }
local cancelled = setmetatable({}, { __mode = "k" })

local function resume(co, ...)
	if cancelled[co] or coroutine.status(co) ~= "suspended" then
		return
	end
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(debug.traceback(co, tostring(err)), 0)
	end
end

TaskLib = {}

function TaskLib.spawn(fnOrThread, ...)
	local co = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	resume(co, ...)
	return co
end

function TaskLib.defer(fnOrThread, ...)
	local co = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	table.insert(deferred, { CUR, co, select("#", ...), ... })
	return co
end

function TaskLib.delay(seconds, fnOrThread, ...)
	local co = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	table.insert(timers, { CUR, NOW + (seconds or 0), co, select("#", ...), ... })
	return co
end

function TaskLib.wait(seconds)
	if not coroutine.isyieldable() then
		error("task.wait outside a yieldable thread (the mock runs frames on the main thread)", 2)
	end
	local start = NOW
	table.insert(timers, { CUR, NOW + (seconds or 0), coroutine.running(), 0 })
	coroutine.yield()
	return NOW - start
end

function TaskLib.cancel(co)
	cancelled[co] = true
	pcall(coroutine.close, co)
end

function TaskLib.synchronize() end
function TaskLib.desynchronize() end

Mock.task = TaskLib

function Mock.runDeferred()
	local i = 1
	while i <= #deferred do
		local rec = deferred[i]
		deferred[i] = false
		local prev = CUR
		if rec[1] then
			setCurrent(rec[1])
		end
		resume(rec[2], table.unpack(rec, 4, 3 + rec[3]))
		if prev then
			setCurrent(prev)
		end
		i += 1
	end
	table.clear(deferred)
end

-- Resumes the threads env scheduled whose wake time has passed.
function Mock.runTimers(env)
	local n = #timers
	if n == 0 then
		return
	end
	local due = nil
	local j = 0
	for i = 1, n do
		local rec = timers[i]
		if rec[1] == env and rec[2] <= NOW then
			due = due or {}
			table.insert(due, rec)
		else
			j += 1
			timers[j] = rec
		end
	end
	for i = j + 1, n do
		timers[i] = nil
	end
	if due then
		for _, rec in due do
			resume(rec[3], table.unpack(rec, 5, 4 + rec[4]))
		end
		Mock.runDeferred()
	end
end

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
		if type(mt) == "table" then
			local rt = rawget(mt, "__robloxtype")
			if rt then
				return rt
			end
		end
	end
	return t
end
Mock.typeof = robloxTypeof

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

local Methods = {}
local GETTERS = {}
local SETTERS = {}
local InstanceMT = { __robloxtype = "Instance" }

local SIGNALS = {
	Changed = true,
	AttributeChanged = true,
	ChildAdded = true,
	ChildRemoved = true,
	DescendantAdded = true,
	DescendantRemoving = true,
	AncestryChanged = true,
	Destroying = true,
	CharacterAdded = true,
	CharacterRemoving = true,
	CharacterAppearanceLoaded = true,
	Died = true,
	StateChanged = true,
	StateEnabledChanged = true,
	HealthChanged = true,
	Running = true,
	Jumping = true,
	OnServerEvent = true,
	OnClientEvent = true,
	Event = true,
	Touched = true,
	TouchEnded = true,
	Chatted = true,
	Idled = true,
	MoveToFinished = true,
}

local IS_A = {
	Part = { BasePart = true, PVInstance = true },
	MeshPart = { BasePart = true, PVInstance = true },
	WedgePart = { BasePart = true, PVInstance = true },
	TrussPart = { BasePart = true, PVInstance = true },
	SpawnLocation = { BasePart = true, Part = true, PVInstance = true },
	Model = { PVInstance = true },
	Workspace = { Model = true, PVInstance = true, WorldRoot = true },
	RemoteEvent = { BaseRemoteEvent = true },
	UnreliableRemoteEvent = { BaseRemoteEvent = true },
	ModuleScript = { LuaSourceContainer = true },
	Script = { LuaSourceContainer = true, BaseScript = true },
	LocalScript = { LuaSourceContainer = true, BaseScript = true, Script = true },
	Weld = { JointInstance = true },
	Motor6D = { JointInstance = true, Motor = true },
	WeldConstraint = {},
	AlignPosition = { Constraint = true },
	AlignOrientation = { Constraint = true },
	Folder = {},
}

-- class defaults for properties never set
local DEFAULTS = {
	Part = { Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, Transparency = 0, Massless = false, Size = vector.create(4, 1, 2), AssemblyLinearVelocity = vector.zero, AssemblyAngularVelocity = vector.zero, Archivable = true, Locked = false, CollisionGroup = "Default", RootPriority = 0 },
	Model = { Archivable = true },
	Humanoid = { Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50, HipHeight = 2, AutoRotate = true, PlatformStand = false, Sit = false, MoveDirection = vector.zero },
	Camera = { FieldOfView = 70, CameraType = "Custom" },
	Weld = { Enabled = true },
	Motor6D = { Enabled = true },
	ModuleScript = { Archivable = true },
	Player = { AccountAge = 100, MembershipType = "None", Team = nil },
}
DEFAULTS.MeshPart = DEFAULTS.Part
DEFAULTS.WedgePart = DEFAULTS.Part

local function isInstance(v): boolean
	return type(v) == "table" and getmetatable(v) == InstanceMT
end
Mock.isInstance = isInstance

-- The instance `inst` as seen on machine env (server instance <-> client replica).
local function mapTo(inst, env)
	if inst == nil then
		return nil
	end
	local owner = rawget(inst, "_env")
	if owner == env then
		return inst
	end
	local server = rawget(inst, "_server") or (if owner and owner.isServer then inst else nil)
	if server == nil then
		return nil -- another client's local instance
	end
	if env.isServer then
		return server
	end
	return env.replicas[server]
end
Mock.mapTo = mapTo

local function findChild(self, name)
	local children = rawget(self, "_children")
	for i = 1, #children do
		local c = children[i]
		if rawget(c, "_name") == name then
			return c
		end
	end
	return nil
end

function InstanceMT.__index(self, key)
	local g = GETTERS[key]
	if g then
		return g(self)
	end
	local m = Methods[key]
	if m then
		return m
	end
	if SIGNALS[key] then
		local s = Signal.new()
		rawset(self, key, s)
		return s
	end
	local server = rawget(self, "_server")
	if server ~= nil and type(key) == "string" and string.byte(key, 1) ~= 95 then
		local v = rawget(server, key)
		if v ~= nil and type(v) ~= "function" then
			if isInstance(v) then
				return mapTo(v, rawget(self, "_env"))
			elseif getmetatable(v) == Signal then
				-- signals are per machine
			else
				return v
			end
		end
	end
	local child = findChild(self, key)
	if child then
		return child
	end
	local defaults = DEFAULTS[rawget(self, "ClassName")]
	if defaults then
		return defaults[key]
	end
	return nil
end

function InstanceMT.__newindex(self, key, value)
	local s = SETTERS[key]
	if s then
		s(self, value)
		return
	end
	rawset(self, key, value)
end

function InstanceMT.__tostring(self)
	return rawget(self, "_name")
end

local function propSignalFire(self, prop)
	local ps = rawget(self, "_propSignals")
	if ps then
		local s = ps[prop]
		if s then
			s:_fire()
		end
	end
	local changed = rawget(self, "Changed")
	if changed then
		changed:_fire(prop)
	end
end

-- Parent / replication ---------------------------------------------------------

local replicateTree -- forward (World)
local unreplicateTree

local function computeReplicated(inst, parent): boolean
	if parent == nil then
		return false
	end
	if rawget(inst, "ClassName") == "Camera" then
		return false
	end
	return rawget(parent, "_rep") == true
end

local function setRepFlag(inst, rep)
	rawset(inst, "_rep", rep or nil)
	for _, child in rawget(inst, "_children") do
		setRepFlag(child, rep and rawget(child, "ClassName") ~= "Camera")
	end
end

local function fireDescendantAdded(parent, inst)
	local p = parent
	while p ~= nil do
		local s = rawget(p, "DescendantAdded")
		if s then
			s:_fire(inst)
		end
		p = rawget(p, "_parent")
	end
end

local function setParent(self, value)
	if rawget(self, "_locked") then
		error(`The Parent property of {rawget(self, "_name")} is locked`, 3)
	end
	local old = rawget(self, "_parent")
	if old == value then
		return
	end
	if value ~= nil and not isInstance(value) then
		error(`cannot parent {rawget(self, "_name")} to a {robloxTypeof(value)}`, 3)
	end
	if old ~= nil then
		local siblings = rawget(old, "_children")
		local index = table.find(siblings, self)
		if index then
			table.remove(siblings, index)
		end
		local s = rawget(old, "ChildRemoved")
		if s then
			s:_fire(self)
		end
	end
	rawset(self, "_parent", value)
	if value ~= nil then
		table.insert(rawget(value, "_children"), self)
	end
	-- replication (server instances only)
	local env = rawget(self, "_env")
	if env and env.isServer then
		local wasRep = rawget(self, "_rep") == true
		local nowRep = computeReplicated(self, value)
		if nowRep ~= wasRep then
			setRepFlag(self, nowRep)
		end
		if nowRep then
			replicateTree(self, value)
		elseif wasRep then
			unreplicateTree(self)
		end
	end
	propSignalFire(self, "Parent")
	local anc = rawget(self, "AncestryChanged")
	if anc then
		anc:_fire(self, value)
	end
	if value ~= nil then
		local s = rawget(value, "ChildAdded")
		if s then
			s:_fire(self)
		end
		fireDescendantAdded(value, self)
	end
end

GETTERS.Parent = function(self)
	return rawget(self, "_parent")
end
SETTERS.Parent = setParent

GETTERS.Name = function(self)
	return rawget(self, "_name")
end
SETTERS.Name = function(self, value)
	value = tostring(value)
	rawset(self, "_name", value)
	local reps = rawget(self, "_replicas")
	if reps then
		for _, r in reps do
			rawset(r, "_name", value)
		end
	end
	propSignalFire(self, "Name")
end

-- CFrame ----------------------------------------------------------------------

local IDENTITY -- set in init

local function getCF(self)
	local cf = rawget(self, "_cf")
	if cf then
		return cf
	end
	local server = rawget(self, "_server")
	if server then
		cf = rawget(server, "_cf")
		if cf then
			return cf
		end
	end
	return IDENTITY
end

GETTERS.CFrame = getCF
SETTERS.CFrame = function(self, cf)
	if type(cf) ~= "table" or getmetatable(cf) ~= R.CFMT then
		error(`CFrame expected, got {robloxTypeof(cf)}`, 3)
	end
	rawset(self, "_cf", cf)
	local env = rawget(self, "_env")
	if env then
		env.stats.cframeWrites += 1
	end
	propSignalFire(self, "CFrame")
end
GETTERS.Position = function(self)
	local cf = getCF(self)
	return vector.create(cf[1], cf[2], cf[3])
end
SETTERS.Position = function(self, v)
	local cf = getCF(self)
	SETTERS.CFrame(self, R.mkCFrame(v.x, v.y, v.z, cf[4], cf[5], cf[6], cf[7], cf[8], cf[9], cf[10], cf[11], cf[12]))
end
GETTERS.Orientation = function(self)
	local rx, ry, rz = getCF(self):ToOrientation()
	return vector.create(math.deg(rx), math.deg(ry), math.deg(rz))
end
GETTERS.AssemblyRootPart = function(self)
	return self
end

-- Physics writes (character movement, physics replication): no Changed signals.
function Mock.physicsSetCFrame(part, cf)
	rawset(part, "_cf", cf)
end

-- References that must map across machines --------------------------------------

local function refGetter(field)
	return function(self)
		local v = rawget(self, field)
		if v ~= nil then
			return v
		end
		local server = rawget(self, "_server")
		if server then
			local sv = rawget(server, field)
			if sv ~= nil then
				return mapTo(sv, rawget(self, "_env"))
			end
		end
		return nil
	end
end
local function refSetter(field, prop)
	return function(self, value)
		rawset(self, field, value)
		propSignalFire(self, prop)
	end
end
GETTERS.PrimaryPart = refGetter("_primary")
SETTERS.PrimaryPart = refSetter("_primary", "PrimaryPart")
GETTERS.Character = refGetter("_character")
SETTERS.Character = refSetter("_character", "Character")
GETTERS.Part0 = refGetter("_part0")
SETTERS.Part0 = refSetter("_part0", "Part0")
GETTERS.Part1 = refGetter("_part1")
SETTERS.Part1 = refSetter("_part1", "Part1")
GETTERS.CameraSubject = refGetter("_subject")
SETTERS.CameraSubject = refSetter("_subject", "CameraSubject")

-- Methods ----------------------------------------------------------------------

function Methods.GetChildren(self)
	return table.clone(rawget(self, "_children"))
end

function Methods.FindFirstChild(self, name, recursive)
	local c = findChild(self, name)
	if c or not recursive then
		return c
	end
	for _, child in rawget(self, "_children") do
		local found = Methods.FindFirstChild(child, name, true)
		if found then
			return found
		end
	end
	return nil
end

local function isA(self, className): boolean
	local cls = rawget(self, "ClassName")
	if cls == className or className == "Instance" then
		return true
	end
	local set = IS_A[cls]
	return set ~= nil and set[className] == true
end
Methods.IsA = isA

function Methods.FindFirstChildOfClass(self, className)
	for _, child in rawget(self, "_children") do
		if rawget(child, "ClassName") == className then
			return child
		end
	end
	return nil
end

function Methods.FindFirstChildWhichIsA(self, className, recursive)
	for _, child in rawget(self, "_children") do
		if isA(child, className) then
			return child
		end
	end
	if recursive then
		for _, child in rawget(self, "_children") do
			local found = Methods.FindFirstChildWhichIsA(child, className, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function Methods.FindFirstAncestor(self, name)
	local p = rawget(self, "_parent")
	while p do
		if rawget(p, "_name") == name then
			return p
		end
		p = rawget(p, "_parent")
	end
	return nil
end

function Methods.FindFirstAncestorWhichIsA(self, className)
	local p = rawget(self, "_parent")
	while p do
		if isA(p, className) then
			return p
		end
		p = rawget(p, "_parent")
	end
	return nil
end
Methods.FindFirstAncestorOfClass = Methods.FindFirstAncestorWhichIsA

function Methods.WaitForChild(self, name, timeout)
	local child = findChild(self, name)
	if child then
		return child
	end
	if coroutine.isyieldable() then
		local deadline = NOW + (timeout or 30)
		while NOW < deadline do
			TaskLib.wait()
			child = findChild(self, name)
			if child then
				return child
			end
		end
		return nil
	end
	error(`WaitForChild("{name}") on {rawget(self, "_name")} would yield on the main thread (nothing created it yet)`, 2)
end

function Methods.GetDescendants(self)
	local out = {}
	local function walk(inst)
		for _, child in rawget(inst, "_children") do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function Methods.QueryDescendants(self, className)
	local out = {}
	for _, d in Methods.GetDescendants(self) do
		if isA(d, className) then
			table.insert(out, d)
		end
	end
	return out
end

function Methods.IsDescendantOf(self, ancestor): boolean
	local p = rawget(self, "_parent")
	while p ~= nil do
		if p == ancestor then
			return true
		end
		p = rawget(p, "_parent")
	end
	return false
end

function Methods.IsAncestorOf(self, descendant): boolean
	return Methods.IsDescendantOf(descendant, self)
end

function Methods.GetFullName(self): string
	local parts = {}
	local inst = self
	while inst ~= nil and rawget(inst, "ClassName") ~= "DataModel" do
		table.insert(parts, 1, rawget(inst, "_name"))
		inst = rawget(inst, "_parent")
	end
	return table.concat(parts, ".")
end

function Methods.Destroy(self)
	local s = rawget(self, "Destroying")
	if s then
		s:_fire()
	end
	for _, child in table.clone(rawget(self, "_children")) do
		Methods.Destroy(child)
	end
	if rawget(self, "_parent") ~= nil then
		setParent(self, nil)
	end
	rawset(self, "_locked", true)
	rawset(self, "_destroyed", true)
end

function Methods.ClearAllChildren(self)
	for _, child in table.clone(rawget(self, "_children")) do
		Methods.Destroy(child)
	end
end

function Methods.GetAttribute(self, name)
	local v = rawget(self, "_attributes")[name]
	if v == nil then
		local server = rawget(self, "_server")
		if server then
			v = rawget(server, "_attributes")[name]
		end
	end
	return v
end

local function attrFire(inst, name)
	local as = rawget(inst, "_attrSignals")
	if as and as[name] then
		as[name]:_fire()
	end
	local s = rawget(inst, "AttributeChanged")
	if s then
		s:_fire(name)
	end
end

function Methods.SetAttribute(self, name, value)
	rawget(self, "_attributes")[name] = value
	attrFire(self, name)
	local reps = rawget(self, "_replicas")
	if reps then
		for _, r in reps do
			if rawget(r, "_attributes")[name] == nil then
				attrFire(r, name)
			end
		end
	end
end

function Methods.GetAttributes(self)
	local out = {}
	local server = rawget(self, "_server")
	if server then
		for k, v in rawget(server, "_attributes") do
			out[k] = v
		end
	end
	for k, v in rawget(self, "_attributes") do
		out[k] = v
	end
	return out
end

function Methods.GetAttributeChangedSignal(self, name)
	local as = rawget(self, "_attrSignals")
	if not as then
		as = {}
		rawset(self, "_attrSignals", as)
	end
	local s = as[name]
	if not s then
		s = Signal.new()
		as[name] = s
	end
	return s
end

function Methods.GetPropertyChangedSignal(self, prop)
	local ps = rawget(self, "_propSignals")
	if not ps then
		ps = {}
		rawset(self, "_propSignals", ps)
	end
	local s = ps[prop]
	if not s then
		s = Signal.new()
		ps[prop] = s
	end
	return s
end

-- Tags (CollectionService) ------------------------------------------------------

local function envTagSignal(env, kind, tag)
	local map = env.tagSignals[kind]
	local s = map[tag]
	if not s then
		s = Signal.new()
		map[tag] = s
	end
	return s
end

local function registerTag(env, inst, tag)
	local set = env.tagged[tag]
	if not set then
		set = {}
		env.tagged[tag] = set
	end
	if set[inst] then
		return
	end
	set[inst] = true
	local s = env.tagSignals.added[tag]
	if s then
		s:_fire(inst)
	end
end

local function unregisterTag(env, inst, tag)
	local set = env.tagged[tag]
	if set and set[inst] then
		set[inst] = nil
		local s = env.tagSignals.removed[tag]
		if s then
			s:_fire(inst)
		end
	end
end

function Methods.AddTag(self, tag)
	local tags = rawget(self, "_tags")
	if not tags then
		tags = {}
		rawset(self, "_tags", tags)
	end
	if tags[tag] then
		return
	end
	tags[tag] = true
	local env = rawget(self, "_env")
	if env then
		registerTag(env, self, tag)
	end
	local reps = rawget(self, "_replicas")
	if reps then
		for client, r in reps do
			registerTag(client, r, tag)
		end
	end
end

function Methods.RemoveTag(self, tag)
	local tags = rawget(self, "_tags")
	if not tags or not tags[tag] then
		return
	end
	tags[tag] = nil
	local env = rawget(self, "_env")
	if env then
		unregisterTag(env, self, tag)
	end
	local reps = rawget(self, "_replicas")
	if reps then
		for client, r in reps do
			unregisterTag(client, r, tag)
		end
	end
end

local function tagsOf(self)
	local tags = rawget(self, "_tags")
	local server = rawget(self, "_server")
	if server then
		tags = rawget(server, "_tags") or tags
	end
	return tags
end

function Methods.HasTag(self, tag): boolean
	local tags = tagsOf(self)
	return tags ~= nil and tags[tag] == true
end

function Methods.GetTags(self)
	local out = {}
	for tag in tagsOf(self) or {} do
		table.insert(out, tag)
	end
	return out
end

-- PVInstance / parts -------------------------------------------------------------

function Methods.GetPivot(self)
	if rawget(self, "ClassName") == "Model" then
		local pp = GETTERS.PrimaryPart(self)
		if pp then
			return getCF(pp)
		end
		return rawget(self, "WorldPivot") or IDENTITY
	end
	return getCF(self)
end

local function moveParts(inst, delta)
	for _, child in rawget(inst, "_children") do
		if isA(child, "BasePart") then
			SETTERS.CFrame(child, delta * getCF(child))
		end
		moveParts(child, delta)
	end
end

function Methods.PivotTo(self, cf)
	if rawget(self, "ClassName") == "Model" then
		local pivot = Methods.GetPivot(self)
		local delta = cf * pivot:Inverse()
		moveParts(self, delta)
		rawset(self, "WorldPivot", cf)
	else
		SETTERS.CFrame(self, cf)
	end
end

function Methods.SetPrimaryPartCFrame(self, cf)
	Methods.PivotTo(self, cf)
end

function Methods.GetPrimaryPartCFrame(self)
	return Methods.GetPivot(self)
end

function Methods.GetBoundingBox(self)
	return Methods.GetPivot(self), vector.create(4, 5, 2)
end

function Methods.GetExtentsSize(self)
	return vector.create(4, 5, 2)
end

function Methods.SetNetworkOwner(self, player)
	rawset(self, "_networkOwner", player)
end
function Methods.GetNetworkOwner(self)
	return rawget(self, "_networkOwner")
end
function Methods.SetNetworkOwnershipAuto(self)
	rawset(self, "_networkOwner", nil)
end
function Methods.CanSetNetworkOwnership(self)
	return true, nil
end
function Methods.GetMass()
	return 1
end
function Methods.ApplyImpulse() end
function Methods.GetConnectedParts(self)
	return { self }
end
function Methods.BreakJoints() end

-- Humanoid -------------------------------------------------------------------------

function Methods.GetState(self)
	return rawget(self, "_state") or R.Enum.HumanoidStateType.Running
end
function Methods.ChangeState(self, state)
	local old = Methods.GetState(self)
	rawset(self, "_state", state)
	local s = rawget(self, "StateChanged")
	if s then
		s:_fire(old, state)
	end
end
function Methods.GetStateEnabled(self, state)
	local d = rawget(self, "_disabled")
	return not (d and d[state])
end
function Methods.SetStateEnabled(self, state, enabled)
	local d = rawget(self, "_disabled")
	if not d then
		d = {}
		rawset(self, "_disabled", d)
	end
	d[state] = not enabled or nil
	local s = rawget(self, "StateEnabledChanged")
	if s then
		s:_fire(state, enabled)
	end
end
function Methods.MoveTo() end
function Methods.Move() end
function Methods.GetPlayingAnimationTracks()
	return {}
end
function Methods.TakeDamage(self, amount)
	rawset(self, "Health", (rawget(self, "Health") or 100) - amount)
end

-- Player -------------------------------------------------------------------------

function Methods.GetNetworkPing(self)
	local server = rawget(self, "_server") or self
	local client = rawget(server, "_client")
	if not client then
		return 0
	end
	return client.link.c2s.base + client.link.s2c.base -- round trip, like Roblox
end
function Methods.Kick() end
function Methods.LoadCharacter() end
function Methods.GetMouse()
	return {}
end
function Methods.IsInGroup()
	return false
end
function Methods.GetRankInGroup()
	return 0
end

-- Clone ---------------------------------------------------------------------------

local newInstance -- forward

local function cloneInto(src, env)
	local copy = newInstance(env, rawget(src, "ClassName"), rawget(src, "_name"))
	for k, v in src do
		if k ~= "_children" and k ~= "_parent" and k ~= "_env" and k ~= "_server" and k ~= "_replicas" and k ~= "_rep" and k ~= "_name" and k ~= "ClassName" and k ~= "_propSignals" and k ~= "_attrSignals" and k ~= "_tags" and getmetatable(v) ~= Signal then
			if k == "_attributes" then
				rawset(copy, k, table.clone(v))
			else
				rawset(copy, k, v)
			end
		end
	end
	local map = { [src] = copy }
	for _, child in rawget(src, "_children") do
		local c = cloneInto(child, env)
		map[child] = c
		setParent(c, copy)
	end
	local pp = rawget(src, "_primary")
	if pp and map[pp] then
		rawset(copy, "_primary", map[pp])
	end
	return copy
end

function Methods.Clone(self)
	if rawget(self, "Archivable") == false then
		return nil
	end
	return cloneInto(self, rawget(self, "_env"))
end

--------------------------------------------------------------------------------
-- Wire size estimate and argument copying
--------------------------------------------------------------------------------

local CALL_OVERHEAD = 12

local function varintSize(n: number): number
	if n < 128 then
		return 1
	elseif n < 16384 then
		return 2
	end
	return 3
end

-- Rough estimate of Roblox's encoding of one remote argument, in bytes (Ripple's estimate plus
-- CFrame and other value types): 1 type byte plus payload.
local function wireSize(v: any): number
	local t = type(v)
	if t == "buffer" then
		local n = buffer.len(v)
		return 1 + varintSize(n) + n
	elseif t == "string" then
		return 1 + varintSize(#v) + #v
	elseif t == "number" then
		return 9
	elseif t == "vector" then
		return 13
	elseif t == "boolean" or t == "nil" then
		return 1
	elseif t == "table" then
		local mt = getmetatable(v)
		if mt == InstanceMT then
			return 5
		elseif mt == R.CFMT then
			return 19 -- position 3 x f32 + compact rotation
		elseif type(mt) == "table" and rawget(mt, "__robloxtype") then
			return 9
		end
		local n, size = 0, 0
		local arrayLen = #v
		for k, item in v do
			n += 1
			if not (type(k) == "number" and k >= 1 and k <= arrayLen) then
				size += wireSize(k)
			end
			size += wireSize(item)
		end
		return 1 + varintSize(n) + size
	end
	return 1
end
Mock.wireSize = wireSize

local function copyArg(v: any, env)
	local t = type(v)
	if t == "buffer" then
		local size = buffer.len(v)
		local copy = buffer.create(size)
		buffer.copy(copy, 0, v, 0, size)
		return copy
	elseif t == "table" then
		local mt = getmetatable(v)
		if mt == InstanceMT then
			return mapTo(v, env)
		elseif mt ~= nil then
			return v -- immutable value types (CFrame, EnumItem, ...)
		end
		local copy = {}
		for k, item in v do
			copy[copyArg(k, env)] = copyArg(item, env)
		end
		return copy
	end
	return v
end

-- Buffer snapshots taken at Fire* time (pooled by length, allocation-free in steady state).
local bufferPool = {}
local function snapshot(v)
	if type(v) ~= "buffer" then
		return v
	end
	local len = buffer.len(v)
	local free = bufferPool[len]
	local copy = if free then table.remove(free) else nil
	if copy == nil then
		copy = buffer.create(len)
	end
	buffer.copy(copy, 0, v, 0, len)
	return copy
end
local function releaseSnapshot(v)
	if type(v) == "buffer" then
		local len = buffer.len(v)
		local free = bufferPool[len]
		if free == nil then
			free = {}
			bufferPool[len] = free
		end
		table.insert(free, v)
	end
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local ALL = newproxy()
local TO_SERVER = newproxy()

-- Queues one Fire* call on env's outgoing list: flat {remote, target, n, args...}.
local function queueFire(env, remote, target, ...)
	local q = env.outgoing
	local pos = env.outgoingPos
	local n = select("#", ...)
	q[pos] = remote
	q[pos + 1] = target
	q[pos + 2] = n
	if n <= 3 then
		local a, b, c = ...
		q[pos + 3], q[pos + 4], q[pos + 5] = snapshot(a), snapshot(b), snapshot(c)
		env.outgoingPos = pos + 6
		return
	end
	for i = 1, n do
		q[pos + 2 + i] = snapshot((select(i, ...)))
	end
	env.outgoingPos = pos + 3 + n
end

local function isRemoteClass(cls)
	return cls == "RemoteEvent" or cls == "UnreliableRemoteEvent"
end

function Methods.FireServer(self, ...)
	local env = rawget(self, "_env")
	if env.isServer then
		error("FireServer can only be called from the client", 2)
	end
	local server = rawget(self, "_server")
	if not server then
		return -- a client-local remote goes nowhere
	end
	queueFire(env, server, TO_SERVER, ...)
end

function Methods.FireClient(self, player, ...)
	local env = rawget(self, "_env")
	if not env.isServer then
		error("FireClient can only be called from the server", 2)
	end
	if not isInstance(player) or rawget(player, "ClassName") ~= "Player" then
		error("FireClient: argument 1 must be a Player", 2)
	end
	queueFire(env, self, player, ...)
end

function Methods.FireAllClients(self, ...)
	local env = rawget(self, "_env")
	if not env.isServer then
		error("FireAllClients can only be called from the server", 2)
	end
	queueFire(env, self, ALL, ...)
end

function Methods.Fire(self, ...)
	-- BindableEvent
	local s = rawget(self, "Event")
	if s then
		s:_fire(...)
	end
end

--------------------------------------------------------------------------------
-- Instance construction
--------------------------------------------------------------------------------

function newInstance(env, className: string, name: string?)
	local inst = setmetatable({
		ClassName = className,
		_name = name or className,
		_children = {},
		_attributes = {},
		_env = env,
	}, InstanceMT)
	if env then
		env.stats.instancesCreated += 1
	end
	return inst
end
Mock.newInstance = newInstance

--------------------------------------------------------------------------------
-- HttpService JSON (from Ripple's mock)
--------------------------------------------------------------------------------

local function jsonEncode(v: any): string
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" or t == "number" then
		return tostring(v)
	elseif t == "string" then
		return '"' .. string.gsub(v, '[%c"\\]', function(c)
			return string.format("\\u%04x", string.byte(c))
		end) .. '"'
	elseif t == "table" then
		local parts = {}
		if next(v) == nil or #v > 0 then
			for i = 1, #v do
				parts[i] = jsonEncode(v[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, item in v do
			table.insert(parts, jsonEncode(tostring(k)) .. ":" .. jsonEncode(item))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error(`JSONEncode: cannot encode a {t}`)
end

local function jsonDecode(s: string): any
	local pos = 1
	local value
	local function skip()
		pos = string.find(s, "[^ \t\r\n]", pos) or #s + 1
	end
	function value()
		skip()
		local c = string.sub(s, pos, pos)
		if c == "{" or c == "[" then
			local out, isObject = {}, c == "{"
			pos += 1
			skip()
			if string.sub(s, pos, pos) == (if isObject then "}" else "]") then
				pos += 1
				return out
			end
			while true do
				if isObject then
					local k = value()
					skip()
					pos += 1
					out[k] = value()
				else
					table.insert(out, value())
				end
				skip()
				local sep = string.sub(s, pos, pos)
				pos += 1
				if sep ~= "," then
					return out
				end
			end
		elseif c == '"' then
			local stop = string.find(s, '"', pos + 1, true)
			local raw = string.sub(s, pos + 1, stop - 1)
			pos = stop + 1
			return raw
		elseif string.sub(s, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(s, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(s, pos, pos + 3) == "null" then
			pos += 4
			return nil
		end
		local num = string.match(s, "^-?[%d%.eE+-]+", pos)
		pos += #num
		return tonumber(num)
	end
	return value()
end

--------------------------------------------------------------------------------
-- Module compilation and instantiation (from Ripple's mock)
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

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

local function normalize(path: string): string
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return (if string.sub(path, 1, 1) == "/" then "/" else "") .. table.concat(parts, "/")
end

local function fileExists(path: string): boolean
	return readfile(path) ~= nil
end

local function resolveStringRequire(fromPath: string, name: string): string
	local base = dirname(fromPath)
	local rel = name
	if string.sub(name, 1, 6) == "@self/" then
		rel = string.sub(name, 7)
	elseif string.match(fromPath, "/init%.luau?$") then
		base = dirname(base)
	end
	local target = normalize(base .. "/" .. rel)
	for _, candidate in { target .. ".luau", target .. ".lua", target .. "/init.luau", target .. "/init.lua" } do
		if fileExists(candidate) then
			return candidate
		end
	end
	error(`require("{name}") from {fromPath}: no module at {target}`)
end

--------------------------------------------------------------------------------
-- Machines (environments)
--------------------------------------------------------------------------------

local World = {}
World.__index = World
local Env = {}
Env.__index = Env

local NIL_RESULT = newproxy()

local SERVICE_NAMES = {
	"RunService",
	"Players",
	"ReplicatedStorage",
	"Workspace",
	"HttpService",
	"CollectionService",
	"ReplicatedFirst",
	"StarterPlayer",
	"StarterGui",
	"Lighting",
	"TweenService",
	"UserInputService",
	"PhysicsService",
	"Debris",
	"Stats",
	"SoundService",
	"Teams",
	"TextChatService",
	"ContextActionService",
	"GuiService",
}

local function newStats()
	return { cframeWrites = 0, bulkMoveCalls = 0, bulkMoveParts = 0, instancesCreated = 0, warnings = 0 }
end

function World:_newEnv(isServer: boolean, index: number?)
	local world = self
	local env = setmetatable({
		world = world,
		isServer = isServer,
		index = index or 0,
		name = if isServer then "server" else `client{index}`,
		G = {},
		shared = {},
		modules = {},
		loading = {},
		scripts = {},
		replicas = {}, -- client: [server instance] = replica
		tagged = {},
		tagSignals = { added = {}, removed = {} },
		outgoing = table.create(4096),
		outgoingPos = 1,
		stats = newStats(),
		warnings = {},
		clockOffset = 0,
		syncError = 0,
	}, Env)

	local game = newInstance(env, "DataModel", "Game")
	env.game = game
	rawset(game, "PlaceId", 0)
	rawset(game, "JobId", "")
	rawset(game, "GetService", function(_self, name)
		local service = findChild(game, name)
		if service == nil then
			error(`mock game:GetService: unknown service "{name}"`)
		end
		return service
	end)
	rawset(game, "IsLoaded", function()
		return true
	end)
	game.Loaded = Signal.new()

	for _, name in SERVICE_NAMES do
		local s = newInstance(env, name)
		setParent(s, game)
		env[name] = s
	end
	local function addMethod(inst, name, fn)
		rawset(inst, name, fn)
	end

	local RunService = env.RunService
	for _, name in { "Heartbeat", "PostSimulation", "Stepped", "PreSimulation", "RenderStepped", "PreRender", "PreAnimation" } do
		rawset(RunService, name, Signal.new())
	end
	addMethod(RunService, "IsServer", function()
		return isServer
	end)
	addMethod(RunService, "IsClient", function()
		return not isServer
	end)
	addMethod(RunService, "IsRunning", function()
		return true
	end)
	addMethod(RunService, "IsStudio", function()
		return false
	end)
	addMethod(RunService, "IsRunMode", function()
		return false
	end)
	addMethod(RunService, "IsEdit", function()
		return false
	end)
	addMethod(RunService, "BindToRenderStep", function(_self, _name, _priority, fn)
		RunService.RenderStepped:Connect(fn)
	end)
	addMethod(RunService, "UnbindFromRenderStep", function() end)

	local Players = env.Players
	rawset(Players, "PlayerAdded", Signal.new())
	rawset(Players, "PlayerRemoving", Signal.new())
	addMethod(Players, "GetPlayers", function()
		local out = {}
		for _, p in world.players do
			local mine = mapTo(p, env)
			if mine then
				table.insert(out, mine)
			end
		end
		return out
	end)
	addMethod(Players, "GetPlayerByUserId", function(_self, id)
		for _, p in world.players do
			if rawget(p, "UserId") == id then
				return mapTo(p, env)
			end
		end
		return nil
	end)
	addMethod(Players, "GetPlayerFromCharacter", function(_self, model)
		for _, p in world.players do
			local mine = mapTo(p, env)
			if mine and GETTERS.Character(mine) == model then
				return mine
			end
		end
		return nil
	end)

	local Workspace = env.Workspace
	rawset(Workspace, "_rep", isServer or nil)
	if isServer then
		rawset(env.ReplicatedStorage, "_rep", true)
		rawset(Players, "_rep", true)
		rawset(env.ReplicatedFirst, "_rep", true)
		rawset(env.Lighting, "_rep", true)
	end
	addMethod(Workspace, "GetServerTimeNow", function()
		return SERVER_EPOCH + NOW + env.syncError
	end)
	addMethod(Workspace, "BulkMoveTo", function(_self, parts, cframes, _mode)
		local stats = env.stats
		stats.bulkMoveCalls += 1
		local n = #parts
		stats.bulkMoveParts += n
		for i = 1, n do
			local part = parts[i]
			rawset(part, "_cf", cframes[i])
			local ps = rawget(part, "_propSignals")
			if ps and ps.CFrame then
				ps.CFrame:_fire()
			end
		end
	end)
	addMethod(Workspace, "Raycast", function()
		return nil
	end)
	addMethod(Workspace, "GetPartBoundsInRadius", function()
		return {}
	end)
	addMethod(Workspace, "GetPartBoundsInBox", function()
		return {}
	end)
	rawset(Workspace, "Gravity", 196.2)
	local camera = newInstance(env, "Camera", "Camera")
	rawset(camera, "_cf", R.CFrame.new(0, 20, 0))
	rawset(camera, "ViewportSize", R.Vector2.new(1920, 1080))
	setParent(camera, Workspace)
	rawset(Workspace, "CurrentCamera", camera)

	local HttpService = env.HttpService
	addMethod(HttpService, "JSONEncode", function(_self, value)
		return jsonEncode(value)
	end)
	addMethod(HttpService, "JSONDecode", function(_self, text: string)
		return jsonDecode(text)
	end)
	local guid = 0
	addMethod(HttpService, "GenerateGUID", function(_self, braces)
		guid += 1
		local s = string.format("%08x-0000-4000-8000-%012x", env.index, guid)
		return if braces == false then s else "{" .. s .. "}"
	end)
	addMethod(HttpService, "GetAsync", function()
		error("HTTP requests are not enabled (mock)")
	end)

	local CollectionService = env.CollectionService
	addMethod(CollectionService, "GetInstanceAddedSignal", function(_self, tag)
		return envTagSignal(env, "added", tag)
	end)
	addMethod(CollectionService, "GetInstanceRemovedSignal", function(_self, tag)
		return envTagSignal(env, "removed", tag)
	end)
	addMethod(CollectionService, "GetTagged", function(_self, tag)
		local out = {}
		for inst in env.tagged[tag] or {} do
			table.insert(out, inst)
		end
		return out
	end)
	addMethod(CollectionService, "AddTag", function(_self, inst, tag)
		Methods.AddTag(inst, tag)
	end)
	addMethod(CollectionService, "RemoveTag", function(_self, inst, tag)
		Methods.RemoveTag(inst, tag)
	end)
	addMethod(CollectionService, "HasTag", function(_self, inst, tag)
		return Methods.HasTag(inst, tag)
	end)
	addMethod(CollectionService, "GetTags", function(_self, inst)
		return Methods.GetTags(inst)
	end)

	local PhysicsService = env.PhysicsService
	addMethod(PhysicsService, "IsCollisionGroupRegistered", function()
		return true
	end)
	addMethod(PhysicsService, "RegisterCollisionGroup", function() end)
	addMethod(PhysicsService, "CollisionGroupSetCollidable", function() end)
	addMethod(PhysicsService, "GetRegisteredCollisionGroups", function()
		return {}
	end)
	addMethod(env.Debris, "AddItem", function(_self, inst, t)
		TaskLib.delay(t or 10, function()
			Methods.Destroy(inst)
		end)
	end)

	if isServer then
		for _, name in { "ServerScriptService", "ServerStorage" } do
			local s = newInstance(env, name)
			setParent(s, game)
			env[name] = s
		end
	end

	env.InstanceLib = {
		new = function(className: string, parent)
			local inst = newInstance(env, className)
			if parent then
				setParent(inst, parent)
			end
			return inst
		end,
		fromExisting = function(inst)
			return Methods.Clone(inst)
		end,
	}
	env.warn = function(...)
		env.stats.warnings += 1
		world.stats.warnings += 1
		if #world.warnings < 30 then
			local parts = table.pack(...)
			for i = 1, parts.n do
				parts[i] = tostring(parts[i])
			end
			table.insert(world.warnings, env.name .. ": " .. table.concat(parts, " ", 1, parts.n))
		end
	end
	return env
end

-- The `require` handed to the module at `path`.
function Env:_makeRequire(path: string?)
	return function(target)
		if type(target) == "string" then
			assert(path, "string require from a module without a file path")
			local file = resolveStringRequire(path, target)
			return self:requireFile(file, self.scripts[file])
		end
		local file = type(target) == "table" and (rawget(target, "_path") or nil)
		if not file then
			error(`require: {tostring(target)} is not a ModuleScript backed by a file`, 2)
		end
		return self:requireFile(file, target)
	end
end

function Env:requireFile(path: string, scriptInst)
	local cached = self.modules[path]
	if cached ~= nil then
		return if cached == NIL_RESULT then nil else cached
	end
	if self.loading[path] then
		error(`cyclic require of {path}`)
	end
	self.loading[path] = true
	if scriptInst == nil then
		scriptInst = self.scripts[path] or newInstance(self, "ModuleScript", string.match(path, "([^/]+)%.luau?$"))
		rawset(scriptInst, "_path", path)
	end
	self.scripts[path] = scriptInst
	local chunk = Mock.compileFile(path)
	local prev = CUR
	setCurrent(self)
	local result = chunk(
		self.game,
		self.Workspace,
		self.InstanceLib,
		TaskLib,
		self.warn,
		robloxTypeof,
		self.G,
		self.shared,
		scriptInst,
		self:_makeRequire(path)
	)
	if prev then
		setCurrent(prev)
	end
	self.loading[path] = nil
	self.modules[path] = if result == nil then NIL_RESULT else result
	return result
end

function Env:require(moduleScript)
	return self:_makeRequire(nil)(moduleScript)
end

-- Mounts a library directory (Rojo layout) under `parent` as `name`. `*.model.json` files
-- ({"ClassName": ...}) become instances of that class (RemoteEvents etc.).
function Env:mountTree(diskPath: string, parent, name: string?)
	local inst
	if listdir(diskPath) ~= nil then
		local init, initModel = nil, nil
		for _, candidate in { "/init.luau", "/init.lua" } do
			if fileExists(diskPath .. candidate) then
				init = diskPath .. candidate
			end
		end
		if not init and fileExists(diskPath .. "/init.model.json") then
			initModel = jsonDecode(readfile(diskPath .. "/init.model.json"))
		end
		local cls = if init then "ModuleScript" elseif initModel then initModel.ClassName else "Folder"
		inst = self.InstanceLib.new(cls)
		rawset(inst, "_name", name or string.match(diskPath, "([^/]+)$"))
		if init then
			rawset(inst, "_path", init)
			self.scripts[init] = inst
		end
		for _, entry in listdir(diskPath) do
			local n = entry.name
			if entry.dir then
				self:mountTree(`{diskPath}/{n}`, inst)
			elseif string.match(n, "%.model%.json$") and n ~= "init.model.json" then
				local def = jsonDecode(readfile(`{diskPath}/{n}`))
				local child = self.InstanceLib.new(def.ClassName)
				rawset(child, "_name", string.match(n, "^(.*)%.model%.json$"))
				setParent(child, inst)
			elseif string.match(n, "%.luau?$") and not string.match(n, "^init%.luau?$") and not string.match(n, "%.server%.luau?$") and not string.match(n, "%.client%.luau?$") then
				self:mountTree(`{diskPath}/{n}`, inst)
			end
		end
	else
		inst = newInstance(self, "ModuleScript", name or string.match(diskPath, "([^/]+)%.luau?$"))
		rawset(inst, "_path", diskPath)
		self.scripts[diskPath] = inst
	end
	setParent(inst, parent)
	return inst
end

-- RunService step helpers --------------------------------------------------------

function Env:fire(signalName: string, ...)
	local s = rawget(self.RunService, signalName)
	if #s._conns > 0 then
		s:_fire(...)
	end
end

--------------------------------------------------------------------------------
-- Replication (server -> clients)
--------------------------------------------------------------------------------

local function makeReplica(client, inst)
	local replica = client.replicas[inst]
	if replica then
		return replica
	end
	replica = setmetatable({
		ClassName = rawget(inst, "ClassName"),
		_name = rawget(inst, "_name"),
		_children = {},
		_attributes = {},
		_server = inst,
		_env = client,
		_path = rawget(inst, "_path"),
	}, InstanceMT)
	client.replicas[inst] = replica
	local reps = rawget(inst, "_replicas")
	if not reps then
		reps = {}
		rawset(inst, "_replicas", reps)
	end
	reps[client] = replica
	return replica
end

-- Ensures the subtree rooted at server instance `inst` (now under replicated `parent`) exists on
-- every client, parented correctly.
function replicateTree(inst, parent)
	local world = rawget(inst, "_env").world
	for _, client in world.clients do
		local parentReplica = client.replicas[parent]
		if parentReplica then
			local isNew = client.replicas[inst] == nil
			local replica = makeReplica(client, inst)
			local function build(serverInst, rep)
				for _, child in rawget(serverInst, "_children") do
					if rawget(child, "_rep") then
						local childRep = makeReplica(client, child)
						if rawget(childRep, "_parent") ~= rep then
							setParent(childRep, rep)
						end
						build(child, childRep)
					end
				end
			end
			build(inst, replica)
			if rawget(replica, "_parent") ~= parentReplica then
				setParent(replica, parentReplica)
			end
			if isNew then
				world:_onReplicaAdded(client, inst, replica)
			end
		end
	end
end

function unreplicateTree(inst)
	local reps = rawget(inst, "_replicas")
	if not reps then
		return
	end
	for _, replica in reps do
		if rawget(replica, "_parent") ~= nil then
			setParent(replica, nil)
		end
	end
end

-- Client-side engine events for a newly replicated subtree: tags, PlayerAdded.
function World:_onReplicaAdded(client, serverInst, replica)
	local prev = CUR
	setCurrent(client)
	local function walk(si, r)
		local tags = rawget(si, "_tags")
		if tags then
			for tag in tags do
				registerTag(client, r, tag)
			end
		end
		if rawget(si, "ClassName") == "Player" and client.started then
			client.Players.PlayerAdded:_fireSpawn(r)
		end
		for _, child in rawget(si, "_children") do
			local cr = client.replicas[child]
			if cr then
				walk(child, cr)
			end
		end
	end
	walk(serverInst, replica)
	if prev then
		setCurrent(prev)
	end
end

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------

-- params: seed, jitter (s), dropRate, latency = function(i) -> one-way base (s),
-- clockOffset(i), syncError(i), clientPhase(i)
function Mock.newWorld(params)
	local self = setmetatable({}, World)
	self.params = params
	self.players = {} -- server Player objects in join order
	self.clients = {}
	self.clientByPlayer = {}
	self.stats = { warnings = 0, droppedUnreliable = 0, droppedOversize = 0 }
	self.warnings = {}
	self.measuring = false
	self.rng = R.Random.new((params.seed or 1) * 7919 + 13)
	self.server = self:_newEnv(true, 0)
	self.server.clockOffset = params.serverClockOffset or 1000
	setCurrent(self.server)
	return self
end

function World:_newLink(base)
	return { base = base, queue = {}, head = 1, tail = 0, last = 0, bytes = 0, calls = 0, payload = 0 }
end

-- Adds a player: server Player (PlayerAdded on the server), the client machine with replicas of
-- everything already replicated. Returns player, client env.
function World:addClient()
	local index = #self.clients + 1
	local params = self.params
	local server = self.server
	local player = newInstance(server, "Player", `Player{index}`)
	rawset(player, "UserId", 1000 + index)
	rawset(player, "DisplayName", `Player{index}`)
	local client = self:_newEnv(false, index)
	client.player = player
	client.clockOffset = params.clockOffset(index)
	client.syncError = params.syncError(index)
	local base = params.latency(index)
	client.link = { c2s = self:_newLink(base), s2c = self:_newLink(base) }
	rawset(player, "_client", client)
	self.clients[index] = client
	self.clientByPlayer[player] = client
	-- replicated containers map onto the client's own services
	for _, name in { "Workspace", "ReplicatedStorage", "Players", "ReplicatedFirst", "Lighting" } do
		client.replicas[server[name]] = client[name]
		rawset(client[name], "_server", server[name])
		local reps = rawget(server[name], "_replicas") or {}
		reps[client] = client[name]
		rawset(server[name], "_replicas", reps)
	end
	-- replicate everything that exists
	for _, name in { "Workspace", "ReplicatedStorage", "Players", "ReplicatedFirst", "Lighting" } do
		for _, child in rawget(server[name], "_children") do
			if rawget(child, "_rep") then
				replicateTree(child, server[name])
			end
		end
	end
	local playerGui = newInstance(server, "PlayerGui", "PlayerGui")
	setParent(player, server.Players)
	setParent(playerGui, player)
	table.insert(self.players, player)
	local replica = client.replicas[player]
	rawset(client.Players, "LocalPlayer", replica)
	client.started = true
	setCurrent(server)
	server.Players.PlayerAdded:_fireSpawn(player)
	for _, other in self.clients do
		if other ~= client and other.replicas[player] then
			setCurrent(other)
			-- (fired by _onReplicaAdded already for started clients)
		end
	end
	setCurrent(server)
	return player, client
end

-- Builds a character-like model on machine env: Model{HumanoidRootPart (PrimaryPart), Head,
-- Humanoid}, at cf.
function World:newCharacterModel(env, name: string, cf)
	local model = newInstance(env, "Model", name)
	local hrp = newInstance(env, "Part", "HumanoidRootPart")
	rawset(hrp, "Size", vector.create(2, 2, 1))
	rawset(hrp, "Transparency", 1)
	rawset(hrp, "CanCollide", false)
	rawset(hrp, "_cf", cf)
	local head = newInstance(env, "Part", "Head")
	rawset(head, "Size", vector.create(2, 1, 1))
	rawset(head, "_cf", cf * R.CFrame.new(0, 1.5, 0))
	local neck = newInstance(env, "Motor6D", "Neck")
	rawset(neck, "_part0", hrp)
	rawset(neck, "_part1", head)
	local humanoid = newInstance(env, "Humanoid", "Humanoid")
	rawset(humanoid, "RigType", R.Enum.HumanoidRigType.R15)
	setParent(hrp, model)
	setParent(head, model)
	setParent(neck, hrp)
	setParent(humanoid, model)
	rawset(model, "_primary", hrp)
	return model
end

-- Spawns `player`'s character on the server at cf and fires CharacterAdded on the server and
-- on every client (their replica of the player).
function World:spawnCharacter(player, cf)
	local server = self.server
	local model = self:newCharacterModel(server, rawget(player, "_name"), cf)
	setParent(model, server.Workspace)
	rawset(player, "_character", model)
	setCurrent(server)
	local s = rawget(player, "CharacterAdded")
	if s then
		s:_fireSpawn(model)
	end
	for _, client in self.clients do
		local rp = client.replicas[player]
		local rm = client.replicas[model]
		if rp and rm then
			setCurrent(client)
			local cs = rawget(rp, "CharacterAdded")
			if cs then
				cs:_fireSpawn(rm)
			end
		end
	end
	setCurrent(server)
	return model
end

-- Network ---------------------------------------------------------------------------

local function pushPacket(world, link, sendTime, unreliable, signal, player, n, args, bytes, payload)
	if unreliable then
		if payload > 1000 then
			world.stats.droppedOversize += 1
			return
		end
		local drop = world.params.dropRate or 0
		if drop > 0 and world.rng:NextNumber() < drop then
			world.stats.droppedUnreliable += 1
			return
		end
	end
	local jitter = world.params.jitter or 0
	local arrival = sendTime + link.base + (if jitter > 0 then jitter * world.rng:NextNumber() else 0)
	if arrival < link.last then
		arrival = link.last -- FIFO: a late packet holds back the ones behind it
	end
	link.last = arrival
	local tail = link.tail + 1
	link.tail = tail
	link.queue[tail] = { arrival, signal, player, n, args }
	if world.measuring then
		link.bytes += bytes
		link.calls += 1
		link.payload += payload
	end
end

-- Network phase for env (untimed): turns the calls env fired this frame into packets.
function World:flush(env)
	local q = env.outgoing
	local endPos = env.outgoingPos
	if endPos == 1 then
		return
	end
	local pos = 1
	local sendTime = NOW
	while pos < endPos do
		local remote, target, n = q[pos], q[pos + 1], q[pos + 2]
		local unreliable = rawget(remote, "ClassName") == "UnreliableRemoteEvent"
		local payload = 0
		for i = 1, n do
			payload += wireSize(q[pos + 2 + i])
		end
		local bytes = payload + CALL_OVERHEAD
		if target == TO_SERVER then
			local args = table.create(n)
			for i = 1, n do
				args[i] = copyArg(q[pos + 2 + i], self.server)
			end
			pushPacket(self, env.link.c2s, sendTime, unreliable, rawget(remote, "OnServerEvent") or remote.OnServerEvent, env.player, n, args, bytes, payload)
		else
			local function sendTo(client)
				local endpoint = client.replicas[remote]
				if endpoint == nil then
					return
				end
				local args = table.create(n)
				for i = 1, n do
					args[i] = copyArg(q[pos + 2 + i], client)
				end
				pushPacket(self, client.link.s2c, sendTime, unreliable, endpoint.OnClientEvent, false, n, args, bytes, payload)
			end
			if target == ALL then
				for _, client in self.clients do
					sendTo(client)
				end
			else
				local client = self.clientByPlayer[target]
				if client then
					sendTo(client)
				end
			end
		end
		local nextPos = pos + 3 + (if n < 3 then 3 else n)
		for i = pos, nextPos - 1 do
			releaseSnapshot(q[i])
			q[i] = nil
		end
		pos = nextPos
	end
	env.outgoingPos = 1
end

-- Collects the packets that have arrived at env by NOW into env.due (untimed). Returns count.
function World:collect(env)
	local due = env.due
	if not due then
		due = table.create(256)
		env.due = due
	end
	local n = 0
	local function drain(link)
		local queue = link.queue
		local head = link.head
		while head <= link.tail and queue[head][1] <= NOW do
			n += 1
			due[n] = queue[head]
			queue[head] = nil
			head += 1
		end
		link.head = head
	end
	if env.isServer then
		for _, client in self.clients do
			drain(client.link.c2s)
		end
		if n > 1 then
			table.sort(due, function(a, b)
				return a[1] < b[1]
			end)
		end
	else
		drain(env.link.s2c)
	end
	env.dueCount = n
	return n
end

-- Runs the handlers for the collected packets (the timed receive phase).
function World:dispatch(env)
	local due = env.due
	local n = env.dueCount or 0
	for i = 1, n do
		local p = due[i]
		due[i] = nil
		local signal, player, argc, args = p[2], p[3], p[4], p[5]
		if player then
			if argc == 1 then
				signal:_fireRemote(player, args[1])
			elseif argc == 2 then
				signal:_fireRemote(player, args[1], args[2])
			else
				signal:_fireRemote(player, table.unpack(args, 1, argc))
			end
		else
			if argc == 1 then
				signal:_fireRemote(args[1])
			elseif argc == 2 then
				signal:_fireRemote(args[1], args[2])
			elseif argc == 3 then
				signal:_fireRemote(args[1], args[2], args[3])
			else
				signal:_fireRemote(table.unpack(args, 1, argc))
			end
		end
	end
	env.dueCount = 0
end

function World:setMeasuring(on: boolean)
	self.measuring = on
	if on then
		for _, client in self.clients do
			for _, link in { client.link.c2s, client.link.s2c } do
				link.bytes, link.calls, link.payload = 0, 0, 0
			end
		end
		self.stats.droppedUnreliable = 0
		self.stats.droppedOversize = 0
	end
end

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

function Mock.init(types)
	R = types
	IDENTITY = R.CFrame.identity
end

-- Installs Roblox globals. Must run BEFORE any library chunk is loaded: with a safe environment
-- Luau resolves imports such as os.clock and debug.profilebegin when a chunk is loaded.
function Mock.installGlobals()
	__setvectormt(R.vectorMT)
	os.clock = vclock
	Vector3 = R.Vector3
	Vector2 = R.Vector2
	CFrame = R.CFrame
	Color3 = R.Color3
	Enum = R.Enum
	Random = R.Random
	PhysicalProperties = R.PhysicalProperties
	tick = function()
		return SERVER_EPOCH + NOW + (if CUR then CUR.syncError else 0)
	end
	time = function()
		return NOW
	end
	elapsedTime = time
	DateTime = {
		now = function()
			local t = SERVER_EPOCH + NOW
			return { UnixTimestamp = math.floor(t), UnixTimestampMillis = math.floor(t * 1000) }
		end,
	}
	wait = TaskLib.wait
	delay = TaskLib.delay
	spawn = TaskLib.spawn
	debug.profilebegin = function() end
	debug.profileend = function() end
	debug.setmemorycategory = function() end
	debug.resetmemorycategory = function() end
	NumberRange = { new = function(a, b)
		return { Min = a, Max = b or a }
	end }
	TweenInfo = { new = function(...)
		return { ... }
	end }
end

Mock.World = World
Mock.Env = Env
Mock.Methods = Methods
Mock.ALL = ALL

return Mock
