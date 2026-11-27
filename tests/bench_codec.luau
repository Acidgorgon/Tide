--!native
--!optimize 2
-- Micro-benchmark of the three ways to pack the 64-bit core:
--   arith   : two u32 built with float arithmetic (what Codec ships)
--   bit32   : two u32 built with bit32.bor/lshift/band/rshift
--   bits    : buffer.writebits / readbits
-- Run: luau-bench [--codegen] tests/bench_codec.luau <tide root>   (root enables the full Codec timing)

local N = 200000
local ROUNDS = 9

local buf = buffer.create(N * 8)
local xs, ys, zs, yws = table.create(N), table.create(N), table.create(N), table.create(N)

math.randomseed(1)
for i = 1, N do
	xs[i] = math.random(0, 131071)
	ys[i] = math.random(0, 131071)
	zs[i] = math.random(0, 131071)
	yws[i] = math.random(0, 1023)
end

local writeu32, readu32 = buffer.writeu32, buffer.readu32
local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
local writebits, readbits = buffer.writebits, buffer.readbits

local function encArith(b, off, fx, fy, fz, yq, flags)
	writeu32(b, off, fx + (fy % 32768) * 131072)
	writeu32(b, off + 4, fy // 32768 + fz * 4 + yq * 524288 + flags * 536870912)
end
local function decArith(b, off)
	local lo = readu32(b, off)
	local hi = readu32(b, off + 4)
	return lo % 131072, lo // 131072 + (hi % 4) * 32768, (hi // 4) % 131072, (hi // 524288) % 1024, hi // 536870912
end

local function encBit32(b, off, fx, fy, fz, yq, flags)
	writeu32(b, off, bor(fx, lshift(fy, 17)))
	writeu32(b, off + 4, bor(rshift(fy, 15), lshift(fz, 2), lshift(yq, 19), lshift(flags, 29)))
end
local function decBit32(b, off)
	local lo = readu32(b, off)
	local hi = readu32(b, off + 4)
	return band(lo, 0x1FFFF),
		bor(rshift(lo, 17), lshift(band(hi, 3), 15)),
		band(rshift(hi, 2), 0x1FFFF),
		band(rshift(hi, 19), 0x3FF),
		rshift(hi, 29)
end

local function encBits(b, off, fx, fy, fz, yq, flags)
	local bit = off * 8
	writebits(b, bit, 17, fx)
	writebits(b, bit + 17, 17, fy)
	writebits(b, bit + 34, 17, fz)
	writebits(b, bit + 51, 10, yq)
	writebits(b, bit + 61, 3, flags)
end
local function decBits(b, off)
	local bit = off * 8
	return readbits(b, bit, 17), readbits(b, bit + 17, 17), readbits(b, bit + 34, 17), readbits(b, bit + 51, 10), readbits(b, bit + 61, 3)
end

local function bench(name, enc, dec)
	-- correctness first
	for i = 1, 1000 do
		enc(buf, (i - 1) * 8, xs[i], ys[i], zs[i], yws[i], i % 8)
		local a, b, c, d, e = dec(buf, (i - 1) * 8)
		assert(a == xs[i] and b == ys[i] and c == zs[i] and d == yws[i] and e == i % 8, name .. " round trip")
	end
	local bestEnc, bestDec = math.huge, math.huge
	local sink = 0
	for _ = 1, ROUNDS do
		local t0 = os.clock()
		for i = 1, N do
			enc(buf, (i - 1) * 8, xs[i], ys[i], zs[i], yws[i], 1)
		end
		local t1 = os.clock()
		for i = 1, N do
			local a, b2, c, d, e = dec(buf, (i - 1) * 8)
			sink += a + b2 + c + d + e
		end
		local t2 = os.clock()
		bestEnc = math.min(bestEnc, t1 - t0)
		bestDec = math.min(bestDec, t2 - t1)
	end
	print(string.format("%-6s encode %6.1f ns/rec   decode %6.1f ns/rec  (sink %d)", name, bestEnc / N * 1e9, bestDec / N * 1e9, sink % 7))
	return bestEnc, bestDec
end

print(`codec core micro-bench, N={N}, native={tostring(__native())}`)
bench("arith", encArith, decArith)
bench("bit32", encBit32, decBit32)
if writebits then
	bench("bits", encBits, decBits)
else
	print("buffer.writebits not available")
end


-- Full Codec.write / Codec.read (rounding, range check, yaw, flags) through the module.
do
	local ROOT = arg and arg[1]
	if ROOT then
		local src = readfile(ROOT .. "/src/Shared/Codec.luau")
		local Codec = assert(loadstring(src, "@Codec"))()
		local fx, fy, fz, fyaw = table.create(N), table.create(N), table.create(N), table.create(N)
		for i = 1, N do
			fx[i] = math.random() * 2000 - 1000
			fy[i] = math.random() * 50
			fz[i] = math.random() * 2000 - 1000
			fyaw[i] = math.random() * 6.28 - 3.14
		end
		local bestW, bestR = math.huge, math.huge
		local sink = 0
		for _ = 1, ROUNDS do
			local t0 = os.clock()
			local off = 0
			for i = 1, N do
				off = Codec.write(buf, (i - 1) * 8, fx[i], fy[i], fz[i], fyaw[i], 0, 0, 0, 0, 1)
			end
			local t1 = os.clock()
			for i = 1, N do
				local _, x, y, z, yaw = Codec.read(buf, (i - 1) * 8)
				sink += x + y + z + yaw
			end
			local t2 = os.clock()
			bestW = math.min(bestW, t1 - t0)
			bestR = math.min(bestR, t2 - t1)
			sink += off
		end
		print(string.format("Codec.write %6.1f ns/sample   Codec.read %6.1f ns/sample  (sink %d)", bestW / N * 1e9, bestR / N * 1e9, sink % 7))

		-- velocity + spin of a velocity record (v0.5): 12 B narrow
		local vbuf = buffer.create(N * 12)
		bestW, bestR = math.huge, math.huge
		sink = 0
		for _ = 1, ROUNDS do
			local t0 = os.clock()
			local hdr = 0
			for i = 1, N do
				local _
				_, hdr = Codec.writeMotion(vbuf, (i - 1) * 12, fx[i] * 0.1 + 0.5, fy[i], fz[i] * 0.1 + 0.5, fyaw[i] * 9 + 0.5, fy[i] + 0.5, fyaw[i] + 4)
			end
			local t1 = os.clock()
			for i = 1, N do
				local _, vx, vy, vz, wx, wy, wz = Codec.readMotion(vbuf, (i - 1) * 12, 3)
				sink += vx + vy + vz + wx + wy + wz
			end
			local t2 = os.clock()
			bestW = math.min(bestW, t1 - t0)
			bestR = math.min(bestR, t2 - t1)
			sink += hdr
		end
		print(string.format("Codec.writeMotion %6.1f ns/sample   Codec.readMotion %6.1f ns/sample  (sink %d)", bestW / N * 1e9, bestR / N * 1e9, sink % 7))
	end
end
