--!strict
-- Choosing the ssh destination for a Tern host.

local check = require("./check")
local config = require("./config")

local target = {}

-- Tern's `address` is `user@host[:port]` for a plain connection, but can also
-- name a Tern port or an iroh endpoint id, none of which ssh understands. Only
-- a plain `user@host` is trusted; `host` must not look like an endpoint id
-- (a long run of hex digits).
function target.from_address(address: string?): string?
	if address == nil or not check.target(address) or not string.find(address, "@", 1, true) then
		return nil
	end
	local host = string.match(address, "@(.+)$") or ""
	if #host >= 40 and string.match(host, "^%x+$") then
		return nil
	end
	return address
end

-- The destination for `host`: its own `user@host` address, else the config
-- mapping (keyed by address, then by name, then by name ignoring case), else nil.
function target.choose(host: ManagedHost, cfg: config.Config): string?
	local from_address = target.from_address(host.address)
	if from_address ~= nil then
		return from_address
	end
	local hosts = cfg.hosts
	if host.address ~= nil and hosts[host.address] ~= nil then
		return hosts[host.address]
	end
	if hosts[host.name] ~= nil then
		return hosts[host.name]
	end
	local lowered = string.lower(host.name)
	for key, value in hosts do
		if string.lower(key) == lowered then
			return value
		end
	end
	return nil
end

return target
