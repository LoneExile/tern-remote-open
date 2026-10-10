--!nocheck
-- Shared fixtures for the tests: hosts, links, and a fake environment.

local fakes = {}

function fakes.host(opts)
	opts = opts or {}
	return {
		id = opts.id or 1,
		name = opts.name or "devbox",
		kind = opts.kind or "remote",
		state = opts.state or "connected",
		address = if opts.address == false then nil else (opts.address or "you@devbox"),
		panes = opts.panes or { 41 },
		sessions = {},
		current = false,
	}
end

function fakes.link(url, opts)
	opts = opts or {}
	local pane = 41
	if opts.pane ~= nil then
		pane = if opts.pane == false then nil else opts.pane
	end
	return {
		url = url,
		pane = pane,
		mods = {
			cmd = opts.cmd or false,
			alt = opts.alt or false,
			shift = opts.shift or false,
			ctrl = opts.ctrl or false,
		},
	}
end

-- Which command an argv is, by its binary and flags.
function fakes.kind(argv)
	local bin = argv[1]
	if bin == "/usr/bin/scp" then
		return "scp"
	elseif bin == "/usr/bin/nc" then
		return "nc"
	elseif bin == "/usr/bin/open" then
		return "open"
	elseif bin == "/usr/bin/perl" then
		return "serve"
	elseif bin == "/usr/bin/uuidgen" then
		return "uuidgen"
	elseif bin == "/usr/bin/find" then
		return "find"
	elseif bin == "/usr/bin/ssh" then
		local i = table.find(argv, "-O")
		if i ~= nil then
			return "ssh_" .. argv[i + 1]
		end
		return "ssh_forward"
	end
	return "unknown"
end

local function ok(extra)
	local r = { status = 0, stdout = "", stderr = "", timed_out = false }
	for k, v in extra or {} do
		r[k] = v
	end
	return r
end
fakes.ok = ok

-- Returned by a responder for a process that keeps running: its callback is
-- not called, only kept in `env.held` until a test releases it.
fakes.HOLD = { hold = true }

-- A fake forward.Env. `responder(argv, env)` returns the result of each run.
-- Callbacks are queued and delivered by `pump`, as real ones arrive later.
function fakes.env(responder)
	local env = {
		log = {},
		queue = {},
		timers = {},
		files = {},
		dirs = {},
		kv_data = {},
		clock = 1000,
		data_dir = "/data",
		held = {},
		randoms = {},
	}
	local cx_counter = 0
	local function new_cx()
		cx_counter += 1
		return { id = cx_counter }
	end
	function env.run(cmd, timeout_ms, cx, cb)
		table.insert(env.log, { argv = cmd, timeout_ms = timeout_ms })
		local result = responder(cmd, env)
		if result == fakes.HOLD then
			table.insert(env.held, { argv = cmd, cb = function(r)
				cb(r, new_cx())
			end })
			return
		end
		table.insert(env.queue, function()
			cb(result, new_cx())
		end)
	end
	function env.after(ms, cb)
		table.insert(env.timers, ms)
		table.insert(env.queue, function()
			cb(new_cx())
		end)
	end
	env.kv = {
		get = function(key)
			return env.kv_data[key]
		end,
		set = function(key, value)
			env.kv_data[key] = value
		end,
	}
	function env.now()
		return env.clock
	end
	-- Hands out `env.randoms` in order, then low, low + 1, …
	local drawn = 0
	function env.random(low)
		drawn += 1
		return table.remove(env.randoms, 1) or (low + drawn - 1)
	end
	function env.exists(path)
		return env.files[path] == true or env.dirs[path] == true
	end
	function env.list(path)
		local out = {}
		local prefix = path .. "/"
		for p in env.files do
			if string.sub(p, 1, #prefix) == prefix and not string.find(string.sub(p, #prefix + 1), "/", 1, true) then
				table.insert(out, string.sub(p, #prefix + 1))
			end
		end
		table.sort(out)
		return out
	end
	function env.remove(path)
		env.files[path] = nil
	end
	function env.mkdir(path)
		env.dirs[path] = true
	end
	function env.pump()
		local guard = 0
		while #env.queue > 0 do
			guard += 1
			if guard > 500 then
				error("pump: runaway")
			end
			local fn = table.remove(env.queue, 1)
			fn()
		end
	end
	function env.kinds()
		local out = {}
		for _, entry in env.log do
			table.insert(out, fakes.kind(entry.argv))
		end
		return out
	end
	return env
end

return fakes
