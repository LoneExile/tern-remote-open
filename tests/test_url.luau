--!nocheck
local h = require("./harness")
local url = require("../lib/url")

h.group("url")

h.test("decode handles valid, invalid and plus", function()
	h.eq(url.decode("a%20b"), "a b")
	h.eq(url.decode("%2F%2f"), "//")
	h.eq(url.decode("100%"), "100%")
	h.eq(url.decode("%zz%4"), "%zz%4")
	h.eq(url.decode("a+b"), "a+b")
	h.eq(url.decode("a+b", true), "a b")
	h.eq(url.decode("%C3%A9"), "é")
	h.eq(url.decode("%2520"), "%20", "decodes exactly once")
	h.eq(url.decode("%00"), "\0")
end)

h.test("encode_path keeps unreserved and slash, escapes the rest", function()
	h.eq(url.encode_path("/tmp/a.html"), "/tmp/a.html")
	h.eq(url.encode_path("/Users/you/Library/Application Support/x/a b.html"), "/Users/you/Library/Application%20Support/x/a%20b.html")
	h.eq(url.encode_path("/a#b?c%d"), "/a%23b%3Fc%25d")
	h.eq(url.encode_path("/é"), "/%C3%A9")
	h.eq(url.decode(url.encode_path("/a b/ü#%.html")), "/a b/ü#%.html")
end)

h.test("parse splits scheme, host, port, path, query, fragment", function()
	local p = url.parse("https://Example.COM:8443/a/b?x=1&y=2#frag")
	h.eq(p.scheme, "https")
	h.eq(p.host, "example.com")
	h.eq(p.port, 8443)
	h.eq(p.path, "/a/b")
	h.eq(p.query, "x=1&y=2")
	h.eq(p.fragment, "frag")
	h.truthy(p.has_authority)
end)

h.test("parse: no port, no path, IPv6 literal", function()
	local p = url.parse("http://localhost")
	h.eq(p.host, "localhost")
	h.eq(p.port, nil)
	h.eq(p.path, "")
	local q = url.parse("http://[::1]:8080/x")
	h.eq(q.host, "[::1]")
	h.eq(q.port, 8080)
	h.eq(q.path, "/x")
	h.eq(url.parse("http://[::1]/").port, nil)
end)

h.test("parse: userinfo is split off at the last @", function()
	local p = url.parse("http://localhost:8250@evil.com/x")
	h.eq(p.host, "evil.com")
	h.eq(p.userinfo, "localhost:8250")
	h.eq(p.port, nil)
	local q = url.parse("http://a@b@c.com:81/")
	h.eq(q.host, "c.com")
	h.eq(q.port, 81)
end)

h.test("parse rejects bad ports, brackets, colons, controls, junk", function()
	for _, bad in {
		"http://localhost:0/",
		"http://localhost:65536/",
		"http://localhost:99999999/",
		"http://localhost:80a/",
		"http://localhost:-1/",
		"http://[::1/",
		"http://[::1]x/",
		"http://[zz]:80/",
		"http://[localhost]:80/",
		"http://a:b:c/",
		"http://local\nhost:80/",
		"http://localhost:80/\0",
		"no scheme",
		"://x",
		"",
		"1http://x",
	} do
		h.eq(url.parse(bad), nil, bad)
	end
	h.eq(url.parse(string.rep("a", 9000)), nil)
end)

h.test("parse: an empty port is no port; no authority is allowed", function()
	h.eq(url.parse("http://localhost:/").port, nil)
	local f = url.parse("file:/tmp/x.html")
	h.eq(f.path, "/tmp/x.html")
	h.falsy(f.has_authority)
	h.eq(url.parse("mailto:you@devbox").path, "you@devbox")
end)

h.test("loopback_link: accepted shapes", function()
	for _, ok in {
		"http://localhost:8765/",
		"http://localhost:8765",
		"https://localhost:8443/x?y=1#z",
		"http://127.0.0.1:3000/app",
		"http://[::1]:5173/",
		"HTTP://LOCALHOST:80/",
		"http://localhost:1/",
		"http://localhost:65535/",
	} do
		h.truthy(url.loopback_link(ok), ok)
	end
	h.eq(url.loopback_link("http://[::1]:5173/").host, "[::1]")
	h.eq(url.loopback_link("HTTP://LOCALHOST:80/").port, 80)
end)

h.test("loopback_link: rejected shapes", function()
	for _, bad in {
		"http://localhost/",
		"http://127.0.0.1/",
		"http://localhost:/",
		"http://localhost:0/",
		"http://localhost:65536/",
		"http://127.0.0.2:80/",
		"http://127.1:80/",
		"http://0.0.0.0:8000/",
		"http://localhost.:80/",
		"http://localhost.evil.com:80/",
		"http://evil.com:80/",
		"http://localhost:8250@evil.com/",
		"http://user@localhost:8250/",
		"http://localhost:8250\\@evil.com/",
		"http://evil.com:80@localhost:81/",
		"ftp://localhost:21/",
		"ssh://localhost:22/",
		"file://localhost:80/x",
		"localhost:8080",
		"//localhost:8080/",
		"http://[::2]:80/",
		"http://%6cocalhost:80/",
	} do
		h.eq(url.loopback_link(bad), nil, bad)
	end
end)

h.test("file_path: the forms terminals produce", function()
	h.eq(url.file_path("file:///tmp/a.html"), "/tmp/a.html")
	h.eq(url.file_path("file://devbox/home/you/a.html"), "/home/you/a.html")
	h.eq(url.file_path("file://localhost/tmp/a.html"), "/tmp/a.html")
	h.eq(url.file_path("file:/tmp/a.html"), "/tmp/a.html")
	h.eq(url.file_path("FILE:///tmp/a.html"), "/tmp/a.html")
	h.eq(url.file_path("file:///tmp/my%20file%20%281%29.html"), "/tmp/my file (1).html")
	h.eq(url.file_path("file:///tmp/%C3%A9.html"), "/tmp/é.html")
	h.eq(url.file_path("file:///tmp/100%25.html"), "/tmp/100%.html")
	h.eq(url.file_path("file:///tmp/100%.html"), "/tmp/100%.html")
	h.eq(url.file_path("file:///tmp/a.html?x=1#top"), "/tmp/a.html", "query and fragment are not part of the path")
	h.eq(url.file_path("file:///tmp/a%23b.html"), "/tmp/a#b.html")
	h.eq(url.file_path("file:///tmp/a%3Fb.html"), "/tmp/a?b.html")
	h.eq(url.file_path("file://[::1]/tmp/a.html"), "/tmp/a.html")
	h.eq(url.file_path("file://devbox:8/tmp/a.html"), "/tmp/a.html", "a port in the host part is ignored with it")
end)

h.test("file_path: rejected", function()
	for _, bad in {
		"file://",
		"file:///",
		"file://devbox",
		"file:relative.html",
		"file:///tmp/a%0Ab.html",
		"file:///tmp/a%00b.html",
		"file:///tmp/a%09b.html",
		"file:///tmp/a%7Fb.html",
		"file:///tmp/a\nb.html",
		"http://localhost:80/tmp/a.html",
		"https://x/tmp/a.html",
		"/tmp/a.html",
		"",
	} do
		h.eq(url.file_path(bad), nil, bad)
	end
end)

h.test("query_values decodes forms and finds repeats", function()
	h.eq(url.query_values("a=1&b=2", "a"), { "1" })
	h.eq(url.query_values("a=1&a=2", "a"), { "1", "2" })
	h.eq(url.query_values("a=x+y%20z", "a"), { "x y z" })
	h.eq(url.query_values("xa=1&a=2&ab=3", "a"), { "2" })
	h.eq(url.query_values("a&b=2", "a"), { "" })
	h.eq(url.query_values(nil, "a"), {})
	h.eq(url.query_values("", "a"), {})
	h.eq(url.query_values("%61=1", "a"), { "1" })
	h.eq(url.query_values("a=1;a=2", "a"), { "1;a=2" }, "only & separates pairs")
end)

local KEYCLOAK = "https://auth.example.com/realms/dev/protocol/openid-connect/auth?client_id=bao&redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Foidc%2Fcallback&response_type=code&scope=openid&state=abc&code_challenge=x"

h.test("oauth_redirect: the usual encoded redirect_uri", function()
	local r = url.oauth_redirect(KEYCLOAK)
	h.eq(r.host, "localhost")
	h.eq(r.port, 8250)
	h.eq(r.scheme, "http")
	h.eq(r.path, "/oidc/callback")
end)

h.test("oauth_redirect: 127.0.0.1, https, raw, plus-encoded, nested query", function()
	h.eq(url.oauth_redirect("https://idp.example.com/auth?redirect_uri=http%3A%2F%2F127.0.0.1%3A9000%2Fcb").port, 9000)
	h.eq(url.oauth_redirect("https://idp.example.com/auth?redirect_uri=http://localhost:8250/cb").port, 8250)
	h.eq(url.oauth_redirect("https://idp.example.com/auth?redirect_uri=https%3A%2F%2Flocalhost%3A8443%2Fcb").scheme, "https")
	h.eq(url.oauth_redirect("http://idp.example.com:8080/auth?a=1&redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Fcb%3Fa%3Db%26c%3Dd&z=9").port, 8250)
	h.eq(url.oauth_redirect("https://idp.example.com/auth?redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Fcb#frag").port, 8250)
end)

h.test("oauth_redirect: rejected", function()
	for _, bad in {
		"https://idp.example.com/auth",
		"https://idp.example.com/auth?redirect_uri=",
		"https://idp.example.com/auth?redirect_uri=http%3A%2F%2Fexample.com%3A8250%2Fcb",
		"https://idp.example.com/auth?redirect_uri=http%3A%2F%2Flocalhost%2Fcb",
		"https://idp.example.com/auth?redirect_uri=http%3A%2F%2Flocalhost%3A0%2Fcb",
		"https://idp.example.com/auth?redirect_uri=http%3A%2F%2Flocalhost%3A70000%2Fcb",
		"https://idp.example.com/auth?redirect_uri=http%3A%2F%2F%5B%3A%3A1%5D%3A8250%2Fcb",
		"https://idp.example.com/auth?redirect_uri=http%3A%2F%2Flocalhost%3A8250%40evil.com%2Fcb",
		"https://idp.example.com/auth?redirect_uri=http%253A%252F%252Flocalhost%253A8250%252Fcb",
		"https://idp.example.com/auth?redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Fcb&redirect_uri=http%3A%2F%2Flocalhost%3A9999%2Fcb",
		"https://idp.example.com/auth?state=redirect_uri%3Dhttp%3A%2F%2Flocalhost%3A8250%2Fcb",
		"https://idp.example.com/auth?xredirect_uri=http%3A%2F%2Flocalhost%3A8250%2Fcb",
		"https://idp.example.com/auth?redirect_uri_extra=http%3A%2F%2Flocalhost%3A8250%2Fcb",
		"ftp://idp.example.com/auth?redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Fcb",
		"mailto:a@b?redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Fcb",
		"file:///tmp/a?redirect_uri=http%3A%2F%2Flocalhost%3A8250%2Fcb",
		"https://idp.example.com/auth?redirect_uri=javascript%3Aalert(1)",
	} do
		h.eq(url.oauth_redirect(bad), nil, bad)
	end
end)

return {}
