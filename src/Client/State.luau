--!strict
-- Client entity state, struct-of-arrays indexed by slot.

local State = {}

State.started = false
State.helloed = false
State.localUserId = 0
State.lockPlayers = true

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
	uploads = 0,
	uploadBytes = 0,
	uploadSkipped = 0, -- unchanged samples not uploaded (idle)
	applyErrors = 0,
}

return State
