--!nocheck
local h = require("./harness")
local config = require("../lib/config")

h.group("config")

h.test("nil and empty give defaults without warnings", function()
	local r = config.normalize(nil)
	h.eq(r.config.hosts, {})
	h.eq(r.config.allowed_ports, nil)
	h.eq(r.warnings, {})
	h.eq(config.normalize({}).warnings, {})
end)

h.test("a full valid config", function()
	local r = config.normalize({
		hosts = { devbox = "you@devbox.lan", ["you@devbox:8376"] = "alias" },
		allowed_ports = { 3000, "8080" },
		control_dir = "/tmp/ro",
	})
	h.eq(r.warnings, {})
	h.eq(r.config.hosts, { devbox = "you@devbox.lan", ["you@devbox:8376"] = "alias" })
	h.eq(r.config.allowed_ports, { 3000, 8080 })
	h.eq(r.config.control_dir, "/tmp/ro")
end)

h.test("invalid host entries are dropped with a warning", function()
	local r = config.normalize({ hosts = { ok = "you@h", bad = "-oFoo", worse = 3 } })
	h.eq(r.config.hosts, { ok = "you@h" })
	h.eq(#r.warnings, 2)
end)

h.test("a non-object config and non-object hosts are ignored", function()
	h.eq(#config.normalize("x").warnings, 1)
	h.eq(#config.normalize(5).warnings, 1)
	h.eq(config.normalize({ hosts = "x" }).config.hosts, {})
	h.eq(#config.normalize({ hosts = "x" }).warnings, 1)
end)

h.test("an invalid port in allowed_ports refuses everything, never widens", function()
	local r = config.normalize({ allowed_ports = { 3000, 70000 } })
	h.eq(r.config.allowed_ports, {})
	h.eq(#r.warnings, 1)
end)

h.test("allowed_ports must be a list; an empty list refuses all", function()
	local r = config.normalize({ allowed_ports = "3000" })
	h.eq(r.config.allowed_ports, nil)
	h.eq(#r.warnings, 1)
	h.eq(config.normalize({ allowed_ports = {} }).config.allowed_ports, {})
end)

h.test("control_dir must be an absolute path", function()
	local r = config.normalize({ control_dir = "relative" })
	h.eq(r.config.control_dir, nil)
	h.eq(#r.warnings, 1)
	h.eq(config.normalize({ control_dir = "/a\nb" }).config.control_dir, nil)
end)

return {}
