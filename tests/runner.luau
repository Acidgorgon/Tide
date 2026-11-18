--!optimize 2
-- Test runner for the luau-bench host.
-- usage: luau-bench [--codegen] tests/runner.luau <tide root> [name filter]

local ROOT = arg[1] or "."
local FILTER = arg[2]

local function load(path: string)
	local src = readfile(path) or error("cannot read " .. path)
	local fn, err = loadstring(src, "@" .. path)
	if not fn then
		error(err)
	end
	return fn()
end

local Mock = load(ROOT .. "/tests/mock.luau")
Mock.installGlobals()

local T = {}
T.Mock = Mock
T.ROOT = ROOT
T.SRC = ROOT .. "/src"

local results = { passed = 0, failed = 0, failures = {} }
local current = ""

function T.test(name: string, fn: () -> ())
	local full = current .. " :: " .. name
	if FILTER and not string.find(full, FILTER, 1, true) then
		return
	end
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		results.passed += 1
		print("  ok   " .. name)
	else
		results.failed += 1
		table.insert(results.failures, full .. "\n" .. tostring(err))
		print("  FAIL " .. name .. "\n" .. tostring(err))
	end
end

function T.check(cond: any, msg: string?)
	if not cond then
		error(msg or "check failed", 2)
	end
end

function T.near(a: number, b: number, tol: number, msg: string?)
	if not (math.abs(a - b) <= tol) then
		error(string.format("%s: %.6f vs %.6f (tol %.6f)", msg or "near", a, b, tol), 2)
	end
end

function T.eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2)
	end
end

-- A world with Tide mounted at ReplicatedStorage.Tide on the server.
function T.world(opts: any?)
	local world = Mock.newWorld(opts)
	world.tideModule = world.server:mountTree(T.SRC, world.server.ReplicatedStorage, "Tide")
	return world
end

function T.serverTide(world)
	return world.server:require(world.tideModule)
end

function T.clientTide(world, index: number)
	local client = world.clients[index]
	local module = client.ReplicatedStorage:FindFirstChild("Tide")
	return client:require(module)
end

-- Another server VM (an Actor's): a fresh env sharing the world's SharedTableRegistry, with
-- its own copy of Tide mounted. Returns a require of a module path, e.g. vm("Shared", "Link").
function T.actorVM(world)
	local env = world:_newEnv(true, nil)
	local root = env:mountTree(T.SRC, env.ReplicatedStorage, "Tide")
	return function(...)
		local inst = root
		for _, name in { ... } do
			inst = inst:FindFirstChild(name) or error("no module " .. name)
		end
		return env:require(inst)
	end
end

-- Requires a module of the mounted tree in the server env, e.g. T.module(world, "Shared", "Codec").
function T.module(world, ...)
	local inst = world.tideModule
	for _, name in { ... } do
		inst = inst:FindFirstChild(name) or error("no module " .. name)
	end
	return world.server:require(inst)
end

function T.clientModule(world, index: number, ...)
	local client = world.clients[index]
	local inst = client.ReplicatedStorage:FindFirstChild("Tide")
	for _, name in { ... } do
		inst = inst:FindFirstChild(name) or error("no module " .. name)
	end
	return client:require(inst)
end

function T.dist(a, b): number
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local files = {}
for _, entry in listdir(ROOT .. "/tests") or {} do
	if not entry.dir and string.match(entry.name, "^test_.*%.luau$") then
		table.insert(files, entry.name)
	end
end
table.sort(files)

local t0 = os.clock()
for _, name in files do
	current = name
	print(name)
	local ok, err = xpcall(function()
		local fn = load(ROOT .. "/tests/" .. name)
		fn(T)
	end, debug.traceback)
	if not ok then
		results.failed += 1
		table.insert(results.failures, name .. " (load)\n" .. tostring(err))
		print("  FAIL (load) " .. tostring(err))
	end
end

print(string.format("\n%d passed, %d failed (%.2f s, native=%s)", results.passed, results.failed, os.clock() - t0, tostring(__native())))
if results.failed > 0 then
	print("\nFailures:")
	for _, f in results.failures do
		print("- " .. f)
	end
	error("tests failed", 0)
end
