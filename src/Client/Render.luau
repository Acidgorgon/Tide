--!strict
--!native
--!optimize 2
-- PreRender: sample every remote entity at now - delay, blend corrections,
-- apply (one BulkMoveTo for anchored roots, CFrame otherwise), then run the
-- kinds' afterApply hooks (model, cf) once every pose of the frame is in place.

local Shared = script.Parent.Parent.Shared
local Config = require(Shared.Config)
local Interp = require(Shared.Interp)
local Rig = require(Shared.Rig)
local State = require(script.Parent.State)
local Buffer = require(script.Parent.Buffer)

local Render = {}

local sample = Interp.sample
local wrapAngle = Interp.wrapAngle
local makeCFrame = Rig.cframe
local update = Buffer.update

local active = State.active
local mine = State.mine
local rings = State.ring
local srcs = State.src
local kinds = State.kind
local models = State.model
local roots = State.root
local dirtyFrom = State.dirtyFrom
local drawn = State.drawn
local dX, dY, dZ, dYaw = State.dX, State.dY, State.dZ, State.dYaw
local dQX, dQY, dQZ, dQW = State.dQX, State.dQY, State.dQZ, State.dQW
local lastRT = State.lastRT
local offX, offY, offZ, offYaw, offT = State.offX, State.offY, State.offZ, State.offYaw, State.offT
local vX, vY, vZ = State.vX, State.vY, State.vZ
local cfs = State.cf

local bulkParts = table.create(64) :: { any }
local bulkCFrames = table.create(64) :: { any }
local sources = {} :: { any } -- distinct sources updated this frame
local seen = {} :: { [any]: number }
local after = table.create(64) :: { number } -- slots whose kind has afterApply
local frameId = 0

-- Optional hook for tests/benchmarks: replaces BulkMoveTo.
Render.bulkMove = nil :: ((parts: { any }, cframes: { any }, n: number) -> ())?

function Render.step(now: number, dt: number)
	frameId += 1
	local count = State.count

	-- 1. advance each source's delay once
	local nsrc = 0
	for k = 1, count do
		local slot = active[k]
		if not mine[slot] then
			local src = srcs[slot]
			if seen[src] ~= frameId then
				seen[src] = frameId
				nsrc += 1
				sources[nsrc] = src
			end
		end
	end
	for i = 1, nsrc do
		update(sources[i], dt)
		sources[i] = nil
	end

	local corrTime = Config.CorrectionTime
	local snap2 = Config.SnapDistance * Config.SnapDistance
	local nb = 0
	local na = 0

	-- 2. sample, blend, apply
	for k = 1, count do
		local slot = active[k]
		if mine[slot] then
			continue
		end
		local r = rings[slot]
		if r.n == 0 then
			continue
		end
		local kind = kinds[slot]
		local extrap = kind.extrapolate
		local rt = now - srcs[slot].delay
		local minGap = 0.5 / kind.rate
		local maxSpeed, maxRise, maxFall = kind.maxSpeed, kind.maxRise, kind.maxFall
		local x, y, z, yaw, qx, qy, qz, qw = sample(r, rt, extrap, minGap, maxSpeed, maxRise, maxFall)

		if drawn[slot] then
			local prevRT = lastRT[slot]
			local tele = r.lastTele
			if tele > prevRT and tele <= rt then
				-- crossed a teleport: snap
				offT[slot] = -math.huge
			elseif prevRT >= dirtyFrom[slot] then
				-- new samples changed the path at the last drawn time: blend from where we drew
				local px, py, pz, pyaw = sample(r, prevRT, extrap, minGap, maxSpeed, maxRise, maxFall)
				local ex = dX[slot] - px
				local ey = dY[slot] - py
				local ez = dZ[slot] - pz
				if ex * ex + ey * ey + ez * ez > snap2 then
					offT[slot] = -math.huge
				else
					offX[slot] = ex
					offY[slot] = ey
					offZ[slot] = ez
					offYaw[slot] = wrapAngle(dYaw[slot] - pyaw)
					offT[slot] = now - dt
				end
			end
		else
			offT[slot] = -math.huge
		end
		dirtyFrom[slot] = math.huge

		local w = 1 - (now - offT[slot]) / corrTime
		if w > 0 then
			x += offX[slot] * w
			y += offY[slot] * w
			z += offZ[slot] * w
			yaw = wrapAngle(yaw + offYaw[slot] * w)
		end

		if drawn[slot] and dt > 0 then
			vX[slot] = (x - dX[slot]) / dt
			vY[slot] = (y - dY[slot]) / dt
			vZ[slot] = (z - dZ[slot]) / dt
		else
			vX[slot], vY[slot], vZ[slot] = 0, 0, 0
		end
		drawn[slot] = true
		lastRT[slot] = rt
		dX[slot], dY[slot], dZ[slot], dYaw[slot] = x, y, z, yaw
		dQX[slot], dQY[slot], dQZ[slot], dQW[slot] = qx, qy, qz, qw

		local apply = kind.apply
		if kind.afterApply then
			na += 1
			after[na] = slot
		elseif apply == "none" then
			cfs[slot] = nil
			continue
		end
		local cf = makeCFrame(x, y, z, yaw, r.full, qx, qy, qz, qw)
		cfs[slot] = cf
		if apply == "none" then
			continue
		elseif apply == "cframe" then
			local root = roots[slot]
			if root ~= nil then
				if root.Anchored then
					nb += 1
					bulkParts[nb] = root
					bulkCFrames[nb] = cf
				else
					root.CFrame = cf
				end
			else
				local model = models[slot]
				if model ~= nil then
					model:PivotTo(cf)
				end
			end
		else
			local model = models[slot]
			if model ~= nil then
				local ok = pcall(apply, model, cf)
				if not ok then
					State.counters.applyErrors += 1
				end
			end
		end
	end

	if nb > 0 then
		local hook = Render.bulkMove
		if hook then
			hook(bulkParts, bulkCFrames, nb)
		else
			workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		end
		table.clear(bulkParts)
		table.clear(bulkCFrames)
	end

	for i = 1, na do
		local slot = after[i]
		local model = models[slot]
		local kind = kinds[slot]
		if model ~= nil and kind ~= nil and kind.afterApply then
			local ok = pcall(kind.afterApply, model, cfs[slot])
			if not ok then
				State.counters.applyErrors += 1
			end
		end
	end
end

return Render
