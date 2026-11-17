--!strict
-- Animation channel, owner side (client): watches the Animator of every entity
-- this client owns (Shared/AnimWatch) and sends the events to the server on
-- "TideR" once per Heartbeat:
--   20 ANIM     f64 baseTime, u8 count (<= MAX_BATCH), count x event (u16 slot)
--   22 REGISTER u8 length, AnimationId     (once per unknown AnimationId; length 0 = every id)
-- Owner-local Animator (Config.animationsOwnerLocal): the local character's
-- server-created Animator is swapped for a client-created one, which Roblox does
-- not replicate, so its tracks stop costing bytes (receivers play Tide's events).
-- The swap only happens while nothing plays on the old Animator yet (at spawn):
-- game code that already uses it keeps it, and Roblox keeps replicating it.

local Players = game:GetService("Players")

local Shared = script.Parent.Parent.Shared
local Control = require(Shared.Control)
local AnimCodec = require(Shared.AnimCodec)
local AnimRegistry = require(Shared.AnimRegistry)
local AnimWatch = require(Shared.AnimWatch)
local State = require(script.Parent.State)

local AnimOwner = {}

AnimOwner.active = false
AnimOwner.ownerLocal = false

local MAX_BATCH = 64
local MAX_SEND = 6000 -- bytes per remote call (the server takes control buffers up to 8 KB)
local WATCH_STEP = 1 / 60
local CHECK_EVERY = 0.25

local qDt = AnimCodec.qDt
local active = State.active
local mine = State.mine
local models = State.model
local kinds = State.kind
local counters = State.counters

local remote: any = nil
local up = Control.writer(256)
local countPos = -1
local batch = 0
local baseT = 0
local watches = {} :: { [number]: AnimWatch.Watch }
local requested = {} :: { [string]: boolean }
local swapped = setmetatable({} :: { [any]: any }, { __mode = "k" }) -- character -> its Animator after the swap
local ours = setmetatable({} :: { [any]: boolean }, { __mode = "k" })
local charConn: any = nil
local watchAcc = 0
local checkAcc = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function flush()
	if up.pos == 0 then
		return
	end
	remote:FireServer(Control.take(up))
	up.pos = 0
	countPos = -1
	batch = 0
end

local function resolveClient(s: string): number
	local id = AnimRegistry.id(s)
	if id ~= nil then
		return id
	end
	if s == "" or #s > 255 then
		return 0
	end
	if not requested[s] then
		requested[s] = true
		if up.pos > MAX_SEND then
			flush()
		end
		Control.u8(up, Control.REGISTER)
		Control.str(up, s)
		countPos = -1 -- the next event opens a new ANIM message
	end
	return 0
end

local function sinkClient(
	slot: number,
	t: number,
	op: number,
	id: number,
	fade: number,
	weight: number,
	speed: number,
	timePos: number,
	prio: number,
	looped: boolean
)
	if up.pos > MAX_SEND then
		flush()
	end
	if countPos < 0 or batch >= MAX_BATCH then
		Control.u8(up, Control.ANIM_UP)
		Control.f64(up, t)
		baseT = t
		countPos = up.pos
		Control.u8(up, 0)
		batch = 0
	end
	AnimCodec.write(up, slot, qDt(t - baseT), op, id, fade, weight, speed, timePos, prio, looped)
	batch += 1
	buffer.writeu8(up.b, countPos, batch)
	counters.animSent += 1
end

function AnimOwner.init(remoteR: any)
	remote = remoteR
	AnimWatch.configure(now, resolveClient, sinkClient)
end

-- The registry from the hello did not match this client's folder: ask for every id.
function AnimOwner.requestTable()
	Control.u8(up, Control.REGISTER)
	Control.u8(up, 0)
	countPos = -1
end

local function detach(slot: number)
	local w = watches[slot]
	if w ~= nil then
		AnimWatch.stopWatching(w)
		watches[slot] = nil
	end
end

local function attach(slot: number)
	local animator = AnimWatch.animator(models[slot])
	if animator ~= nil then
		watches[slot] = AnimWatch.new(slot, animator)
	end
end

-- Swaps the character's replicated Animator for a client-created one (see the header).
local function swap(character: any)
	if character == nil or swapped[character] ~= nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return -- tried again when Tide (re)adds the character
	end
	local old = humanoid:FindFirstChildOfClass("Animator")
	if old ~= nil then
		if ours[old] then
			swapped[character] = old
			return
		end
		if #old:GetPlayingAnimationTracks() > 0 then
			-- game code already plays on it: leave it (Roblox keeps replicating its tracks)
			swapped[character] = old
			counters.animSwapSkipped += 1
			return
		end
	end
	local animator = Instance.new("Animator")
	ours[animator] = true
	animator.Parent = humanoid
	if old ~= nil then
		old:Destroy()
	end
	swapped[character] = animator
	counters.animSwapped += 1
end

-- Early swap at spawn: when this client's own Config says animations are on
-- (Tide.start({ animations = true }) on the client), before game code loads tracks.
function AnimOwner.hookCharacters()
	if charConn ~= nil then
		return
	end
	local player = Players.LocalPlayer
	if player == nil then
		return
	end
	charConn = player.CharacterAdded:Connect(function(character)
		pcall(swap, character)
	end)
	if player.Character ~= nil then
		pcall(swap, player.Character)
	end
end

-- The server's hello: animations off, or owner-local off. Stops the early swap at
-- spawn (an Animator swapped already stays; Roblox does not replicate its tracks).
function AnimOwner.unhook()
	AnimOwner.ownerLocal = false
	if charConn ~= nil then
		charConn:Disconnect()
		charConn = nil
	end
end

-- (Re)decides whether an entity is watched here: ours, animated kind, model in.
function AnimOwner.update(slot: number)
	local kind = kinds[slot]
	local want = AnimOwner.active
		and State.index[slot] ~= nil
		and mine[slot]
		and kind ~= nil
		and kind.animations ~= false
		and models[slot] ~= nil
	if not want then
		detach(slot)
		return
	end
	if AnimOwner.ownerLocal and kind.name == "Player" then
		pcall(swap, models[slot])
	end
	local w = watches[slot]
	if w ~= nil and w.animator.Parent ~= nil and w.animator == AnimWatch.animator(models[slot]) then
		return
	end
	detach(slot)
	attach(slot)
end

function AnimOwner.detach(slot: number)
	detach(slot)
end

-- Heartbeat: watch at 60 Hz at most, re-attach to replaced Animators, send.
function AnimOwner.step(t: number, dt: number)
	if not AnimOwner.active then
		return
	end
	checkAcc += dt
	if checkAcc >= CHECK_EVERY then
		checkAcc = 0
		for k = 1, State.count do
			local slot = active[k]
			if mine[slot] then
				local w = watches[slot]
				if w == nil or w.animator.Parent == nil then
					AnimOwner.update(slot)
				end
			end
		end
	end
	watchAcc += dt
	if watchAcc >= WATCH_STEP * 0.9 then
		watchAcc = 0
		for _, w in watches do
			AnimWatch.step(w, t)
		end
	end
	flush()
end

function AnimOwner.watchOf(slot: number): AnimWatch.Watch?
	return watches[slot]
end

-- Tide.play / Tide.stop on an entity this client owns.
function AnimOwner.animatorOf(slot: number): any
	local w = watches[slot]
	if w ~= nil and w.animator.Parent ~= nil then
		return w.animator
	end
	return AnimWatch.animator(models[slot])
end

return AnimOwner
