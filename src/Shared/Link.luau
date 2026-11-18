--!strict
-- Multi-VM servers (Actors), v0.4. Tide's server runs in ONE Luau VM (it owns the remotes).
-- Code in another VM (a venue Actor) reaches it through a "link": a SharedTable registered
-- as "Tide:<name>" (SharedTableRegistry) that the Tide VM fills and drains.
--
--   Tide VM:      handle:link("Venue1", key)    -- this entity's accepted samples are mirrored
--                                                  under `key` (a string or number of yours)
--   any VM:       local Link = require(ReplicatedStorage.Tide.Shared.Link)
--                 local venue = Link.open("Venue1")
--                 venue:at(key, t) -> CFrame?    -- what Tide.at(model, t) answers in the Tide VM
--                 venue:latest(key) -> (CFrame?, number?)
--                 venue:has(key) -> boolean
--                 venue:setOwner(key, userId?)   -- intents, applied by the Tide VM at the start
--                 venue:teleport(key, cf, vel?)  -- of its next frame (handle:setOwner / teleport /
--                 venue:markTeleport(key, at?)   -- markTeleport); no reply, never synchronous
--
-- Layout of the link's SharedTable:
--   h        key -> entity: gen (link generation), cap, full, last (newest logical index),
--            [i % cap + 1] = sample i packed with string.pack(SAMPLE)
--   q        intent queue: n (indices handed out), [i] = { op, key, ... } (SharedTables)
--   snapGap  the Tide VM's Config.SnapGap (Interp reads it)
-- The Tide VM writes new samples at the end of its frame and appends only (server history is
-- append-only), so a reader copies each sample once into its own Ring and interpolates with
-- the same Shared/Interp as Tide.at: same samples, same answer.
--
-- Limits: samples reach other VMs at the end of the Tide VM's frame (a reader sees up to a
-- frame less than Tide.at would); each mirrored sample costs one SharedTable write (~73 B
-- string) plus one for `last`; intents are applied one frame later, in order, and only for
-- keys linked at that time (others are dropped and counted). SharedTable semantics (atomic
-- increment, visibility between serial and parallel phases) need a Studio check.

local Ring = require(script.Parent.Ring)
local Interp = require(script.Parent.Interp)
local Rig = require(script.Parent.Rig)

local Link = {}

Link.PREFIX = "Tide:"
Link.SAMPLE = "<dddddBdddd" -- t, x, y, z, yaw, flags, qx, qy, qz, qw

local pack = string.pack
local unpack = string.unpack
local SAMPLE = Link.SAMPLE

local function registry(): any
	return game:GetService("SharedTableRegistry")
end

local function field(root: any, key: string, init: { [string]: any }?): any
	SharedTable.update(root, key, function(v)
		if v == nil then
			return SharedTable.new(init or {})
		end
		return v
	end)
	return root[key]
end

-- The link's SharedTable, its entity table and its intent queue (created by whichever VM
-- comes first).
function Link.root(name: string): (any, any, any)
	assert(type(name) == "string" and #name > 0, "Tide link: name must be a string")
	local root = registry():GetSharedTable(Link.PREFIX .. name)
	return root, field(root, "h"), field(root, "q", { n = 0 })
end

function Link.packSample(t: number, x: number, y: number, z: number, yaw: number, fl: number, qx: number, qy: number, qz: number, qw: number): string
	return pack(SAMPLE, t, x, y, z, yaw, fl, qx, qy, qz, qw)
end

--------------------------------------------------------------------------------
-- Reader (any VM)
--------------------------------------------------------------------------------

local View = {}
View.__index = View

export type View = typeof(setmetatable(
	{} :: { name: string, root: any, h: any, q: any, cache: { [any]: { gen: number, last: number, ring: Ring.Ring } } },
	View
))

function Link.open(name: string): View
	local root, h, q = Link.root(name)
	return setmetatable({ name = name, root = root, h = h, q = q, cache = {} }, View)
end

-- Copies the samples written since the last call into this VM's ring of `key`.
local function sync(self: View, key: any): Ring.Ring?
	local e = self.h[key]
	if e == nil then
		self.cache[key] = nil
		return nil
	end
	local gen = e.gen
	local c = self.cache[key]
	if c == nil or c.gen ~= gen then
		c = { gen = gen, last = 0, ring = Ring.new(e.cap, e.full) }
		self.cache[key] = c
	end
	local last = e.last
	if last > c.last then
		local cap = e.cap
		local from = math.max(c.last + 1, last - cap + 1)
		local r = c.ring
		local copied = c.last
		for i = from, last do
			local s = e[i % cap + 1]
			if type(s) ~= "string" then
				break
			end
			local t, x, y, z, yaw, fl, qx, qy, qz, qw = unpack(SAMPLE, s)
			Ring.push(r, t, x, y, z, yaw, fl, qx, qy, qz, qw)
			copied = i
		end
		c.last = copied
	end
	return c.ring
end

function View.has(self: View, key: any): boolean
	return self.h[key] ~= nil
end

-- The pose at server time t, as Tide.at answers it in the Tide VM. nil for unknown keys.
function View.at(self: View, key: any, t: number): CFrame?
	local r = sync(self, key)
	if r == nil then
		return nil
	end
	local snapGap = self.root.snapGap
	if type(snapGap) == "number" then
		Interp.snapGap = snapGap
	end
	local x, y, z, yaw, qx, qy, qz, qw, state = Interp.sample(r, t, 0)
	if state == Interp.STATE_EMPTY then
		return nil
	end
	return Rig.cframe(x, y, z, yaw, r.full, qx, qy, qz, qw)
end

-- The newest mirrored sample and its server time.
function View.latest(self: View, key: any): (CFrame?, number?)
	local r = sync(self, key)
	if r == nil or r.n == 0 then
		return nil, nil
	end
	local p = r.last % r.cap + 1
	local full = r.full
	local cf = Rig.cframe(
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
	return cf, r.t[p]
end

local function push(self: View, intent: { [string]: any })
	local i = SharedTable.increment(self.q, "n", 1) + 1
	self.q[i] = SharedTable.new(intent)
end

local function checkKey(key: any)
	assert(type(key) == "string" or type(key) == "number", "Tide link: key must be a string or a number")
end

-- handle:setOwner in the Tide VM: userId of the new owner, nil/0 = the server.
function View.setOwner(self: View, key: any, userId: number?)
	checkKey(key)
	assert(userId == nil or type(userId) == "number", "Tide link: userId must be a number or nil")
	push(self, { op = "owner", key = key, user = userId or 0 })
end

-- handle:teleport in the Tide VM.
function View.teleport(self: View, key: any, cf: CFrame, velocity: Vector3?)
	checkKey(key)
	assert(typeof(cf) == "CFrame", "Tide link: teleport needs a CFrame")
	local x, y, z, _, qx, qy, qz, qw = Rig.fromCFrame(cf, true)
	local intent: { [string]: any } = { op = "teleport", key = key, x = x, y = y, z = z, qx = qx, qy = qy, qz = qz, qw = qw }
	if velocity ~= nil then
		intent.vx, intent.vy, intent.vz = velocity.X, velocity.Y, velocity.Z
	end
	push(self, intent)
end

-- handle:markTeleport in the Tide VM: with a target, the first sample near it is flagged
-- (the move may land before or after the Tide VM reads the intent); without, the next sample.
function View.markTeleport(self: View, key: any, target: any)
	checkKey(key)
	local intent: { [string]: any } = { op = "mark", key = key }
	if target ~= nil then
		local p = if typeof(target) == "CFrame" then target.Position else target
		assert(typeof(p) == "Vector3", "Tide link: markTeleport target must be a CFrame, a Vector3 or nil")
		intent.x, intent.y, intent.z = p.X, p.Y, p.Z
	end
	push(self, intent)
end

return Link
