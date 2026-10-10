--!strict
-- URL parsing for the three link shapes the plugin acts on. Hand-written and
-- deliberately strict: anything it cannot place exactly is not matched, so the
-- link falls through to Tern's own handling.

local check = require("./check")

local url = {}

export type Parsed = {
	scheme: string, -- lowercase
	userinfo: string?,
	host: string?, -- lowercase; an IPv6 literal keeps its brackets
	port: number?, -- nil when the URL has none
	path: string, -- still percent-encoded
	query: string?,
	fragment: string?,
	has_authority: boolean,
}

local MAX_URL = 8192

-- Percent-decodes `s`. A `%` not followed by two hex digits stays literal.
-- With `plus`, `+` becomes a space (form encoding, for query values).
function url.decode(s: string, plus: boolean?): string
	local input = s
	if plus then
		input = string.gsub(input, "%+", " ")
	end
	local out = string.gsub(input, "%%(%x%x)", function(hex: string): string
		return string.char(tonumber(hex, 16) or 0)
	end)
	return out
end

-- Percent-encodes a filesystem path for a `file://` URL: every byte except
-- `A-Z a-z 0-9 / . _ ~ -`.
function url.encode_path(path: string): string
	local out = string.gsub(path, "[^%w/%._~%-]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end)
	return out
end

local function split_authority(authority: string): (string?, string?, number?, boolean)
	-- returns userinfo, host, port, ok
	local userinfo: string? = nil
	local hostport = authority
	local last_at: number? = nil
	for i = #authority, 1, -1 do
		if string.sub(authority, i, i) == "@" then
			last_at = i
			break
		end
	end
	if last_at ~= nil then
		userinfo = string.sub(authority, 1, last_at - 1)
		hostport = string.sub(authority, last_at + 1)
	end

	local host: string
	local port_text: string = ""
	if string.sub(hostport, 1, 1) == "[" then
		local close = string.find(hostport, "]", 1, true)
		if close == nil then
			return nil, nil, nil, false
		end
		host = string.sub(hostport, 1, close)
		local inner = string.sub(host, 2, -2)
		if not string.find(inner, ":", 1, true) or string.find(inner, "[^%x:.]") then
			return nil, nil, nil, false
		end
		local rest = string.sub(hostport, close + 1)
		if rest ~= "" then
			if string.sub(rest, 1, 1) ~= ":" then
				return nil, nil, nil, false
			end
			port_text = string.sub(rest, 2)
		end
	else
		local colon = string.find(hostport, ":", 1, true)
		if colon ~= nil then
			if string.find(hostport, ":", colon + 1, true) then
				return nil, nil, nil, false
			end
			host = string.sub(hostport, 1, colon - 1)
			port_text = string.sub(hostport, colon + 1)
		else
			host = hostport
		end
	end

	local port: number? = nil
	if port_text ~= "" then
		port = check.port(port_text)
		if port == nil then
			return nil, nil, nil, false
		end
	end
	return userinfo, string.lower(host), port, true
end

-- Parses `input` into its parts, or returns nil for anything malformed: control
-- characters, a bad port, an unbalanced IPv6 literal, more than one colon.
function url.parse(input: string): Parsed?
	if #input == 0 or #input > MAX_URL or string.find(input, "%c") then
		return nil
	end
	local scheme, rest = string.match(input, "^(%a[%w+.-]*):(.*)$")
	if scheme == nil or rest == nil then
		return nil
	end

	local fragment: string? = nil
	local hash = string.find(rest, "#", 1, true)
	if hash ~= nil then
		fragment = string.sub(rest, hash + 1)
		rest = string.sub(rest, 1, hash - 1)
	end
	local query: string? = nil
	local qm = string.find(rest, "?", 1, true)
	if qm ~= nil then
		query = string.sub(rest, qm + 1)
		rest = string.sub(rest, 1, qm - 1)
	end

	if string.sub(rest, 1, 2) ~= "//" then
		return {
			scheme = string.lower(scheme),
			path = rest,
			query = query,
			fragment = fragment,
			has_authority = false,
		}
	end

	rest = string.sub(rest, 3)
	local slash = string.find(rest, "/", 1, true)
	local authority = if slash ~= nil then string.sub(rest, 1, slash - 1) else rest
	local path = if slash ~= nil then string.sub(rest, slash) else ""
	local userinfo, host, port, ok = split_authority(authority)
	if not ok then
		return nil
	end
	return {
		scheme = string.lower(scheme),
		userinfo = userinfo,
		host = host,
		port = port,
		path = path,
		query = query,
		fragment = fragment,
		has_authority = true,
	}
end

-- A loopback web link with an explicit port: `http(s)://localhost|127.0.0.1|[::1]:PORT/…`.
-- Returns the parsed URL, or nil. Userinfo and a missing port disqualify, and the
-- host must be one of the three spellings exactly (a backslash, which browsers
-- treat as a slash, can only make the host or port fail to match), so what Tern
-- would navigate to is exactly what was matched.
function url.loopback_link(input: string): Parsed?
	local p = url.parse(input)
	if p == nil or (p.scheme ~= "http" and p.scheme ~= "https") then
		return nil
	end
	if p.userinfo ~= nil or p.port == nil or not check.loopback_host(p.host) then
		return nil
	end
	return p
end

-- The decoded absolute path of a `file:` URL (`file:///p`, `file://host/p`,
-- `file:/p`), or nil when it is not a usable remote path. The host part is
-- ignored: the click came from a pane of the remote machine.
function url.file_path(input: string): string?
	local p = url.parse(input)
	if p == nil or p.scheme ~= "file" then
		return nil
	end
	local decoded = url.decode(p.path)
	if not check.abs_path(decoded) then
		return nil
	end
	return decoded
end

-- The values of query parameter `name` in `query`, decoded as form data.
function url.query_values(query: string?, name: string): { string }
	local values: { string } = {}
	if query == nil then
		return values
	end
	for pair in string.gmatch(query, "[^&]+") do
		local eq = string.find(pair, "=", 1, true)
		local key = if eq ~= nil then string.sub(pair, 1, eq - 1) else pair
		if url.decode(key, true) == name then
			local value = if eq ~= nil then string.sub(pair, eq + 1) else ""
			table.insert(values, url.decode(value, true))
		end
	end
	return values
end

-- For an `http(s)` URL whose query has `redirect_uri=http(s)://localhost|127.0.0.1:PORT/…`,
-- the loopback URL it names. More than one `redirect_uri`, or a redirect to a
-- host other than localhost / 127.0.0.1, gives nil.
function url.oauth_redirect(input: string): Parsed?
	local p = url.parse(input)
	if p == nil or (p.scheme ~= "http" and p.scheme ~= "https") or not p.has_authority then
		return nil
	end
	local values = url.query_values(p.query, "redirect_uri")
	if #values ~= 1 then
		return nil
	end
	local target = url.loopback_link(values[1])
	if target == nil or target.host == "[::1]" then
		return nil
	end
	return target
end

return url
