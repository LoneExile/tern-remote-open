--!strict
-- Deciding what a link click means. Pure: takes the link, the host list and the
-- config, returns a plan. All effects happen in app.luau.

local check = require("./check")
local config = require("./config")
local hostlib = require("./hosts")
local serve = require("./serve")
local targetlib = require("./target")
local text = require("./text")
local url = require("./url")

local classify = {}

-- Seconds an OAuth loopback forward lives: ten minutes.
classify.OAUTH_TTL = 600

local MAX_NAME = 80

export type Link = {
	url: string,
	pane: number?,
	mods: { cmd: boolean?, alt: boolean?, shift: boolean?, ctrl: boolean? },
}

export type Plan = {
	kind: "pass" | "no_target" | "refuse" | "file" | "local" | "oauth",
	-- The Tern host's display name, cleaned for a toast.
	host_name: string?,
	target: string?,
	-- file
	path: string?,
	name: string?,
	cache_name: string?,
	-- The lowercase extension: the key into the content types.
	ext: string?,
	-- local, oauth
	port: number?,
	remote_host: string?,
	scheme: string?,
	-- The URL to open once the forward is up.
	open_url: string?,
	ttl: number?,
	-- refuse
	title: string?,
	detail: string?,
}

local PASS: Plan = { kind = "pass" }

local function extension(path: string): string
	local name = string.match(path, "([^/]*)$") or ""
	return string.lower(string.match(name, "%.([%w]+)$") or "")
end

local function listed(ports: { number }, port: number): boolean
	for _, p in ports do
		if p == port then
			return true
		end
	end
	return false
end

-- Rebuilds the URL to open with the host Tern can reach: the forward binds
-- 127.0.0.1, so an `[::1]` link is rewritten to it. Everything else is kept as
-- the user clicked it.
local function open_url_for(input: string, parsed: url.Parsed): string
	if parsed.host ~= "[::1]" then
		return input
	end
	local rest = string.match(input, "^[%a][%w+.-]*://[^/?#]*(.*)$") or "/"
	return string.format("%s://127.0.0.1:%d%s", parsed.scheme, parsed.port or 0, rest)
end

-- The plan for fetching `file_path` from `host` over `target`.
local function file_plan(host: ManagedHost, target: string, file_path: string): Plan
	local base = string.match(file_path, "([^/]*)$") or "file"
	local name = text.safe_name(base, MAX_NAME)
	return {
		kind = "file",
		host_name = text.clean(host.name, 60),
		target = target,
		path = file_path,
		name = name,
		cache_name = text.hash8(host.name .. "\0" .. file_path) .. "-" .. name,
		ext = extension(file_path),
	}
end

-- `link` is what Tern passed to the route; `host_list` is `cx.hosts:list()`.
function classify.plan(link: Link, host_list: { ManagedHost }, cfg: config.Config): Plan
	-- Not from a pane, or ⌥ held: Tern's normal handling.
	if link.pane == nil or link.mods.alt == true then
		return PASS
	end
	local host = hostlib.host_for_pane(host_list, link.pane)
	if host == nil or not hostlib.eligible(host) then
		return PASS
	end

	local kind: string? = nil
	local file_path: string? = nil
	local loopback: url.Parsed? = nil

	if string.sub(link.url, 1, 5) == "file:" then
		file_path = url.file_path(link.url)
		if file_path ~= nil and serve.CONTENT_TYPES[extension(file_path)] then
			kind = "file"
		end
	else
		loopback = url.loopback_link(link.url)
		if loopback ~= nil then
			kind = "local"
		else
			loopback = url.oauth_redirect(link.url)
			if loopback ~= nil then
				kind = "oauth"
			end
		end
	end
	if kind == nil then
		return PASS
	end

	local host_name = text.clean(host.name, 60)
	local target = targetlib.choose(host, cfg)
	if target == nil then
		return { kind = "no_target", host_name = host_name }
	end

	if kind == "file" and file_path ~= nil then
		return file_plan(host, target, file_path)
	end

	if loopback ~= nil and loopback.port ~= nil and loopback.host ~= nil then
		local port = loopback.port
		if kind == "local" and cfg.allowed_ports ~= nil and not listed(cfg.allowed_ports, port) then
			return {
				kind = "refuse",
				host_name = host_name,
				title = string.format("Port %d is not allowed", port),
				detail = "allowed_ports in config.json does not list it",
			}
		end
		return {
			kind = kind :: "local" | "oauth",
			host_name = host_name,
			target = target,
			port = port,
			remote_host = loopback.host,
			scheme = loopback.scheme,
			open_url = open_url_for(link.url, loopback),
			ttl = if kind == "oauth" then classify.OAUTH_TTL else nil,
		}
	end
	return PASS
end

-- A file open (`tern.route.open`): an image path clicked in a pane of a
-- connected remote host (origin `link`: a path printed in a terminal, or a file
-- link no link route claimed) is fetched and shown in the image viewer. Every
-- other open, and any image opened another way, is left to Tern.
function classify.plan_open(req: OpenRequest, host_list: { ManagedHost }, cfg: config.Config): Plan
	if req.origin ~= "link" or not serve.VIEWER[extension(req.path)] or not check.abs_path(req.path) then
		return PASS
	end
	local host = hostlib.host_named(host_list, req.host)
	if not host or not hostlib.eligible(host) then
		return PASS
	end
	local target = targetlib.choose(host, cfg)
	if target == nil then
		return { kind = "no_target", host_name = text.clean(host.name, 60) }
	end
	return file_plan(host, target, req.path)
end

return classify
