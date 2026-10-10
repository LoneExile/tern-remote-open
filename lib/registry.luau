--!strict
-- The forwards this plugin started, kept in `tern.kv` under one key so every
-- window sees the same list. Pure over a kv-like table.

local check = require("./check")

local registry = {}

export type Entry = {
	port: number,
	-- The Tern host's display name.
	host: string,
	target: string,
	remote_host: string,
	-- The ssh control socket of this forward's process.
	socket: string,
	-- Seconds since the epoch.
	started: number,
	-- Seconds since the epoch when ssh ends by itself; nil: runs until stopped.
	expires: number?,
}

export type Kv = {
	get: (key: string) -> any,
	set: (key: string, value: any) -> (),
}

local KEY = "forwards"

local function valid(entry: any): boolean
	if type(entry) ~= "table" then
		return false
	end
	local e = entry :: { [string]: any }
	return check.port(e.port) ~= nil
		and type(e.host) == "string"
		and check.target(e.target)
		and check.loopback_host(e.remote_host)
		and check.abs_path(e.socket)
		and type(e.started) == "number"
		and (e.expires == nil or type(e.expires) == "number")
end

-- The stored entries; malformed ones (a hand-edited kv.json) are skipped.
function registry.load(kv: Kv): { Entry }
	local ok, raw = pcall(kv.get, KEY)
	local entries: { Entry } = {}
	if not ok or type(raw) ~= "table" then
		return entries
	end
	for _, item in raw :: { any } do
		if valid(item) then
			table.insert(entries, item :: Entry)
		end
	end
	return entries
end

function registry.save(kv: Kv, entries: { Entry })
	if #entries == 0 then
		kv.set(KEY, nil)
	else
		kv.set(KEY, entries)
	end
end

function registry.find(entries: { Entry }, port: number): Entry?
	for _, entry in entries do
		if entry.port == port then
			return entry
		end
	end
	return nil
end

function registry.without(entries: { Entry }, port: number): { Entry }
	local out: { Entry } = {}
	for _, entry in entries do
		if entry.port ~= port then
			table.insert(out, entry)
		end
	end
	return out
end

-- A copy of `entries` with `entry` replacing any entry for the same port.
function registry.with(entries: { Entry }, entry: Entry): { Entry }
	local out = registry.without(entries, entry.port)
	table.insert(out, entry)
	table.sort(out, function(a: Entry, b: Entry): boolean
		return a.port < b.port
	end)
	return out
end

return registry
