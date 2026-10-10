--!nocheck
local h = require("./harness")
local target = require("../lib/target")
local config = require("../lib/config")

h.group("target")

local function host(name, address)
	return { id = 1, name = name, address = address, kind = "remote", state = "connected", panes = {} }
end

local function cfg(hosts)
	return config.normalize({ hosts = hosts }).config
end

h.test("from_address trusts only a plain user@host", function()
	h.eq(target.from_address("you@devbox"), "you@devbox")
	h.eq(target.from_address("you@devbox.lan"), "you@devbox.lan")
	h.eq(target.from_address("you@192.0.2.7"), "you@192.0.2.7")
end)

h.test("from_address refuses ports, bare hosts, endpoint ids, junk", function()
	h.eq(target.from_address("you@devbox:8376"), nil, "a Tern port is not an ssh port")
	h.eq(target.from_address("devbox"), nil)
	h.eq(target.from_address("you@" .. string.rep("ab12", 16)), nil, "64 hex digits looks like an iroh id")
	h.eq(target.from_address("you@[::1]"), nil)
	h.eq(target.from_address("-oProxyCommand=x@h"), nil)
	h.eq(target.from_address(nil), nil)
	h.eq(target.from_address(""), nil)
	h.eq(target.from_address("you@dev box"), nil)
end)

h.test("choose uses the host's own address first", function()
	h.eq(target.choose(host("devbox", "you@devbox"), cfg({ devbox = "other@elsewhere" })), "you@devbox")
end)

h.test("choose falls back to config keyed by address, name, then name ignoring case", function()
	h.eq(target.choose(host("devbox", "you@devbox:8376"), cfg({ ["you@devbox:8376"] = "you@devbox.lan" })), "you@devbox.lan")
	h.eq(target.choose(host("devbox", nil), cfg({ devbox = "you@devbox.lan" })), "you@devbox.lan")
	h.eq(target.choose(host("DevBox", "abcd"), cfg({ devbox = "you@devbox.lan" })), "you@devbox.lan")
end)

h.test("choose: address key wins over name key; nothing mapped gives nil", function()
	local c = cfg({ ["x@y:1"] = "a@by-address", devbox = "a@by-name" })
	h.eq(target.choose(host("devbox", "x@y:1"), c), "a@by-address")
	h.eq(target.choose(host("other", "x@y:9"), c), nil)
	h.eq(target.choose(host("other", nil), cfg({})), nil)
end)

h.test("choose never returns an invalid mapped target", function()
	h.eq(target.choose(host("devbox", nil), cfg({ devbox = "-oProxyCommand=x" })), nil)
	h.eq(target.choose(host("devbox", nil), cfg({ devbox = "you@host;id" })), nil)
	h.eq(target.choose(host("devbox", nil), cfg({ devbox = 5 })), nil)
end)

return {}
