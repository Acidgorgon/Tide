--!strict
-- Client side of Tide: control channel, entity registry, frame hooks, queries.

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
local Buffer = require(script.Parent.Buffer)
local Receive = require(script.Parent.Receive)
local Render = require(script.Parent.Render)
local Upload = require(script.Parent.Upload)
local AnimPlay = require(script.Parent.AnimPlay)
local AnimOwner = require(script.Parent.AnimOwner)
local AnimCodec = require(Shared.AnimCodec)
local AnimRegistry = require(Shared.AnimRegistry)
local AnimWatch = require(Shared.AnimWatch)
local StateApply = require(script.Parent.StateApply)
local StateSchema = require(Shared.StateSchema)
local Options = require(Shared.Options)
local LH = require(Shared.Lighthouse)

local Client = {}

Client.addedSignal = Signal.new()
Client.removedSignal = Signal.new()
Client.animatedSignal = AnimPlay.animatedSignal
Client.stateChangedSignal = StateApply.changedSignal
Client.stateFieldSignals = StateApply.fieldSignals

local remoteU: any = nil
local remoteR: any = nil
local retryAcc = 0
local rootAcc = 0
local ROOT_CHECK = 0.25 -- seconds between root re-resolves (streaming)

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Animation channel: who watches (owner) and who plays (everyone else) an entity.
-- The side that lets go goes first: becoming the owner, the receiver's replayed
-- tracks stop before the watcher looks at the Animator (they are not this
-- client's to send); no longer the owner, the watcher stops before the receiver
-- takes the Animator over.
local function animUpdate(slot: number)
	if State.animations then
		if State.mine[slot] then
			AnimPlay.update(slot, now())
			AnimOwner.update(slot)
		else
			AnimOwner.update(slot)
			AnimPlay.update(slot, now())
		end
	end
end

--------------------------------------------------------------------------------
-- Entities
--------------------------------------------------------------------------------

local function restoreAnchor(slot: number)
	local before = State.anchoredBefore[slot]
	local root = State.root[slot]
	if before ~= nil and root ~= nil then
		root.Anchored = before
	end
	State.anchoredBefore[slot] = nil
end

local function anchorIfDriven(slot: number)
	local root = State.root[slot]
	local kind = State.kind[slot]
	if
		Config.ClientAnchor
		and root ~= nil
		and not State.mine[slot]
		and kind.apply == "cframe"
		and kind.motion ~= false
		and State.anchoredBefore[slot] == nil
	then
		State.anchoredBefore[slot] = root.Anchored
		root.Anchored = true
	end
end

local function setMine(slot: number, isMine: boolean)
	local was = State.mine[slot]
	State.mine[slot] = isMine
	State.lag[slot] = nil
	State.blendIn[slot] = nil
	if isMine then
		restoreAnchor(slot)
		Upload.reset(slot, now())
		State.drawn[slot] = false
	else
		if was then
			Ring.clear(State.ring[slot])
			local root = State.root[slot]
			if State.ownerEase and root ~= nil and root.Parent ~= nil then
				-- ownerEase: the first draw blends from where this client's copy stands
				local x, y, z, yaw = Rig.fromCFrame(root.CFrame, false)
				State.dX[slot], State.dY[slot], State.dZ[slot], State.dYaw[slot] = x, y, z, yaw
				State.blendIn[slot] = true
			end
		end
		anchorIfDriven(slot)
	end
	animUpdate(slot)
end

-- Moves the copy of an entity this client now owns to a pose (ownerStart), keeping the
-- root's offset in the model, and gives the root that velocity.
local function startAt(slot: number, cf: CFrame, vx: number, vy: number, vz: number)
	local model = State.model[slot]
	local root = State.root[slot]
	if model == nil then
		return
	end
	if root ~= nil and root ~= model then
		model:PivotTo(cf * root.CFrame:ToObjectSpace(model:GetPivot()))
	else
		model:PivotTo(cf)
	end
	local part = root or (model:IsA("Model") and model.PrimaryPart) or nil
	if part ~= nil and not part.Anchored then
		part.AssemblyLinearVelocity = Vector3.new(vx, vy, vz)
	end
end

-- ownerStart = "latest": the newest received sample, carried to now with the stream's
-- velocity (at most Config.MaxBuffer; not past a stale stream's end).
local function startLatest(slot: number)
	local r = State.ring[slot]
	if r.n == 0 then
		return
	end
	local kind = State.kind[slot]
	local t = now()
	local age = t - Ring.newestT(r)
	local carry = if age <= Config.SnapGap then Config.MaxBuffer else 0
	local x, y, z, yaw, qx, qy, qz, qw = Interp.sample(r, t, carry, 0.5 / kind.rate, kind.maxSpeed, kind.maxRise, kind.maxFall)
	local vx, vy, vz = 0, 0, 0
	if carry > 0 then
		local px, py, pz = Interp.sample(r, t - 0.05, carry, 0.5 / kind.rate, kind.maxSpeed, kind.maxRise, kind.maxFall)
		vx, vy, vz = (x - px) / 0.05, (y - py) / 0.05, (z - pz) / 0.05
	end
	startAt(slot, Rig.cframe(x, y, z, yaw, r.full, qx, qy, qz, qw), vx, vy, vz)
end

local function ownerPlayer(ownerId: number): any
	if ownerId == 0 then
		return nil
	end
	return Players:GetPlayerByUserId(ownerId)
end

local function sourceFor(kind: any, ownerId: number): any
	if ownerId ~= 0 then
		return Buffer.new(kind.buffer)
	end
	local src = State.srcByKind[kind]
	if src == nil then
		src = Buffer.new(kind.buffer, true)
		State.srcByKind[kind] = src
	end
	return src
end

local function setModel(slot: number, model: any)
	State.model[slot] = model
	State.root[slot] = Rig.root(model)
	if model ~= nil then
		State.bySlotModel[model] = slot
	end
end

-- rebindStreamed: the entity's model left the DataModel (streamed out). Forget it, keep the
-- stream; retryModels asks for the entity again and the model that comes back (a new
-- instance once re-streamed) is bound to the same slot.
local function dropModel(slot: number)
	local model = State.model[slot]
	if model == nil then
		return
	end
	restoreAnchor(slot)
	if State.bySlotModel[model] == slot then
		State.bySlotModel[model] = nil
	end
	State.lost[slot] = model
	State.model[slot] = nil
	State.root[slot] = nil
	State.cf[slot] = nil
	State.drawn[slot] = false
	State.counters.modelsLost += 1
	animUpdate(slot)
	local kind = State.kind[slot]
	Signal.fire(Client.removedSignal, model, kind and kind.name)
end

-- Binds a model to an entity that has none (late arrival, or after dropModel).
local function attachModel(slot: number, model: any)
	if State.lost[slot] ~= nil then
		State.lost[slot] = nil
		State.counters.modelsRebound += 1
	end
	setModel(slot, model)
	if not State.mine[slot] then
		anchorIfDriven(slot)
	end
	animUpdate(slot)
	StateApply.onModel(slot)
	Signal.fire(Client.addedSignal, model, State.kind[slot].name, ownerPlayer(State.ownerId[slot]))
end

local function removeEntity(slot: number)
	local pos = State.index[slot]
	if pos == nil then
		return
	end
	restoreAnchor(slot)
	if State.animations then
		AnimOwner.detach(slot)
		AnimPlay.release(slot)
	end
	StateApply.onRemove(slot)
	local lastSlot = State.active[State.count]
	State.active[pos] = lastSlot
	State.index[lastSlot] = pos
	State.active[State.count] = nil
	State.count -= 1
	State.index[slot] = nil

	local model = State.model[slot]
	local kind = State.kind[slot]
	if model ~= nil and State.bySlotModel[model] == slot then
		State.bySlotModel[model] = nil
	end
	State.model[slot] = nil
	State.root[slot] = nil
	State.ring[slot] = nil
	State.src[slot] = nil
	State.cf[slot] = nil
	State.drawn[slot] = false
	State.mine[slot] = false
	State.lag[slot] = nil
	State.blendIn[slot] = nil
	State.ox[slot], State.oy[slot], State.oz[slot] = nil, nil, nil
	State.lost[slot] = nil
	Signal.fire(Client.removedSignal, model, kind and kind.name)
end

local function addEntity(slot: number, kind: any, model: any, ownerId: number)
	if State.index[slot] ~= nil then
		local same = State.kind[slot] == kind and State.ownerId[slot] == ownerId
		if same and State.model[slot] == model then
			return -- repeated ADD (answer to an earlier resend)
		end
		local old = State.model[slot]
		if same and old ~= nil and model ~= nil and State.rebindStreamed and old.Parent == nil then
			dropModel(slot) -- a re-streamed model (new instance) replaces one that streamed out
		end
		if same and State.model[slot] == nil and model ~= nil then
			-- model arrived late (streaming): attach it, keep the stream
			attachModel(slot, model)
			return
		end
		removeEntity(slot)
	end
	State.kind[slot] = kind
	State.ownerId[slot] = ownerId
	setModel(slot, model)
	State.ring[slot] = Ring.new(Config.ClientRing, kind.full)
	State.src[slot] = sourceFor(kind, ownerId)
	State.pkt[slot] = 0
	State.dirtyFrom[slot] = math.huge
	State.gapE[slot] = 0
	State.drawn[slot] = false
	State.offT[slot] = -math.huge
	State.offX[slot], State.offY[slot], State.offZ[slot], State.offYaw[slot] = 0, 0, 0, 0
	State.vX[slot], State.vY[slot], State.vZ[slot] = 0, 0, 0
	State.lastRT[slot] = -math.huge
	State.mine[slot] = false
	State.lag[slot] = nil
	State.blendIn[slot] = nil
	State.ox[slot], State.oy[slot], State.oz[slot] = nil, nil, nil
	State.lost[slot] = nil
	State.count += 1
	State.active[State.count] = slot
	State.index[slot] = State.count
	StateApply.onAdd(slot)
	setMine(slot, ownerId ~= 0 and ownerId == State.localUserId)
	if model ~= nil then
		Signal.fire(Client.addedSignal, model, kind.name, ownerPlayer(ownerId))
	end
end

--------------------------------------------------------------------------------
-- Control channel
--------------------------------------------------------------------------------

local function readHello(b: buffer, pos: number, insts: { any }): number
	local version = buffer.readu8(b, pos)
	if version ~= Control.VERSION then
		warn(`Tide: server protocol {version}, client {Control.VERSION}`)
	end
	local ox = buffer.readf64(b, pos + 1)
	local oy = buffer.readf64(b, pos + 9)
	local oz = buffer.readf64(b, pos + 17)
	Codec.setOrigin(ox, oy, oz)
	local flags = buffer.readu8(b, pos + 25)
	State.lockPlayers = flags % 2 == 1
	local anims = (flags // 2) % 2 == 1
	State.ownerEase = (flags // 8) % 2 == 1
	local start = (flags // 16) % 4
	State.ownerStart = if start == 1 then "latest" elseif start == 2 then "server" else "drawn"
	State.rebindStreamed = (flags // 64) % 2 == 1
	Config.UploadRedundancy = buffer.readu8(b, pos + 26)
	local n = buffer.readu8(b, pos + 27)
	pos += 28
	table.clear(Kinds.byId)
	for _ = 1, n do
		local id = buffer.readu8(b, pos)
		local len = buffer.readu8(b, pos + 1)
		local name = buffer.readstring(b, pos + 2, len)
		pos += 2 + len
		local kind = Kinds.bind(name, id)
		kind.rate = buffer.readf32(b, pos)
		local kindFlags = buffer.readu8(b, pos + 4)
		kind.full = kindFlags % 2 == 1
		kind.animations = (kindFlags // 2) % 2 == 0
		kind.motion = (kindFlags // 4) % 2 == 0
		kind.rotation = if kind.full then "full" else "yaw"
		kind.buffer = buffer.readf32(b, pos + 5)
		kind.extrapolate = buffer.readf32(b, pos + 9)
		kind.keepAlive = buffer.readf32(b, pos + 13)
		kind.maxSpeed = buffer.readf32(b, pos + 17)
		kind.maxRise = buffer.readf32(b, pos + 21)
		kind.maxFall = buffer.readf32(b, pos + 25)
		pos += 29
		local src = State.srcByKind[kind]
		if src then
			src.minBuffer = kind.buffer
		end
	end
	if anims then
		local folderIndex = buffer.readu16(b, pos)
		local seeded = buffer.readu16(b, pos + 2)
		local checksum = buffer.readu32(b, pos + 4)
		pos += 8
		if not State.animSeeded then
			State.animSeeded = true
			local folder = if folderIndex > 0 then insts[folderIndex] else Config.animationFolder
			local count, sum = AnimRegistry.seed(folder)
			if count ~= seeded or sum ~= checksum then
				warn(`Tide: animation folder differs from the server's ({count} vs {seeded} ids); asking for the id table`)
				AnimRegistry.reset()
				AnimOwner.requestTable()
			end
		end
		State.animations = true
		AnimOwner.active = true
		if (flags // 4) % 2 == 1 then
			AnimOwner.ownerLocal = true
		else
			AnimOwner.unhook()
		end
		AnimPlay.active = true
		for k = 1, State.count do
			animUpdate(State.active[k])
		end
	elseif State.animations or AnimOwner.ownerLocal then
		warn("Tide: the server has animations off; this client turned them on")
		AnimOwner.unhook()
	end
	State.helloed = true
	return pos
end

local function readAnim(b: buffer, pos: number, n: number): number
	if pos + 10 > n then
		return -1
	end
	local base = buffer.readf64(b, pos)
	local count = buffer.readu16(b, pos + 8)
	pos += 10
	local tick = AnimCodec.TICK
	for _ = 1, count do
		local np, slot, dt, op, id, fade, weight, speed, timePos, prio, looped = AnimCodec.read(b, pos, n)
		if np < 0 then
			return -1
		end
		pos = np
		if State.index[slot] ~= nil then
			AnimPlay.event(slot, base + dt * tick, op, id, fade, weight, speed, timePos, prio, looped)
		end
	end
	return pos
end

local function readSnap(b: buffer, pos: number, n: number): number
	if pos + 11 > n then
		return -1
	end
	local slot = buffer.readu16(b, pos)
	local base = buffer.readf64(b, pos + 2)
	local count = buffer.readu8(b, pos + 10)
	pos += 11
	if pos + count * AnimCodec.STATE > n then
		return -1
	end
	if State.index[slot] ~= nil then
		AnimPlay.snapshot(slot, base, b, pos, count, now())
	end
	return pos + count * AnimCodec.STATE
end

local function readAnimId(b: buffer, pos: number, n: number): number
	if pos + 3 > n then
		return -1
	end
	local id = buffer.readu16(b, pos)
	local len = buffer.readu8(b, pos + 2)
	if pos + 3 + len > n then
		return -1
	end
	if id > 0 then
		AnimRegistry.bind(id, buffer.readstring(b, pos + 3, len))
		AnimPlay.idsBound()
	end
	return pos + 3 + len
end

local function handleControl(payload: any, insts: any)
	if typeof(payload) ~= "buffer" then
		return
	end
	local b: buffer = payload
	local n = buffer.len(b)
	insts = if type(insts) == "table" then insts else {}
	local pos = 0
	while pos < n do
		local tag = buffer.readu8(b, pos)
		pos += 1
		if tag == Control.HELLO then
			pos = readHello(b, pos, insts)
		elseif tag == Control.ADD then
			local slot = buffer.readu16(b, pos)
			local kindId = buffer.readu8(b, pos + 2)
			local instIndex = buffer.readu16(b, pos + 3)
			local ownerId = buffer.readf64(b, pos + 5)
			pos += 13
			local kind = Kinds.byId[kindId]
			if kind ~= nil then
				local model = if instIndex > 0 then insts[instIndex] else nil
				addEntity(slot, kind, model, ownerId)
			end
		elseif tag == Control.REMOVE then
			removeEntity(buffer.readu16(b, pos))
			pos += 2
		elseif tag == Control.OWNER then
			local slot = buffer.readu16(b, pos)
			local ownerId = buffer.readf64(b, pos + 2)
			pos += 10
			if State.index[slot] ~= nil then
				local wasMine = State.mine[slot]
				local before = State.delayOf(slot)
				State.ownerId[slot] = ownerId
				local isMine = ownerId ~= 0 and ownerId == State.localUserId
				setMine(slot, isMine)
				if ownerId ~= 0 and State.src[slot] == State.srcByKind[State.kind[slot]] then
					State.src[slot] = sourceFor(State.kind[slot], ownerId)
				elseif ownerId == 0 then
					State.src[slot] = sourceFor(State.kind[slot], 0)
				end
				if State.ownerEase and not isMine and not wasMine and State.drawn[slot] then
					-- keep this entity's render clock: start at the old delay, ease to the new source's
					State.lag[slot] = before
				end
				if isMine and not wasMine and State.ownerStart == "latest" and State.kind[slot].motion ~= false then
					startLatest(slot)
				end
			end
		elseif tag == Control.ORIGIN then
			local slot = buffer.readu16(b, pos)
			local x = buffer.readf64(b, pos + 2)
			local y = buffer.readf64(b, pos + 10)
			local z = buffer.readf64(b, pos + 18)
			pos += 26
			if State.index[slot] ~= nil then
				local gx, gy, gz = Codec.getOrigin()
				if x == gx and y == gy and z == gz then
					State.ox[slot], State.oy[slot], State.oz[slot] = nil, nil, nil
				else
					State.ox[slot], State.oy[slot], State.oz[slot] = x, y, z
				end
			end
		elseif tag == Control.OWNERPOSE then
			local slot = buffer.readu16(b, pos)
			local stamp = buffer.readf64(b, pos + 2)
			local v = table.create(10, 0)
			for i = 1, 10 do
				v[i] = buffer.readf32(b, pos + 10 + (i - 1) * 4)
			end
			pos += 50
			if State.index[slot] ~= nil and State.mine[slot] and State.ownerStart == "server" then
				local age = math.clamp(now() - stamp, 0, Config.MaxBuffer)
				local cf = CFrame.new(v[1] + v[8] * age, v[2] + v[9] * age, v[3] + v[10] * age, v[4], v[5], v[6], v[7])
				startAt(slot, cf, v[8], v[9], v[10])
			end
		elseif tag == Control.TELEPORT then
			local slot = buffer.readu16(b, pos)
			local x = buffer.readf32(b, pos + 2)
			local y = buffer.readf32(b, pos + 6)
			local z = buffer.readf32(b, pos + 10)
			local qx = buffer.readf32(b, pos + 14)
			local qy = buffer.readf32(b, pos + 18)
			local qz = buffer.readf32(b, pos + 22)
			local qw = buffer.readf32(b, pos + 26)
			local hasVel = buffer.readu8(b, pos + 30) == 1
			local vel: Vector3? = nil
			pos += 31
			if hasVel then
				vel = Vector3.new(buffer.readf32(b, pos), buffer.readf32(b, pos + 4), buffer.readf32(b, pos + 8))
				pos += 12
			end
			if State.index[slot] ~= nil and State.mine[slot] then
				local cf = CFrame.new(x, y, z, qx, qy, qz, qw)
				local model = State.model[slot]
				local root = State.root[slot]
				if root ~= nil and root ~= model then
					model:PivotTo(cf * root.CFrame:ToObjectSpace(model:GetPivot()))
				elseif model ~= nil then
					model:PivotTo(cf)
				end
				local part = root or (model and model.PrimaryPart)
				if vel ~= nil and part ~= nil then
					part.AssemblyLinearVelocity = vel
				end
				Upload.flagTeleport(slot, now())
			end
		elseif tag == Control.STATE or tag == Control.STATESNAP or tag == Control.SCHEMA then
			if tag == Control.STATE then
				pos = StateApply.readState(b, pos, n)
			elseif tag == Control.STATESNAP then
				pos = StateApply.readSnap(b, pos, n)
			else
				pos = StateApply.readSchemas(b, pos, n)
			end
			if pos < 0 then
				State.counters.stateBad += 1
				return
			end
		elseif tag == Control.ANIM or tag == Control.ANIMSNAP or tag == Control.ANIMID then
			if tag == Control.ANIM then
				pos = readAnim(b, pos, n)
			elseif tag == Control.ANIMSNAP then
				pos = readSnap(b, pos, n)
			else
				pos = readAnimId(b, pos, n)
			end
			if pos < 0 then
				State.counters.animBad += 1
				return
			end
		else
			warn(`Tide: unknown control tag {tag}`)
			return
		end
	end
end

-- Streaming: a model can arrive before its root part, and a root can stream out
-- and back in as a new part. Re-resolve missing / detached roots now and then
-- (anchoring the new one), so Render never keeps writing to a detached part.
local function checkRoots(dt: number)
	rootAcc += dt
	if rootAcc < ROOT_CHECK then
		return
	end
	rootAcc = 0
	local rebind = State.rebindStreamed
	for k = 1, State.count do
		local slot = State.active[k]
		local model = State.model[slot]
		if rebind then
			if model ~= nil and model.Parent == nil then
				dropModel(slot)
				model = nil
			elseif model == nil then
				local lost = State.lost[slot]
				if lost ~= nil and lost.Parent ~= nil then
					attachModel(slot, lost) -- it came back as the same instance
					model = lost
				end
			end
		end
		local root = State.root[slot]
		if model ~= nil and (root == nil or root.Parent == nil) then
			if root ~= nil then
				State.root[slot] = nil
				State.anchoredBefore[slot] = nil -- that part is gone
			end
			local found = Rig.root(model)
			if found ~= nil and found.Parent ~= nil then
				State.root[slot] = found
				if not State.mine[slot] then
					anchorIfDriven(slot)
				end
			end
		end
	end
end

-- Ask again for models that arrived as nil (not streamed in yet).
local function retryModels(dt: number)
	retryAcc += dt
	if retryAcc < Config.ModelRetry then
		return
	end
	retryAcc = 0
	local w: Control.Writer? = nil
	local count = 0
	for k = 1, State.count do
		local slot = State.active[k]
		if State.model[slot] == nil and count < 64 then
			if w == nil then
				w = Control.writer(140)
			end
			count += 1
		end
	end
	if w == nil then
		return
	end
	Control.u8(w, Control.RESEND)
	Control.u8(w, count)
	local written = 0
	for k = 1, State.count do
		local slot = State.active[k]
		if State.model[slot] == nil and written < count then
			Control.u16(w, slot)
			written += 1
		end
	end
	local b = Control.take(w)
	remoteR:FireServer(b)
	local lh = LH.api
	if lh then
		lh.net("Tide", "Control", "out", buffer.len(b))
	end
end

--------------------------------------------------------------------------------
-- Frame hooks
--------------------------------------------------------------------------------

local lastRender = 0
local lastBeat = 0

local function onPreRender(dt: number)
	local t = now()
	local step = t - lastRender
	if lastRender == 0 or step < 0 or step > 1 then
		step = dt
	end
	lastRender = t
	local lh = LH.api
	if lh then
		LH.render:begin()
	end
	Render.step(t, step)
	AnimPlay.step(t, step)
	StateApply.step(t)
	if lh then
		LH.render:finish()
	end
end

local function onHeartbeat(dt: number)
	local t = now()
	local step = t - lastBeat
	if lastBeat == 0 or step < 0 or step > 1 then
		step = dt
	end
	lastBeat = t
	local lh = LH.frame()
	if lh then
		LH.upload:begin()
	end
	Upload.step(t)
	AnimOwner.step(t, step)
	if lh then
		LH.upload:finish()
	end
	retryModels(step)
	checkRoots(step)
end

local function onRelay(payload: any)
	local lh = LH.api
	if lh then
		if typeof(payload) == "buffer" then
			lh.net("Tide", "Relay", "in", buffer.len(payload))
		end
		LH.receive:begin()
	end
	local ok = pcall(Receive.packet, payload, now())
	if lh then
		LH.receive:finish()
	end
	if not ok then
		State.counters.badPacket += 1
	end
end

local function onControl(payload: any, insts: any)
	local lh = LH.api
	if lh and typeof(payload) == "buffer" then
		lh.net("Tide", "Control", "in", buffer.len(payload))
	end
	local ok, err = pcall(handleControl, payload, insts)
	if not ok then
		State.counters.badPacket += 1
		warn("Tide: control message error: " .. tostring(err))
	end
end

function Client.start(opts: { [string]: any }?): boolean
	if State.started then
		return true
	end
	Options.apply(opts, {})
	State.started = true
	Interp.snapGap = Config.SnapGap
	Interp.velocityGap = Config.NeedGapMax
	local player = Players.LocalPlayer
	State.localUserId = if player then player.UserId else 0

	-- the server creates the remotes in its Tide.start(); never wait forever
	local parent = script.Parent.Parent
	local timeout = Config.startTimeout
	local deadline = os.clock() + timeout
	local u = parent:WaitForChild("TideU", timeout)
	local r = if u then parent:WaitForChild("TideR", math.max(0.001, deadline - os.clock())) else nil
	if u == nil or r == nil then
		warn(`Tide.start: the server's remotes did not appear within {timeout} s (is Tide.start() called on the server?)`)
		State.started = false
		return false
	end
	remoteU = u
	remoteR = r
	Upload.init(remoteU)
	AnimOwner.init(remoteR)
	if Config.animations and Config.animationsOwnerLocal then
		AnimOwner.ownerLocal = true
		AnimOwner.hookCharacters() -- swap at spawn, before game code loads tracks
	end
	remoteU.OnClientEvent:Connect(onRelay)
	remoteR.OnClientEvent:Connect(onControl)
	RunService.PreRender:Connect(onPreRender)
	RunService.Heartbeat:Connect(onHeartbeat)
	local w = Control.writer(4)
	Control.u8(w, Control.READY)
	remoteR:FireServer(Control.take(w))
	return true
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

local function slotOf(model: any): number?
	return State.bySlotModel[model]
end

-- CFrame Tide drew for this model this frame (nil if not drawn by Tide).
function Client.drawn(model: any): CFrame?
	local slot = slotOf(model)
	if slot == nil or not State.drawn[slot] then
		return nil
	end
	local cf = State.cf[slot]
	if cf ~= nil then
		return cf
	end
	return Rig.cframe(
		State.dX[slot],
		State.dY[slot],
		State.dZ[slot],
		State.dYaw[slot],
		State.ring[slot].full,
		State.dQX[slot],
		State.dQY[slot],
		State.dQZ[slot],
		State.dQW[slot]
	)
end

-- This client owns the entity (uploads it; Tide does not draw it).
function Client.isMine(model: any): boolean
	local slot = slotOf(model)
	return slot ~= nil and State.mine[slot] == true
end

function Client.owner(model: any): any
	local slot = slotOf(model)
	if slot == nil then
		return nil
	end
	return ownerPlayer(State.ownerId[slot])
end

function Client.delay(model: any): number
	local slot = slotOf(model)
	if slot == nil or State.mine[slot] then
		return 0
	end
	return State.delayOf(slot)
end

function Client.velocity(model: any): Vector3
	local slot = slotOf(model)
	if slot == nil or not State.drawn[slot] then
		return Vector3.new(0, 0, 0)
	end
	return Vector3.new(State.vX[slot], State.vY[slot], State.vZ[slot])
end

-- Newest received sample (no buffering delay).
function Client.latest(model: any): CFrame?
	local slot = slotOf(model)
	if slot == nil then
		return nil
	end
	local r = State.ring[slot]
	if r.n == 0 then
		return nil
	end
	local p = r.last % r.cap + 1
	local full = r.full
	return Rig.cframe(
		r.x[p],
		r.y[p],
		r.z[p],
		r.yaw[p],
		full,
		if full then r.qx[p] else 0,
		if full then r.qy[p] else 0,
		if full then r.qz[p] else 0,
		if full then r.qw[p] else 1
	)
end

-- Pose at an arbitrary server time from the client's ring (debug / lag tools).
function Client.at(model: any, t: number): CFrame?
	local slot = slotOf(model)
	if slot == nil then
		return nil
	end
	local r = State.ring[slot]
	local x, y, z, yaw, qx, qy, qz, qw, state = Interp.sample(r, t, 0)
	if state == Interp.STATE_EMPTY then
		return nil
	end
	return Rig.cframe(x, y, z, yaw, r.full, qx, qy, qz, qw)
end

-- Stream health of a remote entity, for lag displays and diagnostics:
--   newest    server time of the newest sample
--   count     samples received so far
--   buffered  samples held in the ring
--   age       now - newest (seconds)
--   delay     current interpolation delay (Tide.delay)
--   held      (now - delay) - newest: > 0 when drawing past the newest sample
--   interval  mean gap between recent moving samples (s), 0 if none
--   jitter    standard deviation of those gaps (s)
--   idle      the stream says the entity is at rest (newest sample repeats the
--             previous pose: stop sample / keep-alive). Gaps up to the kind's
--             keepAlive are then expected, not a stall.
-- Pass `into` to reuse a table (no allocation). nil for unknown entities, ones
-- this client owns, and before the first sample.
function Client.sampleInfo(model: any, into: { [string]: any }?): { [string]: any }?
	local slot = slotOf(model)
	if slot == nil or State.mine[slot] then
		return nil
	end
	local r = State.ring[slot]
	local n = r.n
	if n == 0 then
		return nil
	end
	local info = into or {}
	local cap = r.cap
	local last = r.last
	local ts, xs, ys, zs, yaws, fls = r.t, r.x, r.y, r.z, r.yaw, r.fl
	local p = last % cap + 1
	local t = now()
	local delay = State.delayOf(slot)
	local newest = ts[p]
	info.newest = newest
	info.count = last
	info.buffered = n
	info.age = t - newest
	info.delay = delay
	info.held = (t - delay) - newest

	local idle = false
	if n >= 2 and fls[p] % 2 == 0 then
		local q = (last - 1) % cap + 1
		idle = xs[p] == xs[q] and ys[p] == ys[q] and zs[p] == zs[q] and yaws[p] == yaws[q]
		if idle and r.full then
			idle = r.qx[p] == r.qx[q] and r.qy[p] == r.qy[q] and r.qz[p] == r.qz[q] and r.qw[p] == r.qw[q]
		end
	end
	info.idle = idle

	-- gaps between recent moving samples (idle and keep-alive gaps are left out)
	local maxGap = Config.NeedGapMax
	local sum, sum2, k = 0, 0, 0
	local oldest = last - n + 1
	local i = last
	while i > oldest and k < 16 do
		local a = i % cap + 1
		local b = (i - 1) % cap + 1
		local gap = ts[a] - ts[b]
		if gap > 0 and gap < maxGap and fls[a] % 2 == 0 then
			sum += gap
			sum2 += gap * gap
			k += 1
		end
		i -= 1
	end
	if k > 0 then
		local mean = sum / k
		info.interval = mean
		local var = sum2 / k - mean * mean
		info.jitter = if var > 0 then math.sqrt(var) else 0
	else
		info.interval = 0
		info.jitter = 0
	end
	return info
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

-- Own entities: what the watched Animator plays. Remote ones: what Tide plays
-- for them at their render time. nil when the entity is not animated by Tide.
function Client.playing(model: any): { [string]: any }?
	local slot = slotOf(model)
	if slot == nil or not State.animations then
		return nil
	end
	if State.mine[slot] then
		local w = AnimOwner.watchOf(slot)
		return if w ~= nil then AnimWatch.describe(w, AnimRegistry.name) else nil
	end
	return AnimPlay.playing(slot, now())
end

-- Entities this client owns: plays on the entity's Animator with an exact fade.
function Client.play(model: any, animation: any, fade: number?, weight: number?, speed: number?): any
	local anim = animationOf(animation)
	local slot = slotOf(model)
	if slot == nil or not State.mine[slot] then
		return nil
	end
	local animator = AnimOwner.animatorOf(slot)
	if animator == nil then
		return nil
	end
	return AnimWatch.play(animator, anim, fade, weight, speed)
end

function Client.stop(model: any, animation: any, fade: number?)
	local anim = animationOf(animation)
	local slot = slotOf(model)
	if slot == nil or not State.mine[slot] then
		return
	end
	local animator = AnimOwner.animatorOf(slot)
	if animator ~= nil then
		AnimWatch.stop(animator, anim, fade)
	end
end

--------------------------------------------------------------------------------
-- Timeline state
--------------------------------------------------------------------------------

-- Tide.state on a client: only compared with the server's (which is the one used).
function Client.state(kindName: string, fields: { [string]: any })
	StateSchema.define(kindName, fields)
end

-- Value as drawn: applied when this client's clock for the entity reached its stamp.
function Client.get(model: any, field: string): (any, any)
	local slot = slotOf(model)
	if slot == nil then
		return nil, nil
	end
	return StateApply.get(slot, field)
end

-- Newest received value (may be ahead of the drawing) and its stamp.
function Client.peek(model: any, field: string): (any, number?)
	local slot = slotOf(model)
	if slot == nil then
		return nil, nil
	end
	return StateApply.peek(slot, field)
end

-- Server time this entity is drawn at (its state applies at this clock). Compare "until"
-- times against it instead of GetServerTimeNow().
function Client.timeOf(model: any): number
	local t = now()
	local slot = slotOf(model)
	if slot == nil then
		return t
	end
	return StateApply.timeOf(slot, t)
end

-- Supplies the clock for an entity whose drawing game code owns (fn(now) -> server time).
function Client.clock(model: any, fn: ((now: number) -> number)?)
	assert(model ~= nil, "Tide.clock: model expected")
	assert(fn == nil or type(fn) == "function", "Tide.clock: fn must be a function or nil")
	StateApply.clocks[model] = fn
end

function Client.stats(): { [string]: number }
	return table.clone(State.counters)
end

return Client
