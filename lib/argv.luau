--!strict
-- Every command line the plugin runs, built as an argument vector. There is no
-- shell anywhere: values are validated first and each stays one argv element.
-- Builders raise on invalid input; callers validate earlier, so a raise means
-- a bug, never user data reaching a process.

local check = require("./check")

local argv = {}

argv.SSH = "/usr/bin/ssh"
argv.SCP = "/usr/bin/scp"
argv.NC = "/usr/bin/nc"
argv.OPEN = "/usr/bin/open"
argv.FIND = "/usr/bin/find"
argv.PERL = "/usr/bin/perl"
argv.UUIDGEN = "/usr/bin/uuidgen"

-- Options on every ssh/scp the plugin starts: no prompts, and a host key that
-- is not already trusted is a failure, never a question.
local function safe_options(): { string }
	return { "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes" }
end

local function need_target(target: string)
	if not check.target(target) then
		error("invalid ssh target")
	end
end

local function need_path(path: string, what: string)
	if not check.abs_path(path) then
		error("invalid " .. what)
	end
end

-- Copies `target:path` to the local file `dest`. `-s` forces the SFTP protocol,
-- which passes the remote path as data; the legacy protocol would hand it to a
-- remote shell. `--` ends options before the two operands.
function argv.scp(target: string, path: string, dest: string): { string }
	need_target(target)
	need_path(path, "remote path")
	need_path(dest, "local path")
	local out = { argv.SCP, "-q", "-s" }
	for _, o in safe_options() do
		table.insert(out, o)
	end
	for _, o in { "-o", "ConnectTimeout=10", "--", target .. ":" .. path, dest } do
		table.insert(out, o)
	end
	return out
end

export type Forward = {
	target: string,
	socket: string,
	port: number,
	-- The host to connect to on the remote side: `localhost`, `127.0.0.1` or `[::1]`.
	remote_host: string,
	-- Seconds the forward lives. nil: until stopped.
	ttl: number?,
}

-- A local forward of 127.0.0.1:PORT to REMOTE_HOST:PORT on `target`, as a
-- backgrounded ssh that is also a control master on `socket`. The control
-- socket is how the plugin later checks and stops exactly this process.
--
-- Without `ttl` the session is `-N` (no command) and lives until stopped. With
-- `ttl` the remote command is `sleep TTL`, so ssh ends by itself; forwarded
-- connections still open at that moment are allowed to finish.
function argv.ssh_forward(f: Forward): { string }
	need_target(f.target)
	need_path(f.socket, "control socket path")
	local port = check.port(f.port)
	if port == nil then
		error("invalid port")
	end
	if not check.loopback_host(f.remote_host) then
		error("invalid remote host")
	end
	local out = { argv.SSH, "-f", "-T", "-M", "-S", f.socket }
	for _, o in safe_options() do
		table.insert(out, o)
	end
	for _, o in {
		"-o",
		"ExitOnForwardFailure=yes",
		"-o",
		"ServerAliveInterval=30",
		"-o",
		"ConnectTimeout=10",
		"-o",
		"ControlPersist=no",
		"-L",
		string.format("127.0.0.1:%d:%s:%d", port, f.remote_host, port),
	} do
		table.insert(out, o)
	end
	if f.ttl == nil then
		table.insert(out, "-N")
	end
	table.insert(out, "--")
	table.insert(out, f.target)
	if f.ttl ~= nil then
		local ttl = f.ttl
		if ttl ~= math.floor(ttl) or ttl < 1 or ttl > 86400 then
			error("invalid ttl")
		end
		table.insert(out, "sleep")
		table.insert(out, string.format("%d", ttl))
	end
	return out
end

-- Asks the control master on `socket` for `op` ("check" or "exit"). The
-- destination is required by ssh's syntax; it is not contacted.
local function ssh_control(op: string, socket: string, target: string): { string }
	need_target(target)
	need_path(socket, "control socket path")
	return { argv.SSH, "-S", socket, "-O", op, "-o", "BatchMode=yes", "--", target }
end

function argv.ssh_check(socket: string, target: string): { string }
	return ssh_control("check", socket, target)
end

function argv.ssh_exit(socket: string, target: string): { string }
	return ssh_control("exit", socket, target)
end

-- Exits 0 when something accepts connections on 127.0.0.1:PORT.
function argv.nc_probe(port: number): { string }
	local p = check.port(port)
	if p == nil then
		error("invalid port")
	end
	return { argv.NC, "-z", "-w", "2", "127.0.0.1", string.format("%d", p) }
end

-- The macOS default handler for a local file.
function argv.open(path: string): { string }
	need_path(path, "local path")
	return { argv.OPEN, path }
end

-- Deletes cached copies older than `days` days from `dir`.
function argv.find_old(dir: string, days: number): { string }
	need_path(dir, "cache directory")
	if days ~= math.floor(days) or days < 1 then
		error("invalid days")
	end
	return { argv.FIND, dir, "-type", "f", "-mtime", string.format("+%d", days), "-delete" }
end

-- A fresh random UUID on stdout: the unguessable part of a served file's URL.
function argv.uuidgen(): { string }
	return { argv.UUIDGEN }
end

-- The content types `serve.pl` may send. Anything else is refused.
argv.CONTENT_TYPES = {
	["text/html; charset=utf-8"] = true,
	["image/svg+xml"] = true,
	["application/pdf"] = true,
	["image/png"] = true,
	["image/jpeg"] = true,
	["image/gif"] = true,
	["image/webp"] = true,
}

export type Serve = {
	script: string,
	port: number,
	token: string,
	file: string,
	name: string,
	content_type: string,
	idle: number,
}

-- `serve.pl` serving `file` at /TOKEN/NAME on 127.0.0.1:PORT until it has been
-- idle for `idle` seconds.
function argv.serve(s: Serve): { string }
	need_path(s.script, "script path")
	need_path(s.file, "file path")
	local port = check.port(s.port)
	if port == nil then
		error("invalid port")
	end
	if #s.token ~= 32 or string.find(s.token, "[^0-9a-f]") then
		error("invalid token")
	end
	if #s.name < 1 or #s.name > 200 or string.find(s.name, "[^%w._-]") then
		error("invalid name")
	end
	if not argv.CONTENT_TYPES[s.content_type] then
		error("invalid content type")
	end
	if s.idle ~= math.floor(s.idle) or s.idle < 1 or s.idle > 86400 then
		error("invalid idle time")
	end
	return {
		argv.PERL,
		s.script,
		string.format("%d", port),
		s.token,
		s.file,
		s.name,
		s.content_type,
		string.format("%d", s.idle),
	}
end

return argv
