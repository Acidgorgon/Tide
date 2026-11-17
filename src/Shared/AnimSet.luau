--!strict
-- What one entity is playing, as of its newest animation event: the server keeps
-- one per entity (snapshots, Tide.playing), receivers keep one per remote entity
-- (state to apply when the model or its Animator arrives late). Entry tables are
-- reused; at most CAP entries (the oldest goes first).

local AnimCodec = require(script.Parent.AnimCodec)

local PLAY, STOP, SPEED, WEIGHT, SEEK, PRIORITY =
	AnimCodec.PLAY, AnimCodec.STOP, AnimCodec.SPEED, AnimCodec.WEIGHT, AnimCodec.SEEK, AnimCodec.PRIORITY

export type Entry = {
	id: number,
	start: number, -- server time of the PLAY
	t0: number, -- server time timePos refers to
	tp: number, -- time position at t0 (seconds, not wrapped)
	speed: number,
	weight: number,
	fade: number,
	prio: number,
	looped: boolean,
	stopT: number, -- fully faded out at this time (inf = playing)
}

export type Set = { n: number, e: { Entry } }

local AnimSet = {}

AnimSet.CAP = 16

local INF = math.huge

function AnimSet.new(): Set
	return { n = 0, e = {} }
end

function AnimSet.clear(set: Set)
	set.n = 0
end

local function find(set: Set, id: number): number
	local e = set.e
	for i = 1, set.n do
		if e[i].id == id then
			return i
		end
	end
	return 0
end
AnimSet.find = find

local function removeAt(set: Set, i: number)
	local e = set.e
	local n = set.n
	local gone = e[i]
	e[i] = e[n]
	e[n] = gone -- kept for reuse
	set.n = n - 1
end

-- Time position of an entry at server time t (not wrapped).
function AnimSet.timeAt(entry: Entry, t: number): number
	return entry.tp + (t - entry.t0) * entry.speed
end

-- Applies one event. Ops other than PLAY on an id that is not playing are ignored.
function AnimSet.apply(
	set: Set,
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
	local i = find(set, id)
	if op == PLAY then
		local entry
		if i == 0 then
			if set.n >= AnimSet.CAP then
				-- drop the oldest (fading-out entries first)
				local oldest, oldestT, oldestStop = 1, INF, false
				for k = 1, set.n do
					local c = set.e[k]
					local stopping = c.stopT < INF
					if (stopping and not oldestStop) or (stopping == oldestStop and c.t0 < oldestT) then
						oldest, oldestT, oldestStop = k, c.t0, stopping
					end
				end
				removeAt(set, oldest)
			end
			local n = set.n + 1
			set.n = n
			entry = set.e[n]
			if entry == nil then
				entry = { id = 0, start = 0, t0 = 0, tp = 0, speed = 1, weight = 1, fade = 0, prio = 0, looped = false, stopT = INF }
				set.e[n] = entry
			end
		else
			entry = set.e[i]
		end
		entry.id = id
		entry.start = t
		entry.t0 = t
		entry.tp = timePos
		entry.speed = speed
		entry.weight = weight
		entry.fade = fade
		entry.prio = prio
		entry.looped = looped
		entry.stopT = INF
		return
	end
	if i == 0 then
		return
	end
	local entry = set.e[i]
	if op == STOP then
		entry.tp = AnimSet.timeAt(entry, t)
		entry.t0 = t
		if entry.stopT == INF then
			entry.stopT = t + fade
		end
	elseif op == SPEED then
		entry.tp = AnimSet.timeAt(entry, t)
		entry.t0 = t
		entry.speed = speed
	elseif op == WEIGHT then
		entry.weight = weight
	elseif op == SEEK then
		entry.tp = timePos
		entry.t0 = t
	elseif op == PRIORITY then
		entry.prio = prio
	end
end

-- Drops entries that finished fading out by `now`.
function AnimSet.prune(set: Set, now: number)
	local i = 1
	while i <= set.n do
		if set.e[i].stopT <= now then
			removeAt(set, i)
		else
			i += 1
		end
	end
end

-- Entries started by time t and not yet faded out, as Tide.playing info tables keyed by `nameOf(id)`.
function AnimSet.describe(set: Set, t: number, nameOf: (id: number) -> string): { [string]: any }
	local out = {}
	for i = 1, set.n do
		local entry = set.e[i]
		if entry.start <= t + 1e-6 and entry.stopT > t then
			local name = nameOf(entry.id)
			out[name] = {
				id = entry.id,
				name = name,
				since = entry.start,
				timePosition = AnimSet.timeAt(entry, t),
				speed = entry.speed,
				weight = entry.weight,
				fade = entry.fade,
				priority = AnimCodec.priority(entry.prio),
				looped = entry.looped,
				stopping = entry.stopT < INF, -- a STOP arrived; fading out until `stopT`
				stopT = if entry.stopT < INF then entry.stopT else nil,
			}
		end
	end
	return out
end

return AnimSet
