#!/usr/bin/env python3
"""Proves the tests can fail.

Each mutation breaks one guarded behaviour in a throwaway copy of the repo and
runs the suite. The suite must go RED because a test assertion failed (a
`FAIL` line), not because the mutated code no longer parses. A mutation whose
search text is missing or ambiguous aborts the run: a neuter that silently
changes nothing would look like a pass.

    python3 scripts/neuter.py            # all mutations
    python3 scripts/neuter.py url-       # those whose id starts with "url-"
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUAU = os.environ.get("LUAU", "luau")

# (id, file, text to find exactly once, replacement)
MUTATIONS = [
    # --- url ---------------------------------------------------------------
    ("url-userinfo", "lib/url.luau",
     "if p.userinfo ~= nil or p.port == nil or not check.loopback_host(p.host) then",
     "if p.port == nil or not check.loopback_host(p.host) then"),
    ("url-last-at", "lib/url.luau",
     "for i = #authority, 1, -1 do", "for i = 1, #authority do"),
    ("url-port-required", "lib/url.luau",
     "p.userinfo ~= nil or p.port == nil or", "p.userinfo ~= nil or"),
    ("url-single-redirect", "lib/url.luau", "if #values ~= 1 then", "if #values < 1 then"),
    ("url-oauth-no-ipv6", "lib/url.luau",
     'if target == nil or target.host == "[::1]" then', "if target == nil then"),
    ("url-decode-once", "lib/url.luau",
     'string.char(tonumber(hex, 16) or 0)', 'string.char(tonumber(hex, 16) or 0) .. "x"'),
    ("url-file-abs", "lib/url.luau",
     "if not check.abs_path(decoded) then", "if false then"),
    ("url-scheme-file", "lib/url.luau",
     'if p == nil or p.scheme ~= "file" then', "if p == nil then"),
    ("url-query-amp", "lib/url.luau",
     'string.gmatch(query, "[^&]+")', 'string.gmatch(query, "[^&;]+")'),
    ("url-encode-path", "lib/url.luau",
     '"[^%w/%._~%-]"', '"[^%w/%._~%- ]"'),
    # --- check -------------------------------------------------------------
    ("check-port-high", "lib/check.luau", "n > 65535", "n > 65536"),
    ("check-port-low", "lib/check.luau", "n < 1 or", "n < 0 or"),
    ("check-port-int", "lib/check.luau",
     "n ~= math.floor(n) or ", ""),
    ("check-path-controls", "lib/check.luau", 'and not string.find(value, "%c")', ""),
    ("check-target-dash", "lib/check.luau", 'local LABEL = "[%w_][%w_.-]*"', 'local LABEL = "[%w_-][%w_.-]*"'),
    ("check-loopback-any", "lib/check.luau",
     'local LOOPBACK = { ["localhost"] = true, ["127.0.0.1"] = true, ["[::1]"] = true }',
     'local LOOPBACK = { ["localhost"] = true, ["127.0.0.1"] = true, ["[::1]"] = true, ["0.0.0.0"] = true }'),
    # --- hosts / target ------------------------------------------------------
    ("hosts-state", "lib/hosts.luau",
     'and host.state == "connected"', ""),
    ("hosts-kind", "lib/hosts.luau",
     'host ~= nil and host.kind == "remote" and', "host ~= nil and"),
    ("hosts-fallback", "lib/hosts.luau",
     "\treturn nil\nend\n\n-- The one host named",
     "\treturn list[1]\nend\n\n-- The one host named"),
    ("target-iroh", "lib/target.luau", "if #host >= 40 and string.match(host, \"^%x+$\") then", "if false then"),
    ("target-at", "lib/target.luau",
     'or not string.find(address, "@", 1, true) then', "then"),
    ("target-order", "lib/target.luau",
     "\tlocal from_address = target.from_address(host.address)\n\tif from_address ~= nil then\n\t\treturn from_address\n\tend\n",
     "\tif cfg.hosts[host.name] ~= nil then\n\t\treturn cfg.hosts[host.name]\n\tend\n\tlocal from_address = target.from_address(host.address)\n\tif from_address ~= nil then\n\t\treturn from_address\n\tend\n"),
    # --- config ------------------------------------------------------------
    ("config-widen", "lib/config.luau", "\t\t\t\tports = {}\n", ""),
    ("config-host-valid", "lib/config.luau",
     'if type(key) == "string" and check.target(value) then',
     'if type(key) == "string" then'),
    # --- argv --------------------------------------------------------------
    ("argv-scp-sftp", "lib/argv.luau", 'local out = { argv.SCP, "-q", "-s" }', 'local out = { argv.SCP, "-q" }'),
    ("argv-scp-dashdash", "lib/argv.luau", '"ConnectTimeout=10", "--", target', '"ConnectTimeout=10", target'),
    ("argv-batchmode", "lib/argv.luau",
     '{ "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes" }',
     '{ "-o", "StrictHostKeyChecking=yes" }'),
    ("argv-hostkey", "lib/argv.luau",
     '{ "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes" }',
     '{ "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no" }'),
    ("argv-bind-all", "lib/argv.luau", '"127.0.0.1:%d:%s:%d"', '"0.0.0.0:%d:%s:%d"'),
    ("argv-exitonfail", "lib/argv.luau", '"ExitOnForwardFailure=yes",', '"ExitOnForwardFailure=no",'),
    ("argv-ttl-sleep", "lib/argv.luau",
     '\t\ttable.insert(out, "sleep")\n', '\t\ttable.insert(out, "echo")\n'),
    ("argv-no-N", "lib/argv.luau",
     "\tif f.ttl == nil then\n\t\ttable.insert(out, \"-N\")\n\tend\n", ""),
    ("argv-remote-host", "lib/argv.luau",
     "if not check.loopback_host(f.remote_host) then", "if false then"),
    ("argv-port-check", "lib/argv.luau",
     "\tlocal port = check.port(f.port)\n\tif port == nil then\n\t\terror(\"invalid port\")\n\tend\n\tif not check.loopback_host",
     "\tlocal port = f.port\n\tif not check.loopback_host"),
    ("argv-target-check", "lib/argv.luau",
     "\tif not check.target(target) then\n\t\terror(\"invalid ssh target\")\n\tend\n", ""),
    ("argv-exit-op", "lib/argv.luau",
     'return ssh_control("exit", socket, target)', 'return ssh_control("check", socket, target)'),
    # --- classify ----------------------------------------------------------
    ("classify-alt", "lib/classify.luau", "or link.mods.alt == true then", "then"),
    ("classify-eligible", "lib/classify.luau", "if host == nil or not hostlib.eligible(host) then",
     "if host == nil then"),
    ("classify-ext", "lib/classify.luau",
     "if file_path ~= nil and serve.CONTENT_TYPES[extension(file_path)] then",
     "if file_path ~= nil then"),
    ("classify-ext-case", "lib/classify.luau",
     'return string.lower(string.match(name, "%.([%w]+)$") or "")',
     'return string.match(name, "%.([%w]+)$") or ""'),
    ("classify-allowed", "lib/classify.luau",
     'if kind == "local" and cfg.allowed_ports ~= nil and not listed(cfg.allowed_ports, port) then',
     "if false then"),
    ("classify-ttl", "lib/classify.luau",
     'ttl = if kind == "oauth" then classify.OAUTH_TTL else nil,', "ttl = nil,"),
    ("classify-ipv6-open", "lib/classify.luau",
     'if parsed.host ~= "[::1]" then', "if true then"),
    ("classify-no-target-first", "lib/classify.luau",
     "\tlocal host_name = text.clean(host.name, 60)\n\tlocal target = targetlib.choose(host, cfg)\n\tif target == nil then\n\t\treturn { kind = \"no_target\", host_name = host_name }\n\tend\n",
     "\tlocal host_name = text.clean(host.name, 60)\n\tlocal target = targetlib.choose(host, cfg) or \"you@devbox\"\n"),
    # --- forward -----------------------------------------------------------
    ("forward-reuse-host", "lib/forward.luau",
     "if entry.target ~= req.target or entry.remote_host ~= req.remote_host then", "if false then"),
    ("forward-probe", "lib/forward.luau",
     "\t\t\tif res.status ~= 0 then\n\t\t\t\tstart(cx3)\n",
     "\t\t\tif true then\n\t\t\t\tstart(cx3)\n"),
    ("forward-in-use-flag", "lib/forward.luau",
     'string.find(res.stderr, "Address already in use", 1, true)', "false"),
    ("forward-timed-replace", "lib/forward.luau", "if entry.expires == nil then", "if true then"),
    ("forward-dead-forget", "lib/forward.luau",
     "\t\t\tguard(function()\n\t\t\t\tregistry.save(env.kv, registry.without(registry.load(env.kv), port))\n\t\t\tend)\n\t\t\treap_then_start(cx2)",
     "\t\t\treap_then_start(cx2)"),
    ("forward-orphan", "lib/forward.luau",
     "\t\tif not env.exists(sock) then\n\t\t\tawait_free(0, cx2)", "\t\tif true then\n\t\t\tawait_free(0, cx2)"),
    ("forward-stop-pattern", "lib/forward.luau",
     'string.match(name, "^(%d+)%.sock$")', 'string.match(name, "^(.+)%.sock$")'),
    ("forward-stop-orphans", "lib/forward.luau",
     "if digits ~= nil and not seen[socket] then", "if false then"),
    ("forward-stop-clear", "lib/forward.luau",
     "\t\t\tguard(function()\n\t\t\t\tregistry.save(env.kv, {})\n\t\t\tend)\n", ""),
    ("forward-serialise", "lib/forward.luau",
     "\tif waiting ~= nil then\n\t\ttable.insert(waiting, done)\n\t\treturn\n\tend\n", ""),
    ("forward-socket-budget", "lib/forward.luau", "if #sock > SOCKET_BUDGET then", "if false then"),
    ("forward-retries", "lib/forward.luau", "local PROBE_RETRIES = 10", "local PROBE_RETRIES = 0"),
    ("forward-refresh-prune", "lib/forward.luau",
     "\t\t\tif #dead > 0 then\n", "\t\t\tif false then\n"),
    # --- registry / text ------------------------------------------------------
    ("registry-validate", "lib/registry.luau", "\t\tif valid(item) then\n", "\t\tif true then\n"),
    ("text-hash", "lib/text.luau", "h * 403", "h * 404"),
    ("text-clean", "lib/text.luau", 'string.gsub(s, "%c", " ")', "s"),
    ("text-safe-name", "lib/text.luau", '"[^%w._-]"', '"[^%w._/-]"'),
    ("text-safe-dot", "lib/text.luau", '\tcleaned = string.gsub(cleaned, "^%.+", "_")\n', ""),
    # --- app ---------------------------------------------------------------
    ("app-opens-served-url", "lib/app.luau",
            "\t\t\tlocal opened, err = pcall(function()\n\t\t\t\tcx2:open(page)\n\t\t\tend)",
            "\t\t\tlocal opened, err = pcall(function()\n\t\t\t\tcx2:open(copy)\n\t\t\tend)"),
    ("app-file-handled", "lib/app.luau",
     '\t\tstart_file(ctx, plan, cx)\n\t\treturn { handled = true }', '\t\tstart_file(ctx, plan, cx)\n\t\treturn nil'),
    ("app-no-target-toast", "lib/app.luau",
     '\t\t\t"No SSH target for " .. (plan.host_name or "this host"),', '\t\t\t"",'),
    ("app-refuse-handled", "lib/app.luau",
     '\t\ttoast(cx, "error", plan.title or "Refused", plan.detail)\n\t\treturn { handled = true }',
     '\t\ttoast(cx, "error", plan.title or "Refused", plan.detail)\n\t\treturn nil'),
    ("app-oauth-probe", "lib/app.luau", '\t\tif plan.kind == "oauth" then\n', '\t\tif false then\n'),
    ("app-script-path", "lib/app.luau", 'ctx.t.plugin.dir .. "/serve.pl"', 'ctx.t.plugin.dir .. "/lib/serve.pl"'),
    ("serve-token-length", "lib/serve.luau", "if #token ~= 32 then", "if #token < 1 then"),
    ("serve-retry", "lib/serve.luau", "if state.status == 66 and n < MAX_ATTEMPTS then", "if false then"),
    ("serve-poll-limit", "lib/serve.luau", "elseif i >= POLL_MAX then", "elseif false then"),
    ("serve-idle-timeout", "lib/serve.luau", "(serve.IDLE + 60) * 1000", "(serve.IDLE - 599) * 1000"),
    ("serve-content-type", "lib/serve.luau", 'png = "image/png",', 'png = "image/jpeg",'),
    ("argv-serve-token", "lib/argv.luau", '#s.token ~= 32 or string.find(s.token, "[^0-9a-f]")', "false"),
    ("argv-serve-type", "lib/argv.luau", "if not argv.CONTENT_TYPES[s.content_type] then", "if false then"),
    ("forward-ready-check", "lib/forward.luau", "\t\t\t\tif res.status == 0 then\n\t\t\t\t\tlocal entry: registry.Entry = {",
     "\t\t\t\tif true then\n\t\t\t\t\tlocal entry: registry.Entry = {"),
    ("forward-ready-giveup", "lib/forward.luau", "elseif i >= READY_POLLS then", "elseif false then"),
    ("forward-early-failure", "lib/forward.luau", "\t\t\tif res.status == 0 then\n\t\t\t\t-- ssh went to the background after setting up; readiness is",
     "\t\t\tif true then\n\t\t\t\t-- ssh went to the background after setting up; readiness is"),
    ("forward-lifetime", "lib/forward.luau", "math.max(25000, lifetime_ms)", "25000"),
    ("forward-late-prune", "lib/forward.luau", "\t\t\t\t\t\tif check.status ~= 0 then\n", "\t\t\t\t\t\tif false then\n"),
    ("app-scp-timeout", "lib/app.luau", "local FETCH_TIMEOUT_MS = 120000", "local FETCH_TIMEOUT_MS = 0"),
    ("app-config-reread", "lib/app.luau",
     "\tlocal cfg = app.load_config(ctx.t)\n\treturn act(ctx, cfg, classify.plan(",
     "\tctx.cfg = ctx.cfg or app.load_config(ctx.t)\n\tlocal cfg = ctx.cfg\n\treturn act(ctx, cfg, classify.plan("),
    ("app-ready-poll", "lib/app.luau", "if res.status == 0 then\n\t\t\tready(cx2)", "if true then\n\t\t\tready(cx2)"),
    ("app-load-refresh", "lib/app.luau", "\tforward.refresh(ctx.env, nil, function() end)\n", ""),
    ("app-stop-clears", "lib/app.luau", '"No forwards to stop"', '"Stopped"'),
    # --- the image viewer and the open route ------------------------------------
    ("viewer-ext", "lib/serve.luau",
     "local viewer = serve.VIEWER[req.ext] == true and req.downloads ~= nil",
     "local viewer = req.downloads ~= nil"),
    ("viewer-home", "lib/app.luau",
     "if serve.VIEWER[ext] and home ~= nil and check.abs_path(home) then",
     "if serve.VIEWER[ext] and home ~= nil then"),
    ("viewer-downloads", "lib/app.luau", 'request.downloads = home .. "/Downloads"', 'request.downloads = home'),
    ("argv-viewer-type", "lib/argv.luau", "if not argv.VIEWER_TYPES[s.content_type] then", "if false then"),
    ("argv-copier-ctrl", "lib/argv.luau", 'if a == "" or string.find(a, "%c") then', 'if a == "" then'),
    ("argv-copier-binary", "lib/argv.luau", 'need_path(copier[1], "copier")', ""),
    ("open-origin", "lib/classify.luau", 'if req.origin ~= "link" or', "if false or"),
    ("open-ext", "lib/classify.luau", 'or not serve.VIEWER[extension(req.path)] or', "or"),
    ("open-eligible", "lib/classify.luau", "if not host or not hostlib.eligible(host) then", "if not host then"),
    ("hosts-named-ambiguous", "lib/hosts.luau", "if found ~= nil then\n\t\t\t\treturn nil", "if false then\n\t\t\t\treturn nil"),
    ("app-open-route", "lib/app.luau", "return on_open(ctx, req, cx)", "return nil"),
    # --- render in browser ----------------------------------------------------
    ("render-ext", "lib/classify.luau",
     "classify.RENDER = { html = true, htm = true }",
     "classify.RENDER = { html = true, htm = true, md = true, svg = true }"),
    ("render-kind", "lib/classify.luau", '\t\tand info.kind == "file"\n', ""),
    ("render-abs", "lib/classify.luau", "if not check.abs_path(path) then", "if false then"),
    ("render-membership", "lib/classify.luau",
     "\tlocal host = hostlib.host_for_pane(host_list, info.pane)\n",
     "\tlocal host = hostlib.host_for_pane(host_list, info.pane) or host_list[1]\n"),
    ("render-local", "lib/classify.luau", 'if host.kind == "local" then', "if false then"),
    ("render-eligible", "lib/classify.luau", "if not hostlib.eligible(host) then", "if false then"),
    ("app-render-show", "lib/app.luau",
     'open_copy(ctx, cx, plan.path or "", plan.name or "file", plan.ext or "")\n', ""),
    ("app-render-available", "lib/app.luau",
     "return pane ~= nil and classify.renderable(cx.session:pane(pane))", "return true"),
    ("app-render-focused", "lib/app.luau",
     "local info = if pane ~= nil then cx.session:pane(pane) else nil", "local info = nil"),
]


def run_suite(root):
    proc = subprocess.run(
        [LUAU, os.path.join(root, "tests", "run.luau")],
        capture_output=True, text=True, errors="replace", cwd=root,
    )
    out = proc.stdout + proc.stderr
    return proc.returncode, out


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else ""
    rc, out = run_suite(ROOT)
    if rc != 0:
        print("baseline is RED; fix the suite before neutering\n" + out)
        return 2
    print("baseline GREEN")

    tmp = tempfile.mkdtemp(prefix="neuter-")
    bad = []
    ran = 0
    try:
        for ident, rel, old, new in MUTATIONS:
            if not ident.startswith(prefix):
                continue
            work = os.path.join(tmp, ident)
            shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "node_modules"))
            path = os.path.join(work, rel)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            count = text.count(old)
            if count != 1:
                # A neuter that changes nothing (or the wrong place) would look like a pass.
                print(f"STALE    {ident}: the search text occurs {count} times in {rel}, not once")
                bad.append(ident)
                shutil.rmtree(work)
                continue
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text.replace(old, new))
            code, out = run_suite(work)
            ran += 1
            fails = [line for line in out.splitlines() if line.startswith("FAIL ")]
            if code == 0:
                print(f"SURVIVED {ident}: the suite stayed GREEN")
                bad.append(ident)
            elif not fails:
                print(f"CRASHED  {ident}: RED without a failing assertion\n{out[:400]}")
                bad.append(ident)
            else:
                print(f"RED      {ident}: {len(fails)} failing test(s); first: {fails[0][5:80]}")
            shutil.rmtree(work)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n{ran} mutation(s), {ran - len(bad)} caught, {len(bad)} not caught")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
