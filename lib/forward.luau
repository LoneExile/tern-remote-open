--!strict
-- Starting, reusing, listing and stopping ssh port forwards.
--
-- Each forward is one backgrounded `ssh -f -M -S <socket> -L …` process. The
-- control socket (`<control dir>/<port>.sock`) is the handle on that process:
-- `ssh -O check` asks whether it is alive and `ssh -O exit` ends exactly it, so
-- nothing is matched by process name and nothing but our own forwards can be
-- stopped. Every step is asynchronous; the effects come in through `Env`.

local argv = require("./argv")
local config = require("./config")
local registry = require("./registry")
local text = require("./text")

local forward = {}

export type RunResult = { status: number, stdout: string, stderr: string, timed_out: boolean }

export type Env = {
	-- Runs a process; calls `cb` with its result and a context. A failure to
	-- start is reported as a result with status -2 (never raised).
	run: (cmd: { string }, timeout_ms: number, cx: WindowCx?, cb: (RunResult, WindowCx?) -> ()) -> (),
	-- Calls `cb` after `ms` milliseconds.
	after: (ms: number, cb: (WindowCx?) -> ()) -> (),
	kv: registry.Kv,
	-- Seconds since the epoch.
	now: () -> number,
	exists: (path: string) -> boolean,
	list: (path: string) -> { string },
	remove: (path: string) -> (),
	mkdir: (path: string) -> (),
	-- A random integer from `low` to `high`, both included.
	random: (low: number, high: number) -> number,
	-- The plugin's data directory.
	data_dir: string,
}

export type Request = {
	port: number,
	remote_host: string,
	target: string,
	host_name: string,
	-- Seconds the forward may live; nil: until stopped.
	ttl: number?,
}

export type Result = {
	ok: boolean,
	reused: boolean?,
	-- "port_in_use" | "other_forward" | "ssh" | "bad_request" | "socket_path"
	code: string?,
	title: string?,
	detail: string?,
}

export type Done = (Result, WindowCx?) -> ()

-- macOS limits a unix socket path to 103 bytes; ssh first creates the socket
-- under a name with a 17 byte random suffix.
local SOCKET_BUDGET = 103 - 17
local PROBE_RETRIES = 10
local PROBE_DELAY_MS = 150
-- Readiness polling of a starting forward: up to 100 x 250 ms.
local READY_POLLS = 100
local READY_DELAY_MS = 250

local inflight: { [number]: { Done } } = {}

function forward.control_dir(env: Env, cfg: config.Config): string
	return cfg.control_dir or (env.data_dir .. "/cm")
end

function forward.socket_path(env: Env, cfg: config.Config, port: number): string
	return string.format("%s/%d.sock", forward.control_dir(env, cfg), port)
end

local function guard(fn: () -> ()): string?
	local ok, err = pcall(function(): any
		fn()
		return nil
	end)
	if ok then
		return nil
	end
	return tostring(err)
end

-- Ensures `req.port` is forwarded from `req.target`. Calls `done` once.
function forward.ensure(env: Env, cfg: config.Config, req: Request, cx: WindowCx?, done: Done)
	local port = req.port
	local waiting = inflight[port]
	if waiting ~= nil then
		table.insert(waiting, done)
		return
	end
	inflight[port] = { done }

	local function finish(result: Result, cx2: WindowCx?)
		local waiters: { Done } = inflight[port] or {}
		inflight[port] = nil
		for _, waiter in waiters do
			waiter(result, cx2)
		end
	end
	local function fail(code: string, title: string, detail: string?, cx2: WindowCx?)
		finish({ ok = false, code = code, title = title, detail = detail }, cx2)
	end

	local sock = forward.socket_path(env, cfg, port)
	if #sock > SOCKET_BUDGET then
		fail(
			"socket_path",
			"Data directory path is too long for ssh",
			"Set control_dir in config.json to a short absolute path",
			cx
		)
		return
	end

	local function in_use(cx2: WindowCx?)
		fail(
			"port_in_use",
			string.format("Port %d is already in use on this Mac", port),
			"Stop what listens on it, or hold ⌥ to open the link as Tern normally does",
			cx2
		)
	end

	-- Starts ssh and waits until its control master answers `-O check`.
	--
	-- The process callback cannot signal readiness: with a remote command
	-- (`sleep TTL`) the backgrounded ssh keeps the runner's output pipes open
	-- until it ends, so the callback of a timed forward only arrives at its end.
	-- The control master is created after the local listener is bound, so a
	-- positive `-O check` means the forward is up. The callback still matters for
	-- failures (ssh exits non-zero at once, e.g. on a bind error) and as the end
	-- marker of a timed forward.
	local function start(cx2: WindowCx?)
		local dir = forward.control_dir(env, cfg)
		local mk = guard(function()
			env.mkdir(dir)
		end)
		if mk ~= nil then
			fail("ssh", "Cannot create the control directory", text.clean(mk, 120), cx2)
			return
		end
		local built, cmd = pcall(argv.ssh_forward, {
			target = req.target,
			socket = sock,
			port = port,
			remote_host = req.remote_host,
			ttl = req.ttl,
		})
		if not built then
			fail("bad_request", "Cannot forward this port", text.clean(tostring(cmd), 120), cx2)
			return
		end

		local settled = false
		local started = env.now()
		local function settle(result: Result, cx3: WindowCx?)
			if not settled then
				settled = true
				finish(result, cx3)
			end
		end
		local function clear_socket()
			guard(function()
				if env.exists(sock) then
					env.remove(sock)
				end
			end)
		end

		-- Runs until a timed forward ends; a bit longer than its lifetime so the
		-- runner never cuts it short.
		local lifetime_ms = ((req.ttl or 0) + 60) * 1000
		env.run(cmd :: { string }, math.max(25000, lifetime_ms), cx2, function(res: RunResult, cx3: WindowCx?)
			if settled then
				-- The end of a timed forward (or the parent of a permanent one
				-- returning): forget the entry if its process is gone.
				local recorded = registry.find(registry.load(env.kv), port)
				if recorded ~= nil and recorded.started == started then
					env.run(argv.ssh_check(sock, req.target), 8000, cx3, function(check: RunResult)
						if check.status ~= 0 then
							guard(function()
								registry.save(env.kv, registry.without(registry.load(env.kv), port))
							end)
							clear_socket()
						end
					end)
				end
				return
			end
			if res.status == 0 then
				-- ssh went to the background after setting up; readiness is
				-- confirmed by the poll below.
				return
			end
			clear_socket()
			if
				string.find(res.stderr, "Address already in use", 1, true)
				or string.find(res.stderr, "cannot listen to port", 1, true)
			then
				settle({
					ok = false,
					code = "port_in_use",
					title = string.format("Port %d is already in use on this Mac", port),
					detail = "Stop what listens on it, or hold ⌥ to open the link as Tern normally does",
				}, cx3)
			elseif res.timed_out then
				settle({ ok = false, code = "ssh", title = string.format("Timed out connecting to %s", req.host_name) }, cx3)
			else
				settle({
					ok = false,
					code = "ssh",
					title = string.format("Could not forward port %d from %s", port, req.host_name),
					detail = text.first_line(res.stderr, 160),
				}, cx3)
			end
		end)

		local function poll(i: number, cx3: WindowCx?)
			if settled then
				return
			end
			env.run(argv.ssh_check(sock, req.target), 8000, cx3, function(res: RunResult, cx4: WindowCx?)
				if settled then
					return
				end
				if res.status == 0 then
					local entry: registry.Entry = {
						port = port,
						host = req.host_name,
						target = req.target,
						remote_host = req.remote_host,
						socket = sock,
						started = started,
						expires = if req.ttl ~= nil then started + req.ttl else nil,
					}
					-- Re-read just before writing so another window's change is kept.
					guard(function()
						registry.save(env.kv, registry.with(registry.load(env.kv), entry))
					end)
					settle({ ok = true, reused = false }, cx4)
				elseif i >= READY_POLLS then
					-- Never came up: end whatever is half-started.
					env.run(argv.ssh_exit(sock, req.target), 8000, cx4, function(_: RunResult, cx5: WindowCx?)
						clear_socket()
						settle({
							ok = false,
							code = "ssh",
							title = string.format("Timed out connecting to %s", req.host_name),
						}, cx5)
					end)
				else
					env.after(READY_DELAY_MS, function(cx5: WindowCx?)
						poll(i + 1, cx5)
					end)
				end
			end)
		end
		poll(1, cx2)
	end

	-- Polls until nothing listens on 127.0.0.1:PORT, then starts. `retries` is
	-- for the moment after we ended a forward ourselves: its process leaves a
	-- beat after `-O exit` answers.
	local function await_free(retries: number, cx2: WindowCx?)
		env.run(argv.nc_probe(port), 5000, cx2, function(res: RunResult, cx3: WindowCx?)
			if res.status ~= 0 then
				start(cx3)
			elseif retries > 0 then
				env.after(PROBE_DELAY_MS, function(cx4: WindowCx?)
					await_free(retries - 1, cx4)
				end)
			else
				in_use(cx3)
			end
		end)
	end

	-- A control socket with no live registry entry is an orphan: end its
	-- process (if any) and clear the file before binding the port again.
	local function reap_then_start(cx2: WindowCx?)
		if not env.exists(sock) then
			await_free(0, cx2)
			return
		end
		env.run(argv.ssh_exit(sock, req.target), 8000, cx2, function(_: RunResult, cx3: WindowCx?)
			guard(function()
				if env.exists(sock) then
					env.remove(sock)
				end
			end)
			await_free(PROBE_RETRIES, cx3)
		end)
	end

	local entries = registry.load(env.kv)
	local entry = registry.find(entries, port)
	if entry == nil then
		reap_then_start(cx)
		return
	end

	env.run(argv.ssh_check(entry.socket, entry.target), 8000, cx, function(res: RunResult, cx2: WindowCx?)
		if res.status ~= 0 then
			-- Dead: forget it and carry on as if it had never been recorded.
			guard(function()
				registry.save(env.kv, registry.without(registry.load(env.kv), port))
			end)
			reap_then_start(cx2)
			return
		end
		if entry.target ~= req.target or entry.remote_host ~= req.remote_host then
			fail(
				"other_forward",
				string.format("Port %d is already forwarded from %s", port, entry.host),
				"Run Remote Open: Stop forwards first",
				cx2
			)
			return
		end
		if entry.expires == nil then
			finish({ ok = true, reused = true }, cx2)
			return
		end
		-- A timed forward is replaced, so a new sign-in gets a full lifetime
		-- (and a click on a localhost link makes it permanent).
		env.run(argv.ssh_exit(entry.socket, entry.target), 8000, cx2, function(_: RunResult, cx3: WindowCx?)
			guard(function()
				registry.save(env.kv, registry.without(registry.load(env.kv), port))
				if env.exists(entry.socket) then
					env.remove(entry.socket)
				end
			end)
			await_free(PROBE_RETRIES, cx3)
		end)
	end)
end

export type Listing = { alive: { registry.Entry }, pruned: number }

-- Checks every recorded forward against its process, drops the dead ones from
-- the registry and returns the live ones.
function forward.refresh(env: Env, cx: WindowCx?, done: (Listing, WindowCx?) -> ())
	local entries = registry.load(env.kv)
	if #entries == 0 then
		done({ alive = {}, pruned = 0 }, cx)
		return
	end
	local alive: { registry.Entry } = {}
	local dead: { number } = {}
	local remaining = #entries
	for _, entry in entries do
		env.run(argv.ssh_check(entry.socket, entry.target), 8000, cx, function(res: RunResult, cx2: WindowCx?)
			if res.status == 0 then
				table.insert(alive, entry)
			else
				table.insert(dead, entry.port)
			end
			remaining -= 1
			if remaining > 0 then
				return
			end
			if #dead > 0 then
				guard(function()
					local current = registry.load(env.kv)
					for _, port in dead do
						current = registry.without(current, port)
					end
					registry.save(env.kv, current)
				end)
			end
			table.sort(alive, function(a: registry.Entry, b: registry.Entry): boolean
				return a.port < b.port
			end)
			done({ alive = alive, pruned = #dead }, cx2)
		end)
	end
end

export type Stopped = { ports: { number }, failed: number }

-- Ends every forward the plugin started: each recorded one, and any control
-- socket left in the control directory by a forward the registry lost. Nothing
-- else is touched: only processes that own one of our sockets are asked to exit.
function forward.stop_all(env: Env, cfg: config.Config, cx: WindowCx?, done: (Stopped, WindowCx?) -> ())
	type Job = { socket: string, target: string, port: number? }
	local jobs: { Job } = {}
	local seen: { [string]: boolean } = {}
	for _, entry in registry.load(env.kv) do
		jobs[#jobs + 1] = { socket = entry.socket, target = entry.target, port = entry.port }
		seen[entry.socket] = true
	end
	local dir = forward.control_dir(env, cfg)
	local ok, names = pcall(env.list, dir)
	if ok then
		for _, name in names :: { string } do
			local digits = string.match(name, "^(%d+)%.sock$")
			local socket = dir .. "/" .. name
			if digits ~= nil and not seen[socket] then
				jobs[#jobs + 1] = { socket = socket, target = "remote-open", port = tonumber(digits) }
			end
		end
	end
	if #jobs == 0 then
		done({ ports = {}, failed = 0 }, cx)
		return
	end

	local ports: { number } = {}
	local failed = 0
	local remaining = #jobs
	for _, job in jobs do
		env.run(argv.ssh_exit(job.socket, job.target), 8000, cx, function(res: RunResult, cx2: WindowCx?)
			-- Status 255 with the socket gone means it was already dead: not a failure.
			if res.status == 0 and job.port ~= nil then
				table.insert(ports, job.port)
			elseif res.status ~= 0 and env.exists(job.socket) then
				-- A stale file nobody serves: clear it.
				guard(function()
					env.remove(job.socket)
				end)
			end
			if res.status == -2 then
				failed += 1
			end
			remaining -= 1
			if remaining > 0 then
				return
			end
			guard(function()
				registry.save(env.kv, {})
			end)
			table.sort(ports)
			done({ ports = ports, failed = failed }, cx2)
		end)
	end
end

return forward
