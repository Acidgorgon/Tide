--!strict
--!native
--!optimize 2
-- Smart buffer: one per source (each client-owned entity; each server-owned kind).
-- On every packet that extends a source's stream with motion we record a need:
-- how far behind "now" the render clock must run for the sample to still be
-- ahead of it (see Receive for how it is measured). The target delay is the p95 of the last 128 needs + a margin,
-- clamped to [kind.buffer, Config.MaxBuffer]. The applied delay eases toward
-- the target (render clock runs 0.75x..1.1x) and only snaps for large changes.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)

export type Source = {
	needs: { number },
	count: number, -- valid entries (<= SIZE)
	head: number, -- next write position (1-based)
	minBuffer: number,
	delay: number,
	target: number,
	dirty: boolean,
	started: boolean,
	shared: boolean, -- one source for all server-owned entities of a kind
}

local Buffer = {}

local SIZE = 128
local TOPK_MAX = 8
local top = table.create(TOPK_MAX, 0) -- scratch for top-k selection

function Buffer.new(minBuffer: number, shared: boolean?): Source
	return {
		needs = table.create(SIZE, 0),
		count = 0,
		head = 1,
		minBuffer = minBuffer,
		delay = minBuffer,
		target = minBuffer,
		dirty = false,
		started = false,
		shared = shared == true,
	}
end

function Buffer.addNeed(src: Source, need: number)
	if need ~= need then
		return
	end
	local head = src.head
	src.needs[head] = need
	head += 1
	if head > SIZE then
		head = 1
	end
	src.head = head
	if src.count < SIZE then
		src.count += 1
	end
	src.dirty = true
end

-- k-th largest need (k = ceil(5% of count)): the p95.
local function p95(src: Source): number
	local count = src.count
	local k = math.ceil(count * 0.05)
	if k < 1 then
		k = 1
	end
	local needs = src.needs
	local filled = 0
	for i = 1, count do
		local v = needs[i]
		if filled < k then
			-- insert keeping top[] descending
			filled += 1
			local j = filled
			while j > 1 and top[j - 1] < v do
				top[j] = top[j - 1]
				j -= 1
			end
			top[j] = v
		elseif v > top[k] then
			local j = k
			while j > 1 and top[j - 1] < v do
				top[j] = top[j - 1]
				j -= 1
			end
			top[j] = v
		end
	end
	return top[k]
end
Buffer.p95 = p95

local function computeTarget(src: Source): number
	local target
	if src.count == 0 then
		target = src.minBuffer + 0.05
	else
		target = p95(src) + Config.BufferMargin
	end
	if target < src.minBuffer then
		target = src.minBuffer
	end
	local maxBuffer = Config.MaxBuffer
	if target > maxBuffer then
		target = maxBuffer
	end
	return target
end

-- Advances the applied delay toward the target. Called once per render frame.
function Buffer.update(src: Source, dt: number)
	if src.dirty then
		src.dirty = false
		src.target = computeTarget(src)
	end
	local target = src.target
	if not src.started then
		if src.count == 0 then
			src.delay = computeTarget(src)
			return
		end
		src.started = true
		src.delay = target
		return
	end
	local delay = src.delay
	local diff = target - delay
	if diff > Config.DelaySnap or diff < -Config.DelaySnap or (diff < 1e-4 and diff > -1e-4) then
		src.delay = target
		return
	end
	local step = diff * math.min(1, 5 * dt)
	local up = 0.25 * dt
	local down = -0.1 * dt
	if step > up then
		step = up
	elseif step < down then
		step = down
	end
	src.delay = delay + step
end

return Buffer
