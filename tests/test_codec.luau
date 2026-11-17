-- Codec round trips: random positions/yaws/quaternions, edges, absolute fallback, dt extension.
return function(T)
	local world = T.world()
	local Codec = T.module(world, "Shared", "Codec")
	local b = buffer.create(64)
	math.randomseed(42)

	local function rnd(lo, hi)
		return lo + math.random() * (hi - lo)
	end

	local function yawErr(a, b2)
		local d = (a - b2 + math.pi) % (2 * math.pi) - math.pi
		return math.abs(d)
	end

	T.test("random positions and yaws round trip within 1/128 stud and half a yaw step", function()
		Codec.setOrigin(0, 0, 0)
		for _ = 1, 20000 do
			local x, y, z = rnd(-1023.9, 1023.9), rnd(-1023.9, 1023.9), rnd(-1023.9, 1023.9)
			local yaw = rnd(-math.pi, math.pi)
			local tele = math.random() < 0.5
			local off = Codec.write(b, 0, x, y, z, yaw, if tele then 1 else 0, 0, 0, 0, 1)
			T.eq(off, 8, "packed size")
			T.eq(Codec.sizeAt(b, 0), 8, "sizeAt")
			local roff, rx, ry, rz, ryaw, flags = Codec.read(b, 0)
			T.eq(roff, 8)
			T.near(rx, x, 1 / 128 + 1e-9, "x")
			T.near(ry, y, 1 / 128 + 1e-9, "y")
			T.near(rz, z, 1 / 128 + 1e-9, "z")
			T.check(yawErr(ryaw, yaw) <= math.pi / 1024 + 1e-9, "yaw error " .. yawErr(ryaw, yaw))
			T.eq(flags % 2 == 1, tele, "teleport flag")
			T.eq(flags >= 4, false, "not abs")
		end
	end)

	T.test("edge values: +-1024 boundary, exact quanta, yaw wrap", function()
		Codec.setOrigin(0, 0, 0)
		-- largest in-range values
		local hi = 65535 / 64
		local lo = -1024
		for _, v in { lo, hi, 0, 1 / 64, -1 / 64, 512.015625 } do
			Codec.write(b, 0, v, v, v, 0, 0, 0, 0, 0, 1)
			local _, rx, ry, rz, _, flags = Codec.read(b, 0)
			T.eq(flags, 0, "packed for " .. v)
			T.eq(rx, v, "exact x")
			T.eq(ry, v, "exact y")
			T.eq(rz, v, "exact z")
		end
		-- just past the edge -> absolute
		Codec.write(b, 0, 1024, 0, 0, 0, 0, 0, 0, 0, 1)
		local _, rx, _, _, _, flags = Codec.read(b, 0)
		T.eq(flags, 4, "abs flag at +1024")
		T.eq(rx, 1024)
		-- yaw wrap: pi and -pi decode to the same step, 2pi+0.1 == 0.1
		for _, yaw in { math.pi, -math.pi, 2 * math.pi + 0.1, -2 * math.pi - 0.1, 1e-9 } do
			Codec.write(b, 0, 0, 0, 0, yaw, 0, 0, 0, 0, 1)
			local _, _, _, _, ryaw = Codec.read(b, 0)
			T.check(yawErr(ryaw, yaw) <= math.pi / 1024 + 1e-9, "yaw wrap " .. yaw)
			T.check(ryaw > -math.pi - 1e-9 and ryaw <= math.pi + 1e-9, "range")
		end
		-- all flag bits survive with max coordinates
		Codec.write(b, 0, hi, hi, hi, -0.001, 1, 0, 0, 0, 1)
		local _, _, _, _, _, f2 = Codec.read(b, 0)
		T.eq(f2, 1)
	end)

	T.test("origin offset", function()
		Codec.setOrigin(5000, -20, 300.5)
		for _ = 1, 2000 do
			local x, y, z = 5000 + rnd(-1000, 1000), -20 + rnd(-1000, 1000), 300.5 + rnd(-1000, 1000)
			Codec.write(b, 0, x, y, z, 0, 0, 0, 0, 0, 1)
			local _, rx, ry, rz, _, flags = Codec.read(b, 0)
			T.eq(flags, 0)
			T.near(rx, x, 1 / 128 + 1e-9)
			T.near(ry, y, 1 / 128 + 1e-9)
			T.near(rz, z, 1 / 128 + 1e-9)
		end
		-- 0,0,0 is now 5000 studs away: absolute
		Codec.write(b, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
		local _, _, _, _, _, flags = Codec.read(b, 0)
		T.eq(flags, 4)
		Codec.setOrigin(0, 0, 0)
	end)

	T.test("absolute fallback: far, NaN, inf use 3 x f32", function()
		Codec.setOrigin(0, 0, 0)
		for _ = 1, 2000 do
			local x, y, z = rnd(-1e5, 1e5), rnd(-1e5, 1e5), rnd(-1e5, 1e5)
			if math.abs(x) < 1100 then
				x += 2000
			end
			local off = Codec.write(b, 0, x, y, z, 1, 1, 0, 0, 0, 1)
			T.eq(off, 20, "abs size")
			T.eq(Codec.sizeAt(b, 0), 20)
			local roff, rx, ry, rz, _, flags = Codec.read(b, 0)
			T.eq(roff, 20)
			T.eq(flags, 5, "abs + teleport")
			-- f32 precision
			T.near(rx, x, math.abs(x) * 1e-7 + 1e-6)
			T.near(ry, y, math.abs(y) * 1e-7 + 1e-6)
			T.near(rz, z, math.abs(z) * 1e-7 + 1e-6)
		end
		Codec.write(b, 0, 0 / 0, 1, 1, 0, 0, 0, 0, 0, 1)
		local _, rx, _, _, _, flags = Codec.read(b, 0)
		T.eq(flags, 4, "NaN goes absolute")
		T.check(rx ~= rx, "NaN preserved for the validator")
		Codec.write(b, 0, math.huge, 1, 1, 0, 0, 0, 0, 0, 1)
		local _, rx2, _, _, _, flags2 = Codec.read(b, 0)
		T.eq(flags2, 4)
		T.eq(rx2, math.huge)
	end)

	T.test("smallest-three quaternion: random rotations within 0.25 deg", function()
		local maxErr = 0
		for _ = 1, 20000 do
			local qx, qy, qz, qw = rnd(-1, 1), rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)
			local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
			qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
			local off = Codec.write(b, 0, 1, 2, 3, 0.5, 2, qx, qy, qz, qw)
			T.eq(off, 12, "full size")
			T.eq(Codec.sizeAt(b, 0), 12)
			local roff, _, _, _, _, flags, rx, ry, rz, rw = Codec.read(b, 0)
			T.eq(roff, 12)
			T.eq(flags, 2)
			local dot = math.abs(qx * rx + qy * ry + qz * rz + qw * rw)
			local angle = 2 * math.acos(math.min(1, dot))
			if angle > maxErr then
				maxErr = angle
			end
		end
		T.check(math.deg(maxErr) < 0.25, "max quaternion error " .. math.deg(maxErr) .. " deg")
		-- degenerate input -> identity
		Codec.write(b, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0)
		local _, _, _, _, _, _, rx, ry, rz, rw = Codec.read(b, 0)
		T.near(rw, 1, 1e-3)
		T.near(rx + ry + rz, 0, 3e-3)
	end)

	T.test("full + abs + teleport combined", function()
		local off = Codec.write(b, 0, 5000, -3000, 7, 1, 3, 0, 0.7071, 0, 0.7071)
		T.eq(off, 24)
		T.eq(Codec.sizeAt(b, 0), 24)
		local roff, rx, ry, rz, _, flags, qx, qy, qz, qw = Codec.read(b, 0)
		T.eq(roff, 24)
		T.eq(flags, 7)
		T.eq(rx, 5000)
		T.eq(ry, -3000)
		T.eq(rz, 7)
		T.near(qy, 0.7071, 2e-3)
		T.near(qw, 0.7071, 2e-3)
		T.near(qx, 0, 2e-3)
		T.near(qz, 0, 2e-3)
	end)

	T.test("dt byte with 255 extension", function()
		for _, ticks in { 0, 1, 200, 254, 255, 256, 1000, 65535, 70000 } do
			local off = Codec.writeDt(b, 3, ticks)
			local roff, v = Codec.readDt(b, 3)
			T.eq(roff, off)
			T.eq(off - 3, if ticks < 255 then 1 else 3, "size for " .. ticks)
			T.eq(v, math.min(ticks, 65535), "value for " .. ticks)
		end
	end)

	T.test("quantize matches what a receiver decodes", function()
		for _ = 1, 2000 do
			local x, y, z, yaw = rnd(-2000, 2000), rnd(-50, 50), rnd(-2000, 2000), rnd(-4, 4)
			local full = math.random() < 0.5
			local qx, qy, qz, qw = rnd(-1, 1), rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)
			local fl = if full then 2 else 0
			local ax, ay, az, ayaw, _, aqx, aqy, aqz, aqw = Codec.quantize(x, y, z, yaw, fl, qx, qy, qz, qw)
			Codec.write(b, 0, x, y, z, yaw, fl, qx, qy, qz, qw)
			local _, bx, by, bz, byaw, _, bqx, bqy, bqz, bqw = Codec.read(b, 0)
			T.eq(ax, bx)
			T.eq(ay, by)
			T.eq(az, bz)
			T.eq(ayaw, byaw)
			T.eq(aqx, bqx)
			T.eq(aqy, bqy)
			T.eq(aqz, bqz)
			T.eq(aqw, bqw)
			-- idempotent: quantizing again changes nothing (server re-encodes stored samples)
			local cx, cy, cz, cyaw = Codec.quantize(ax, ay, az, ayaw, fl, aqx, aqy, aqz, aqw)
			T.eq(cx, ax)
			T.eq(cy, ay)
			T.eq(cz, az)
			T.eq(cyaw, ayaw)
		end
	end)

	T.test("matrix -> quaternion -> yaw consistent with CFrame", function()
		for _ = 1, 500 do
			local yaw = rnd(-math.pi, math.pi)
			local cf = CFrame.Angles(0, yaw, 0)
			local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
			T.near(Codec.yawOf(r02, r22), yaw, 1e-9)
			local qx, qy, qz, qw = Codec.matrixToQuat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
			local back = CFrame.new(0, 0, 0, qx, qy, qz, qw)
			local _, _, _, s00, _, s02, _, _, _, _, _, s22 = back:GetComponents()
			T.near(s00, r00, 1e-9)
			T.near(s02, r02, 1e-9)
			T.near(s22, r22, 1e-9)
		end
		for _ = 1, 500 do
			local cf = CFrame.Angles(rnd(-3, 3), rnd(-3, 3), rnd(-3, 3))
			local c = { cf:GetComponents() }
			local qx, qy, qz, qw = Codec.matrixToQuat(table.unpack(c, 4, 12))
			local back = { CFrame.new(0, 0, 0, qx, qy, qz, qw):GetComponents() }
			for i = 4, 12 do
				T.near(back[i], c[i], 1e-9)
			end
		end
	end)
end
