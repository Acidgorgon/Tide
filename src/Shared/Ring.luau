--!strict
--!native
--!optimize 2
-- Fixed-size ring of samples stored as parallel number arrays (no table per sample).
-- Samples are addressed by a logical index that only grows; the newest is `last`,
-- the oldest `last - n + 1`. Physical position of logical i is i % cap + 1.
-- Samples are kept sorted by time: a late (out-of-order) sample is inserted in place.

export type Ring = {
	cap: number,
	last: number,
	n: number,
	full: boolean,
	t: { number },
	x: { number },
	y: { number },
	z: { number },
	yaw: { number },
	fl: { number },
	qx: { number },
	qy: { number },
	qz: { number },
	qw: { number },
	lastTele: number, -- time of the newest teleport sample (-inf if none)
}

local Ring = {}

function Ring.new(cap: number, full: boolean): Ring
	local q = if full then cap else 0
	return {
		cap = cap,
		last = 0,
		n = 0,
		full = full,
		t = table.create(cap, 0),
		x = table.create(cap, 0),
		y = table.create(cap, 0),
		z = table.create(cap, 0),
		yaw = table.create(cap, 0),
		fl = table.create(cap, 0),
		qx = table.create(q, 0),
		qy = table.create(q, 0),
		qz = table.create(q, 0),
		qw = table.create(q, 1),
		lastTele = -math.huge,
	}
end

function Ring.clear(r: Ring)
	r.last = 0
	r.n = 0
	r.lastTele = -math.huge
end

local function store(r: Ring, p: number, t: number, x: number, y: number, z: number, yaw: number, fl: number, qx: number, qy: number, qz: number, qw: number)
	r.t[p] = t
	r.x[p] = x
	r.y[p] = y
	r.z[p] = z
	r.yaw[p] = yaw
	r.fl[p] = fl
	if r.full then
		r.qx[p] = qx
		r.qy[p] = qy
		r.qz[p] = qz
		r.qw[p] = qw
	end
end

local function move(r: Ring, from: number, to: number)
	r.t[to] = r.t[from]
	r.x[to] = r.x[from]
	r.y[to] = r.y[from]
	r.z[to] = r.z[from]
	r.yaw[to] = r.yaw[from]
	r.fl[to] = r.fl[from]
	if r.full then
		r.qx[to] = r.qx[from]
		r.qy[to] = r.qy[from]
		r.qz[to] = r.qz[from]
		r.qw[to] = r.qw[from]
	end
end

-- Inserts a sample; returns its logical index, or 0 if rejected
-- (duplicate time, or older than everything kept).
function Ring.push(r: Ring, t: number, x: number, y: number, z: number, yaw: number, fl: number, qx: number, qy: number, qz: number, qw: number): number
	local cap = r.cap
	local last = r.last
	local n = r.n
	local ts = r.t
	if fl % 2 == 1 and t > r.lastTele then
		r.lastTele = t
	end
	if n == 0 or t > ts[last % cap + 1] then
		last += 1
		r.last = last
		if n < cap then
			r.n = n + 1
		end
		store(r, last % cap + 1, t, x, y, z, yaw, fl, qx, qy, qz, qw)
		return last
	end
	local oldest = last - n + 1
	if t <= ts[oldest % cap + 1] then
		return 0
	end
	-- find k: the newest sample with time < t
	local k = last
	while k >= oldest do
		local tk = ts[k % cap + 1]
		if tk == t then
			return 0
		elseif tk < t then
			break
		end
		k -= 1
	end
	-- shift (k, last] up by one; when full the oldest falls off
	for i = last, k + 1, -1 do
		move(r, i % cap + 1, (i + 1) % cap + 1)
	end
	r.last = last + 1
	if n < cap then
		r.n = n + 1
	end
	store(r, (k + 1) % cap + 1, t, x, y, z, yaw, fl, qx, qy, qz, qw)
	return k + 1
end

-- Newest sample time (or -inf when empty).
function Ring.newestT(r: Ring): number
	if r.n == 0 then
		return -math.huge
	end
	return r.t[r.last % r.cap + 1]
end

-- Logical index of the newest sample with time <= t; oldest - 1 if t is before all.
function Ring.find(r: Ring, t: number): number
	local cap = r.cap
	local ts = r.t
	local hi = r.last
	local lo = hi - r.n + 1
	if t >= ts[hi % cap + 1] then
		return hi
	end
	if t < ts[lo % cap + 1] then
		return lo - 1
	end
	-- invariant: ts[lo] <= t < ts[hi]
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if ts[mid % cap + 1] <= t then
			lo = mid
		else
			hi = mid
		end
	end
	return lo
end

return Ring
