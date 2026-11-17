--!optimize 2
-- Minimal JSON encoder (sorted object keys, arrays detected by 1..n keys).

local function encodeString(s: string): string
	s = string.gsub(s, '[%c"\\]', function(c)
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. s .. '"'
end

local encode

local function isArray(t): boolean
	local n = #t
	local count = 0
	for _ in t do
		count += 1
	end
	return count == n and (n > 0 or next(t) == nil)
end

function encode(v: any, out: { string })
	local t = type(v)
	if t == "nil" then
		table.insert(out, "null")
	elseif t == "boolean" then
		table.insert(out, if v then "true" else "false")
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			table.insert(out, "null")
		elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			table.insert(out, string.format("%d", v))
		else
			table.insert(out, string.format("%.17g", v))
		end
	elseif t == "string" then
		table.insert(out, encodeString(v))
	elseif t == "table" then
		if isArray(v) and #v > 0 then
			table.insert(out, "[")
			for i, item in ipairs(v) do
				if i > 1 then
					table.insert(out, ",")
				end
				encode(item, out)
			end
			table.insert(out, "]")
		else
			local keys = {}
			local original = {}
			for k in v do
				local ks = tostring(k)
				table.insert(keys, ks)
				original[ks] = k
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, k in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, encodeString(k))
				table.insert(out, ":")
				encode(v[original[k]], out)
			end
			table.insert(out, "}")
		end
	else
		table.insert(out, encodeString(tostring(v)))
	end
end

return {
	encode = function(v: any): string
		local out = {}
		encode(v, out)
		return table.concat(out)
	end,
}
