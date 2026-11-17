--!strict
-- Tide.start(opts) handling: every Config field is accepted and type checked
-- against its default; `kinds = { Name = kindOpts }` defines/updates kinds;
-- side-specific extras (server: `players`) are passed through.

local Config = require(script.Parent.Config)
local Kinds = require(script.Parent.Kinds)

local Options = {}

-- Fields whose default is `false` but which also take a table.
local FALSE_OR_TABLE = {
	lockHumanoidStates = true,
}

-- Fields whose default is nil but which take an Instance.
local INSTANCE = {
	animationFolder = true,
}

local CHOICES = {
	lockMode = { root = true, anchored = true },
	teleportOnWriteVelocity = { zero = true, keep = true },
}

-- Applies opts to Config; returns the extras the caller asked for (by name).
function Options.apply(opts: { [string]: any }?, extras: { [string]: string }): { [string]: any }
	local out = {}
	if opts == nil then
		return out
	end
	if type(opts) ~= "table" then
		error("Tide.start: options must be a table", 4)
	end
	for key, value in opts do
		if type(key) ~= "string" then
			error("Tide.start: option names must be strings", 4)
		end
		local extraType = extras[key]
		if extraType ~= nil then
			if typeof(value) ~= extraType then
				error(`Tide.start: option {key} must be a {extraType}`, 4)
			end
			out[key] = value
		elseif key == "kinds" then
			if type(value) ~= "table" then
				error("Tide.start: kinds must be a table of { [kindName] = options }", 4)
			end
			for name, kindOpts in value do
				Kinds.define(name, kindOpts)
			end
			out.kinds = value
		elseif INSTANCE[key] then
			if typeof(value) ~= "Instance" then
				error(`Tide.start: option {key} must be an Instance`, 4)
			end
			(Config :: any)[key] = value
		else
			local default = (Config :: any)[key]
			if default == nil then
				error(`Tide.start: unknown option {key}`, 4)
			end
			local ok = typeof(value) == typeof(default)
			if FALSE_OR_TABLE[key] then
				ok = value == false or type(value) == "table"
			end
			if not ok then
				error(`Tide.start: option {key} must be a {typeof(default)}`, 4)
			end
			local choices = CHOICES[key]
			if choices and not choices[value] then
				error(`Tide.start: invalid value for {key}: {tostring(value)}`, 4)
			end
			if type(value) == "number" and value ~= value then
				error(`Tide.start: option {key} is NaN`, 4)
			end
			(Config :: any)[key] = value
		end
	end
	return out
end

return Options
