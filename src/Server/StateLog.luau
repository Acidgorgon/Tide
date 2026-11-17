--!strict
-- Timeline state, server side (v0.3; on for kinds with a schema, see Shared/StateSchema):
--   * Tide.set / Tide.fire stamp each change with server time (now, or a given stamp clamped to
--     [now - MaxBackdate, now]) on the 0.5 ms grid, keep the current value per field and a
--     history ring per field (Config.StateHistory changes; evicted values become the ring's
--     base) for Tide.stateAt;
--   * once per frame the frame's changes are encoded once into groups (same entity, stamp and
--     audience) and each receiver gets the groups it may see (`to`, not culled) in the same
--     reliable message as the frame's animation events;
--   * a receiver that starts getting an entity (late join, back inside its cull range, owner
--     change for owner/others fields) gets a snapshot: the values in effect Config.StateReplay
--     ago, then every change after that it has not received, so it lands on the same timeline.
--     Missed changes are tracked by flush number, so nothing is sent twice;
--   * refs to an entity that goes are set to nil.
-- Clients never send state: tags 30-32 from a client are counted and dropped (Server).
-- Steady state (sets of bool / number / time / ref fields, flush, no listeners) allocates nothing.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Control = require(Shared.Control)
local Kinds = require(Shared.Kinds)
local Signal = require(Shared.Signal)
local StateSchema = require(Shared.StateSchema)
local State = require(script.Parent.State)

type Field = StateSchema.Field
type Schema = StateSchema.Schema
type Ring = {
	t: { number },
	v: { any },
	fq: { number }, -- flush number the change went out in
	sq: { number }, -- global set order (stable merges across fields)
	cap: number,
	last: number,
	n: number,
	base: any, -- value of the newest evicted change
	baseT: number, -- its stamp (-inf: nothing evicted)
	evictFq: number, -- newest flush number among evicted changes
}

local StateLog = {}

StateLog.changedSignal = Signal.new()
-- model -> field name -> Signal (Tide.changed)
local fieldSignals = setmetatable({} :: { [any]: { [string]: Signal.Signal } }, { __mode = "k" })
StateLog.fieldSignals = fieldSignals

local TICK = StateSchema.TICK
local INF = math.huge
local REF = StateSchema.CODES.ref
local TIME = StateSchema.CODES.time
local TO_ALL, TO_OWNER, TO_OTHERS, TO_SERVER =
	StateSchema.TO_ALL, StateSchema.TO_OWNER, StateSchema.TO_OTHERS, StateSchema.TO_SERVER

local round = math.round
local ensure = Control.ensure
local writeValue = StateSchema.writeValue

local owner = State.owner
local index = State.index
local active = State.active
local models = State.model
local bySlotModel = State.bySlotModel
local counters = State.counters

local schemaOf = {} :: { [number]: Schema }
local cur = {} :: { [number]: { [number]: any } }
local curT = {} :: { [number]: { [number]: number } }
local rings = {} :: { [number]: { [number]: Ring } }
local gen = {} :: { [number]: number }
local hasState = {} :: { [number]: boolean }

StateLog.flushNo = 1
local seq = 0

-- this frame's changes
local CH = 256
local chSlot = table.create(CH, 0) :: { number }
local chGen = table.create(CH, 0) :: { number }
local chT = table.create(CH, 0) :: { number }
local chF = table.create(CH, false) :: { any }
local chV = table.create(CH, false) :: { any }
local nch = 0
local snapsPending = false

-- encoded groups (StateLog.prepare)
local enc = Control.writer(1024)
local gStart = table.create(64, 0) :: { number }
local gEnd = table.create(64, 0) :: { number }
local gSlot = table.create(64, 0) :: { number }
local gAud = table.create(64, 0) :: { number }
local ng = 0
local base = 0

-- snapshot replay scratch
local repT = table.create(64, 0) :: { number }
local repSq = table.create(64, 0) :: { number }
local repF = table.create(64, false) :: { any }
local repV = table.create(64, false) :: { any }

local function now(): number
	return workspace:GetServerTimeNow()
end

local function quantize(t: number): number
	return round(t / TICK) * TICK
end

-- A change's stamp: on the grid and never after t (a stamp rounded up into the future would be
-- missing from stateAt / changedAt at now right after the set).
local function stampOn(t: number): number
	local k = round(t / TICK)
	local s = k * TICK
	if s > t then
		if s - t < 1e-7 then
			return t -- t is on the grid (float noise)
		end
		s = (k - 1) * TICK
	end
	return s
end

--------------------------------------------------------------------------------
-- History rings
--------------------------------------------------------------------------------

local function newRing(cap: number): Ring
	return {
		t = table.create(cap, 0),
		v = table.create(cap, false),
		fq = table.create(cap, 0),
		sq = table.create(cap, 0),
		cap = cap,
		last = 0,
		n = 0,
		base = nil,
		baseT = -INF,
		evictFq = -1,
	}
end

-- Inserts a change in stamp order (after changes with the same stamp). When full, the oldest
-- change becomes the base. A change older than everything kept in a full ring becomes the base
-- itself (or is dropped when older than the base).
local function insert(r: Ring, t: number, v: any, fq: number, sq: number)
	local cap = r.cap
	local ts = r.t
	local last = r.last
	local first = last - r.n + 1
	local k = last + 1
	while k > first and ts[(k - 2) % cap + 1] > t do
		k -= 1
	end
	if r.n == cap then
		if k == first then
			if t >= r.baseT then
				r.base = v
				r.baseT = t
			end
			if fq > r.evictFq then
				r.evictFq = fq
			end
			return
		end
		local p0 = (first - 1) % cap + 1
		r.base = r.v[p0]
		r.baseT = ts[p0]
		if r.fq[p0] > r.evictFq then
			r.evictFq = r.fq[p0]
		end
		r.n -= 1
	end
	local vs, fqs, sqs = r.v, r.fq, r.sq
	for i = last, k, -1 do
		local src = (i - 1) % cap + 1
		local dst = i % cap + 1
		ts[dst] = ts[src]
		vs[dst] = vs[src]
		fqs[dst] = fqs[src]
		sqs[dst] = sqs[src]
	end
	local p = (k - 1) % cap + 1
	ts[p] = t
	vs[p] = v
	fqs[p] = fq
	sqs[p] = sq
	r.last = last + 1
	r.n += 1
end

-- Value in effect at t (the newest change stamped <= t).
local function valueAt(r: Ring, f: Field, t: number): any
	local cap = r.cap
	local ts = r.t
	for i = r.last, r.last - r.n + 1, -1 do
		local p = (i - 1) % cap + 1
		if ts[p] <= t then
			return r.v[p]
		end
	end
	if r.baseT > -INF then
		return r.base
	end
	return f.default
end

--------------------------------------------------------------------------------
-- Entities
--------------------------------------------------------------------------------

-- Ref values are models; a ref to an entity that is gone reads nil.
local function live(f: Field, v: any): any
	if f.code == REF and v ~= nil and bySlotModel[v] == nil then
		return nil
	end
	return v
end

function StateLog.onAdd(slot: number)
	gen[slot] = (gen[slot] or 0) + 1
	local kind = State.kind[slot]
	local s = StateSchema.byKind[kind.name]
	hasState[slot] = false
	if s == nil then
		schemaOf[slot] = nil
		cur[slot] = nil
		curT[slot] = nil
		rings[slot] = nil
		return
	end
	schemaOf[slot] = s
	local c = {}
	for _, f in s.fields do
		c[f.id] = f.default
	end
	cur[slot] = c
	curT[slot] = {}
	rings[slot] = {}
end

-- A kind's schema may be (re)declared while none of its entities has state yet.
function StateLog.checkDeclare(kindName: string)
	for k = 1, State.count do
		local slot = active[k]
		if State.kind[slot].name == kindName and hasState[slot] then
			error(`Tide.state("{kindName}"): entities of this kind already have state`, 4)
		end
	end
end

-- A schema was declared (or replaced) after entities of its kind were added.
function StateLog.attach(kindName: string)
	for k = 1, State.count do
		local slot = active[k]
		if State.kind[slot].name == kindName then
			local g = gen[slot]
			StateLog.onAdd(slot)
			gen[slot] = g
		end
	end
end

local record: (slot: number, f: Field, t: number, value: any) -> ()

function StateLog.onRemove(slot: number, model: any)
	schemaOf[slot] = nil
	cur[slot] = nil
	curT[slot] = nil
	rings[slot] = nil
	hasState[slot] = false
	for _, rx in State.rxList do
		local miss = rx.stateMiss
		if miss then
			miss[1][slot] = nil
			miss[2][slot] = nil
			miss[3][slot] = nil
		end
	end
	-- refs to it become nil
	local t = -1
	for k = 1, State.count do
		local s = active[k]
		local sch = schemaOf[s]
		if sch ~= nil and #sch.refs > 0 then
			local c = cur[s]
			for _, f in sch.refs do
				if c[f.id] == model then
					if t < 0 then
						t = stampOn(now())
					end
					record(s, f, t, nil)
				end
			end
		end
	end
end

-- What each receiver gets of each entity, per audience class (1 all-fields, 2 owner-fields,
-- 3 others-fields): rx.stateMiss[class][slot] = the flush number from which it has not been
-- getting that class (nil: getting it). A receiver gets a class when the class is visible to it
-- (ownership) and the entity is not culled for it (an owner is never culled from its own
-- entity's state: Relay keeps an owner's tier as it was). When a class starts again, a snapshot
-- brings exactly the changes missed since then; nothing it already got is sent twice.
local function missOf(rx: any): { { [number]: number } }
	local miss = rx.stateMiss
	if miss == nil then
		miss = { {}, {}, {} }
		rx.stateMiss = miss
	end
	return miss
end

local function queueSnap(rx: any, slot: number, class: number, since: number)
	local slots = rx.snapSlot
	if slots == nil then
		slots = {}
		rx.snapSlot = slots
		rx.snapSince = { {}, {}, {} }
		rx.snapN = 0
	end
	local ss = rx.snapSince
	local n = rx.snapN
	local at = 0
	for i = 1, n do
		if slots[i] == slot then
			at = i
			break
		end
	end
	if at == 0 then
		n += 1
		rx.snapN = n
		slots[n] = slot
		ss[1][n], ss[2][n], ss[3][n] = INF, INF, INF
		at = n
	end
	if since < ss[class][at] then
		ss[class][at] = since
	end
	snapsPending = true
end

-- A class stops: a snapshot still queued for it (not written yet) carries over.
local function unqueue(rx: any, slot: number, class: number): number?
	local slots = rx.snapSlot
	if slots == nil then
		return nil
	end
	for i = 1, rx.snapN do
		if slots[i] == slot then
			local since = rx.snapSince[class][i]
			rx.snapSince[class][i] = INF
			return if since < INF then since else nil
		end
	end
	return nil
end

-- Brings what a receiver gets of an entity up to date (tier and owner as they are now).
local function sync(rx: any, slot: number)
	local miss = missOf(rx)
	local isOwner = owner[slot] == rx.player
	local culled = not isOwner and rx.tier[slot] == 4
	for class = 1, 3 do
		local gets = not culled and (class == 1 or (class == 2) == isOwner)
		local m = miss[class]
		local since = m[slot]
		if gets then
			if since ~= nil then
				m[slot] = nil
				if schemaOf[slot] ~= nil and hasState[slot] then
					queueSnap(rx, slot, class, since)
				end
			end
		elseif since == nil then
			m[slot] = unqueue(rx, slot, class) or StateLog.flushNo
		end
	end
end

-- A new entity: each ready receiver starts getting what it may see of it.
function StateLog.onAddRx(slot: number)
	for _, rx in State.rxList do
		local miss = missOf(rx)
		miss[1][slot], miss[2][slot], miss[3][slot] = nil, nil, nil
		sync(rx, slot)
	end
end

-- A receiver became ready (tiers known): it has missed everything so far.
function StateLog.onReady(rx: any)
	local miss = missOf(rx)
	for k = 1, State.count do
		local slot = active[k]
		miss[1][slot], miss[2][slot], miss[3][slot] = 0, 0, 0
		sync(rx, slot)
	end
end

-- Relay hooks: a receiver stops / starts getting an entity (cull range).
function StateLog.onLeave(rx: any, slot: number)
	sync(rx, slot)
end

function StateLog.onEnter(rx: any, slot: number)
	sync(rx, slot)
end

-- Owner changed: owner-fields become visible to the new owner, others-fields to the old one.
function StateLog.onOwner(slot: number, old: any)
	local new = owner[slot]
	if new then
		local rx = State.rx[new]
		if rx and rx.ready then
			sync(rx, slot)
		end
	end
	if old and old ~= new then
		local rx = State.rx[old]
		if rx and rx.ready then
			sync(rx, slot)
		end
	end
end

--------------------------------------------------------------------------------
-- Changes
--------------------------------------------------------------------------------

local function fireSignals(slot: number, f: Field, value: any, old: any, t: number)
	local model = models[slot]
	local general = StateLog.changedSignal
	if #general.fns > 0 then
		Signal.fire(general, model, f.name, live(f, value), live(f, old), t)
	end
	local byField = fieldSignals[model]
	if byField ~= nil then
		local sig = byField[f.name]
		if sig ~= nil and #sig.fns > 0 then
			Signal.fire(sig, live(f, value), live(f, old), t)
		end
	end
end

record = function(slot: number, f: Field, t: number, value: any)
	local id = f.id
	local c = cur[slot]
	local ct = curT[slot]
	local lastT = ct[id] or -INF
	if not f.event and t >= lastT and c[id] == value then
		counters.stateSame += 1
		return
	end
	local ringsOf = rings[slot]
	local r = ringsOf[id]
	if r == nil then
		r = newRing(if f.history > 0 then f.history else math.max(1, Config.StateHistory))
		ringsOf[id] = r
	end
	seq += 1
	insert(r, t, value, StateLog.flushNo, seq)
	hasState[slot] = true
	counters.stateSets += 1
	local old = c[id]
	if t >= lastT then
		c[id] = value
		ct[id] = t
	end
	if f.to ~= TO_SERVER then
		nch += 1
		chSlot[nch] = slot
		chGen[nch] = gen[slot]
		chT[nch] = t
		chF[nch] = f
		chV[nch] = value
	end
	if t >= lastT or f.event then
		fireSignals(slot, f, value, if f.event then nil else old, t)
	end
end

local function stampFor(stamp: number?): number
	local t = now()
	if stamp ~= nil then
		if type(stamp) ~= "number" or stamp ~= stamp then
			error("Tide.set: stamp must be a number", 5)
		end
		local lo = t - math.min(Config.MaxBackdate, 16)
		if stamp < lo then
			counters.stateClamped += 1
			t = lo
		elseif stamp > t then
			counters.stateClamped += 1
		else
			t = stamp
		end
	end
	return stampOn(t)
end

local function fieldOf(slot: number, name: any, api: string): Field
	local s = schemaOf[slot]
	if s == nil then
		error(`{api}: kind {State.kind[slot].name} has no state (declare it with Tide.state)`, 5)
	end
	local f = s.byName[name]
	if f == nil then
		error(`{api}: kind {State.kind[slot].name} has no field {tostring(name)}`, 5)
	end
	return f
end

local function refModel(value: any): any
	if value == nil then
		return nil
	end
	if typeof(value) == "table" then
		value = value.model -- a handle (Instances are not tables)
	end
	if bySlotModel[value] == nil then
		error("Tide.set: a ref must be a Tide entity (model or handle) or nil", 5)
	end
	return value
end

function StateLog.set(slot: number, name: string, value: any, stamp: number?)
	local f = fieldOf(slot, name, "Tide.set")
	if f.event then
		error(`Tide.set: {name} is an event field (use Tide.fire)`, 4)
	end
	if f.code == REF then
		value = refModel(value)
	else
		value = StateSchema.check(f, value, 5)
	end
	local t = stampFor(stamp)
	if f.code == TIME and value ~= nil then
		value = StateSchema.quantizeTime(value, t)
	end
	record(slot, f, t, value)
end

function StateLog.fire(slot: number, name: string, payload: any, stamp: number?)
	local f = fieldOf(slot, name, "Tide.fire")
	if not f.event then
		error(`Tide.fire: {name} is not an event field`, 4)
	end
	local pf = f.payloadField
	if pf ~= nil and pf.code == REF then
		payload = refModel(payload)
	else
		payload = StateSchema.checkPayload(f, payload, 5)
	end
	record(slot, f, stampFor(stamp), payload)
end

-- Current value (event fields: stamp of the latest fire, and its payload).
function StateLog.get(slot: number, name: string): (any, any)
	local f = fieldOf(slot, name, "Tide.get")
	local v = cur[slot][f.id]
	if f.event then
		local t = curT[slot][f.id]
		if t == nil then
			return nil, nil
		end
		return t, live(f.payloadField or f, v)
	end
	return live(f, v)
end

-- Value in effect at server time t (event fields: stamp and payload of the latest fire <= t).
function StateLog.stateAt(slot: number, name: string, t: number): (any, any)
	local f = fieldOf(slot, name, "Tide.stateAt")
	local r = rings[slot][f.id]
	if f.event then
		if r == nil then
			return nil, nil
		end
		local cap = r.cap
		for i = r.last, r.last - r.n + 1, -1 do
			local p = (i - 1) % cap + 1
			if r.t[p] <= t then
				return r.t[p], live(f.payloadField or f, r.v[p])
			end
		end
		-- older than the ring: the newest evicted fire (the ring's base), if it is <= t
		if r.baseT > -INF and r.baseT <= t then
			return r.baseT, live(f.payloadField or f, r.base)
		end
		return nil, nil
	end
	if r == nil then
		return f.default
	end
	return live(f, valueAt(r, f, t))
end

-- Stamp of the first change of a field in (t0, t1], or nil.
function StateLog.changedAt(slot: number, name: string, t0: number, t1: number): number?
	local f = fieldOf(slot, name, "Tide.changedAt")
	local r = rings[slot][f.id]
	if r == nil then
		return nil
	end
	local cap = r.cap
	local found = nil
	for i = r.last, r.last - r.n + 1, -1 do
		local t = r.t[(i - 1) % cap + 1]
		if t <= t0 then
			break
		elseif t <= t1 then
			found = t
		end
	end
	-- the newest evicted change (the base) is older than every kept one
	local bt = r.baseT
	if bt > t0 and bt <= t1 then
		found = bt
	end
	return found
end

--------------------------------------------------------------------------------
-- Schemas (32 SCHEMA)
--------------------------------------------------------------------------------

function StateLog.writeSchemas(w: Control.Writer)
	if StateSchema.count == 0 then
		return
	end
	local n = 0
	for _, kind in Kinds.list do
		if StateSchema.byKind[kind.name] ~= nil then
			n += 1
		end
	end
	if n == 0 then
		return
	end
	Control.u8(w, Control.SCHEMA)
	Control.u8(w, n)
	for _, kind in Kinds.list do
		local s = StateSchema.byKind[kind.name]
		if s ~= nil then
			StateSchema.writeSchema(w, ensure, kind.id, s)
		end
	end
end

--------------------------------------------------------------------------------
-- Flush
--------------------------------------------------------------------------------

local function writeField(w: Control.Writer, f: Field, value: any, stamp: number)
	if f.event then
		local pf = f.payloadField
		if pf == nil then
			Control.u8(w, f.id)
			return
		end
		local code = pf.code
		if code == REF then
			local s = if value ~= nil then bySlotModel[value] else nil
			Control.u8(w, f.id)
			Control.u16(w, s or 0)
			return
		end
		Control.u8(w, f.id)
		writeValue(w, ensure, code, pf, if value == nil then pf.default else value, stamp)
		return
	end
	if value == nil or value == f.default then
		Control.u8(w, f.id + 128)
		return
	end
	if f.code == REF then
		local s = bySlotModel[value]
		if s == nil then
			Control.u8(w, f.id + 128)
			return
		end
		Control.u8(w, f.id)
		Control.u16(w, s)
		return
	end
	Control.u8(w, f.id)
	writeValue(w, ensure, f.code, f, value, stamp)
end

function StateLog.pending(): boolean
	return nch > 0 or snapsPending
end

-- Encodes this frame's changes once (groups of one entity, stamp and audience).
function StateLog.prepare(t: number)
	base = quantize(t)
	enc.pos = 0
	ng = 0
	local i = 1
	while i <= nch do
		local slot = chSlot[i]
		local g = chGen[i]
		if index[slot] == nil or gen[slot] ~= g then
			i += 1
			continue
		end
		local st = chT[i]
		local aud = chF[i].to
		ng += 1
		gSlot[ng] = slot
		gAud[ng] = aud
		gStart[ng] = enc.pos
		Control.u16(enc, slot)
		local dt = round((st - base) / TICK)
		Control.i16(enc, if dt < -32768 then -32768 elseif dt > 32767 then 32767 else dt)
		local countPos = enc.pos
		Control.u8(enc, 0)
		local c = 0
		while i <= nch and c < 255 and chSlot[i] == slot and chGen[i] == g and chT[i] == st and chF[i].to == aud do
			writeField(enc, chF[i], chV[i], st)
			c += 1
			i += 1
		end
		buffer.writeu8(enc.b, countPos, c)
		gEnd[ng] = enc.pos
	end
end

local function visible(f: Field, isOwner: boolean): boolean
	local to = f.to
	return to == TO_ALL or (to == TO_OWNER and isOwner) or (to == TO_OTHERS and not isOwner)
end

-- 31 STATESNAP for one receiver: values at t0 for fields whose missed changes (flush number
-- >= the since of the field's class, INF: none missed) lie at or before t0, then the missed
-- changes after t0 in stamp order.
local function writeSnap(w: Control.Writer, rx: any, slot: number, s1: number, s2: number, s3: number, t: number)
	local sch = schemaOf[slot]
	if sch == nil or index[slot] == nil or not hasState[slot] then
		return
	end
	local isOwner = owner[slot] == rx.player
	local t0 = quantize(t - Config.StateReplay)
	local flushNo = StateLog.flushNo
	local ringsOf = rings[slot]
	Control.u8(w, Control.STATESNAP)
	Control.u16(w, slot)
	Control.f64(w, t0)
	local countPos = w.pos
	Control.u8(w, 0)
	local nb = 0
	local nrep = 0
	for _, f in sch.fields do
		local to = f.to
		local since = if to == TO_ALL then s1 elseif to == TO_OWNER then s2 elseif to == TO_OTHERS then s3 else INF
		if since == INF or not visible(f, isOwner) then
			continue
		end
		local r = ringsOf[f.id]
		if r == nil then
			continue
		end
		local needBase = r.evictFq >= since
		local cap = r.cap
		for i = r.last - r.n + 1, r.last do
			local p = (i - 1) % cap + 1
			local fq = r.fq[p]
			if fq >= since and fq < flushNo then
				if r.t[p] > t0 then
					nrep += 1
					repT[nrep] = r.t[p]
					repSq[nrep] = r.sq[p]
					repF[nrep] = f
					repV[nrep] = r.v[p]
				else
					needBase = true
				end
			end
		end
		if needBase and not f.event then
			-- this frame's changes count too: one stamped at or before t0 (backdated) goes out in
			-- the frame's groups older than t0 and must not be overridden by an older base
			writeField(w, f, valueAt(r, f, t0), t0)
			nb += 1
		end
	end
	buffer.writeu8(w.b, countPos, nb)
	-- stamp order (stable across fields by set order): insertion sort, small n
	for i = 2, nrep do
		local ti, si, fi, vi = repT[i], repSq[i], repF[i], repV[i]
		local j = i - 1
		while j >= 1 and (repT[j] > ti or (repT[j] == ti and repSq[j] > si)) do
			repT[j + 1], repSq[j + 1], repF[j + 1], repV[j + 1] = repT[j], repSq[j], repF[j], repV[j]
			j -= 1
		end
		repT[j + 1], repSq[j + 1], repF[j + 1], repV[j + 1] = ti, si, fi, vi
	end
	Control.u16(w, nrep)
	for i = 1, nrep do
		local dt = round((repT[i] - t0) / TICK)
		Control.u16(w, if dt < 0 then 0 elseif dt > 65535 then 65535 else dt)
		writeField(w, repF[i], repV[i], repT[i])
		repF[i] = false
		repV[i] = false
	end
	counters.stateSnaps += 1
end

-- Writes what one receiver gets this frame: its pending snapshots, then the frame's groups.
function StateLog.writeRx(rx: any, w: Control.Writer, t: number)
	local n = rx.snapN
	if n ~= nil and n > 0 then
		local ss = rx.snapSince
		local s1, s2, s3 = ss[1], ss[2], ss[3]
		for i = 1, n do
			if s1[i] < INF or s2[i] < INF or s3[i] < INF then
				writeSnap(w, rx, rx.snapSlot[i], s1[i], s2[i], s3[i], t)
			end
		end
		rx.snapN = 0
	end
	if ng == 0 then
		return
	end
	local me = rx.player
	local tiers = rx.tier
	local count = 0
	local countPos = 0
	for g = 1, ng do
		local slot = gSlot[g]
		if tiers[slot] == 4 and owner[slot] ~= me then
			continue -- culled (never for the owner: see sync)
		end
		local aud = gAud[g]
		if (aud == TO_OWNER and owner[slot] ~= me) or (aud == TO_OTHERS and owner[slot] == me) then
			continue
		end
		if count == 0 then
			Control.u8(w, Control.STATE)
			Control.f64(w, base)
			countPos = w.pos
			Control.u16(w, 0)
		end
		local a = gStart[g]
		Control.bytes(w, enc.b, a, gEnd[g] - a)
		count += 1
	end
	if count > 0 then
		buffer.writeu16(w.b, countPos, count)
	end
end

function StateLog.flushDone()
	for i = 1, nch do
		chF[i] = false
		chV[i] = false
	end
	nch = 0
	ng = 0
	snapsPending = false
	StateLog.flushNo += 1
end

return StateLog
