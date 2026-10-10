--!nocheck
-- The whole plugin against a stubbed `tern`: install it, click links, answer
-- the processes it starts, and look at what it asked Tern to do.

local h = require("./harness")
local app = require("../lib/app")
local argv = require("../lib/argv")
local classify = require("../lib/classify")
local serve = require("../lib/serve")
local fakes = require("./fakes")

h.group("app")

local KEYCLOAK = "https://auth.example.com/realms/dev/protocol/openid-connect/auth?client_id=bao&redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Foidc%2Fcallback&state=abc"
local UUID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301\n"
local TOKEN = "3f2504e04f8911d39a0c0305e82c3301"
local ALLOWED_BINARIES = {
	["/usr/bin/ssh"] = true, ["/usr/bin/scp"] = true, ["/usr/bin/nc"] = true,
	["/usr/bin/open"] = true, ["/usr/bin/find"] = true,
	["/usr/bin/perl"] = true, ["/usr/bin/uuidgen"] = true,
}

-- Builds a stub `tern`, installs the plugin, and returns the tools to drive it.
local function setup(opts)
	opts = opts or {}
	local s = {
		t = {},
		toasts = {},
		opened = {},
		procs = {},
		timers = {},
		warns = {},
		files = opts.files or {},
		dirs = {},
		removed = {},
		kv_data = {},
		ran = {},
		held = {},
	}
	local t = s.t
	t.route = {
		link = function(fn)
			s.link = fn
		end,
	}
	s.commands = {}
	t.command = function(def)
		s.commands[def.id] = def
	end
	t.plugin = { data = "/data", dir = "/plugin", id = "remote-open", name = "Remote Open" }
	t.process = {
		run = function(cmd, popts, cb)
			if opts.spawn_fails and fakes.kind(cmd) == opts.spawn_fails then
				error("No such file or directory (os error 2)")
			end
			table.insert(s.procs, { argv = cmd, opts = popts, cb = cb })
		end,
	}
	t.timer = function(ms, fn)
		table.insert(s.timers, { ms = ms, fn = fn })
	end
	t.kv = {
		get = function(key)
			return s.kv_data[key]
		end,
		set = function(key, value)
			s.kv_data[key] = value
		end,
	}
	t.fs = {
		exists = function(path)
			return s.files[path] ~= nil or s.dirs[path] == true
		end,
		read = function(path)
			return s.files[path]
		end,
		list = function(path)
			local out = {}
			local prefix = path .. "/"
			for p in s.files do
				if string.sub(p, 1, #prefix) == prefix then
					table.insert(out, string.sub(p, #prefix + 1))
				end
			end
			table.sort(out)
			return out
		end,
		remove = function(path)
			s.files[path] = nil
			table.insert(s.removed, path)
		end,
		mkdir = function(path)
			s.dirs[path] = true
		end,
	}
	t.json = {
		decode = function(text)
			if text == "BROKEN" then
				error("expected value")
			end
			return opts.config
		end,
	}
	t.log = {
		warn = function(...)
			table.insert(s.warns, table.concat({ ... }, " "))
		end,
	}
	if opts.config ~= nil or opts.broken_config then
		s.files["/data/config.json"] = if opts.broken_config then "BROKEN" else "{}"
	end

	s.hosts = opts.hosts or { fakes.host() }
	local cx_n = 0
	function s.new_cx()
		cx_n += 1
		local cx = { n = cx_n }
		cx.hosts = {
			list = function()
				return s.hosts
			end,
		}
		function cx.toast(_, level, title, sub)
			table.insert(s.toasts, { level = level, title = title, sub = sub })
		end
		function cx.open(_, target)
			if opts.open_raises then
				error("cannot open")
			end
			table.insert(s.opened, target)
		end
		-- No `browser` or `layout`: a call to either would raise and fail the test.
		return cx
	end

	app.install(t)

	-- Click `url` in a pane; returns the decision.
	function s.click(url, copts)
		return s.link(fakes.link(url, copts), s.new_cx())
	end

	-- Answers every pending process and timer until quiet. `responses` maps a
	-- command kind to a result or a function(argv, n). A server process is held
	-- (it runs until idle) unless the test gives it a result.
	function s.drain(responses)
		responses = responses or {}
		local counts = {}
		local guard = 0
		while #s.procs > 0 or #s.timers > 0 do
			guard += 1
			if guard > 600 then
				error("drain: runaway")
			end
			if #s.procs > 0 then
				local p = table.remove(s.procs, 1)
				h.truthy(ALLOWED_BINARIES[p.argv[1]], "unexpected binary " .. tostring(p.argv[1]))
				for _, a in p.argv do
					h.eq(type(a), "string")
				end
				table.insert(s.ran, p.argv)
				local kind = fakes.kind(p.argv)
				counts[kind] = (counts[kind] or 0) + 1
				local r = responses[kind]
				if type(r) == "function" then
					r = r(p.argv, counts[kind])
				end
				if r == nil and kind == "uuidgen" then
					r = fakes.ok({ stdout = UUID })
				end
				if r == nil and kind == "serve" then
					r = fakes.HOLD
				end
				if r == fakes.HOLD then
					table.insert(s.held, p)
				else
					p.cb(r or fakes.ok(), s.new_cx())
				end
			else
				local tm = table.remove(s.timers, 1)
				tm.fn(s.new_cx())
			end
		end
	end

	function s.kinds()
		local out = {}
		for _, a in s.ran do
			table.insert(out, fakes.kind(a))
		end
		return out
	end

	return s
end

local FREE = { status = 1, stdout = "", stderr = "", timed_out = false }
local DEAD = { status = 255, stdout = "", stderr = "no master", timed_out = false }

h.test("install registers one link route and the two commands, and touches no process on an empty state", function()
	local s = setup()
	h.truthy(s.link, "route.link handler")
	h.eq(s.commands.stop.title, "Remote Open: Stop forwards")
	h.eq(s.commands.list.title, "Remote Open: List forwards")
	h.eq(#s.procs, 0)
end)

h.test("install ages out old cached copies, only when the cache exists", function()
	local s = setup()
	h.eq(#s.procs, 0)
	local s2 = setup({})
	s2.dirs["/data/cache"] = true
	app.install(s2.t)
	h.eq(s2.procs[1].argv, argv.find_old("/data/cache", 7))
end)

h.test("install forgets recorded forwards that are no longer alive", function()
	local s = setup()
	s.kv_data.forwards = {
		{ port = 8250, host = "devbox", target = "you@devbox", remote_host = "localhost", socket = "/data/cm/8250.sock", started = 1 },
	}
	app.install(s.t)
	h.eq(s.kinds(), {})
	s.drain({ ssh_check = DEAD })
	h.eq(s.kinds(), { "ssh_check" })
	h.eq(s.kv_data.forwards, nil)
end)

h.test("file: the handler claims the click at once; scp, then a local server, then Tern's own open", function()
	local s = setup()
	local decision = s.click("file:///home/you/out/report.html")
	h.eq(decision, { handled = true })
	h.eq(#s.procs, 1, "scp started, nothing else yet")
	h.eq(s.toasts[1].level, "info")
	h.eq(s.toasts[1].title, "Fetching report.html…")
	local plan = classify.plan(fakes.link("file:///home/you/out/report.html"), s.hosts, { hosts = {} })
	local dest = "/data/cache/" .. plan.cache_name
	h.truthy(s.dirs["/data/cache"])
	h.eq(s.procs[1].argv, argv.scp("you@devbox", "/home/you/out/report.html", dest))
	h.eq(s.procs[1].opts.timeout_ms, 120000)
	s.drain()
	h.eq(s.kinds(), { "scp", "uuidgen", "serve", "nc" })
	local port = tonumber(s.ran[3][3])
	h.truthy(port >= 49152 and port <= 65535, "a random high port")
	h.eq(s.ran[3], argv.serve({
		script = "/plugin/serve.pl", port = port, token = TOKEN, file = dest, name = "report.html",
		content_type = "text/html; charset=utf-8", idle = 600,
	}))
	h.eq(s.opened, { serve.url(port, TOKEN, "report.html") })
	h.eq(#s.held, 1, "the server keeps running")
end)

h.test("file: the served name is the cleaned file name", function()
	local s = setup()
	s.click("file:///home/you/my%20report%20(1).html")
	s.drain()
	local port = tonumber(s.ran[3][3])
	h.eq(s.opened, { serve.url(port, TOKEN, "my_report__1_.html") })
end)

h.test("file: every file type is served with its content type", function()
	local cases = { svg = "image/svg+xml", pdf = "application/pdf", png = "image/png", jpeg = "image/jpeg", webp = "image/webp" }
	for ext, ctype in cases do
		local s = setup()
		s.click("file:///home/you/x." .. ext)
		s.drain()
		h.eq(s.ran[3][7], ctype, ext)
		h.eq(#s.opened, 1, ext)
	end
end)

h.test("file: when the server cannot start, the default browser is used and the toast says so", function()
	local s = setup()
	s.click("file:///home/you/a.pdf")
	s.drain({ serve = { status = 255, stdout = "", stderr = "perl: not found", timed_out = false }, nc = FREE })
	h.eq(s.kinds(), { "scp", "uuidgen", "serve", "nc", "open" })
	h.eq(s.ran[5][1], "/usr/bin/open")
	h.eq(s.opened, {})
	local last = s.toasts[#s.toasts]
	h.eq(last.level, "info")
	h.truthy(string.find(last.title, "default browser", 1, true), last.title)
	h.truthy(string.find(last.sub, "browser block was unavailable", 1, true))
	h.truthy(string.find(s.warns[1], "perl: not found", 1, true), "the reason is logged")
end)

h.test("file: if even the default browser cannot open it, that is an error toast", function()
	local s = setup()
	s.click("file:///home/you/a.pdf")
	s.drain({ uuidgen = { status = 1, stdout = "", stderr = "", timed_out = false }, open = { status = 1, stdout = "", stderr = "The file does not exist.\n", timed_out = false } })
	local last = s.toasts[#s.toasts]
	h.eq(last.level, "error")
	h.eq(last.title, "Could not open a.pdf")
	h.eq(last.sub, "The file does not exist.")
end)

h.test("file: Tern's open raising falls back the same way", function()
	local s = setup({ open_raises = true })
	s.click("file:///home/you/a.svg")
	s.drain()
	h.eq(s.kinds(), { "scp", "uuidgen", "serve", "nc", "open" })
end)

h.test("file: a failed fetch is an error toast and nothing is served", function()
	local s = setup()
	s.click("file:///home/you/a.html")
	s.drain({ scp = { status = 1, stdout = "", stderr = "scp: /home/you/a.html: No such file or directory\n", timed_out = false } })
	local last = s.toasts[#s.toasts]
	h.eq(last.level, "error")
	h.eq(last.title, "Could not fetch a.html")
	h.eq(last.sub, "scp: /home/you/a.html: No such file or directory")
	h.eq(s.kinds(), { "scp" })
	h.eq(s.opened, {})
end)

h.test("file: a fetch timeout says so", function()
	local s = setup()
	s.click("file:///home/you/a.html")
	s.drain({ scp = { status = -1, stdout = "", stderr = "", timed_out = true } })
	h.eq(s.toasts[#s.toasts].sub, "timed out")
end)

h.test("file: scp that cannot start is an error toast, not a crash", function()
	local s = setup({ spawn_fails = "scp" })
	h.eq(s.click("file:///home/you/a.html"), { handled = true })
	local last = s.toasts[#s.toasts]
	h.eq(last.level, "error")
	h.eq(last.title, "Could not fetch a.html")
end)

h.test("file: other extensions go to Tern untouched", function()
	local s = setup()
	h.eq(s.click("file:///home/you/notes.txt"), nil)
	h.eq(#s.toasts, 0)
	h.eq(#s.procs, 0)
end)

h.test("local: forward, wait for the port, then Tern opens the link", function()
	local s = setup()
	h.eq(s.click("http://localhost:8765/index.html"), { handled = true })
	h.eq(#s.toasts, 0, "no toast until ssh has the forward")
	s.drain({ nc = function(_, n)
		if n == 1 then
			return FREE -- nothing on the Mac's port yet
		end
		return fakes.ok() -- then the forward answers
	end })
	h.eq(s.kinds(), { "nc", "ssh_forward", "ssh_check", "nc" })
	h.eq(s.ran[2], argv.ssh_forward({ target = "you@devbox", socket = "/data/cm/8765.sock", port = 8765, remote_host = "localhost" }))
	h.eq(s.toasts[1].level, "success")
	h.eq(s.toasts[1].title, "Forwarding 127.0.0.1:8765 from devbox")
	h.eq(s.opened, { "http://localhost:8765/index.html" })
	h.eq(s.kv_data.forwards[1].port, 8765)
	h.eq(s.kv_data.forwards[1].expires, nil)
end)

h.test("local: the port is polled until it answers, without blocking", function()
	local s = setup()
	s.click("http://localhost:8765/")
	s.drain({ nc = function(_, n)
		if n <= 3 then
			return FREE
		end
		return fakes.ok()
	end })
	h.eq(s.kinds(), { "nc", "ssh_forward", "ssh_check", "nc", "nc", "nc" })
	h.eq(#s.opened, 1)
end)

h.test("local: a port that never answers is reported and nothing opens", function()
	local s = setup()
	s.click("http://localhost:8765/")
	s.drain({ nc = FREE })
	local last = s.toasts[#s.toasts]
	h.eq(last.level, "error")
	h.eq(last.title, "Port 8765 did not answer")
	h.eq(s.opened, {})
end)

h.test("local: an [::1] link is opened as 127.0.0.1 and forwarded from [::1]", function()
	local s = setup()
	s.click("http://[::1]:5173/app")
	s.drain({ nc = function(_, n)
		if n == 1 then
			return FREE
		end
		return fakes.ok()
	end })
	h.truthy(table.find(s.ran[2], "127.0.0.1:5173:[::1]:5173"))
	h.eq(s.opened, { "http://127.0.0.1:5173/app" })
end)

h.test("local: a forward that is already ours is reused with no new toast", function()
	local s = setup()
	s.kv_data.forwards = {
		{ port = 3000, host = "devbox", target = "you@devbox", remote_host = "localhost", socket = "/data/cm/3000.sock", started = 1 },
	}
	s.click("http://localhost:3000/")
	s.drain()
	h.eq(s.kinds(), { "ssh_check", "nc" })
	h.eq(#s.toasts, 0)
	h.eq(#s.opened, 1)
end)

h.test("local: a port in use on the Mac is refused with a toast naming it", function()
	local s = setup()
	h.eq(s.click("http://localhost:3000/"), { handled = true })
	s.drain({ nc = fakes.ok() })
	h.eq(s.kinds(), { "nc" })
	local last = s.toasts[#s.toasts]
	h.eq(last.level, "error")
	h.truthy(string.find(last.title, "3000", 1, true), last.title)
	h.eq(s.opened, {})
end)

h.test("local: an ssh failure is an error toast and nothing opens", function()
	local s = setup()
	s.click("http://localhost:3000/")
	s.drain({ nc = FREE, ssh_check = DEAD, ssh_forward = { status = 255, stdout = "", stderr = "you@devbox: Permission denied (publickey).", timed_out = false } })
	local last = s.toasts[#s.toasts]
	h.eq(last.title, "Could not forward port 3000 from devbox")
	h.eq(last.sub, "you@devbox: Permission denied (publickey).")
	h.eq(s.opened, {})
end)

h.test("local: allowed_ports refuses the others with a toast and claims the click", function()
	local s = setup({ config = { allowed_ports = { 3000 } } })
	h.eq(s.click("http://localhost:4000/"), { handled = true })
	h.eq(s.toasts[1].level, "error")
	h.truthy(string.find(s.toasts[1].title, "4000", 1, true))
	h.eq(#s.procs, 0)
	h.truthy(s.click("http://localhost:3000/"))
	h.eq(#s.procs, 1)
end)

h.test("oauth: forward for ten minutes, then open the sign-in page as clicked", function()
	local s = setup()
	h.eq(s.click(KEYCLOAK), { handled = true })
	s.drain({
		-- ssh stays up for the ten minutes: its process does not finish
		ssh_forward = fakes.HOLD,
		nc = function(_, n)
			if n == 1 then
				return FREE
			end
			return fakes.ok()
		end,
	})
	local forward_cmd = s.ran[2]
	h.eq(forward_cmd[#forward_cmd - 1], "sleep")
	h.eq(forward_cmd[#forward_cmd], "600")
	h.falsy(table.find(forward_cmd, "-N"))
	h.truthy(table.find(forward_cmd, "127.0.0.1:8250:localhost:8250"))
	h.eq(s.toasts[1].title, "Forwarding 127.0.0.1:8250 from devbox")
	h.truthy(string.find(s.toasts[1].sub, "10 min", 1, true), s.toasts[1].sub)
	h.eq(s.opened, { KEYCLOAK })
	h.eq(s.kv_data.forwards[1].expires - s.kv_data.forwards[1].started, 600)
	h.eq(#s.held, 1, "the forward's ssh keeps running")
end)

h.test("oauth: nothing connects through the forward before the sign-in page opens", function()
	-- A one-shot callback server on the remote side must not mistake a probe for the callback.
	local s = setup()
	s.click(KEYCLOAK)
	s.drain({
		ssh_forward = fakes.HOLD,
		nc = function(_, n)
			if n == 1 then
				return FREE
			end
			error("an nc probe ran after the forward started")
		end,
	})
	h.eq(s.kinds(), { "nc", "ssh_forward", "ssh_check" })
	h.eq(s.opened, { KEYCLOAK })
end)

h.test("oauth: if the forward fails, the sign-in page is not opened", function()
	local s = setup()
	s.click(KEYCLOAK)
	s.drain({ nc = fakes.ok() }) -- port 8250 is busy on the Mac
	h.eq(s.opened, {})
	h.eq(s.toasts[#s.toasts].level, "error")
end)

h.test("holding alt leaves every kind of link to Tern", function()
	local s = setup()
	for _, url in { "file:///home/you/a.html", "http://localhost:3000/", KEYCLOAK } do
		h.eq(s.click(url, { alt = true }), nil, url)
	end
	h.eq(#s.procs, 0)
	h.eq(#s.toasts, 0)
end)

h.test("links from no pane, local panes and disconnected hosts are left to Tern", function()
	local s = setup()
	h.eq(s.click("file:///home/you/a.html", { pane = false }), nil)
	s.hosts = { fakes.host({ state = "reconnecting" }) }
	h.eq(s.click("file:///home/you/a.html"), nil)
	s.hosts = { fakes.host({ kind = "local", name = "local" }) }
	h.eq(s.click("http://localhost:3000/"), nil)
	h.eq(#s.procs, 0)
	h.eq(#s.toasts, 0)
end)

h.test("unrelated links are left to Tern", function()
	local s = setup()
	for _, url in { "https://example.com/", "mailto:you@devbox", "http://localhost/", "file:///home/you/a.txt" } do
		h.eq(s.click(url), nil, url)
	end
	h.eq(#s.toasts, 0)
end)

h.test("no usable ssh target: a toast, then Tern's own handling", function()
	local s = setup({ hosts = { fakes.host({ address = "you@devbox:8376" }) } })
	h.eq(s.click("file:///home/you/a.html"), nil)
	h.eq(s.toasts[1].level, "error")
	h.eq(s.toasts[1].title, "No SSH target for devbox")
	h.eq(#s.procs, 0)
end)

h.test("config.json maps an unusable address to an ssh target", function()
	local s = setup({
		hosts = { fakes.host({ address = "you@devbox:8376" }) },
		config = { hosts = { devbox = "me@devbox.lan" } },
	})
	h.eq(s.click("file:///home/you/a.html"), { handled = true })
	h.eq(s.procs[1].argv[#s.procs[1].argv - 1], "me@devbox.lan:/home/you/a.html")
end)

h.test("a broken config.json is ignored with a warning, never a crash", function()
	local s = setup({ broken_config = true })
	h.eq(s.click("file:///home/you/a.html"), { handled = true })
	h.truthy(string.find(s.warns[1], "not valid JSON", 1, true), s.warns[1])
	local s2 = setup({ config = { hosts = { bad = "-oFoo" }, allowed_ports = "x" } })
	s2.click("http://localhost:3000/")
	h.eq(#s2.warns, 2)
end)

h.test("config.json is re-read on every click, with no reload", function()
	local s = setup({ config = { allowed_ports = { 3000 } } })
	h.eq(s.click("http://localhost:4000/"), { handled = true })
	h.eq(#s.procs, 0)
	s.t.json.decode = function()
		return { allowed_ports = { 4000 } }
	end
	s.click("http://localhost:4000/")
	h.eq(#s.procs, 1)
end)

h.test("a handler only starts work: no process has finished when it returns", function()
	local s = setup()
	local before = #s.procs
	s.click("file:///home/you/a.html")
	h.eq(#s.procs - before, 1)
	h.eq(#s.opened, 0)
end)

h.test("Stop forwards ends ours, names the ports, and clears the record", function()
	local s = setup()
	s.kv_data.forwards = {
		{ port = 8250, host = "devbox", target = "you@devbox", remote_host = "localhost", socket = "/data/cm/8250.sock", started = 1 },
	}
	s.files["/data/cm/8250.sock"] = "x"
	s.files["/data/cm/9001.sock"] = "x"
	s.commands.stop.run(s.new_cx())
	s.drain()
	h.eq(#s.ran, 2)
	for _, cmd in s.ran do
		h.eq(fakes.kind(cmd), "ssh_exit")
	end
	h.eq(s.toasts[1].level, "success")
	h.eq(s.toasts[1].title, "Stopped 2 forwards")
	h.eq(s.toasts[1].sub, "8250, 9001")
	h.eq(s.kv_data.forwards, nil)
end)

h.test("Stop forwards with nothing running says so", function()
	local s = setup()
	s.commands.stop.run(s.new_cx())
	s.drain()
	h.eq(s.toasts[1].title, "No forwards to stop")
end)

h.test("List forwards shows live forwards, with time left on timed ones", function()
	local s = setup()
	local now = os.time()
	s.kv_data.forwards = {
		{ port = 3000, host = "devbox", target = "you@devbox", remote_host = "localhost", socket = "/data/cm/3000.sock", started = now },
		{ port = 8250, host = "devbox", target = "you@devbox", remote_host = "localhost", socket = "/data/cm/8250.sock", started = now, expires = now + 540 },
		{ port = 9000, host = "gone", target = "you@gone", remote_host = "localhost", socket = "/data/cm/9000.sock", started = now },
	}
	s.commands.list.run(s.new_cx())
	s.drain({ ssh_check = function(cmd)
		if table.find(cmd, "/data/cm/9000.sock") then
			return DEAD
		end
		return fakes.ok()
	end })
	h.eq(s.toasts[1].title, "Remote Open: 2 forwards")
	h.eq(s.toasts[1].sub, "3000 ← devbox; 8250 ← devbox (9 min left)")
	h.eq(#s.kv_data.forwards, 2, "the dead one was dropped")
	local s2 = setup()
	s2.commands.list.run(s2.new_cx())
	s2.drain()
	h.eq(s2.toasts[1].title, "No forwards running")
end)

h.test("no process the plugin runs goes through a shell", function()
	local s = setup()
	s.click("file:///home/you/a b; rm -rf ~.html")
	s.click("http://localhost:3000/")
	s.click(KEYCLOAK)
	s.drain({ nc = FREE })
	for _, cmd in s.ran do
		h.truthy(ALLOWED_BINARIES[cmd[1]], cmd[1])
		for _, a in cmd do
			h.falsy(a == "sh" or a == "bash" or a == "-c", "no shell: " .. a)
		end
	end
end)

return {}
