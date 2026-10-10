--!nocheck
local h = require("./harness")
local argv = require("../lib/argv")

h.group("argv")

local SOCK = "/data/cm/8250.sock"
local TOKEN32 = "0123456789abcdef0123456789abcdef"

h.test("scp: the exact vector", function()
	h.eq(argv.scp("you@devbox", "/home/you/a b.html", "/data/cache/ab12cd34-a_b.html"), {
		"/usr/bin/scp", "-q", "-s",
		"-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
		"-o", "ConnectTimeout=10",
		"--", "you@devbox:/home/you/a b.html", "/data/cache/ab12cd34-a_b.html",
	})
end)

h.test("scp: a hostile remote path stays one argv element", function()
	local v = argv.scp("you@devbox", "/tmp/$(id);rm -rf ~ `x` 'q' \"d\".html", "/data/cache/x.html")
	h.eq(#v, 12)
	h.eq(v[11], "you@devbox:/tmp/$(id);rm -rf ~ `x` 'q' \"d\".html")
end)

h.test("scp: refuses bad target, relative or control-character paths", function()
	h.raises(function() argv.scp("-oProxyCommand=x@h", "/tmp/a.html", "/d/x") end)
	h.raises(function() argv.scp("you@devbox", "tmp/a.html", "/d/x") end)
	h.raises(function() argv.scp("you@devbox", "/tmp/a\nb.html", "/d/x") end)
	h.raises(function() argv.scp("you@devbox", "/tmp/a.html", "relative") end)
	h.raises(function() argv.scp("you@devbox", "/tmp/a.html", "/d/x\0y") end)
	h.raises(function() argv.scp("you@dev box", "/tmp/a.html", "/d/x") end)
end)

h.test("ssh_forward: persistent forward is -N, bound to 127.0.0.1, control master", function()
	h.eq(argv.ssh_forward({ target = "you@devbox", socket = SOCK, port = 8765, remote_host = "127.0.0.1" }), {
		"/usr/bin/ssh", "-f", "-T", "-M", "-S", SOCK,
		"-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
		"-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
		"-o", "ConnectTimeout=10", "-o", "ControlPersist=no",
		"-L", "127.0.0.1:8765:127.0.0.1:8765",
		"-N", "--", "you@devbox",
	})
end)

h.test("ssh_forward: a timed forward runs `sleep TTL` instead of -N", function()
	local v = argv.ssh_forward({ target = "you@devbox", socket = SOCK, port = 8250, remote_host = "localhost", ttl = 600 })
	h.eq(v[#v - 2], "you@devbox")
	h.eq(v[#v - 1], "sleep")
	h.eq(v[#v], "600")
	h.falsy(table.find(v, "-N"), "no -N")
	h.truthy(table.find(v, "127.0.0.1:8250:localhost:8250"))
end)

h.test("ssh_forward: the remote end follows the link's loopback spelling", function()
	local v = argv.ssh_forward({ target = "you@devbox", socket = SOCK, port = 5173, remote_host = "[::1]" })
	h.truthy(table.find(v, "127.0.0.1:5173:[::1]:5173"))
end)

h.test("ssh_forward: the local bind is always 127.0.0.1", function()
	for _, rh in { "localhost", "127.0.0.1", "[::1]" } do
		local v = argv.ssh_forward({ target = "you@devbox", socket = SOCK, port = 80, remote_host = rh })
		local spec = v[table.find(v, "-L") + 1]
		h.eq(string.sub(spec, 1, 13), "127.0.0.1:80:")
	end
end)

h.test("ssh_forward: refuses bad port, remote host, ttl, target, socket", function()
	local base = { target = "you@devbox", socket = SOCK, port = 8250, remote_host = "localhost" }
	local function with(k, v)
		local c = table.clone(base)
		c[k] = v
		return c
	end
	h.raises(function() argv.ssh_forward(with("port", 0)) end)
	h.raises(function() argv.ssh_forward(with("port", 65536)) end)
	h.raises(function() argv.ssh_forward(with("port", "80;id")) end)
	h.raises(function() argv.ssh_forward(with("remote_host", "evil.com")) end)
	h.raises(function() argv.ssh_forward(with("remote_host", "0.0.0.0")) end)
	h.raises(function() argv.ssh_forward(with("ttl", 0)) end)
	h.raises(function() argv.ssh_forward(with("ttl", 1.5)) end)
	h.raises(function() argv.ssh_forward(with("ttl", 100000)) end)
	h.raises(function() argv.ssh_forward(with("target", "-v@x")) end)
	h.raises(function() argv.ssh_forward(with("socket", "rel.sock")) end)
end)

h.test("ssh_check and ssh_exit address the control socket", function()
	h.eq(argv.ssh_check(SOCK, "you@devbox"), { "/usr/bin/ssh", "-S", SOCK, "-O", "check", "-o", "BatchMode=yes", "--", "you@devbox" })
	h.eq(argv.ssh_exit(SOCK, "you@devbox"), { "/usr/bin/ssh", "-S", SOCK, "-O", "exit", "-o", "BatchMode=yes", "--", "you@devbox" })
	h.raises(function() argv.ssh_exit("sock", "you@devbox") end)
	h.raises(function() argv.ssh_check(SOCK, "bad target") end)
end)

h.test("nc_probe", function()
	h.eq(argv.nc_probe(8250), { "/usr/bin/nc", "-z", "-w", "2", "127.0.0.1", "8250" })
	h.raises(function() argv.nc_probe(0) end)
	h.raises(function() argv.nc_probe(99999) end)
end)

h.test("open and find_old", function()
	h.eq(argv.open("/data/cache/x.html"), { "/usr/bin/open", "/data/cache/x.html" })
	h.raises(function() argv.open("x.html") end)
	h.eq(argv.find_old("/data/cache", 7), { "/usr/bin/find", "/data/cache", "-type", "f", "-mtime", "+7", "-delete" })
	h.raises(function() argv.find_old("cache", 7) end)
	h.raises(function() argv.find_old("/data/cache", 0) end)
end)

h.test("every command starts with an absolute binary path", function()
	local all = {
		argv.scp("you@devbox", "/a.html", "/d/x"),
		argv.ssh_forward({ target = "you@devbox", socket = SOCK, port = 1, remote_host = "localhost" }),
		argv.ssh_check(SOCK, "you@devbox"),
		argv.ssh_exit(SOCK, "you@devbox"),
		argv.nc_probe(1),
		argv.open("/d/x"),
		argv.find_old("/d", 7),
		argv.uuidgen(),
		argv.serve({ script = "/p/serve.pl", port = 50000, token = TOKEN32, file = "/d/x.html", name = "x.html", content_type = "text/html; charset=utf-8", idle = 600 }),
	}
	for _, v in all do
		h.eq(string.sub(v[1], 1, 1), "/", v[1])
		for _, a in v do
			h.falsy(string.find(a, "\0", 1, true), "no NUL in argv")
		end
	end
end)

h.test("uuidgen", function()
	h.eq(argv.uuidgen(), { "/usr/bin/uuidgen" })
end)

h.test("serve: the exact vector", function()
	h.eq(argv.serve({
		script = "/plugin/serve.pl", port = 50123, token = TOKEN32, file = "/data/cache/ab-x.png",
		name = "x.png", content_type = "image/png", idle = 600,
	}), { "/usr/bin/perl", "/plugin/serve.pl", "50123", TOKEN32, "/data/cache/ab-x.png", "x.png", "image/png", "600" })
end)

h.test("serve: refuses a bad port, token, name, type, idle, path", function()
	local base = { script = "/p/serve.pl", port = 50000, token = TOKEN32, file = "/d/x.html", name = "x.html", content_type = "text/html; charset=utf-8", idle = 600 }
	local function with(k, v)
		local c = table.clone(base)
		c[k] = v
		return c
	end
	h.eq(#argv.serve(base), 8)
	h.raises(function() argv.serve(with("port", 0)) end)
	h.raises(function() argv.serve(with("port", 70000)) end)
	h.raises(function() argv.serve(with("token", "short")) end)
	h.raises(function() argv.serve(with("token", string.rep("A", 32))) end, "uppercase is not the token alphabet")
	h.raises(function() argv.serve(with("token", string.rep("g", 32))) end)
	h.raises(function() argv.serve(with("name", "../x.html")) end)
	h.raises(function() argv.serve(with("name", "a b.html")) end)
	h.raises(function() argv.serve(with("name", "")) end)
	h.raises(function() argv.serve(with("name", string.rep("a", 201))) end)
	h.raises(function() argv.serve(with("content_type", "text/html")) end)
	h.raises(function() argv.serve(with("content_type", "text/html; charset=utf-8; x")) end)
	h.raises(function() argv.serve(with("idle", 0)) end)
	h.raises(function() argv.serve(with("idle", 1.5)) end)
	h.raises(function() argv.serve(with("idle", 100000)) end)
	h.raises(function() argv.serve(with("script", "serve.pl")) end)
	h.raises(function() argv.serve(with("file", "x.html")) end)
	h.raises(function() argv.serve(with("file", "/d/a\nb.html")) end)
end)

return {}
