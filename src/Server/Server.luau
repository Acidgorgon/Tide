--!strict
-- Server side of Tide: entity registry, players, control channel, frame loop.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Codec = require(Shared.Codec)
local Kinds = require(Shared.Kinds)
local Ring = require(Shared.Ring)
local Interp = require(Shared.Interp)
local Rig = require(Shared.Rig)
local Control = require(Shared.Control)
local Signal = require(Shared.Signal)
local State = require(script.Parent.State)
local Receive = require(script.Parent.Receive)
local Relay = require(script.Parent.Relay)
local Ticker = require(script.Parent.Ticker)
local Lock = require(script.Parent.Lock)
local Motion = require(script.Parent.Motion)
local Options = require(Shared.Options)

local Server = {}

Server.addedSignal = Signal.new()
Server.removedSignal = Signal.new()

local remoteU: any = nil
local remoteR: any = nil
local frame = 0
local autoPlayers = false
local bcast = Control.writer(512)
local NOOP_DIST2 = 0.05 * 0.05 -- teleportOnWrite: writes this close to the held pose are no-ops
local NOOP_YAW = math.rad(1)
local NOOP_DOT = math.cos(math.rad(0.5)) -- quaternion dot for 1 degree

local function now(): number
	return workspace:GetServerTimeNow()
end

local watchRoot: (slot: number) -> ()

--------------------------------------------------------------------------------
-- Handles
--------------------------------------------------------------------------------

local Handle = {}
Handle.__index = Handle

export type Handle = typeof(setmetatable({} :: { slot: number, model: any }, Handle))

local function liveSlot(handle: any): number?
	local slot = handle.slot
	if State.handle[slot] == handle then
		return slot
	end
	return nil
end

function Handle.teleport(self: any, cf: CFrame, velocity: Vector3?)
	assert(typeof(cf) == "CFrame", "teleport: cf must be a CFrame")
	assert(velocity == nil or typeof(velocity) == "Vector3", "teleport: velocity must be a Vector3 or nil")
	local slot = liveSlot(self)
	if slot then
		Server.teleport(slot, cf, velocity)
	end
end

function Handle.remove(self: any)
	local slot = liveSlot(self)
	if slot then
		Server.remove(slot)
	end
end

function Handle.setOwner(self: any, player: any)
	local slot = liveSlot(self)
	if slot then
		Server.setOwner(slot, player)
	end
end

function Handle.alive(self: any): boolean
	return liveSlot(self) ~= nil
end

-- Slot of a model or handle (nil if not registered).
function Server.slotOf(target: any): number?
	if type(target) == "table" and getmetatable(target) == Handle then
		return liveSlot(target)
	end
	return State.bySlotModel[target]
end

--------------------------------------------------------------------------------
-- Control messages
--------------------------------------------------------------------------------

local function writeAdd(w: Control.Writer, slot: number)
	local owner = State.owner[slot]
	Control.u8(w, Control.ADD)
	Control.u16(w, slot)
	Control.u8(w, State.kind[slot].id)
	Control.u16(w, Control.inst(w, State.model[slot]))
	Control.f64(w, if owner then owner.UserId else 0)
end

local function writeHello(w: Control.Writer)
	local ox, oy, oz = Codec.getOrigin()
	Control.u8(w, Control.HELLO)
	Control.u8(w, Control.VERSION)
	Control.f64(w, ox)
	Control.f64(w, oy)
	Control.f64(w, oz)
	Control.u8(w, if Config.lockPlayers then 1 else 0)
	Control.u8(w, math.clamp(Config.UploadRedundancy, 1, 2))
	Control.u8(w, #Kinds.list)
	for _, kind in Kinds.list do
		Control.u8(w, kind.id)
		Control.str(w, kind.name)
		Control.f32(w, kind.rate)
		Control.u8(w, if kind.full then 1 else 0)
		Control.f32(w, kind.buffer)
		Control.f32(w, kind.extrapolate)
		Control.f32(w, kind.keepAlive)
		Control.f32(w, kind.maxSpeed)
		Control.f32(w, kind.maxRise)
		Control.f32(w, kind.maxFall)
	end
end

local function flushBroadcast()
	if bcast.pos == 0 then
		return
	end
	local b, insts = Control.takeAll(bcast)
	for _, rx in State.rxList do
		remoteR:FireClient(rx.player, b, insts)
	end
end

local function sendTo(player: any, w: Control.Writer)
	local b, insts = Control.takeAll(w)
	remoteR:FireClient(player, b, insts)
end

-- Called when a kind changes after start: resend the kinds table.
function Server.kindsChanged()
	if not State.started then
		return
	end
	writeHello(bcast)
end

local function onReady(player: any, rx: any)
	if rx.ready then
		return
	end
	local w = Control.writer(256)
	writeHello(w)
	for k = 1, State.count do
		writeAdd(w, State.active[k])
	end
	sendTo(player, w)
	rx.ready = true
	table.insert(State.rxList, rx)
	Relay.onReady(rx)
end

local function onResend(player: any, rx: any, b: buffer, pos: number): number
	local n = buffer.len(b)
	if pos + 1 > n then
		return n
	end
	local count = buffer.readu8(b, pos)
	pos += 1
	if pos + count * 2 > n or count > 64 then
		return n
	end
	local t = os.clock()
	if t - (rx.resendT or -1) < 0.5 then
		return pos + count * 2
	end
	rx.resendT = t
	local w = Control.writer(64)
	for i = 0, count - 1 do
		local slot = buffer.readu16(b, pos + i * 2)
		if State.index[slot] ~= nil then
			writeAdd(w, slot)
		end
	end
	if w.pos > 0 then
		sendTo(player, w)
	end
	return pos + count * 2
end

local function handleControl(player: any, payload: any)
	local rx = State.rx[player]
	if rx == nil or typeof(payload) ~= "buffer" then
		State.counters.badPacket += 1
		return
	end
	local b: buffer = payload
	local n = buffer.len(b)
	if n > 512 then
		State.counters.badPacket += 1
		return
	end
	local pos = 0
	while pos < n do
		local tag = buffer.readu8(b, pos)
		pos += 1
		if tag == Control.READY then
			onReady(player, rx)
		elseif tag == Control.RESEND then
			pos = onResend(player, rx, b, pos)
		else
			State.counters.badPacket += 1
			return
		end
	end
end

--------------------------------------------------------------------------------
-- Entities
--------------------------------------------------------------------------------

local function unwatch(slot: number)
	local conn = State.watch[slot]
	if conn ~= nil then
		conn:Disconnect()
		State.watch[slot] = nil
	end
end

-- teleportOnWrite: a server write to a client-owned root's CFrame (CFrame =,
-- PivotTo) becomes a teleport. Writes that land on the held pose (the lock's own
-- moves, `root.CFrame = root.CFrame`) are no-ops.
local function onRootWrite(slot: number, root: any)
	if Lock.writing or State.index[slot] == nil or State.root[slot] ~= root or not State.owner[slot] then
		return
	end
	local cf = root.CFrame
	local full = State.hist[slot].full
	local x, y, z, yaw, qx, qy, qz, qw = Rig.fromCFrame(cf, full)
	local h = State.hist[slot]
	local p = h.last % h.cap + 1
	local dx, dy, dz = x - h.x[p], y - h.y[p], z - h.z[p]
	if dx * dx + dy * dy + dz * dz < NOOP_DIST2 then
		if full then
			local dot = qx * h.qx[p] + qy * h.qy[p] + qz * h.qz[p] + qw * h.qw[p]
			if math.abs(dot) >= NOOP_DOT then
				return
			end
		elseif math.abs(Interp.wrapAngle(yaw - h.yaw[p])) < NOOP_YAW then
			return
		end
	end
	Server.teleport(slot, cf, if Config.teleportOnWriteVelocity == "zero" then Vector3.new(0, 0, 0) else nil)
end

watchRoot = function(slot: number)
	unwatch(slot)
	local root = State.root[slot]
	if not Config.teleportOnWrite or root == nil or not State.owner[slot] then
		return
	end
	State.watch[slot] = root:GetPropertyChangedSignal("CFrame"):Connect(function()
		onRootWrite(slot, root)
	end)
end

local function allocSlot(t: number): number
	local index = State.index
	local freedAt = State.freedAt
	local quarantine = Config.SlotQuarantine
	for s = 1, State.maxSlot do
		if index[s] == nil then
			local freed = freedAt[s]
			if freed == nil or t - freed >= quarantine then
				return s
			end
		end
	end
	local s = State.maxSlot + 1
	if s > 65535 then
		error("Tide: out of entity slots (65535)", 3)
	end
	State.maxSlot = s
	return s
end

function Server.add(model: any, kindName: string?, owner: any?): any
	assert(State.started, "Tide.add: call Tide.start() first")
	assert(typeof(model) == "Instance", "Tide.add: model must be an Instance")
	local kind = Kinds.byName[kindName or "Bot"]
	if kind == nil then
		error(`Tide.add: unknown kind "{tostring(kindName)}"`, 2)
	end
	if owner ~= nil then
		assert(typeof(owner) == "Instance" and owner:IsA("Player"), "Tide.add: owner must be a Player or nil")
	end
	local existing = State.bySlotModel[model]
	if existing ~= nil then
		Server.remove(existing)
	end
	local t = now()
	local slot = allocSlot(t)
	local root = Rig.root(model)
	local full = kind.full

	State.model[slot] = model
	State.root[slot] = root
	State.kind[slot] = kind
	State.owner[slot] = owner or false
	local h = Ring.new(Config.HistorySize, full)
	State.hist[slot] = h
	-- seed with the server's current pose (speed-check reference for uploads)
	local x, y, z, yaw, qx, qy, qz, qw = Rig.read(model, root, full)
	local _fl
	x, y, z, yaw, _fl, qx, qy, qz, qw = Codec.quantize(x, y, z, yaw, if full then 2 else 0, qx, qy, qz, qw)
	Ring.push(h, if owner then t - Config.MaxBackdate else t, x, y, z, yaw, 0, qx, qy, qz, qw)
	State.relayed[slot] = 0
	State.sentT[slot] = t
	State.heldT[slot] = 0
	State.forceTele[slot] = false
	State.still[slot] = false
	State.tpVel[slot] = nil
	Receive.reset(slot, t)

	State.count += 1
	State.active[State.count] = slot
	State.index[slot] = State.count
	State.bySlotModel[model] = slot
	if owner ~= nil and kind.name == "Player" then
		State.charSlot[owner] = slot
	end
	if owner ~= nil and Config.lockPlayers then
		Lock.lock(slot)
	end
	watchRoot(slot)

	local handle = setmetatable({ slot = slot, model = model }, Handle)
	State.handle[slot] = handle
	State.conn[slot] = model.Destroying:Connect(function()
		if State.handle[slot] == handle then
			Server.remove(slot)
		end
	end)

	writeAdd(bcast, slot)
	Relay.onAdd(slot)
	Signal.fire(Server.addedSignal, model, kind.name, owner)
	return handle
end

function Server.remove(slot: number)
	local pos = State.index[slot]
	if pos == nil then
		return
	end
	Lock.unlock(slot)
	unwatch(slot)
	State.endTeleport(slot)
	local conn = State.conn[slot]
	if conn then
		conn:Disconnect()
	end
	-- swap-remove from the active list
	local lastSlot = State.active[State.count]
	State.active[pos] = lastSlot
	State.index[lastSlot] = pos
	State.active[State.count] = nil
	State.count -= 1
	State.index[slot] = nil

	local model = State.model[slot]
	local owner = State.owner[slot]
	local kindName = State.kind[slot].name
	if owner and State.charSlot[owner] == slot then
		State.charSlot[owner] = nil
	end
	State.bySlotModel[model] = nil
	State.model[slot] = nil
	State.root[slot] = nil
	State.kind[slot] = nil
	State.owner[slot] = nil
	State.hist[slot] = nil
	State.handle[slot] = nil
	State.conn[slot] = nil
	State.tpVel[slot] = nil
	State.freedAt[slot] = now()
	for _, rx in State.rxList do
		rx.tier[slot] = nil
	end

	Control.u8(bcast, Control.REMOVE)
	Control.u16(bcast, slot)
	Signal.fire(Server.removedSignal, model, kindName, if owner then owner else nil)
end

local function sendTeleport(slot: number)
	local owner = State.owner[slot]
	local cf = State.tpCF[slot]
	if not owner or cf == nil then
		return
	end
	-- queued ADD / OWNER messages first: the owner must know the entity is its own
	flushBroadcast()
	local x, y, z, _, qx, qy, qz, qw = Rig.fromCFrame(cf, true)
	local vel = State.tpVel[slot]
	local w = Control.writer(48)
	Control.u8(w, Control.TELEPORT)
	Control.u16(w, slot)
	Control.f32(w, x)
	Control.f32(w, y)
	Control.f32(w, z)
	Control.f32(w, qx)
	Control.f32(w, qy)
	Control.f32(w, qz)
	Control.f32(w, qw)
	if vel ~= nil then
		Control.u8(w, 1)
		Control.f32(w, vel.X)
		Control.f32(w, vel.Y)
		Control.f32(w, vel.Z)
	else
		Control.u8(w, 0)
	end
	sendTo(owner, w)
	State.tpSentT[slot] = now()
end

function Server.teleport(slot: number, cf: CFrame, velocity: Vector3?)
	if State.index[slot] == nil then
		return
	end
	local t = now()
	local owner = State.owner[slot]
	State.tpVel[slot] = velocity
	if owner then
		-- The target goes into history now, flagged: receivers snap to it and the
		-- lock holds the server copy there. Owner uploads are dropped until its
		-- flagged sample near the target arrives (Receive); resent until then.
		local full = State.hist[slot].full
		local x, y, z, yaw, qx, qy, qz, qw = Rig.fromCFrame(cf, full)
		local _fl
		x, y, z, yaw, _fl, qx, qy, qz, qw = Codec.quantize(x, y, z, yaw, if full then 3 else 1, qx, qy, qz, qw)
		local h = State.hist[slot]
		local stamp = math.max(t, Ring.newestT(h) + 0.0005)
		Ring.push(h, stamp, x, y, z, yaw, 1, qx, qy, qz, qw)
		if not State.tpPending[slot] then
			State.tpPending[slot] = true
			State.tpCount += 1
		end
		State.tpX[slot] = x
		State.tpY[slot] = y
		State.tpZ[slot] = z
		State.tpCF[slot] = cf
		State.tpTries[slot] = 1
		State.tpReported[slot] = nil
		sendTeleport(slot)
	else
		local model = State.model[slot]
		local root = State.root[slot]
		if root ~= nil and root ~= model then
			-- move the whole model so welded/attached parts follow
			model:PivotTo(cf * root.CFrame:ToObjectSpace(model:GetPivot()))
		else
			model:PivotTo(cf)
		end
		if velocity ~= nil and root ~= nil and not root.Anchored then
			root.AssemblyLinearVelocity = velocity
		end
		State.forceTele[slot] = true
		Ticker.sample(slot, math.max(t, Ring.newestT(State.hist[slot]) + 0.0005))
	end
end

-- Resends unacknowledged teleports every TeleportRetry; after TeleportTries
-- sends, reports the owner once (the server copy keeps holding the target).
local function retryTeleports(t: number)
	if State.tpCount == 0 then
		return
	end
	local retry = Config.TeleportRetry
	for k = 1, State.count do
		local slot = State.active[k]
		if State.tpPending[slot] and t - State.tpSentT[slot] >= retry then
			local owner = State.owner[slot]
			if State.tpTries[slot] >= Config.TeleportTries and not State.tpReported[slot] then
				State.tpReported[slot] = true
				State.counters.teleportIgnored += 1
				if owner then
					State.suspicious(owner, "teleportIgnored")
				end
			end
			State.tpTries[slot] += 1
			sendTeleport(slot)
		end
	end
end

function Server.setOwner(slot: number, player: any?)
	if State.index[slot] == nil then
		return
	end
	if player ~= nil then
		assert(typeof(player) == "Instance" and player:IsA("Player"), "Tide: owner must be a Player or nil")
	end
	local old = State.owner[slot]
	if old == (player or false) then
		return
	end
	if old and State.charSlot[old] == slot then
		State.charSlot[old] = nil
	end
	Lock.unlock(slot)
	unwatch(slot)
	State.endTeleport(slot)
	State.owner[slot] = player or false
	State.sentT[slot] = now()
	State.heldT[slot] = 0
	State.still[slot] = false
	Receive.reset(slot, now())
	if player ~= nil then
		if State.kind[slot].name == "Player" then
			State.charSlot[player] = slot
		end
		if Config.lockPlayers then
			Lock.lock(slot)
		end
		watchRoot(slot)
	end
	Control.u8(bcast, Control.OWNER)
	Control.u16(bcast, slot)
	Control.f64(bcast, if player then player.UserId else 0)
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

local function poseCFrame(slot: number, t: number?): CFrame?
	local h = State.hist[slot]
	local full = State.hist[slot].full
	if t == nil then
		local p = h.last % h.cap + 1
		return Rig.cframe(
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
	end
	local x, y, z, yaw, qx, qy, qz, qw, state = Interp.sample(h, t, 0)
	if state == Interp.STATE_EMPTY then
		return nil
	end
	return Rig.cframe(x, y, z, yaw, full, qx, qy, qz, qw)
end

-- CFrame at server time t from history (same interpolation clients draw).
function Server.at(target: any, t: number): CFrame?
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil
	end
	return poseCFrame(slot, t)
end

function Server.latest(target: any): CFrame?
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil
	end
	return poseCFrame(slot, nil)
end

-- Velocity from history (studs/s); zero if unknown or idle.
function Server.velocity(target: any): Vector3
	local slot = Server.slotOf(target)
	if slot == nil then
		return Vector3.new(0, 0, 0)
	end
	local vx, vy, vz = Motion.velocity(slot)
	return Vector3.new(vx, vy, vz)
end

function Server.handleOf(target: any): any
	local slot = Server.slotOf(target)
	return if slot then State.handle[slot] else nil
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function addCharacter(player: any, character: any)
	if Rig.root(character) == nil then
		local hrp = character:WaitForChild("HumanoidRootPart", 10)
		if hrp == nil or character.Parent == nil or player.Character ~= character then
			return
		end
	end
	if State.rx[player] == nil then
		return -- left meanwhile
	end
	Server.add(character, "Player", player)
end

local function onPlayerAdded(player: any)
	if State.rx[player] ~= nil then
		return
	end
	local t = now()
	State.rx[player] = {
		player = player,
		ready = false,
		tier = {},
		defer = {},
		tokens = 0,
		upTokens = Config.PlayerBytesPerSecond,
		upT = t,
		upFrame = 0,
		upFrameBytes = 0,
		resendT = -1,
		conns = {},
	}
	if autoPlayers then
		local rx = State.rx[player]
		table.insert(
			rx.conns,
			player.CharacterAdded:Connect(function(character)
				addCharacter(player, character)
			end)
		)
		table.insert(
			rx.conns,
			player.CharacterRemoving:Connect(function(character)
				local slot = State.bySlotModel[character]
				if slot then
					Server.remove(slot)
				end
			end)
		)
		if player.Character then
			task.spawn(addCharacter, player, player.Character)
		end
	end
end

local function onPlayerRemoving(player: any)
	local rx = State.rx[player]
	if rx == nil then
		return
	end
	for _, conn in rx.conns do
		conn:Disconnect()
	end
	-- entities owned by the player: the character goes, anything else reverts to the server
	for k = State.count, 1, -1 do
		local slot = State.active[k]
		if slot and State.owner[slot] == player then
			if State.kind[slot].name == "Player" then
				Server.remove(slot)
			else
				Server.setOwner(slot, nil)
			end
		end
	end
	State.rx[player] = nil
	State.charSlot[player] = nil
	local i = table.find(State.rxList, rx)
	if i then
		table.remove(State.rxList, i)
	end
	State.forget(player)
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local lastT = 0
local rateT = 0
local rateIn = 0
local rateRelay = 0

local function countRates(t: number)
	local c = State.counters
	local span = t - rateT
	if span >= 1 then
		c.inBytesPerSecond = math.floor((c.inBytes - rateIn) / span + 0.5)
		c.relayBytesPerSecond = math.floor((c.relayBytes - rateRelay) / span + 0.5)
		rateT = t
		rateIn = c.inBytes
		rateRelay = c.relayBytes
	end
end

local function onFrame(dt: number)
	local t = now()
	frame += 1
	-- server time is the clock; fall back to dt if it did not move
	local step = t - lastT
	if lastT == 0 or step <= 0 or step > 1 then
		step = dt
	end
	lastT = t
	Ticker.step(t, step)
	retryTeleports(t)
	Lock.step()
	flushBroadcast()
	Relay.step(t, step)
	countRates(t)
end

local function onUpload(player: any, payload: any)
	if typeof(payload) == "buffer" then
		State.counters.inBytes += buffer.len(payload)
	end
	local rx = State.rx[player]
	if rx == nil then
		return
	end
	local ok = pcall(Receive.handle, player, rx, payload, now(), frame)
	if not ok then
		State.counters.errors += 1
	end
end

local function onControl(player: any, payload: any)
	if typeof(payload) == "buffer" then
		State.counters.inBytes += buffer.len(payload)
	end
	local ok = pcall(handleControl, player, payload)
	if not ok then
		State.counters.errors += 1
	end
end

function Server.start(opts: { [string]: any }?): boolean
	if State.started then
		return true
	end
	local extras = Options.apply(opts, { players = "boolean" })
	autoPlayers = extras.players == true
	if Config.lockMode ~= "root" and Config.lockMode ~= "anchored" then
		error(`Tide.start: lockMode must be "root" or "anchored"`, 3)
	end
	State.started = true
	State.onResync = function(slot: number)
		local cf = poseCFrame(slot, nil)
		if cf ~= nil then
			Server.teleport(slot, cf, Vector3.new(0, 0, 0))
		end
	end
	local origin = Config.origin
	Codec.setOrigin(origin.X, origin.Y, origin.Z)
	Interp.snapGap = Config.SnapGap
	Interp.velocityGap = Config.NeedGapMax

	local parent = script.Parent.Parent
	remoteU = Instance.new("UnreliableRemoteEvent")
	remoteU.Name = "TideU"
	remoteU.Parent = parent
	remoteR = Instance.new("RemoteEvent")
	remoteR.Name = "TideR"
	remoteR.Parent = parent
	Relay.init(remoteU)

	remoteU.OnServerEvent:Connect(onUpload)
	remoteR.OnServerEvent:Connect(onControl)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	rateT = now()
	RunService.PostSimulation:Connect(onFrame)
	return true
end

function Server.stats(): { [string]: number }
	return table.clone(State.counters)
end

function Server.onSuspicious(fn: (player: any, reason: string) -> ())
	State.onSuspicious = fn
end

return Server
