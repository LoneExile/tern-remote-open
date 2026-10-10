--!strict
-- Showing a local file in Tern's browser block.
--
-- Measured: Tern opens a `file://` URL in a source-code file block, a `data:`
-- URL goes to the system, and the browser automation cannot address a block of
-- a remote host's tab ("no block … in this window's tabs"). What does open the
-- browser block beside a remote pane is an `http://` link. So the copy is
-- served for a few minutes by `serve.pl` on 127.0.0.1: one file, at an
-- unguessable path, on a random port.

local argv = require("./argv")
local forward = require("./forward")
local text = require("./text")

local serve = {}

-- Seconds the server waits without a connection before it exits.
serve.IDLE = 600

local MAX_ATTEMPTS = 4
local POLL_MAX = 40
local POLL_DELAY_MS = 100
local PORT_LOW = 49152
local PORT_HIGH = 65535

serve.CONTENT_TYPES = {
	html = "text/html; charset=utf-8",
	htm = "text/html; charset=utf-8",
	svg = "image/svg+xml",
	pdf = "application/pdf",
	png = "image/png",
	jpg = "image/jpeg",
	jpeg = "image/jpeg",
	gif = "image/gif",
	webp = "image/webp",
}

function serve.url(port: number, token: string, name: string): string
	return string.format("http://127.0.0.1:%d/%s/%s", port, token, name)
end

-- `uuidgen` prints `XXXXXXXX-XXXX-…`; the token is its 32 hex digits, lowercase.
function serve.token_from(stdout: string): string?
	local digits = string.gsub(stdout, "[^%x]", "")
	local token = string.lower(digits)
	if #token ~= 32 then
		return nil
	end
	return token
end

export type Request = {
	-- Absolute path of serve.pl.
	script: string,
	file: string,
	-- The file name in the URL: [A-Za-z0-9._-].
	name: string,
	-- The lowercase extension, a key of `serve.CONTENT_TYPES`.
	ext: string,
}

export type Result = { ok: boolean, url: string?, detail: string? }

-- Starts a server for `req.file` and calls `done` once the port answers (or
-- with the reason it could not start). The server process lives on after
-- `done`; it ends itself after `serve.IDLE` seconds without a connection.
function serve.start(env: forward.Env, req: Request, cx: WindowCx?, done: (Result, WindowCx?) -> ())
	local content_type = serve.CONTENT_TYPES[req.ext]
	if content_type == nil then
		done({ ok = false, detail = "no content type for ." .. req.ext }, cx)
		return
	end

	local function attempt(n: number, token: string, cx2: WindowCx?)
		local port = env.random(PORT_LOW, PORT_HIGH)
		local built, cmd = pcall(argv.serve, {
			script = req.script,
			port = port,
			token = token,
			file = req.file,
			name = req.name,
			content_type = content_type,
			idle = serve.IDLE,
		})
		if not built then
			done({ ok = false, detail = text.clean(tostring(cmd), 120) }, cx2)
			return
		end

		local state = { exited = false, status = 0, stderr = "" }
		local settled = false
		local function settle(result: Result, cx3: WindowCx?)
			if not settled then
				settled = true
				done(result, cx3)
			end
		end

		-- The server runs until it has been idle; this callback is its exit.
		env.run(cmd :: { string }, (serve.IDLE + 60) * 1000, cx2, function(res: forward.RunResult, _: WindowCx?)
			state.exited = true
			state.status = res.status
			state.stderr = res.stderr
		end)

		local function poll(i: number, cx3: WindowCx?)
			if state.exited then
				if state.status == 66 and n < MAX_ATTEMPTS then
					attempt(n + 1, token, cx3)
				else
					settle({
						ok = false,
						detail = if state.status == 66
							then "no free port for the preview server"
							else text.first_line(state.stderr, 160),
					}, cx3)
				end
				return
			end
			env.run(argv.nc_probe(port), 3000, cx3, function(res: forward.RunResult, cx4: WindowCx?)
				if res.status == 0 and not state.exited then
					settle({ ok = true, url = serve.url(port, token, req.name) }, cx4)
				elseif i >= POLL_MAX then
					settle({ ok = false, detail = "the preview server did not start" }, cx4)
				else
					env.after(POLL_DELAY_MS, function(cx5: WindowCx?)
						poll(i + 1, cx5)
					end)
				end
			end)
		end
		poll(1, cx2)
	end

	env.run(argv.uuidgen(), 5000, cx, function(res: forward.RunResult, cx2: WindowCx?)
		local token = if res.status == 0 then serve.token_from(res.stdout) else nil
		if token == nil then
			done({ ok = false, detail = "uuidgen gave no token" }, cx2)
			return
		end
		attempt(1, token, cx2)
	end)
end

return serve
