--!strict
-- Animation ids: a u16 per AnimationId string, so events carry 2 bytes instead of
-- the asset URL. Ids 1..seeded come from Config.animationFolder (the Animation
-- descendants sorted by full name, then AnimationId) on both sides, without bytes;
-- a checksum in the hello tells the client its folder matches the server's.
-- Later ids are assigned by the server (REGISTER from an owner, or a bot's
-- watcher) and announced with ANIMID.

local Config = require(script.Parent.Config)

local AnimRegistry = {}

local idOf: { [string]: number } = {}
local strOf: { [number]: string } = {}
local nameOf: { [number]: string } = {}
local animOf: { [number]: any } = {}

AnimRegistry.count = 0 -- highest id in use
AnimRegistry.seeded = 0 -- ids that came from the folder
AnimRegistry.checksum = 0
AnimRegistry.folder = nil :: Instance?

function AnimRegistry.reset()
	table.clear(idOf)
	table.clear(strOf)
	table.clear(nameOf)
	table.clear(animOf)
	AnimRegistry.count = 0
	AnimRegistry.seeded = 0
	AnimRegistry.checksum = 0
end

-- FNV-1a (32 bit) over the id strings in id order.
local function hash(h: number, s: string): number
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296 -- h * 16777619 mod 2^32, exact in doubles
	end
	h = bit32.bxor(h, 10)
	return (bit32.lshift(h, 24) + h * 403) % 4294967296
end

-- Fills ids from a folder of Animation instances. Returns the id count and checksum.
function AnimRegistry.seed(folder: Instance?): (number, number)
	AnimRegistry.reset()
	AnimRegistry.folder = folder
	if folder == nil then
		return 0, 0
	end
	local list = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("Animation") then
			table.insert(list, { full = d:GetFullName(), id = (d :: any).AnimationId, inst = d })
		end
	end
	table.sort(list, function(a, b)
		if a.full == b.full then
			return a.id < b.id
		end
		return a.full < b.full
	end)
	local h = 2166136261
	local max = Config.MaxAnimIds
	for _, item in list do
		local s = item.id
		if s ~= "" and idOf[s] == nil and AnimRegistry.count < max then
			local id = AnimRegistry.count + 1
			AnimRegistry.count = id
			idOf[s] = id
			strOf[id] = s
			nameOf[id] = item.inst.Name
			animOf[id] = item.inst
			h = hash(h, s)
		end
	end
	AnimRegistry.seeded = AnimRegistry.count
	AnimRegistry.checksum = h
	return AnimRegistry.count, h
end

-- Binds id <-> string (client, from ANIMID).
function AnimRegistry.bind(id: number, s: string)
	local old = strOf[id]
	if old ~= nil and old ~= s and idOf[old] == id then
		idOf[old] = nil
		animOf[id] = nil
		nameOf[id] = nil
	end
	idOf[s] = id
	strOf[id] = s
	if id > AnimRegistry.count then
		AnimRegistry.count = id
	end
end

-- Server: the next free id for s (nil when Config.MaxAnimIds is reached).
function AnimRegistry.assign(s: string): number?
	local id = idOf[s]
	if id ~= nil then
		return id
	end
	if AnimRegistry.count >= Config.MaxAnimIds then
		return nil
	end
	id = AnimRegistry.count + 1
	AnimRegistry.count = id
	idOf[s] = id
	strOf[id] = s
	return id
end

-- What an AnimationId string may look like before the server registers it.
function AnimRegistry.valid(s: string): boolean
	if #s == 0 or #s > 100 then
		return false
	end
	return string.match(s, "^rbxassetid://%d+$") ~= nil or string.match(s, "^https?://[%w%.%-_/%?=&:]+$") ~= nil
end

function AnimRegistry.id(s: string): number?
	return idOf[s]
end

function AnimRegistry.string(id: number): string?
	return strOf[id]
end

-- Display name: the Animation's name in the folder, else the AnimationId.
function AnimRegistry.name(id: number): string
	return nameOf[id] or strOf[id] or tostring(id)
end

-- An Animation instance to load for an id (the folder's, else a cached new one).
function AnimRegistry.animation(id: number): any
	local anim = animOf[id]
	if anim ~= nil then
		return anim
	end
	local s = strOf[id]
	if s == nil then
		return nil
	end
	anim = Instance.new("Animation")
	anim.AnimationId = s
	animOf[id] = anim
	return anim
end

-- Animation by name under the folder (Tide.play(model, "Name")).
function AnimRegistry.byName(name: string): any
	local folder = AnimRegistry.folder or Config.animationFolder
	if folder == nil then
		return nil
	end
	local found = folder:FindFirstChild(name, true)
	if found ~= nil and found:IsA("Animation") then
		return found
	end
	return nil
end

return AnimRegistry
