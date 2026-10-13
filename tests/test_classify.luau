--!nocheck
local h = require("./harness")
local classify = require("../lib/classify")
local config = require("../lib/config")
local fakes = require("./fakes")

h.group("classify")

local function cfg(raw)
	return config.normalize(raw).config
end
local DEFAULT = cfg({})

local function plan(url, opts, hosts, c)
	return classify.plan(fakes.link(url, opts), hosts or { fakes.host() }, c or DEFAULT)
end

local KEYCLOAK = "https://auth.example.com/realms/dev/protocol/openid-connect/auth?client_id=bao&redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Foidc%2Fcallback&state=abc"

h.test("a click that is not in a pane is left to Tern", function()
	h.eq(plan("file:///tmp/a.html", { pane = false }).kind, "pass")
	h.eq(plan("http://localhost:3000/", { pane = false }).kind, "pass")
end)

h.test("holding alt passes through, other modifiers do not", function()
	h.eq(plan("file:///tmp/a.html", { alt = true }).kind, "pass")
	h.eq(plan("http://localhost:3000/", { alt = true }).kind, "pass")
	h.eq(plan(KEYCLOAK, { alt = true }).kind, "pass")
	h.eq(plan("file:///tmp/a.html", { cmd = true }).kind, "file")
	h.eq(plan("file:///tmp/a.html", { shift = true }).kind, "file")
	h.eq(plan("file:///tmp/a.html", { ctrl = true }).kind, "file")
end)

h.test("a pane on the local host, or on no listed host, passes", function()
	h.eq(plan("file:///tmp/a.html", {}, { fakes.host({ kind = "local", name = "local" }) }).kind, "pass")
	h.eq(plan("file:///tmp/a.html", { pane = 99 }).kind, "pass")
	h.eq(plan("file:///tmp/a.html", {}, {}).kind, "pass")
end)

h.test("a host that is not connected passes, whatever its state", function()
	for _, state in { "connecting", "stalled", "verify", "reconnecting", "failed" } do
		h.eq(plan("file:///tmp/a.html", {}, { fakes.host({ state = state }) }).kind, "pass", state)
		h.eq(plan("http://localhost:3000/", {}, { fakes.host({ state = state }) }).kind, "pass", state)
	end
end)

h.test("the host is found by pane membership among several", function()
	local hosts = {
		fakes.host({ id = 1, name = "one", address = "a@one", panes = { 1 } }),
		fakes.host({ id = 2, name = "two", address = "b@two", panes = { 2, 41 } }),
	}
	local p = plan("file:///tmp/a.html", { pane = 41 }, hosts)
	h.eq(p.target, "b@two")
	h.eq(p.host_name, "two")
end)

h.test("file: every listed extension, any case, is a file plan", function()
	for _, ext in { "html", "htm", "svg", "pdf", "png", "jpg", "jpeg", "gif", "webp", "HTML", "PdF", "JPEG" } do
		local p = plan("file:///home/you/out/report." .. ext)
		h.eq(p.kind, "file", ext)
		h.eq(p.path, "/home/you/out/report." .. ext)
		h.eq(p.target, "you@devbox")
	end
end)

h.test("file: other extensions, extensionless and odd names pass", function()
	for _, bad in { "a.txt", "a.md", "a.json", "a", "a.html.bak", "a.htmlx", ".html", "a.js", "a.exe", "a.tar.gz", "html" } do
		local p = plan("file:///tmp/" .. bad)
		-- `.html` is a file named ".html" whose extension is html: allowed. Everything else passes.
		if bad == ".html" then
			h.eq(p.kind, "file", bad)
		else
			h.eq(p.kind, "pass", bad)
		end
	end
	h.eq(plan("file:///tmp/dir.html/").kind, "pass", "a directory-looking path has no file extension")
end)

h.test("file: file://host/path, percent-decoding, name and cache name", function()
	local p = plan("file://devbox/home/you/my%20report%20%281%29.html")
	h.eq(p.kind, "file")
	h.eq(p.path, "/home/you/my report (1).html")
	h.eq(p.name, "my_report__1_.html")
	h.truthy(string.match(p.cache_name, "^%x%x%x%x%x%x%x%x%-my_report__1_%.html$"), p.cache_name)
end)

h.test("file: the cache name depends on host and path, and is stable", function()
	local a = plan("file:///tmp/a.html").cache_name
	h.eq(plan("file:///tmp/a.html").cache_name, a)
	h.truthy(plan("file:///tmp/b/a.html").cache_name ~= a, "same basename, other directory")
	local other = plan("file:///tmp/a.html", {}, { fakes.host({ name = "other", address = "you@other" }) }).cache_name
	h.truthy(other ~= a, "same path, other host")
end)

h.test("file: bad paths pass", function()
	h.eq(plan("file:///tmp/a%0A.html").kind, "pass")
	h.eq(plan("file:///tmp/a%00.html").kind, "pass")
	h.eq(plan("file://").kind, "pass")
	h.eq(plan("file:relative.html").kind, "pass")
end)

h.test("file: the cache name never carries a path separator", function()
	local p = plan("file:///tmp/%2E%2E%2F%2E%2E%2Fetc%2Fx.html")
	h.eq(p.kind, "file")
	h.falsy(string.find(p.cache_name, "/", 1, true))
	h.falsy(string.find(p.cache_name, "..", 1, true) and string.find(p.cache_name, "/", 1, true))
end)

h.test("local: localhost, 127.0.0.1 and [::1] links become forwards", function()
	local p = plan("http://localhost:8765/index.html")
	h.eq(p.kind, "local")
	h.eq(p.port, 8765)
	h.eq(p.remote_host, "localhost")
	h.eq(p.scheme, "http")
	h.eq(p.open_url, "http://localhost:8765/index.html")
	h.eq(p.target, "you@devbox")
	h.eq(p.ttl, nil)
	h.eq(plan("https://127.0.0.1:8443/a?b=c#d").open_url, "https://127.0.0.1:8443/a?b=c#d")
	h.eq(plan("https://127.0.0.1:8443/").scheme, "https")
	h.eq(plan("http://127.0.0.1:3000").remote_host, "127.0.0.1")
end)

h.test("local: an [::1] link forwards to [::1] and opens as 127.0.0.1", function()
	local p = plan("http://[::1]:5173/app?x=1#y")
	h.eq(p.kind, "local")
	h.eq(p.remote_host, "[::1]")
	h.eq(p.open_url, "http://127.0.0.1:5173/app?x=1#y")
	h.eq(plan("http://[::1]:5173").open_url, "http://127.0.0.1:5173")
end)

h.test("local: no port, a wrong host or a lookalike pass", function()
	for _, bad in {
		"http://localhost/", "http://localhost:/", "http://localhost.evil.com:80/", "http://127.0.0.2:80/",
		"http://localhost:8250@evil.com/", "http://evil.com:8250/", "https://example.com/", "ftp://localhost:21/",
		"mailto:you@devbox", "ssh://devbox", "http://localhost:99999/",
	} do
		h.eq(plan(bad).kind, "pass", bad)
	end
end)

h.test("oauth: a redirect_uri to localhost makes a timed forward that opens the link as clicked", function()
	local p = plan(KEYCLOAK)
	h.eq(p.kind, "oauth")
	h.eq(p.port, 8250)
	h.eq(p.ttl, 600)
	h.eq(p.remote_host, "localhost")
	h.eq(p.open_url, KEYCLOAK)
	h.eq(p.target, "you@devbox")
end)

h.test("oauth: 127.0.0.1 in redirect_uri; [::1] or a foreign host passes", function()
	local u = "https://idp.example.com/auth?redirect_uri=http%3A%2F%2F127.0.0.1%3A9001%2Fcb"
	h.eq(plan(u).remote_host, "127.0.0.1")
	h.eq(plan(u).port, 9001)
	h.eq(plan("https://idp.example.com/auth?redirect_uri=http%3A%2F%2F%5B%3A%3A1%5D%3A9001%2Fcb").kind, "pass")
	h.eq(plan("https://idp.example.com/auth?redirect_uri=http%3A%2F%2Fexample.com%3A9001%2Fcb").kind, "pass")
	h.eq(plan("https://idp.example.com/auth").kind, "pass")
end)

h.test("oauth: a loopback link whose redirect_uri is loopback too is a local link", function()
	local p = plan("http://localhost:4000/login?redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Fcb")
	h.eq(p.kind, "local")
	h.eq(p.port, 4000)
end)

h.test("target: none available gives no_target, but only for links we would handle", function()
	local nothing = { fakes.host({ address = "you@devbox:8376", name = "devbox" }) }
	local p = plan("file:///tmp/a.html", {}, nothing)
	h.eq(p.kind, "no_target")
	h.eq(p.host_name, "devbox")
	h.eq(plan("http://localhost:3000/", {}, nothing).kind, "no_target")
	h.eq(plan(KEYCLOAK, {}, nothing).kind, "no_target")
	h.eq(plan("https://example.com/", {}, nothing).kind, "pass")
	h.eq(plan("file:///tmp/a.txt", {}, nothing).kind, "pass")
end)

h.test("target: the config mapping fills in for an address ssh cannot use", function()
	local hosts = { fakes.host({ address = false, name = "devbox" }) }
	h.eq(plan("file:///tmp/a.html", {}, hosts, cfg({ hosts = { devbox = "you@devbox.lan" } })).target, "you@devbox.lan")
end)

h.test("allowed_ports: refuses unlisted local ports, allows listed, never touches oauth or files", function()
	local c = cfg({ allowed_ports = { 3000 } })
	local refused = plan("http://localhost:4000/", {}, nil, c)
	h.eq(refused.kind, "refuse")
	h.truthy(string.find(refused.title, "4000", 1, true), "the toast names the port")
	h.eq(plan("http://localhost:3000/", {}, nil, c).kind, "local")
	h.eq(plan(KEYCLOAK, {}, nil, c).kind, "oauth")
	h.eq(plan("file:///tmp/a.html", {}, nil, c).kind, "file")
	h.eq(plan("http://localhost:4000/", {}, nil, cfg({})).kind, "local", "unset: any port")
	h.eq(plan("http://localhost:4000/", {}, nil, cfg({ allowed_ports = {} })).kind, "refuse", "empty list: none")
end)

h.test("host names in plans are cleaned for toasts", function()
	local p = plan("file:///tmp/a.html", {}, { fakes.host({ name = "dev\27[31mbox\n" }) })
	h.eq(p.host_name, "dev [31mbox")
end)

local function open(path, opts, hosts, c)
	opts = opts or {}
	return classify.plan_open(
		{ path = path, host = opts.host or "devbox", how = "default", origin = opts.origin or "link" },
		hosts or { fakes.host() },
		c or DEFAULT
	)
end

h.test("open: an image path clicked on a connected remote host is the same file plan as its file:// link", function()
	for _, ext in { "png", "jpg", "jpeg", "gif", "webp", "PNG" } do
		local path = "/home/you/out/diagram." .. ext
		local p = open(path)
		h.eq(p, plan("file://" .. path), ext)
		h.eq(p.kind, "file", ext)
	end
end)

h.test("open: only clicks (origin link) are taken; the palette, Files, drops, the system, tern open and Carly are not", function()
	for _, origin in { "palette", "files", "drop", "system", "cli", "carly" } do
		h.eq(open("/home/you/a.png", { origin = origin }).kind, "pass", origin)
	end
end)

h.test("open: pages, svg, pdf and other files stay Tern's", function()
	for _, name in { "a.html", "a.svg", "a.pdf", "a.txt", "a", "a.png.bak" } do
		h.eq(open("/home/you/" .. name).kind, "pass", name)
	end
end)

h.test("open: a local, disconnected, unknown or ambiguous host passes, and so does a bad path", function()
	h.eq(open("/tmp/a.png", {}, { fakes.host({ kind = "local", name = "devbox" }) }).kind, "pass", "local")
	h.eq(open("/tmp/a.png", {}, { fakes.host({ state = "reconnecting" }) }).kind, "pass", "disconnected")
	h.eq(open("/tmp/a.png", { host = "elsewhere" }).kind, "pass", "unknown host")
	h.eq(open("/tmp/a.png", {}, { fakes.host(), fakes.host({ id = 2, address = "me@devbox2" }) }).kind, "pass", "two hosts named devbox")
	h.eq(open("tmp/a.png").kind, "pass", "relative")
	h.eq(open("/tmp/a\n.png").kind, "pass", "control character")
end)

h.test("open: no usable ssh target gives no_target", function()
	local p = open("/tmp/a.png", {}, { fakes.host({ address = "you@devbox:8376" }) })
	h.eq(p.kind, "no_target")
	h.eq(p.host_name, "devbox")
end)

local function render(path, hosts, kind, c)
	local info = { pane = 41, kind = kind or "file", path = path, title = "x", cwd = "" }
	return classify.plan_render(info, hosts or { fakes.host() }, c or DEFAULT)
end

h.test("render: a page in a file block of a connected remote host is the same file plan as its file:// link", function()
	for _, name in { "a.html", "a.htm", "INDEX.HTML" } do
		local path = "/home/you/out/" .. name
		local p = render(path)
		h.eq(p, plan("file://" .. path), name)
		h.eq(p.kind, "file", name)
	end
end)

h.test("render: a page on the Mac is shown where it is, under a cleaned name", function()
	local p = render("/Users/you/My Page.html", { fakes.host({ kind = "local", name = "you", address = false }) })
	h.eq(p, { kind = "show", path = "/Users/you/My Page.html", name = "My_Page.html", ext = "html" })
end)

h.test("render: anything but a page in a file block is refused", function()
	for _, name in { "a.svg", "a.pdf", "a.png", "a.md", "a", "a.html.bak" } do
		h.eq(render("/home/you/" .. name).kind, "refuse", name)
	end
	h.eq(render("/home/you/a.html", nil, "git").kind, "refuse", "git block")
	h.eq(classify.plan_render(nil, { fakes.host() }, DEFAULT).kind, "refuse", "no focus")
	h.eq(render("home/you/a.html").title, "Cannot render this file", "relative path")
	h.eq(render("/home/you/a\n.html").title, "Cannot render this file", "control character")
end)

h.test("render: the file's machine is the host listing its pane, never a fallback", function()
	local other = fakes.host({ id = 2, name = "other", address = "you@other", panes = { 7 } })
	h.eq(render("/home/you/a.html", { other }).title, "Cannot tell which machine holds this file")
	local p = render("/home/you/a.html", { other, fakes.host() })
	h.eq(p.target, "you@devbox")
end)

h.test("render: a remote host that is not connected is refused, naming it; no ssh target gives no_target", function()
	local p = render("/home/you/a.html", { fakes.host({ state = "stalled" }) })
	h.eq(p.kind, "refuse")
	h.eq(p.title, "devbox is not connected")
	h.eq(render("/home/you/a.html", { fakes.host({ address = "you@devbox:8376" }) }).kind, "no_target")
end)

return {}
