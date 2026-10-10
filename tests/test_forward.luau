--!nocheck
local h = require("./harness")
local argv = require("../lib/argv")
local config = require("../lib/config")
local forward = require("../lib/forward")
local registry = require("../lib/registry")
local fakes = require("./fakes")

h.group("forward")

local ok = fakes.ok
local CFG = config.normalize({}).config
local SOCK = "/data/cm/8250.sock"

-- `script` maps a command kind to a result, `fakes.HOLD`, or a function
-- (argv, n, env) returning one (n counts the calls of that kind).
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

local function request(extra)
	local r = { port = 8250, remote_host = "localhost", target = "you@devbox", host_name = "devbox" }
	for k, v in extra or {} do
		r[k] = v
	end
	return r
end

local function entry(port, extra)
	local e = {
		port = port, host = "devbox", target = "you@devbox", remote_host = "localhost",
		socket = "/data/cm/" .. port .. ".sock", started = 900,
	}
	for k, v in extra or {} do
		e[k] = v
	end
	return e
end

local function ensure(env, req, cfg)
	local got = {}
	forward.ensure(env, cfg or CFG, req or request(), { id = 0 }, function(result, cx)
		table.insert(got, { result = result, cx = cx })
	end)
	env.pump()
	return got
end

local function forward_cmd(env)
	for _, call in env.log do
		if fakes.kind(call.argv) == "ssh_forward" then
			return call.argv
		end
	end
end

local FREE = { status = 1, stdout = "", stderr = "", timed_out = false }
local BUSY = ok()
local DEAD = { status = 255, stdout = "", stderr = "Control socket connect(x): No such file or directory", timed_out = false }
local BIND_FAIL = { status = 255, stdout = "", stderr = "bind [127.0.0.1]:8250: Address already in use\nCould not request local forwarding.", timed_out = false }

-- ssh_check: dead for its first `n` calls, then alive.
local function alive_after(n)
	return function(_, calls)
		if calls <= n then
			return DEAD
		end
		return ok()
	end
end

h.test("a fresh forward: probe the port, start ssh, confirm with its control master, record it", function()
	local env = env_for({ nc = FREE })
	local got = ensure(env)
	h.eq(#got, 1)
	h.eq(got[1].result.ok, true)
	h.eq(got[1].result.reused, false)
	h.eq(env.kinds(), { "nc", "ssh_forward", "ssh_check" })
	h.eq(env.log[1].argv, argv.nc_probe(8250))
	h.eq(env.log[2].argv, argv.ssh_forward({ target = "you@devbox", socket = SOCK, port = 8250, remote_host = "localhost" }))
	h.eq(env.log[3].argv, argv.ssh_check(SOCK, "you@devbox"))
	h.truthy(env.dirs["/data/cm"], "the control directory was created")
	local saved = registry.load(env.kv)
	h.eq(#saved, 1)
	h.eq(saved[1].port, 8250)
	h.eq(saved[1].socket, SOCK)
	h.eq(saved[1].host, "devbox")
	h.eq(saved[1].started, 1000)
	h.eq(saved[1].expires, nil)
	h.truthy(got[1].cx, "the final callback receives a fresh context")
end)

h.test("readiness waits for the control master, polling without blocking", function()
	local env = env_for({ nc = FREE, ssh_check = alive_after(3) })
	local got = ensure(env)
	h.eq(got[1].result.ok, true)
	h.eq(env.kinds(), { "nc", "ssh_forward", "ssh_check", "ssh_check", "ssh_check", "ssh_check" })
	h.eq(#env.timers, 3)
	h.eq(env.timers[1], 250)
end)

h.test("a timed forward is confirmed while its ssh is still running, and records when it ends", function()
	local env = env_for({ nc = FREE, ssh_forward = fakes.HOLD })
	local got = ensure(env, request({ ttl = 600 }))
	h.eq(got[1].result.ok, true, "the result does not wait for ssh to end")
	local cmd = forward_cmd(env)
	h.eq(cmd[#cmd], "600")
	h.eq(cmd[#cmd - 1], "sleep")
	h.eq(registry.load(env.kv)[1].expires, 1600)
	h.eq(#env.held, 1, "ssh is still running")
	local started = 0
	for _, call in env.log do
		if fakes.kind(call.argv) == "ssh_forward" then
			h.eq(call.timeout_ms, 660000, "the runner never cuts a timed forward short")
			started += 1
		end
	end
	h.eq(started, 1)
end)

h.test("when a timed forward's ssh ends, its entry is dropped only if the process is gone", function()
	local env = env_for({ nc = FREE, ssh_forward = fakes.HOLD, ssh_check = ok() })
	ensure(env, request({ ttl = 600 }))
	-- ssh ends while the master still answers (an open connection keeps it): keep the entry
	env.held[1].cb(ok())
	env.pump()
	h.eq(#registry.load(env.kv), 1)

	local env2 = env_for({ nc = FREE, ssh_forward = fakes.HOLD, ssh_check = function(_, n)
		if n == 1 then
			return ok()
		end
		return DEAD
	end })
	env2.files[SOCK] = true
	ensure(env2, request({ ttl = 600 }))
	h.eq(#registry.load(env2.kv), 1)
	env2.held[1].cb(ok())
	env2.pump()
	h.eq(registry.load(env2.kv), {}, "the finished forward is forgotten")
	h.falsy(env2.files[SOCK], "and its socket file removed")
end)

h.test("something else on the port refuses, and starts nothing", function()
	local env = env_for({ nc = BUSY })
	local got = ensure(env)
	h.eq(got[1].result.ok, false)
	h.eq(got[1].result.code, "port_in_use")
	h.truthy(string.find(got[1].result.title, "8250", 1, true), "the toast names the port")
	h.eq(env.kinds(), { "nc" })
	h.eq(registry.load(env.kv), {})
end)

h.test("our own live forward to the same host and port is reused", function()
	local env = env_for({ ssh_check = ok() })
	registry.save(env.kv, { entry(8250) })
	local got = ensure(env)
	h.eq(got[1].result.ok, true)
	h.eq(got[1].result.reused, true)
	h.eq(env.kinds(), { "ssh_check" })
	h.eq(env.log[1].argv, argv.ssh_check(SOCK, "you@devbox"))
end)

h.test("our own forward to another host or remote end is refused, not reused", function()
	local env = env_for({ ssh_check = ok() })
	registry.save(env.kv, { entry(8250, { target = "me@elsewhere", host = "elsewhere" }) })
	local got = ensure(env)
	h.eq(got[1].result.ok, false)
	h.eq(got[1].result.code, "other_forward")
	h.truthy(string.find(got[1].result.title, "elsewhere", 1, true))
	h.eq(env.kinds(), { "ssh_check" })

	local env2 = env_for({ ssh_check = ok() })
	registry.save(env2.kv, { entry(8250, { remote_host = "127.0.0.1" }) })
	h.eq(ensure(env2)[1].result.code, "other_forward")
end)

h.test("a dead recorded forward is forgotten and replaced", function()
	local env = env_for({ ssh_check = alive_after(1), nc = FREE })
	registry.save(env.kv, { entry(8250, { started = 5 }) })
	local got = ensure(env)
	h.eq(got[1].result.ok, true)
	h.eq(got[1].result.reused, false)
	h.eq(env.kinds(), { "ssh_check", "nc", "ssh_forward", "ssh_check" })
	h.eq(registry.load(env.kv)[1].started, 1000)
end)

h.test("a dead recorded forward is dropped even when the replacement cannot start", function()
	local env = env_for({ ssh_check = DEAD, nc = BUSY })
	registry.save(env.kv, { entry(8250) })
	local got = ensure(env)
	h.eq(got[1].result.code, "port_in_use")
	h.eq(registry.load(env.kv), {}, "no record of a forward that is not running")
end)

h.test("a timed forward is replaced so a new sign-in gets a full lifetime", function()
	local env = env_for({
		ssh_check = ok(),
		ssh_exit = ok(),
		ssh_forward = fakes.HOLD,
		nc = function(_, n)
			if n <= 2 then
				return BUSY
			end
			return FREE
		end,
	})
	registry.save(env.kv, { entry(8250, { expires = 1010 }) })
	local got = ensure(env, request({ ttl = 600 }))
	h.eq(got[1].result.ok, true)
	h.eq(got[1].result.reused, false)
	h.eq(env.kinds(), { "ssh_check", "ssh_exit", "nc", "nc", "nc", "ssh_forward", "ssh_check" })
	h.eq(#env.timers, 2, "it waited for the old process to release the port")
	h.eq(registry.load(env.kv)[1].expires, 1600)
end)

h.test("a timed forward becomes permanent when a localhost link needs the same port", function()
	local env = env_for({ ssh_check = ok(), ssh_exit = ok(), nc = FREE })
	registry.save(env.kv, { entry(8250, { expires = 1500 }) })
	ensure(env, request())
	h.eq(registry.load(env.kv)[1].expires, nil)
	h.truthy(table.find(forward_cmd(env), "-N"))
end)

h.test("a replaced forward whose port never frees refuses after bounded retries", function()
	local env = env_for({ ssh_check = ok(), ssh_exit = ok(), nc = BUSY })
	registry.save(env.kv, { entry(8250, { expires = 1500 }) })
	local got = ensure(env, request({ ttl = 600 }))
	h.eq(got[1].result.code, "port_in_use")
	h.eq(#env.timers, 10)
end)

h.test("ssh failing on the bind reports the port as in use and clears the socket", function()
	local env = env_for({
		nc = FREE,
		ssh_check = DEAD,
		ssh_forward = function(_, _, e)
			e.files[SOCK] = true
			return BIND_FAIL
		end,
	})
	local got = ensure(env)
	h.eq(#got, 1, "the result is reported once")
	h.eq(got[1].result.code, "port_in_use")
	h.falsy(env.files[SOCK], "the stale socket is removed")
	h.eq(registry.load(env.kv), {})
end)

h.test("any other ssh failure shows the first line of stderr, cleaned", function()
	local env = env_for({
		nc = FREE,
		ssh_check = DEAD,
		ssh_forward = { status = 255, stdout = "", stderr = "\27[31mHost key verification failed.\27[0m\nmore", timed_out = false },
	})
	local got = ensure(env)
	h.eq(got[1].result.ok, false)
	h.eq(got[1].result.code, "ssh")
	h.eq(got[1].result.title, "Could not forward port 8250 from devbox")
	h.eq(got[1].result.detail, "[31mHost key verification failed. [0m")
	h.eq(registry.load(env.kv), {})
end)

h.test("an ssh timeout is named as one", function()
	local env = env_for({ nc = FREE, ssh_check = DEAD, ssh_forward = { status = -1, stdout = "", stderr = "", timed_out = true } })
	local got = ensure(env)
	h.eq(got[1].result.code, "ssh")
	h.truthy(string.find(got[1].result.title, "Timed out", 1, true))
end)

h.test("a process that cannot start is a failure, not a crash or a probe hit", function()
	local env = env_for({
		nc = { status = -2, stdout = "", stderr = "spawn failed", timed_out = false },
		ssh_check = DEAD,
		ssh_forward = { status = -2, stdout = "", stderr = "spawn failed: no such file", timed_out = false },
	})
	local got = ensure(env)
	h.eq(got[1].result.code, "ssh")
	h.eq(got[1].result.detail, "spawn failed: no such file")
end)

h.test("a forward that never comes up is ended, cleaned up and reported", function()
	local env = env_for({
		nc = FREE,
		ssh_check = DEAD,
		ssh_exit = ok(),
		ssh_forward = function(_, _, e)
			e.files[SOCK] = true -- ssh made its control socket, then never answered
			return fakes.HOLD
		end,
	})
	local got = ensure(env)
	h.eq(#got, 1)
	h.eq(got[1].result.ok, false)
	h.eq(got[1].result.code, "ssh")
	h.truthy(string.find(got[1].result.title, "Timed out", 1, true))
	local checks, exits = 0, 0
	for _, k in env.kinds() do
		if k == "ssh_check" then
			checks += 1
		elseif k == "ssh_exit" then
			exits += 1
		end
	end
	h.eq(checks, 100)
	h.eq(exits, 1, "whatever was half-started is ended")
	h.eq(#env.timers, 99)
	h.falsy(env.files[SOCK])
	h.eq(registry.load(env.kv), {})
end)

h.test("a result that arrives after the failure is ignored", function()
	local env = env_for({ nc = FREE, ssh_check = alive_after(2), ssh_forward = BIND_FAIL })
	local got = ensure(env)
	h.eq(#got, 1)
	h.eq(got[1].result.code, "port_in_use", "the early ssh failure wins over the later poll")
	h.eq(registry.load(env.kv), {})
end)

h.test("the parent ssh returning 0 is not a finished forward", function()
	-- `ssh -f` returns once it has gone to the background; readiness decides.
	local env = env_for({ nc = FREE, ssh_check = alive_after(2), ssh_forward = ok() })
	local got = ensure(env)
	h.eq(got[1].result.ok, true)
	h.eq(#got, 1)
end)

h.test("a data directory too deep for a unix socket is refused up front", function()
	local env = env_for({})
	env.data_dir = "/" .. string.rep("a", 90)
	local got = ensure(env)
	h.eq(got[1].result.code, "socket_path")
	h.eq(#env.log, 0)
	-- control_dir from config is the way out
	local env2 = env_for({ nc = FREE })
	env2.data_dir = "/" .. string.rep("a", 90)
	local cfg = config.normalize({ control_dir = "/tmp/ro" }).config
	local got2 = ensure(env2, request(), cfg)
	h.eq(got2[1].result.ok, true)
	h.truthy(table.find(env2.log[2].argv, "/tmp/ro/8250.sock"))
end)

h.test("two clicks on one port start one forward and both hear the result", function()
	local env = env_for({ nc = FREE })
	local got = {}
	for _ = 1, 2 do
		forward.ensure(env, CFG, request(), nil, function(result)
			table.insert(got, result)
		end)
	end
	env.pump()
	h.eq(#got, 2)
	h.eq(got[1].ok, true)
	h.eq(got[2].ok, true)
	local starts = 0
	for _, k in env.kinds() do
		if k == "ssh_forward" then
			starts += 1
		end
	end
	h.eq(starts, 1)
end)

h.test("an orphan control socket is ended and cleared before binding again", function()
	local env = env_for({
		ssh_exit = ok(),
		nc = function(_, n)
			if n == 1 then
				return BUSY
			end
			return FREE
		end,
	})
	env.files[SOCK] = true
	local got = ensure(env)
	h.eq(got[1].result.ok, true)
	h.eq(env.kinds(), { "ssh_exit", "nc", "nc", "ssh_forward", "ssh_check" })
	h.falsy(env.files[SOCK])
end)

h.test("different ports do not block each other", function()
	local env = env_for({ nc = FREE })
	local got = {}
	for _, port in { 3000, 3001 } do
		forward.ensure(env, CFG, request({ port = port }), nil, function(result)
			table.insert(got, result)
		end)
	end
	env.pump()
	h.eq(#got, 2)
	h.eq(#registry.load(env.kv), 2)
end)

h.test("refresh keeps live forwards, drops dead ones from the registry", function()
	local env = env_for({
		ssh_check = function(cmd)
			if table.find(cmd, "/data/cm/8250.sock") then
				return ok()
			end
			return DEAD
		end,
	})
	registry.save(env.kv, { entry(3000), entry(3001), entry(8250) })
	local listing
	forward.refresh(env, { id = 0 }, function(l)
		listing = l
	end)
	env.pump()
	h.eq(#listing.alive, 1)
	h.eq(listing.alive[1].port, 8250)
	h.eq(listing.pruned, 2)
	h.eq(#registry.load(env.kv), 1)
	h.eq(registry.load(env.kv)[1].port, 8250)
end)

h.test("refresh with nothing recorded runs nothing", function()
	local env = env_for({})
	local listing
	forward.refresh(env, nil, function(l)
		listing = l
	end)
	env.pump()
	h.eq(listing, { alive = {}, pruned = 0 })
	h.eq(#env.log, 0)
end)

h.test("stop_all ends exactly our sockets: recorded and orphaned, nothing else", function()
	local env = env_for({ ssh_exit = ok() })
	registry.save(env.kv, { entry(8250), entry(3000) })
	env.files["/data/cm/8250.sock"] = true
	env.files["/data/cm/3000.sock"] = true
	env.files["/data/cm/9999.sock"] = true -- the registry lost this one
	env.files["/data/cm/notes.txt"] = true
	env.files["/data/cm/12ab.sock"] = true
	env.files["/data/other.sock"] = true
	env.files["/elsewhere/4444.sock"] = true
	local stopped
	forward.stop_all(env, CFG, { id = 0 }, function(s)
		stopped = s
	end)
	env.pump()
	h.eq(stopped.ports, { 3000, 8250, 9999 })
	h.eq(stopped.failed, 0)
	h.eq(#env.log, 3)
	local sockets = {}
	for _, call in env.log do
		h.eq(fakes.kind(call.argv), "ssh_exit")
		local i = table.find(call.argv, "-S")
		table.insert(sockets, call.argv[i + 1])
	end
	table.sort(sockets)
	h.eq(sockets, { "/data/cm/3000.sock", "/data/cm/8250.sock", "/data/cm/9999.sock" })
	h.eq(registry.load(env.kv), {})
end)

h.test("stop_all clears a stale socket nobody serves and does not count it", function()
	local env = env_for({ ssh_exit = DEAD })
	env.files["/data/cm/5555.sock"] = true
	local stopped
	forward.stop_all(env, CFG, nil, function(s)
		stopped = s
	end)
	env.pump()
	h.eq(stopped.ports, {})
	h.falsy(env.files["/data/cm/5555.sock"])
end)

h.test("stop_all with nothing running runs nothing", function()
	local env = env_for({})
	local stopped
	forward.stop_all(env, CFG, nil, function(s)
		stopped = s
	end)
	env.pump()
	h.eq(stopped, { ports = {}, failed = 0 })
	h.eq(#env.log, 0)
end)

h.test("stop_all honours control_dir from the config", function()
	local env = env_for({ ssh_exit = ok() })
	env.files["/tmp/ro/7000.sock"] = true
	env.files["/data/cm/8250.sock"] = true
	local cfg = config.normalize({ control_dir = "/tmp/ro" }).config
	local stopped
	forward.stop_all(env, cfg, nil, function(s)
		stopped = s
	end)
	env.pump()
	h.eq(stopped.ports, { 7000 })
end)

return {}
