--!strict
-- Input validators. Everything that reaches an argv goes through one of these.

local check = {}

-- A TCP port as a number: an integer from 1 to 65535.
function check.port(value: any): number?
	local n: number? = nil
	if type(value) == "number" then
		n = value
	elseif type(value) == "string" and string.match(value, "^%d+$") and #value <= 5 then
		n = tonumber(value)
	end
	if n == nil or n ~= math.floor(n) or n < 1 or n > 65535 then
		return nil
	end
	return n
end

-- An absolute path with no control characters (no newline, no NUL).
function check.abs_path(value: any): boolean
	return type(value) == "string"
		and #value > 1
		and string.sub(value, 1, 1) == "/"
		and not string.find(value, "%c")
end

local LABEL = "[%w_][%w_.-]*"

-- An ssh destination: `user@host` or a bare host/alias. Never starts with `-`,
-- never carries a port, a bracket, a colon or whitespace.
function check.target(value: any): boolean
	if type(value) ~= "string" or #value == 0 or #value > 255 then
		return false
	end
	return string.match(value, "^" .. LABEL .. "@" .. LABEL .. "$") ~= nil
		or string.match(value, "^" .. LABEL .. "$") ~= nil
end

-- The three loopback host spellings the plugin recognises, lowercase.
local LOOPBACK = { ["localhost"] = true, ["127.0.0.1"] = true, ["[::1]"] = true }

function check.loopback_host(host: string?): boolean
	return host ~= nil and LOOPBACK[host] == true
end

return check
