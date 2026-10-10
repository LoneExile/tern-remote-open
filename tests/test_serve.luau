--!nocheck
local h = require("./harness")
local argv = require("../lib/argv")
local serve = require("../lib/serve")
local fakes = require("./fakes")

h.group("serve")

local ok = fakes.ok
local UUID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301\n"
local TOKEN = "3f2504e04f8911d39a0c0305e82c3301"
local REQ = { script = "/plugin/serve.pl", file = "/data/cache/ab12cd34-report.html", name = "report.html", ext = "html" }
local FREE = { status = 1, stdout = "", stderr = "", timed_out = false }

-- `script` maps a command kind to a result or function(argv, n, env).
local function env_for(script)
	local counts = {}
	return fakes.env(function(cmd, e)
		local kind = fakes.kind(cmd)
		counts[kind] = (counts[kind] or 0) + 1
		local entry = script[kind]
		if type(entry) == "function" then
			return entry(cmd, counts[kind], e)
		end
		return entry or ok()
	end)
end

local function start(env, req)
	local got = {}
	serve.start(env, req or REQ, { id = 0 }, function(result, cx)
		table.insert(got, { result = result, cx = cx })
	end)
	env.pump()
	return got
end

h.test("token_from keeps the 32 hex digits of a UUID, lowercase", function()
	h.eq(serve.token_from(UUID), TOKEN)
	h.eq(serve.token_from("garbage"), nil)
	h.eq(serve.token_from(""), nil)
	h.eq(serve.token_from("3F2504E0-4F89-11D3-9A0C-0305E82C33"), nil, "too short")
	h.eq(serve.token_from(UUID .. "extra\n"), nil, "no stray digits are folded in")
end)

h.test("url", function()
	h.eq(serve.url(50000, TOKEN, "a.html"), "http://127.0.0.1:50000/" .. TOKEN .. "/a.html")
end)

h.test("content types cover exactly the openable extensions", function()
	local names = {}
	for ext in serve.CONTENT_TYPES do
		table.insert(names, ext)
	end
	table.sort(names)
	h.eq(names, { "gif", "htm", "html", "jpeg", "jpg", "pdf", "png", "svg", "webp" })
	for _, ctype in serve.CONTENT_TYPES do
		h.truthy(argv.CONTENT_TYPES[ctype], ctype .. " is a type serve.pl is told it may send")
	end
end)

h.test("a server that comes up: uuidgen, start perl, probe until the port answers", function()
	local env = env_for({
		uuidgen = ok({ stdout = UUID }),
		serve = fakes.HOLD,
		nc = function(_, n)
			if n < 3 then
				return FREE
			end
			return ok()
		end,
	})
	env.randoms = { 50123 }
	local got = start(env)
	h.eq(#got, 1)
	h.eq(got[1].result.ok, true)
	h.eq(got[1].result.url, "http://127.0.0.1:50123/" .. TOKEN .. "/report.html")
	h.eq(env.kinds(), { "uuidgen", "serve", "nc", "nc", "nc" })
	h.eq(env.log[2].argv, argv.serve({
		script = "/plugin/serve.pl", port = 50123, token = TOKEN, file = "/data/cache/ab12cd34-report.html",
		name = "report.html", content_type = "text/html; charset=utf-8", idle = 600,
	}))
	h.eq(env.log[2].timeout_ms, 660000, "Tern ends it for good a minute after its own idle exit")
	h.eq(#env.timers, 2)
	h.truthy(got[1].cx, "the final callback receives a context")
	h.eq(#env.held, 1, "the server process is still running")
end)

h.test("each content type is passed for its extension", function()
	local cases = { svg = "image/svg+xml", pdf = "application/pdf", png = "image/png", jpg = "image/jpeg", gif = "image/gif", webp = "image/webp", htm = "text/html; charset=utf-8" }
	for ext, ctype in cases do
		local env = env_for({ uuidgen = ok({ stdout = UUID }), serve = fakes.HOLD })
		start(env, { script = "/plugin/serve.pl", file = "/d/x." .. ext, name = "x." .. ext, ext = ext })
		h.eq(env.log[2].argv[7], ctype, ext)
	end
end)

h.test("a port that is taken is retried on another one", function()
	local env = env_for({
		uuidgen = ok({ stdout = UUID }),
		serve = function(_, n)
			if n == 1 then
				return { status = 66, stdout = "", stderr = "", timed_out = false }
			end
			return fakes.HOLD
		end,
		nc = function(_, n)
			if n == 1 then
				return FREE
			end
			return ok()
		end,
	})
	env.randoms = { 50000, 50001 }
	local got = start(env)
	h.eq(got[1].result.ok, true)
	h.eq(got[1].result.url, "http://127.0.0.1:50001/" .. TOKEN .. "/report.html")
	h.eq(env.log[2].argv[3], "50000")
	h.eq(env.log[4].argv[3], "50001")
end)

h.test("a foreign listener on the chosen port is not mistaken for our server", function()
	-- The server exits 66 (port taken) while nc already sees someone listening.
	local env = env_for({
		uuidgen = ok({ stdout = UUID }),
		serve = function(_, n)
			if n == 1 then
				return { status = 66, stdout = "", stderr = "", timed_out = false }
			end
			return fakes.HOLD
		end,
		nc = ok(),
	})
	env.randoms = { 50000, 50001 }
	local got = start(env)
	h.eq(got[1].result.url, "http://127.0.0.1:50001/" .. TOKEN .. "/report.html")
end)

h.test("giving up after four taken ports", function()
	local env = env_for({
		uuidgen = ok({ stdout = UUID }),
		serve = { status = 66, stdout = "", stderr = "", timed_out = false },
		nc = FREE,
	})
	local got = start(env)
	h.eq(got[1].result.ok, false)
	h.eq(got[1].result.detail, "no free port for the preview server")
	local starts = 0
	for _, k in env.kinds() do
		if k == "serve" then
			starts += 1
		end
	end
	h.eq(starts, 4)
end)

h.test("a server that dies for another reason fails with its first stderr line", function()
	local env = env_for({
		uuidgen = ok({ stdout = UUID }),
		serve = { status = 255, stdout = "", stderr = "Can't locate IO/Socket/INET.pm in @INC\nmore", timed_out = false },
		nc = FREE,
	})
	local got = start(env)
	h.eq(got[1].result.ok, false)
	h.eq(got[1].result.detail, "Can't locate IO/Socket/INET.pm in @INC")
	h.eq(#got, 1, "done is called once")
end)

h.test("perl that cannot start is a failure, not a crash", function()
	local env = env_for({
		uuidgen = ok({ stdout = UUID }),
		serve = { status = -2, stdout = "", stderr = "spawn failed: no such file", timed_out = false },
		nc = FREE,
	})
	local got = start(env)
	h.eq(got[1].result.ok, false)
	h.eq(got[1].result.detail, "spawn failed: no such file")
end)

h.test("a server whose port never answers fails after bounded polling", function()
	local env = env_for({ uuidgen = ok({ stdout = UUID }), serve = fakes.HOLD, nc = FREE })
	local got = start(env)
	h.eq(got[1].result.ok, false)
	h.eq(got[1].result.detail, "the preview server did not start")
	h.eq(#env.timers, 39)
end)

h.test("no token, no server", function()
	local env = env_for({ uuidgen = ok({ stdout = "nonsense" }) })
	local got = start(env)
	h.eq(got[1].result.ok, false)
	h.eq(env.kinds(), { "uuidgen" })
	local env2 = env_for({ uuidgen = { status = 1, stdout = UUID, stderr = "", timed_out = false } })
	h.eq(start(env2)[1].result.ok, false, "a failed uuidgen is not trusted even with output")
end)

h.test("an extension with no content type is refused up front", function()
	local env = env_for({})
	local got = start(env, { script = "/p/serve.pl", file = "/d/x.txt", name = "x.txt", ext = "txt" })
	h.eq(got[1].result.ok, false)
	h.eq(#env.log, 0)
end)

h.test("an unusable name is a failure, never an argv", function()
	local env = env_for({ uuidgen = ok({ stdout = UUID }), serve = fakes.HOLD })
	local got = start(env, { script = "/p/serve.pl", file = "/d/x.html", name = "../x.html", ext = "html" })
	h.eq(got[1].result.ok, false)
	h.eq(env.kinds(), { "uuidgen" })
end)

return {}
