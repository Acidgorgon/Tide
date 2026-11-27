--!strict
-- Client entity state, struct-of-arrays indexed by slot.

local State = {}

State.started = false
State.helloed = false
State.localUserId = 0
State.lockPlayers = true
State.animations = false -- the server's Config.animations (hello)
State.animSeeded = false
State.ownerEase = false -- the server's Config.ownerEase (hello)
State.ownerStart = "drawn" -- the server's Config.ownerStart (hello)
State.rebindStreamed = false -- the server's Config.rebindStreamed (hello)

State.model = {} :: { [number]: any }
State.root = {} :: { [number]: any }
State.kind = {} :: { [number]: any }
State.ownerId = {} :: { [number]: number }
State.mine = {} :: { [number]: boolean }
State.ring = {} :: { [number]: any }
State.src = {} :: { [number]: any }
State.anchoredBefore = {} :: { [number]: boolean? }
State.pkt = {} :: { [number]: number } -- last packet id that measured this entity's need
State.dirtyFrom = {} :: { [number]: number } -- earliest time whose drawn path new samples may have changed (inf = none)
State.gapE = {} :: { [number]: number } -- expected sample gap (moving samples; kind-shared buffers measure need against it)
State.lag = {} :: { [number]: number } -- ownerEase: this entity's own delay while it eases to its source's (nil = the source's)
State.blendIn = {} :: { [number]: boolean } -- ownerEase: first draw after losing ownership blends from the local pose
State.ox = {} :: { [number]: number } -- the entity's own quantization origin (ORIGIN; nil = the hello's)
State.oy = {} :: { [number]: number }
State.oz = {} :: { [number]: number }
State.lost = {} :: { [number]: any } -- rebindStreamed: the model that streamed out (Parent nil), until a model is bound again

-- render
State.drawn = {} :: { [number]: boolean }
State.dX = {} :: { [number]: number }
State.dY = {} :: { [number]: number }
State.dZ = {} :: { [number]: number }
State.dYaw = {} :: { [number]: number }
State.dQX = {} :: { [number]: number }
State.dQY = {} :: { [number]: number }
State.dQZ = {} :: { [number]: number }
State.dQW = {} :: { [number]: number }
State.lastRT = {} :: { [number]: number }
State.offX = {} :: { [number]: number }
State.offY = {} :: { [number]: number }
State.offZ = {} :: { [number]: number }
State.offYaw = {} :: { [number]: number }
State.offT = {} :: { [number]: number }
State.vX = {} :: { [number]: number }
State.vY = {} :: { [number]: number }
State.vZ = {} :: { [number]: number }
State.cf = {} :: { [number]: any } -- CFrame applied this frame (apply = "cframe" / function)

-- upload (entities this client owns)
State.nextT = {} :: { [number]: number }
State.teleUntil = {} :: { [number]: number } -- uploads are flagged as teleports until this time
State.lastRec = {} :: { [number]: buffer } -- last uploaded record (redundancy, rest marker)
State.lastLen = {} :: { [number]: number } -- 0 = nothing uploaded yet
State.upStill = {} :: { [number]: boolean } -- a stop sample went out; unchanged samples are skipped
State.upHeldT = {} :: { [number]: number } -- newest skipped (unchanged) sample time, 0 = none
State.upSentT = {} :: { [number]: number } -- time of the last uploaded sample
State.upTickT = {} :: { [number]: number } -- time of the last sample taken (uploaded or skipped)
State.upX = {} :: { [number]: number } -- last uploaded pose, quantized
State.upY = {} :: { [number]: number }
State.upZ = {} :: { [number]: number }
State.upYaw = {} :: { [number]: number }
State.upQX = {} :: { [number]: number }
State.upQY = {} :: { [number]: number }
State.upQZ = {} :: { [number]: number }
State.upQW = {} :: { [number]: number }

-- active list
State.active = {} :: { number }
State.count = 0
State.index = {} :: { [number]: number }
State.bySlotModel = {} :: { [any]: number }
State.srcByKind = {} :: { [any]: any }

State.counters = {
	packets = 0,
	records = 0,
	badPacket = 0,
	unknownSlot = 0,
	late = 0,
	repeats = 0, -- records that were a copy of a sample already held (stop repeats, kind option restRepeats)
	uploads = 0,
	uploadBytes = 0,
	uploadSkipped = 0, -- unchanged samples not uploaded (idle)
	applyErrors = 0,
	velocityRecords = 0, -- records with velocity received (kinds with velocity = true, v0.5)
	-- animation channel
	animSent = 0, -- events this client sent for entities it owns
	animApplied = 0, -- events applied to remote entities
	animSnaps = 0, -- snapshots applied
	animIgnored = 0, -- events / snapshots for entities not animated here
	animOverflow = 0, -- events applied early because an entity's queue was full
	animDrift = 0, -- tracks put back on the render clock (delay changes)
	animUnknown = 0, -- ids with no AnimationId known yet
	animBad = 0, -- malformed animation messages
	animSwapped = 0, -- owner-local Animator swaps
	animSwapSkipped = 0, -- swaps skipped: game code already played on the Animator
	-- timeline state
	stateApplied = 0, -- changes applied
	stateLate = 0, -- changes that arrived after this client's clock for the entity passed their stamp
	stateStale = 0, -- changes older than the field's applied one (skipped)
	stateOverflow = 0, -- changes applied early because an entity's queue was full
	stateSnaps = 0, -- snapshots received
	stateBad = 0, -- malformed state messages
	stateClockErrors = 0, -- Tide.clock functions that errored or returned no number
	stateMirrorErrors = 0, -- mirror attributes that could not be set
	modelsLost = 0, -- rebindStreamed: models dropped because their Parent became nil (streamed out)
	modelsRebound = 0, -- rebindStreamed: entities bound to a model again after one was dropped
}

-- The delay an entity is drawn at (its source's, or its own while easing after an owner change).
function State.delayOf(slot: number): number
	local lag = State.lag[slot]
	if lag ~= nil then
		return lag
	end
	return State.src[slot].delay
end

return State
