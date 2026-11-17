--!strict
-- Server entity state, struct-of-arrays indexed by slot (u16, 1-based).

local State = {}

State.started = false

-- per slot
State.model = {} :: { [number]: any }
State.root = {} :: { [number]: any }
State.kind = {} :: { [number]: any }
State.owner = {} :: { [number]: any } -- Player, or false for server-owned
State.hist = {} :: { [number]: any } -- Ring
State.handle = {} :: { [number]: any }
State.relayed = {} :: { [number]: number } -- last history index already relayed
State.conn = {} :: { [number]: any } -- Destroying connection

-- server-owned sampler
State.sentT = {} :: { [number]: number } -- time of the last pushed sample
State.heldT = {} :: { [number]: number } -- newest unchanged tick not pushed (0 = none)
State.forceTele = {} :: { [number]: boolean } -- next sample carries the teleport flag

State.still = {} :: { [number]: boolean } -- a "stopped" sample (same pose twice) was pushed

-- pending server teleport of a client-owned entity (until the owner's flagged upload)
State.tpPending = {} :: { [number]: boolean }
State.tpX = {} :: { [number]: number }
State.tpY = {} :: { [number]: number }
State.tpZ = {} :: { [number]: number }
State.tpCF = {} :: { [number]: any }
State.tpSentT = {} :: { [number]: number }
State.tpTries = {} :: { [number]: number }
State.tpReported = {} :: { [number]: boolean } -- onSuspicious("teleportIgnored") already called
State.tpCount = 0 -- pending teleports (the retry loop is skipped when 0)
-- velocity given to the last teleport (used while the teleport sample is the newest)
State.tpVel = {} :: { [number]: Vector3? }
State.watch = {} :: { [number]: any } -- teleportOnWrite CFrame connection

-- upload validation (client-owned)
State.lastArr = {} :: { [number]: number } -- server time the last sample was accepted
State.stampBank = {} :: { [number]: number } -- seconds stamps may run ahead of arrivals (jitter credit)
State.slackH = {} :: { [number]: number } -- studs of horizontal speed tolerance left
State.slackV = {} :: { [number]: number } -- studs of vertical speed tolerance left
State.speedSince = {} :: { [number]: number? } -- first speed rejection since the last accepted sample

-- lock
State.locker = {} :: { [number]: any }
State.weld = {} :: { [number]: any }

-- active list
State.active = {} :: { number }
State.count = 0
State.index = {} :: { [number]: number } -- slot -> position in active
State.freedAt = {} :: { [number]: number }
State.maxSlot = 0 -- highest slot ever handed out

State.bySlotModel = {} :: { [any]: number } -- model -> slot
State.charSlot = {} :: { [any]: number } -- player -> slot of their Player-kind entity

-- receivers (players)
State.rx = {} :: { [any]: any } -- player -> receiver record
State.rxList = {} :: { any } -- ready receivers

State.counters = {
	packets = 0,
	samples = 0,
	badPacket = 0,
	owner = 0,
	stamp = 0,
	nan = 0,
	speed = 0,
	rate = 0,
	errors = 0,
	relayBytes = 0,
	relayPackets = 0,
	budgetDropped = 0,
	spacing = 0, -- uploaded samples closer than half an upload interval to the previous one
	teleportWait = 0, -- owner uploads dropped while a server teleport is unacknowledged
	teleportIgnored = 0,
	inBytes = 0, -- payload bytes received from clients (both remotes, accepted or not)
	inBytesPerSecond = 0, -- over the last full second
	relayBytesPerSecond = 0,
	-- animation channel (Config.animations)
	animEvents = 0, -- events accepted (owner uploads and server-watched bots)
	animBad = 0, -- malformed animation messages
	animRate = 0, -- events over Config.AnimEventsPerSecond
	animOwner = 0, -- events for entities the sender does not own
	animStamp = 0, -- events stamped before the entity's previous event
	animUnknown = 0, -- events with an unknown id or priority
	animDropped = 0, -- events for kinds with animations = false
	animRegister = 0, -- REGISTER requests refused (invalid string, per-player cap)
	animIdsFull = 0, -- ids refused at Config.MaxAnimIds
	animRelayBytes = 0, -- animation bytes sent to clients
}

State.onSuspicious = nil :: ((player: any, reason: string) -> ())?
-- Set by Server: teleports the owner back to the server's pose (persistent speed rejections).
State.onResync = nil :: ((slot: number) -> ())?

-- Hook calls are rate limited per player (counters are not).
local HOOK_PER_SECOND = 4
local hookBudget = {} :: { [any]: number }
local hookT = {} :: { [any]: number }
State.hookBudget = hookBudget
State.hookT = hookT

-- Counts are kept by the caller; this only runs the user hook.
function State.suspicious(player: any, reason: string)
	local hook = State.onSuspicious
	if hook == nil then
		return
	end
	local now = os.clock()
	local budget = (hookBudget[player] or HOOK_PER_SECOND) + (now - (hookT[player] or now)) * HOOK_PER_SECOND
	if budget > HOOK_PER_SECOND then
		budget = HOOK_PER_SECOND
	end
	hookT[player] = now
	if budget < 1 then
		hookBudget[player] = budget
		return
	end
	hookBudget[player] = budget - 1
	task.spawn(hook, player, reason)
end

-- Ends a pending teleport (acknowledged, entity removed, owner changed).
function State.endTeleport(slot: number)
	if State.tpPending[slot] then
		State.tpPending[slot] = nil
		State.tpCount -= 1
	end
	State.tpCF[slot] = nil
	State.tpReported[slot] = nil
end

function State.forget(player: any)
	hookBudget[player] = nil
	hookT[player] = nil
end

return State
