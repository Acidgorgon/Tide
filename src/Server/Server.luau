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
local Anim = require(script.Parent.Anim)
local StateLog = require(script.Parent.StateLog)
local Mirror = require(script.Parent.Mirror)
local StateSchema = require(Shared.StateSchema)
local AnimRegistry = require(Shared.AnimRegistry)
local Options = require(Shared.Options)
local LH = require(Shared.Lighthouse)

local Server = {}

Server.addedSignal = Signal.new()
Server.removedSignal = Signal.new()
Server.animatedSignal = Anim.animatedSignal
Server.stateChangedSignal = StateLog.changedSignal
Server.stateFieldSignals = StateLog.fieldSignals

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

-- Flags a server-owned entity's jump as a teleport (receivers snap instead of sweeping)
-- without moving it. No target: the entity is sampled now, flagged (call it after moving the
-- model). A target (CFrame or Vector3): the first sample within Config.TeleportGrantRadius of
-- it, in the next second, is flagged (for moves made elsewhere, e.g. another VM). Does nothing
-- for client-owned entities (use teleport).
function Handle.markTeleport(self: any, target: any)
	local slot = liveSlot(self)
	if slot then
		Server.markTeleport(slot, target)
	end
end

-- Samples a server-owned entity now, out of tick, and marks the sample a cut (see Server.bump).
function Handle.bump(self: any): number?
	local slot = liveSlot(self)
	if slot then
		return Server.bump(slot)
	end
	return nil
end

-- Quantization origin of this entity (nil: Config.origin). Packed positions cover +-1024
-- studs around it; give entities far from Config.origin (another arena, a far venue) one
-- near them to keep the compact record. Set it in the frame of Tide.add (it travels with the
-- ADD); a later change sends the entity's records in the absolute form for a second while
-- clients get it.
function Handle.setOrigin(self: any, origin: Vector3?)
	local slot = liveSlot(self)
	if slot then
		Server.setOrigin(slot, origin)
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

-- The owning player, nil when server-owned (or removed).
function Handle.owner(self: any): Player?
	local slot = liveSlot(self)
	if slot then
		return State.owner[slot] or nil
	end
	return nil
end

function Handle.alive(self: any): boolean
	return liveSlot(self) ~= nil
end

-- Mirrors this entity's history into the link `name` under `key` (a string or number of
-- yours) for code in other VMs (Shared/Link: rewind, owner/teleport intents). nil name: unlink.
-- One entity per key; linking another entity under a taken key unlinks the first.
function Handle.link(self: any, name: string?, key: any)
	local slot = liveSlot(self)
	if slot == nil then
		return
	end
	if name == nil then
		Mirror.unlink(slot)
	else
		Mirror.link(slot, name, key)
	end
end

-- Who receives this entity: nil = every player (the default), a list (or set) of Players,
-- or fn(player) -> boolean (asked every Config.InterestEvery). Receivers outside it get
-- nothing of it (samples, animations, state), as if culled.
function Handle.setAudience(self: any, audience: any)
	local slot = liveSlot(self)
	if slot then
		Server.setAudience(slot, audience)
	end
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

local function writeOrigin(w: Control.Writer, slot: number)
	local ox, oy, oz = Codec.getOrigin()
	Control.u8(w, Control.ORIGIN)
	Control.u16(w, slot)
	Control.f64(w, State.ox[slot] or ox)
	Control.f64(w, State.oy[slot] or oy)
	Control.f64(w, State.oz[slot] or oz)
end

local function writeAdd(w: Control.Writer, slot: number)
	local owner = State.owner[slot]
	Control.u8(w, Control.ADD)
	Control.u16(w, slot)
	Control.u8(w, State.kind[slot].id)
	Control.u16(w, Control.inst(w, State.model[slot]))
	Control.f64(w, if owner then owner.UserId else 0)
	if State.ox[slot] ~= nil then
		writeOrigin(w, slot)
	end
end

local function writeHello(w: Control.Writer)
	local ox, oy, oz = Codec.getOrigin()
	Control.u8(w, Control.HELLO)
	Control.u8(w, Control.VERSION)
	Control.f64(w, ox)
	Control.f64(w, oy)
	Control.f64(w, oz)
	local anims = Anim.active
	local flags = if Config.lockPlayers then 1 else 0
	if anims then
		flags += 2
		if Config.animationsOwnerLocal then
			flags += 4
		end
	end
	if Config.ownerEase then
		flags += 8
	end
	if Config.ownerStart == "latest" then
		flags += 16
	elseif Config.ownerStart == "server" then
		flags += 32
	end
	if Config.rebindStreamed then
		flags += 64
	end
	Control.u8(w, flags)
	Control.u8(w, math.clamp(Config.UploadRedundancy, 1, 2))
	Control.u8(w, #Kinds.list)
	for _, kind in Kinds.list do
		Control.u8(w, kind.id)
		Control.str(w, kind.name)
		Control.f32(w, kind.rate)
		Control.u8(
			w,
			(if kind.full then 1 else 0)
				+ (if anims and (kind.animations == false or kind.motion == false) then 2 else 0)
				+ (if kind.motion == false then 4 else 0)
				+ (if kind.velocity then 8 else 0)
				+ (if kind.apply == "none" and kind.motion ~= false then 16 else 0)
		)
		Control.f32(w, kind.buffer)
		Control.f32(w, kind.extrapolate)
		Control.f32(w, kind.keepAlive)
		Control.f32(w, kind.maxSpeed)
		Control.f32(w, kind.maxRise)
		Control.f32(w, kind.maxFall)
	end
	if anims then
		Control.u16(w, Control.inst(w, Config.animationFolder))
		Control.u16(w, AnimRegistry.seeded)
		Control.u32(w, AnimRegistry.checksum)
	end
end

local function flushBroadcast()
	if bcast.pos == 0 then
		return
	end
	local b, insts = Control.takeAll(bcast)
	local lh = LH.api
	for _, rx in State.rxList do
		remoteR:FireClient(rx.player, b, insts)
		if lh then
			lh.net("Tide", "Control", "out", buffer.len(b), rx.player)
		end
	end
end

local function sendTo(player: any, w: Control.Writer)
	local b, insts = Control.takeAll(w)
	remoteR:FireClient(player, b, insts)
	local lh = LH.api
	if lh then
		lh.net("Tide", "Control", "out", buffer.len(b), player)
	end
end

-- Called when a kind changes after start: resend the kinds table.
function Server.kindsChanged()
	if not State.started then
		return
	end
	writeHello(bcast)
	StateLog.writeSchemas(bcast)
end

local function onReady(player: any, rx: any)
	if rx.ready then
		return
	end
	local w = Control.writer(256)
	writeHello(w)
	Anim.helloIds(w)
	StateLog.writeSchemas(w)
	for k = 1, State.count do
		writeAdd(w, State.active[k])
	end
	sendTo(player, w)
	rx.ready = true
	table.insert(State.rxList, rx)
	Relay.onReady(rx)
	Anim.onReady(rx)
	StateLog.onReady(rx)
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
	local t = now()
	if t - (rx.resendT or -1) < 0.5 then
		return pos + count * 2
	end
	rx.resendT = t
	local w = Control.writer(64)
	for i = 0, count - 1 do
		local slot = buffer.readu16(b, pos + i * 2)
		-- (not for entities whose audience leaves this receiver out: it gets nothing of them)
		if State.index[slot] ~= nil and not rx.outside[slot] then
			writeAdd(w, slot)
		end
	end
	if w.pos > 0 then
		sendTo(player, w)
	end
	return pos + count * 2
end

-- Receivers that came back into an entity's audience: each gets the entity's ADD again, once,
-- after the frame's broadcast (it may have asked for the model while outside, unanswered).
local rejoined = {} :: { any }

local function onAudienceEnter(rx: any, slot: number)
	local pending = rx.rejoin
	if pending[slot] then
		return
	end
	if next(pending) == nil then
		table.insert(rejoined, rx)
	end
	pending[slot] = true
end

local function flushRejoined()
	if #rejoined == 0 then
		return
	end
	for _, rx in rejoined do
		local pending = rx.rejoin
		if State.rx[rx.player] == rx then
			local w: Control.Writer? = nil
			for slot in pending do
				if State.index[slot] ~= nil and not rx.outside[slot] then
					if w == nil then
						w = Control.writer(64)
					end
					writeAdd(w :: Control.Writer, slot)
					State.counters.audienceAdds += 1
				end
			end
			if w ~= nil then
				sendTo(rx.player, w)
			end
		end
		table.clear(pending)
	end
	table.clear(rejoined)
end

local function handleControl(player: any, payload: any)
	local rx = State.rx[player]
	if rx == nil or typeof(payload) ~= "buffer" then
		State.counters.badPacket += 1
		return
	end
	local b: buffer = payload
	local n = buffer.len(b)
	if n > (if Anim.active then 8192 else 512) then
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
		elseif tag == Control.ANIM_UP and Anim.active then
			pos = Anim.handleUp(player, rx, b, pos)
		elseif tag == Control.REGISTER and Anim.active then
			pos = Anim.handleRegister(player, rx, b, pos)
		elseif tag == Control.STATE or tag == Control.STATESNAP or tag == Control.SCHEMA then
			-- state is server-authoritative: clients never send it
			State.counters.stateRejected += 1
			State.suspicious(player, "stateFromClient")
			return
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
	if not Config.teleportOnWrite or root == nil or not State.owner[slot] or State.kind[slot].motion == false then
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
		if kind.velocity then
			error(`Tide.add: kind "{kind.name}" has velocity = true, which is for server-owned entities`, 2)
		end
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
	local h = Ring.new(Config.HistorySize, full, kind.velocity and kind.motion ~= false)
	State.hist[slot] = h
	-- seed with the server's current pose (speed-check reference for uploads)
	local x, y, z, yaw, qx, qy, qz, qw = Rig.read(model, root, full)
	local _fl
	x, y, z, yaw, _fl, qx, qy, qz, qw = Codec.quantize(x, y, z, yaw, if full then 2 else 0, qx, qy, qz, qw)
	local seeded = Ring.push(h, if owner then t - Config.MaxBackdate else t, x, y, z, yaw, 0, qx, qy, qz, qw)
	if h.vel then
		Ring.setVel(h, seeded, Codec.quantizeMotion(Rig.readMotion(root)))
	end
	-- state-only kinds (motion = false) never relay a sample
	State.relayed[slot] = if kind.motion == false then h.last else 0
	State.sentT[slot] = t
	State.heldT[slot] = 0
	State.forceTele[slot] = false
	State.forceCut[slot] = false
	State.still[slot] = false
	State.tpVel[slot] = nil
	State.audience[slot] = nil
	State.markUntil[slot] = nil
	State.ox[slot], State.oy[slot], State.oz[slot] = nil, nil, nil
	State.originUntil[slot] = nil
	State.addFrame[slot] = frame
	Receive.reset(slot, t)

	State.count += 1
	State.active[State.count] = slot
	State.index[slot] = State.count
	State.bySlotModel[model] = slot
	if owner ~= nil and kind.name == "Player" then
		State.charSlot[owner] = slot
	end
	if owner ~= nil and Config.lockPlayers and kind.motion ~= false then
		Lock.lock(slot)
	elseif owner == nil and kind.lock and kind.motion ~= false then
		Lock.lockServer(slot)
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
	StateLog.onAdd(slot)
	StateLog.onAddRx(slot)
	Relay.onAdd(slot)
	Anim.onAdd(slot)
	Signal.fire(Server.addedSignal, model, kind.name, owner)
	return handle
end

function Server.remove(slot: number)
	local pos = State.index[slot]
	if pos == nil then
		return
	end
	Lock.unlock(slot)
	Lock.unlockServer(slot)
	if State.bumped[slot] then
		State.bumped[slot] = nil
		State.bumpN -= 1
	end
	State.forceCut[slot] = nil
	unwatch(slot)
	Mirror.unlink(slot)
	Anim.onRemove(slot)
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
	State.bySlotModel[model] = nil
	StateLog.onRemove(slot, model)
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
	State.audience[slot] = nil
	State.markUntil[slot] = nil
	State.ox[slot], State.oy[slot], State.oz[slot] = nil, nil, nil
	State.originUntil[slot] = nil
	State.freedAt[slot] = now()
	for _, rx in State.rxList do
		rx.tier[slot] = nil
		rx.outside[slot] = nil
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
	if State.index[slot] == nil or State.kind[slot].motion == false then
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
		x, y, z, yaw, _fl, qx, qy, qz, qw =
			Codec.quantize(x, y, z, yaw, if full then 3 else 1, qx, qy, qz, qw, State.ox[slot], State.oy[slot], State.oz[slot])
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

local ORIGIN_GRACE = 1.0 -- seconds of absolute-form records after a later origin change

function Server.setOrigin(slot: number, origin: Vector3?)
	if State.index[slot] == nil then
		return
	end
	assert(origin == nil or typeof(origin) == "Vector3", "setOrigin: a Vector3 or nil expected")
	local gx, gy, gz = Codec.getOrigin()
	local x, y, z
	if origin ~= nil then
		-- on Config.origin's 1/64 grid, so samples move between the two without rounding
		x = gx + math.round((origin.X - gx) * 64) / 64
		y = gy + math.round((origin.Y - gy) * 64) / 64
		z = gz + math.round((origin.Z - gz) * 64) / 64
		if x ~= x or y ~= y or z ~= z or math.abs(x) == math.huge or math.abs(y) == math.huge or math.abs(z) == math.huge then
			error("setOrigin: origin must be finite", 3)
		end
		if x == gx and y == gy and z == gz then
			x, y, z = nil, nil, nil
		end
	end
	if x == State.ox[slot] and y == State.oy[slot] and z == State.oz[slot] then
		return
	end
	State.ox[slot], State.oy[slot], State.oz[slot] = x, y, z
	if State.addFrame[slot] ~= frame then
		-- clients learnt the entity already: ORIGIN may land after records encoded for it
		State.originUntil[slot] = now() + ORIGIN_GRACE
	end
	writeOrigin(bcast, slot)
end

local MARK_WINDOW = 1.0 -- seconds a targeted markTeleport waits for the entity to arrive

function Server.markTeleport(slot: number, target: any)
	if State.index[slot] == nil or State.owner[slot] or State.kind[slot].motion == false then
		return
	end
	local kind = typeof(target)
	local t = now()
	if target == nil then
		State.forceTele[slot] = true
		State.counters.teleportFlagged += 1
		Ticker.sample(slot, math.max(t, Ring.newestT(State.hist[slot]) + 0.0005))
		return
	end
	local p: Vector3
	if kind == "CFrame" then
		p = target.Position
	elseif kind == "Vector3" then
		p = target
	else
		error("markTeleport: target must be a CFrame, a Vector3 or nil", 3)
	end
	State.markX[slot], State.markY[slot], State.markZ[slot] = p.X, p.Y, p.Z
	State.markUntil[slot] = t + MARK_WINDOW
	-- it may already be there (moved earlier this frame)
	Ticker.sample(slot, math.max(t, Ring.newestT(State.hist[slot]) + 0.0005))
end

-- Samples a server-owned entity now, out of tick (v0.5): call it right after game code changed
-- its motion abruptly (a kick, a bounce it resolved itself, a catch), so receivers get the new
-- pose and velocity with this frame's packet instead of at the kind's next tick. For kinds
-- with velocity = true the sample is marked a CUT: paths do not curve across it.
--
-- Returns the sample's server time (pass it as the stamp of a Tide.fire / Tide.set that
-- belongs to the same moment), or nil when the entity is not a server-owned motion entity.
--   * outside the physics step (remote handlers, Heartbeat after Tide's own step, task
--     scheduler resumes): sampled at once. The poses that stand are the ones the last frame
--     ended with, so the stamp is that frame's time (1 ms after the entity's newest sample
--     when it was sampled that frame already).
--   * between PreSimulation and Tide's step of the frame (physics has not finished): the
--     entity is sampled at that step whatever its kind's tick, with the pose physics ends on;
--     the time returned is the time of the call (the sample's is within the frame after it).
-- Nothing is sent when neither the pose nor the velocity changed since the newest sample.
function Server.bump(target: any): number?
	local slot = if type(target) == "number" then target else Server.slotOf(target)
	if slot == nil or State.index[slot] == nil or State.owner[slot] or State.kind[slot].motion == false then
		return nil
	end
	local c = State.counters
	local lh = LH.api
	if lh then
		lh.count("Tide.Bump")
	end
	if State.inSim then
		if not State.bumped[slot] then
			State.bumped[slot] = true
			State.bumpN += 1
		end
		State.forceCut[slot] = true
		c.bumpsDeferred += 1
		return now()
	end
	local h = State.hist[slot]
	local stamp = State.frameT
	if stamp == 0 then
		stamp = now()
	end
	-- two ticks of the wire's time grid after anything known: receivers never see two samples
	-- at one time
	local floor = math.max(Ring.newestT(h), State.heldT[slot]) + 0.001
	if stamp < floor then
		stamp = floor
	end
	State.forceCut[slot] = true
	Ticker.sample(slot, stamp, true)
	c.bumps += 1
	return stamp
end

-- Intents queued by other VMs on a link (Shared/Link), applied at the start of a frame.
Mirror.apply = function(op: string, slot: number, intent: any)
	if op == "owner" then
		local user = intent.user
		local player = nil
		if type(user) == "number" and user ~= 0 then
			player = Players:GetPlayerByUserId(user)
			if player == nil then
				error("no such player") -- counted as linkBad
			end
		end
		Server.setOwner(slot, player)
	elseif op == "teleport" then
		local x, y, z = intent.x, intent.y, intent.z
		local cf = CFrame.new(x, y, z, intent.qx, intent.qy, intent.qz, intent.qw)
		local velocity = nil
		if intent.vx ~= nil then
			velocity = Vector3.new(intent.vx, intent.vy, intent.vz)
		end
		Server.teleport(slot, cf, velocity)
	elseif op == "mark" then
		local target = nil
		if intent.x ~= nil then
			target = Vector3.new(intent.x, intent.y, intent.z)
		end
		Server.markTeleport(slot, target)
	elseif op == "bump" then
		Server.bump(slot)
	else
		error("unknown op")
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
	if player ~= nil and State.hist[slot].vel then
		error(`Tide: kind "{State.kind[slot].name}" has velocity = true, which is for server-owned entities`, 3)
	end
	-- ownerStart = "server": the new owner starts from the server's pose (live for a
	-- server-owned entity, else the newest accepted sample), carried to its arrival time
	local pose: { number }? = nil
	if player ~= nil and Config.ownerStart == "server" and State.kind[slot].motion ~= false then
		local h = State.hist[slot]
		local vx, vy, vz = Motion.velocity(slot)
		local x, y, z, qx, qy, qz, qw, stamp
		local model = State.model[slot]
		if not old and model.Parent ~= nil then
			local root = State.root[slot]
			if root ~= nil and root.Parent == nil then
				root = nil
			end
			local _yaw
			x, y, z, _yaw, qx, qy, qz, qw = Rig.read(model, root, true)
			stamp = now()
		elseif h.n > 0 then
			local p = h.last % h.cap + 1
			x, y, z, stamp = h.x[p], h.y[p], h.z[p], h.t[p]
			if h.full then
				qx, qy, qz, qw = h.qx[p], h.qy[p], h.qz[p], h.qw[p]
			else
				local half = h.yaw[p] * 0.5
				qx, qy, qz, qw = 0, math.sin(half), 0, math.cos(half)
			end
		end
		if x ~= nil then
			pose = { stamp, x, y, z, qx, qy, qz, qw, vx, vy, vz }
		end
	end
	if old and State.charSlot[old] == slot then
		State.charSlot[old] = nil
	end
	Lock.unlock(slot)
	Lock.unlockServer(slot)
	if State.bumped[slot] then
		State.bumped[slot] = nil
		State.bumpN -= 1
	end
	State.forceCut[slot] = false
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
		if Config.lockPlayers and State.kind[slot].motion ~= false then
			Lock.lock(slot)
		end
		watchRoot(slot)
	elseif State.kind[slot].lock and State.kind[slot].motion ~= false then
		Lock.lockServer(slot)
	end
	Control.u8(bcast, Control.OWNER)
	Control.u16(bcast, slot)
	Control.f64(bcast, if player then player.UserId else 0)
	if pose ~= nil then
		-- in the same broadcast, right after the OWNER (everyone else ignores it): the new
		-- owner gets both at once, before its first upload
		Control.u8(bcast, Control.OWNERPOSE)
		Control.u16(bcast, slot)
		Control.f64(bcast, pose[1])
		for i = 2, 11 do
			Control.f32(bcast, pose[i])
		end
	end
	Anim.onOwner(slot, old)
	StateLog.onOwner(slot, old)
end

function Server.setAudience(slot: number, audience: any)
	if State.index[slot] == nil then
		return
	end
	local value: any = nil
	if type(audience) == "function" then
		value = audience
	elseif type(audience) == "table" then
		local set = {}
		for k, v in audience do
			local player = if type(k) == "number" then v else k
			if typeof(player) ~= "Instance" or not player:IsA("Player") then
				error("setAudience: a list or set of Players expected", 3)
			end
			set[player] = true
		end
		value = table.freeze(set)
	elseif audience ~= nil then
		error("setAudience: expected a function, a list of Players or nil", 3)
	end
	State.audience[slot] = value
	Relay.recomputeSlot(slot)
end

-- Interest centre of a player that has no "Player" entity (a spectator camera, a watched
-- match): a BasePart or Model (followed), a Vector3, or nil (none). A character entity,
-- while it exists, still wins.
function Server.focus(player: any, target: any)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Tide.focus: player expected")
	local kind = typeof(target)
	assert(
		target == nil or kind == "Vector3" or (kind == "Instance" and (target:IsA("BasePart") or target:IsA("Model"))),
		"Tide.focus: target must be a BasePart, a Model, a Vector3 or nil"
	)
	local rx = State.rx[player]
	if rx == nil then
		return
	end
	rx.focus = target
	rx.focusX, rx.focusY, rx.focusZ = nil, nil, nil
	if rx.ready then
		Relay.recomputeRx(rx)
	end
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

local function poseCFrame(slot: number, t: number?): CFrame?
	if State.kind[slot].motion == false then
		return nil
	end
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

local motion = Interp.motion

-- CFrame at server time t from history (same interpolation clients draw). Kinds with
-- velocity = true (v0.5): also the linear velocity (studs/s) and the spin (rad/s) of the path
-- at t; other kinds return the CFrame alone.
function Server.at(target: any, t: number): (CFrame?, Vector3?, Vector3?)
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil
	end
	local cf = poseCFrame(slot, t)
	if cf ~= nil and State.hist[slot].vel then
		return cf, Vector3.new(motion[1], motion[2], motion[3]), Vector3.new(motion[4], motion[5], motion[6])
	end
	return cf
end

-- Newest sample. Kinds with velocity = true (v0.5): also its velocity, its spin and its server
-- time.
function Server.latest(target: any): (CFrame?, Vector3?, Vector3?, number?)
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil
	end
	local cf = poseCFrame(slot, nil)
	local h = State.hist[slot]
	if cf ~= nil and h.vel then
		local p = h.last % h.cap + 1
		return cf, Vector3.new(h.vx[p], h.vy[p], h.vz[p]), Vector3.new(h.wx[p], h.wy[p], h.wz[p]), h.t[p]
	end
	return cf
end

-- Velocity from history (studs/s); zero if unknown or idle.
function Server.velocity(target: any): Vector3
	local slot = Server.slotOf(target)
	if slot == nil or State.kind[slot].motion == false then
		return Vector3.new(0, 0, 0)
	end
	local vx, vy, vz = Motion.velocity(slot)
	return Vector3.new(vx, vy, vz)
end

--------------------------------------------------------------------------------
-- Animations
--------------------------------------------------------------------------------

local function animationOf(animation: any): any
	if type(animation) == "string" then
		local found = AnimRegistry.byName(animation)
		if found == nil then
			error(`Tide.play: no Animation named "{animation}" under Config.animationFolder`, 3)
		end
		return found
	end
	assert(typeof(animation) == "Instance" and animation:IsA("Animation"), "Tide.play: animation must be an Animation or a name")
	return animation
end

-- What Tide knows an entity plays at server time t (default now). nil when not animated.
function Server.playing(target: any, t: number?): { [string]: any }?
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil
	end
	return Anim.playing(slot, t)
end

-- Server-owned entities: plays on the entity's Animator with an exact fade.
function Server.play(target: any, animation: any, fade: number?, weight: number?, speed: number?): any
	local anim = animationOf(animation)
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil
	end
	return Anim.play(slot, anim, fade, weight, speed)
end

function Server.stop(target: any, animation: any, fade: number?)
	local anim = animationOf(animation)
	local slot = Server.slotOf(target)
	if slot ~= nil then
		Anim.stop(slot, anim, fade)
	end
end

--------------------------------------------------------------------------------
-- Timeline state
--------------------------------------------------------------------------------

-- Tide.state: declares a kind's fields (shared code; the server's declaration is sent to clients).
function Server.state(kindName: string, fields: { [string]: any })
	StateLog.checkDeclare(kindName)
	StateSchema.define(kindName, fields)
	StateLog.attach(kindName)
	if State.started then
		StateLog.writeSchemas(bcast)
	end
end

local function stateSlot(target: any): number?
	local slot = Server.slotOf(target)
	if slot == nil then
		State.counters.stateNoEntity += 1
	end
	return slot
end

function Server.set(target: any, field: string, value: any, stamp: number?)
	local slot = stateSlot(target)
	if slot ~= nil then
		StateLog.set(slot, field, value, stamp)
	end
end

function Server.fire(target: any, field: string, payload: any, stamp: number?)
	local slot = stateSlot(target)
	if slot ~= nil then
		StateLog.fire(slot, field, payload, stamp)
	end
end

function Server.get(target: any, field: string): (any, any)
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil, nil
	end
	return StateLog.get(slot, field)
end

function Server.stateAt(target: any, field: string, t: number): (any, any)
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil, nil
	end
	return StateLog.stateAt(slot, field, t)
end

function Server.changedAt(target: any, field: string, t0: number, t1: number): number?
	local slot = Server.slotOf(target)
	if slot == nil then
		return nil
	end
	return StateLog.changedAt(slot, field, t0, t1)
end

function Server.timeOf(_target: any): number
	return now()
end

function Server.owner(target: any): any
	local slot = Server.slotOf(target)
	return if slot then State.owner[slot] or nil else nil
end

function Server.isMine(target: any): boolean
	local slot = Server.slotOf(target)
	return slot ~= nil and State.owner[slot] == false
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
		outside = {}, -- slots culled because the receiver is outside their audience
		audCache = {}, -- audience function -> result, per recompute
		rejoin = {}, -- slots whose audience it came back into this frame (their ADD goes again)
		focus = nil,
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

-- One reliable message per receiver per frame: animation events and timeline state together.
local relOut = Control.writer(512)
local exactR = {} :: { [number]: buffer } -- exact-size send buffers (the remote copies at the call)
local NO_INSTS = table.freeze({})

-- `remote` replaces the reliable remote (tests).
function Server.flushReliable(t: number, remote: any?)
	local anims = Anim.pending()
	local states = StateLog.pending()
	if not anims and not states then
		return
	end
	if states then
		StateLog.prepare(t)
	end
	local w = relOut
	local counters = State.counters
	for _, rx in State.rxList do
		if anims then
			Anim.writeRx(rx, w, t)
		end
		local mid = w.pos
		if states then
			StateLog.writeRx(rx, w, t)
		end
		local n = w.pos
		if n > 0 then
			local b = if n <= 2048 then exactR[n] else nil
			if b == nil then
				b = buffer.create(n)
				if n <= 2048 then
					exactR[n] = b
				end
			end
			buffer.copy(b, 0, w.b, 0, n)
			w.pos = 0
			(remote or remoteR):FireClient(rx.player, b, NO_INSTS)
			local lh = LH.api
			if lh then
				lh.net("Tide", "Anim", "out", n, rx.player)
			end
			counters.animRelayBytes += mid
			counters.stateRelayBytes += n - mid
		end
	end
	if anims then
		Anim.flushDone()
	end
	if states then
		StateLog.flushDone()
	end
end

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

-- Physics is about to step: poses are not final until Tide's own step of this frame
-- (Server.bump defers to it).
local function onPreSimulation()
	State.inSim = true
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
	local lh = LH.frame()
	if lh then
		LH.sample:begin()
	end
	Mirror.read()
	Ticker.step(t, step)
	State.frameT = t
	State.inSim = false
	Anim.step(t, step)
	retryTeleports(t)
	Lock.step()
	if lh then
		LH.sample:finish()
		LH.relay:begin()
	end
	flushBroadcast()
	Relay.step(t, step)
	flushRejoined()
	Server.flushReliable(t)
	if lh then
		LH.relay:finish()
	end
	Mirror.write()
	countRates(t)
end

local function onUpload(player: any, payload: any)
	local lh = LH.api
	if typeof(payload) == "buffer" then
		State.counters.inBytes += buffer.len(payload)
		if lh then
			lh.net("Tide", "Upload", "in", buffer.len(payload), player)
		end
	end
	local rx = State.rx[player]
	if rx == nil then
		return
	end
	if lh then
		LH.receive:begin()
	end
	local ok = pcall(Receive.handle, player, rx, payload, now(), frame)
	if lh then
		LH.receive:finish()
	end
	if not ok then
		State.counters.errors += 1
	end
end

local function onControl(player: any, payload: any)
	if typeof(payload) == "buffer" then
		State.counters.inBytes += buffer.len(payload)
		local lh = LH.api
		if lh then
			lh.net("Tide", "Control", "in", buffer.len(payload), player)
		end
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
	Anim.init(remoteR, bcast)
	Relay.onEnter = function(rx: any, slot: number)
		if Anim.active then
			Anim.onEnter(rx, slot)
		end
		StateLog.onEnter(rx, slot)
	end
	Relay.onLeave = StateLog.onLeave
	Relay.onAudienceEnter = onAudienceEnter

	remoteU.OnServerEvent:Connect(onUpload)
	remoteR.OnServerEvent:Connect(onControl)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	rateT = now()
	RunService.PreSimulation:Connect(onPreSimulation)
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
