-- Shim for Chrono's Shared/Warn module, which is missing from Strike's wally package copy.
-- Same behaviour as upstream: warn() when the message level >= Config WARNING_SEVERITY.
local Config = require(script.Parent.Config)

local LEVELS = { NONE = 0, LOW = 1, MEDIUM = 2, HIGH = 3 }

local function enabled(level: string): boolean
	local current = LEVELS[Config._GetConfig("WARNING_SEVERITY")] or 0
	return current ~= 0 and current <= (LEVELS[level] or 0)
end

local function noop() end

return setmetatable({}, {
	__index = function(_, level: string)
		return if enabled(string.upper(level)) then warn else noop
	end,
})
