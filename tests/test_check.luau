--!nocheck
local h = require("./harness")
local check = require("../lib/check")

h.group("check")

h.test("port accepts 1 and 65535, numbers and digit strings", function()
	h.eq(check.port(1), 1)
	h.eq(check.port(65535), 65535)
	h.eq(check.port(8250), 8250)
	h.eq(check.port("8250"), 8250)
	h.eq(check.port("00080"), 80)
end)

h.test("port rejects out of range, non-integers, junk and non-scalars", function()
	for _, bad in { 0, -1, 65536, 99999, 1.5, "0", "65536", "99999", "", " 80", "80 ", "8o", "-1", "+80", "1e3", "٣٣" } do
		h.eq(check.port(bad), nil, "port " .. h.show(bad))
	end
	h.eq(check.port(nil), nil)
	h.eq(check.port({}), nil)
	h.eq(check.port(true), nil)
	h.eq(check.port("123456"), nil, "six digits is too long even with leading zeros")
	h.eq(check.port(0 / 0), nil, "NaN")
	h.eq(check.port(math.huge), nil)
end)

h.test("abs_path needs a leading slash and no control characters", function()
	h.truthy(check.abs_path("/tmp/a.html"))
	h.truthy(check.abs_path("/home/you/my file.html"))
	h.falsy(check.abs_path("tmp/a.html"))
	h.falsy(check.abs_path("/"))
	h.falsy(check.abs_path(""))
	h.falsy(check.abs_path("/tmp/a\nb"))
	h.falsy(check.abs_path("/tmp/a\0b"))
	h.falsy(check.abs_path("/tmp/a\tb"))
	h.falsy(check.abs_path("/tmp/a\127b"))
	h.falsy(check.abs_path(nil))
	h.falsy(check.abs_path(5))
end)

h.test("target accepts user@host and bare aliases", function()
	for _, ok in { "you@devbox", "you@devbox.lan", "you@192.0.2.7", "you_1@dev-box.example.com", "devbox", "dev.box" } do
		h.truthy(check.target(ok), ok)
	end
end)

h.test("target rejects options, ports, brackets, whitespace, empties", function()
	for _, bad in { "-oProxyCommand=x@host", "-v@host", "-host", "you@-host", "you@host:22", "you@[::1]", "you@host name", "you @host", "", "@host", "you@", "you@@host", "a@b@c", "you@host\n", "you@ho/st", ";id", "$(id)@host", "you@host;id" } do
		h.falsy(check.target(bad), bad)
	end
	h.falsy(check.target(nil))
	h.falsy(check.target(string.rep("a", 300)))
end)

h.test("loopback_host knows exactly three spellings", function()
	h.truthy(check.loopback_host("localhost"))
	h.truthy(check.loopback_host("127.0.0.1"))
	h.truthy(check.loopback_host("[::1]"))
	for _, bad in { "127.0.0.2", "0.0.0.0", "::1", "localhost.", "LOCALHOST", "127.1", "evil.com", "" } do
		h.falsy(check.loopback_host(bad), bad)
	end
	h.falsy(check.loopback_host(nil))
end)

return {}
