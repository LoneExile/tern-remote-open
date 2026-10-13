--!strict
-- The effects: toasts, processes, opening pages. `install` registers the link
-- and open routes and the two palette commands; every decision is made by the
-- pure modules, every slow step runs in a callback, so no handler nears Tern's
-- 50 ms.

local argv = require("./argv")
local check = require("./check")
local classify = require("./classify")
local config = require("./config")
local forward = require("./forward")
local serve = require("./serve")
local text = require("./text")

local app = {}

local CACHE_DAYS = 7
local FETCH_TIMEOUT_MS = 120000
local READY_ATTEMPTS = 20
local READY_DELAY_MS = 250

export type Tern = typeof(tern)

type Ctx = {
	t: Tern,
	env: forward.Env,
}

local function toast(cx: WindowCx?, level: ToastLevel, title: string, sub: string?)
	if cx ~= nil then
		cx:toast(level, title, sub)
	end
end

-- The `Env` the forward and serve modules run on, over the real `tern` API.
function app.make_env(t: Tern): forward.Env
	math.randomseed(os.time() + math.floor(os.clock() * 1000000))
	return {
		run = function(cmd: { string }, timeout_ms: number, cx: WindowCx?, cb: (forward.RunResult, WindowCx?) -> ())
			local started, err = pcall(function()
				t.process.run(cmd, { timeout_ms = timeout_ms }, function(res: ProcessResult, cx2: WindowCx?)
					cb(res, cx2)
				end)
			end)
			if not started then
				cb({ status = -2, stdout = "", stderr = tostring(err), timed_out = false }, cx)
			end
		end,
		after = function(ms: number, cb: (WindowCx?) -> ())
			t.timer(ms, cb)
		end,
		kv = {
			get = function(key: string): any
				return t.kv.get(key)
			end,
			set = function(key: string, value: any)
				t.kv.set(key, value)
			end,
		},
		now = function(): number
			return os.time()
		end,
		exists = function(path: string): boolean
			return t.fs.exists(path)
		end,
		list = function(path: string): { string }
			return t.fs.list(path)
		end,
		remove = function(path: string)
			t.fs.remove(path)
		end,
		mkdir = function(path: string)
			t.fs.mkdir(path)
		end,
		random = function(low: number, high: number): number
			return math.random(low, high)
		end,
		data_dir = t.plugin.data,
	}
end

-- `config.json` from the data directory, re-read on every click so an edit
-- needs no reload. A missing or broken file is the default config.
function app.load_config(t: Tern): config.Config
	local path = t.plugin.data .. "/config.json"
	local raw: any = nil
	local present = t.fs.exists(path)
	if present then
		local ok, body = pcall(t.fs.read, path, 65536)
		if ok then
			local decoded, value = pcall(t.json.decode, body)
			if decoded then
				raw = value
			else
				t.log.warn("remote-open: config.json is not valid JSON")
			end
		else
			t.log.warn("remote-open: cannot read config.json")
		end
	end
	local result = config.normalize(raw)
	for _, warning in result.warnings do
		t.log.warn("remote-open: " .. warning)
	end
	return result.config
end

-- Opens the fetched copy in Tern's browser block, through the preview server;
-- when the server cannot start, in the macOS default browser, and says so.
local function open_copy(ctx: Ctx, cx: WindowCx, copy: string, name: string, ext: string)
	local function fallback(cx2: WindowCx?, why: string?)
		ctx.t.log.warn("remote-open: preview server unavailable: " .. (why or "unknown"))
		ctx.env.run(argv.open(copy), 10000, cx2, function(res: forward.RunResult, cx3: WindowCx?)
			if res.status == 0 then
				toast(cx3, "info", "Opened " .. name .. " in the default browser", "Tern's browser block was unavailable")
			else
				toast(cx3, "error", "Could not open " .. name, text.first_line(res.stderr, 160))
			end
		end)
	end
	local request: serve.Request = { script = ctx.t.plugin.dir .. "/serve.pl", file = copy, name = name, ext = ext }
	-- An image gets the viewer: Save copies it into ~/Downloads, Copy puts it on
	-- the clipboard. Without a usable HOME there is no Downloads, so no viewer.
	local home = ctx.t.getenv("HOME")
	if serve.VIEWER[ext] and home ~= nil and check.abs_path(home) then
		request.downloads = home .. "/Downloads"
		request.copier = argv.copier(ctx.t.plugin.dir .. "/copy-image.js")
	end
	serve.start(ctx.env, request, cx, function(result: serve.Result, cx2: WindowCx?)
		local page = result.url
		if result.ok and page ~= nil and cx2 ~= nil then
			local opened, err = pcall(function()
				cx2:open(page)
			end)
			if not opened then
				fallback(cx2, tostring(err))
			end
		else
			fallback(cx2, result.detail)
		end
	end)
end

local function start_file(ctx: Ctx, plan: classify.Plan, cx: WindowCx)
	local name = plan.name or "file"
	local cache = ctx.t.plugin.data .. "/cache"
	local dest = cache .. "/" .. (plan.cache_name or name)
	toast(cx, "info", "Fetching " .. name .. "…", plan.host_name)
	local ok, err = pcall(function()
		ctx.t.fs.mkdir(cache)
	end)
	if not ok then
		toast(cx, "error", "Cannot create the cache directory", text.clean(tostring(err), 120))
		return
	end
	local built, cmd = pcall(argv.scp, plan.target or "", plan.path or "", dest)
	if not built then
		toast(cx, "error", "Cannot fetch " .. name, text.clean(tostring(cmd), 120))
		return
	end
	ctx.env.run(cmd :: { string }, FETCH_TIMEOUT_MS, cx, function(res: forward.RunResult, cx2: WindowCx?)
		if res.status ~= 0 then
			local why = if res.timed_out then "timed out" else text.first_line(res.stderr, 160)
			toast(cx2, "error", "Could not fetch " .. name, why)
			return
		end
		if cx2 ~= nil then
			open_copy(ctx, cx2, dest, name, plan.ext or "")
		end
	end)
end

-- Polls until 127.0.0.1:PORT accepts a connection, then calls `ready`.
local function wait_port(
	ctx: Ctx,
	port: number,
	attempt: number,
	cx: WindowCx?,
	ready: (WindowCx?) -> (),
	gave_up: (WindowCx?) -> ()
)
	ctx.env.run(argv.nc_probe(port), 5000, cx, function(res: forward.RunResult, cx2: WindowCx?)
		if res.status == 0 then
			ready(cx2)
		elseif attempt >= READY_ATTEMPTS then
			gave_up(cx2)
		else
			ctx.env.after(READY_DELAY_MS, function(cx3: WindowCx?)
				wait_port(ctx, port, attempt + 1, cx3, ready, gave_up)
			end)
		end
	end)
end

local function start_forward(ctx: Ctx, cfg: config.Config, plan: classify.Plan, cx: WindowCx)
	local port = plan.port or 0
	local host = plan.host_name or "remote"
	local request: forward.Request = {
		port = port,
		remote_host = plan.remote_host or "",
		target = plan.target or "",
		host_name = host,
		ttl = plan.ttl,
	}
	forward.ensure(ctx.env, cfg, request, cx, function(result: forward.Result, cx2: WindowCx?)
		if not result.ok then
			toast(cx2, "error", result.title or "Could not forward the port", result.detail)
			return
		end
		if result.reused ~= true then
			if plan.ttl ~= nil then
				toast(
					cx2,
					"success",
					string.format("Forwarding 127.0.0.1:%d from %s", port, host),
					string.format("for the sign-in callback, closes in %d min", math.floor(plan.ttl / 60))
				)
			else
				toast(
					cx2,
					"success",
					string.format("Forwarding 127.0.0.1:%d from %s", port, host),
					"Remote Open: Stop forwards ends it"
				)
			end
		end
		local open_url = plan.open_url or ""
		local function open_now(cx3: WindowCx?)
			-- Tern's own open of a web link: its browser block, per `link_target`.
			if cx3 ~= nil then
				cx3:open(open_url)
			end
		end
		if plan.kind == "oauth" then
			-- No probe: a connection through the forward would reach the program
			-- waiting for the callback, and a one-shot server could take that bare
			-- connection for the callback and exit. `forward.ensure` already
			-- confirmed the listener is bound.
			open_now(cx2)
			return
		end
		wait_port(ctx, port, 1, cx2, open_now, function(cx3: WindowCx?)
			toast(
				cx3,
				"error",
				string.format("Port %d did not answer", port),
				"The forward is up, but nothing accepted a connection"
			)
		end)
	end)
end

-- Carries out a plan; the route's decision.
local function act(ctx: Ctx, cfg: config.Config, plan: classify.Plan, cx: WindowCx): RouteDecision?
	if plan.kind == "pass" then
		return nil
	elseif plan.kind == "no_target" then
		toast(
			cx,
			"error",
			"No SSH target for " .. (plan.host_name or "this host"),
			"Add it to config.json (see the Remote Open README)"
		)
		return nil
	elseif plan.kind == "refuse" then
		toast(cx, "error", plan.title or "Refused", plan.detail)
		return { handled = true }
	elseif plan.kind == "file" then
		start_file(ctx, plan, cx)
		return { handled = true }
	elseif plan.kind == "show" then
		open_copy(ctx, cx, plan.path or "", plan.name or "file", plan.ext or "")
		return { handled = true }
	else
		start_forward(ctx, cfg, plan, cx)
		return { handled = true }
	end
end

local function on_link(ctx: Ctx, link: LinkRequest, cx: WindowCx): RouteDecision?
	local cfg = app.load_config(ctx.t)
	return act(ctx, cfg, classify.plan(link, cx.hosts:list(), cfg), cx)
end

local function on_open(ctx: Ctx, req: OpenRequest, cx: WindowCx): RouteDecision?
	local cfg = app.load_config(ctx.t)
	return act(ctx, cfg, classify.plan_open(req, cx.hosts:list(), cfg), cx)
end

-- Render in browser: the page in the focused file block, in Tern's browser block.
local function render(ctx: Ctx, cx: WindowCx)
	local pane = cx.session:focused()
	local info = if pane ~= nil then cx.session:pane(pane) else nil
	local cfg = app.load_config(ctx.t)
	act(ctx, cfg, classify.plan_render(info, cx.hosts:list(), cfg), cx)
end

local function describe(listing: forward.Listing, now: number): string
	local parts: { string } = {}
	for _, e in listing.alive do
		local left = ""
		if e.expires ~= nil then
			left = string.format(" (%d min left)", math.max(0, math.ceil((e.expires - now) / 60)))
		end
		table.insert(parts, string.format("%d ← %s%s", e.port, text.clean(e.host, 40), left))
	end
	return table.concat(parts, "; ")
end

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

local function list_forwards(ctx: Ctx, cx: WindowCx)
	forward.refresh(ctx.env, cx, function(listing: forward.Listing, cx2: WindowCx?)
		if #listing.alive == 0 then
			toast(cx2, "info", "No forwards running")
		else
			toast(cx2, "info", "Remote Open: " .. plural(#listing.alive, "forward"), describe(listing, os.time()))
		end
	end)
end

local function stop_forwards(ctx: Ctx, cx: WindowCx)
	local cfg = app.load_config(ctx.t)
	forward.stop_all(ctx.env, cfg, cx, function(stopped: forward.Stopped, cx2: WindowCx?)
		if #stopped.ports == 0 and stopped.failed == 0 then
			toast(cx2, "info", "No forwards to stop")
			return
		end
		local ports: { string } = {}
		for _, p in stopped.ports do
			table.insert(ports, string.format("%d", p))
		end
		local level: ToastLevel = if stopped.failed > 0 then "error" else "success"
		toast(cx2, level, "Stopped " .. plural(#stopped.ports, "forward"), table.concat(ports, ", "))
	end)
end

-- Registers the plugin on `t`: the link and open routes, the three commands, and
-- the load-time housekeeping (forget dead forwards, age out old cached copies).
function app.install(t: Tern)
	local ctx: Ctx = { t = t, env = app.make_env(t) }

	t.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
		return on_link(ctx, link, cx)
	end)
	t.route.open(function(req: OpenRequest, cx: WindowCx): RouteDecision?
		return on_open(ctx, req, cx)
	end)

	t.command({
		id = "list",
		title = "Remote Open: List forwards",
		run = function(cx: WindowCx)
			list_forwards(ctx, cx)
		end,
	})
	t.command({
		id = "stop",
		title = "Remote Open: Stop forwards",
		run = function(cx: WindowCx)
			stop_forwards(ctx, cx)
		end,
	})
	t.command({
		id = "render",
		title = "Remote Open: Render in browser",
		available = function(cx: WindowCx): boolean
			local pane = cx.session:focused()
			return pane ~= nil and classify.renderable(cx.session:pane(pane))
		end,
		run = function(cx: WindowCx)
			render(ctx, cx)
		end,
	})

	forward.refresh(ctx.env, nil, function() end)
	local cache = t.plugin.data .. "/cache"
	if t.fs.exists(cache) then
		ctx.env.run(argv.find_old(cache, CACHE_DAYS), 20000, nil, function() end)
	end
end

return app
