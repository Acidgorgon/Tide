--!strict
-- Links (v0.4, see Shared/Link): mirrors linked entities' history into their link's
-- SharedTable at the end of each frame, and applies the intents other VMs queued there at
-- the start of the next one. Nothing runs until handle:link is called.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Link = require(Shared.Link)
local State = require(script.Parent.State)

local Mirror = {}

type LinkRec = { name: string, root: any, h: any, q: any, head: number, stall: number, byKey: { [any]: number } }

local links = {} :: { [string]: LinkRec }
local linkOf = {} :: { [number]: LinkRec } -- slot -> link
local keyOf = {} :: { [number]: any } -- slot -> key
local entryOf = {} :: { [number]: any } -- slot -> its entity SharedTable
local mirrored = {} :: { [number]: number } -- slot -> newest logical index written
local gen = 0
local nlinked = 0

-- Set by Server: applies an intent (op, slot, intent SharedTable).
Mirror.apply = nil :: ((op: string, slot: number, intent: any) -> ())?

local packSample = Link.packSample
local packSampleVel = Link.packSampleVel
local STALL = 30 -- frames an index handed out but never written holds the queue, then skipped

function Mirror.unlink(slot: number)
	local rec = linkOf[slot]
	if rec == nil then
		return
	end
	local key = keyOf[slot]
	if rec.byKey[key] == slot then
		rec.byKey[key] = nil
		rec.h[key] = nil
	end
	linkOf[slot] = nil
	keyOf[slot] = nil
	entryOf[slot] = nil
	mirrored[slot] = nil
	nlinked -= 1
end

function Mirror.link(slot: number, name: string, key: any)
	assert(type(name) == "string" and #name > 0, "link: name must be a string")
	assert(type(key) == "string" or type(key) == "number", "link: key must be a string or a number")
	Mirror.unlink(slot)
	local rec = links[name]
	if rec == nil then
		local root, h, q = Link.root(name)
		rec = { name = name, root = root, h = h, q = q, head = q.n, stall = 0, byKey = {} }
		links[name] = rec
	end
	rec.root.snapGap = Config.SnapGap
	local other = rec.byKey[key]
	if other ~= nil and other ~= slot then
		Mirror.unlink(other) -- one entity per key
	end
	local h = State.hist[slot]
	gen += 1
	local init: { [string]: any } = { gen = gen, cap = h.cap, full = h.full, last = 0 }
	if h.vel then
		init.vel = true
	end
	local e = SharedTable.new(init)
	rec.h[key] = e
	rec.byKey[key] = slot
	linkOf[slot] = rec
	keyOf[slot] = key
	entryOf[slot] = rec.h[key]
	mirrored[slot] = h.last - h.n -- everything in history goes out on the next step
	nlinked += 1
end

-- End of frame: new history samples of linked entities into their links.
function Mirror.write()
	if nlinked == 0 then
		return
	end
	for slot, e in entryOf do
		local h = State.hist[slot]
		if h == nil then
			continue
		end
		local last = h.last
		local from = mirrored[slot] + 1
		if from > last then
			continue
		end
		local oldest = last - h.n + 1
		if from < oldest then
			from = oldest
		end
		local cap = h.cap
		local full = h.full
		local ts, xs, ys, zs, yaws, fls = h.t, h.x, h.y, h.z, h.yaw, h.fl
		if h.vel then
			for i = from, last do
				local p = i % cap + 1
				e[p] = packSampleVel(
					ts[p],
					xs[p],
					ys[p],
					zs[p],
					yaws[p],
					fls[p],
					if full then h.qx[p] else 0,
					if full then h.qy[p] else 0,
					if full then h.qz[p] else 0,
					if full then h.qw[p] else 1,
					h.vx[p],
					h.vy[p],
					h.vz[p],
					h.wx[p],
					h.wy[p],
					h.wz[p]
				)
			end
			from = last + 1
		end
		for i = from, last do
			local p = i % cap + 1
			e[p] = packSample(
				ts[p],
				xs[p],
				ys[p],
				zs[p],
				yaws[p],
				fls[p],
				if full then h.qx[p] else 0,
				if full then h.qy[p] else 0,
				if full then h.qz[p] else 0,
				if full then h.qw[p] else 1
			)
		end
		e.last = last -- after the samples: a reader never reads past what is written
		mirrored[slot] = last
	end
end

-- Start of frame: intents other VMs queued, in order.
function Mirror.read()
	for _, rec in links do
		local q = rec.q
		local n = q.n
		local i = rec.head
		while i < n do
			local intent = q[i + 1]
			if intent == nil then
				-- handed out but not written yet (the writer is mid-push): next frame; a VM
				-- that died between the two steps would hold the queue, so give up after a while
				rec.stall += 1
				if rec.stall < STALL then
					break
				end
				State.counters.linkBad += 1
			end
			rec.stall = 0
			i += 1
			q[i] = nil
			if intent == nil then
				continue
			end
			local slot = rec.byKey[intent.key]
			local apply = Mirror.apply
			if slot ~= nil and State.index[slot] ~= nil and apply ~= nil then
				local ok = pcall(apply, intent.op, slot, intent)
				if not ok then
					State.counters.linkBad += 1
				end
			else
				State.counters.linkUnknown += 1
			end
		end
		rec.head = i
	end
end

return Mirror
