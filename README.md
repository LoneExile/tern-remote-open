# Remote Open

A [Tern](https://stencil.so) plugin that makes links in **remote** panes work on your Mac.

When a program on a remote host prints `file:///home/you/report.html`, `http://localhost:8765`,
or an OAuth sign-in URL whose callback is `http://localhost:8250/…`, Tern opens it on the Mac,
where the file does not exist and nothing listens on that port. Remote Open fixes the three cases
over plain `ssh`:

| You click | It does |
| --- | --- |
| `file://…` to `html htm svg pdf png jpg jpeg gif webp` | Copies the file with `scp` and shows it in Tern's browser block. |
| `http(s)://localhost\|127.0.0.1\|[::1]:PORT/…` | Starts an `ssh -L` forward of PORT, waits for it, opens the link in Tern's browser block. |
| An `http(s)` URL with `redirect_uri=http://localhost:PORT/…` (OAuth/OIDC loopback sign-in) | Starts a forward of PORT that **closes by itself after 10 minutes**, then opens the sign-in page as clicked. |

It acts only when the click came from a pane of a **connected remote host** and **⌥ is not held**.
Everything else (local panes, other links, other file types, a disconnected host) is left to Tern.
Hold ⌥ to get Tern's normal handling of any link.

Palette commands: **Remote Open: List forwards**, **Remote Open: Stop forwards**.

It is a window-only plugin: nothing is installed on the remote host.

## Install

```sh
git clone https://github.com/LoneExile/tern-remote-open
tern plugin link ./tern-remote-open        # live: edits reload; or `tern plugin install ./tern-remote-open`
tern plugin list                           # remote-open … ready
```

Home Manager (macOS), linking a checkout so the plugin follows the repository:

```nix
{ config, ... }: {
  home.file."Library/Application Support/Tern/plugins/remote-open.path".text =
    "${config.home.homeDirectory}/src/tern-remote-open";
}
```

(Tern accepts a folder, a symlink to one, or a `<name>.path` file holding the directory.)

### SSH

Remote Open runs `/usr/bin/ssh` and `/usr/bin/scp` with `BatchMode=yes` and
`StrictHostKeyChecking=yes`. So:

- your key must already be usable without a prompt (an agent, or Keychain via `AddKeysToAgent` /
  `UseKeychain`);
- the host key must already be in `known_hosts`: connect once with `ssh you@devbox` first. An unknown
  or changed key is a failure, never a question.

The ssh destination is the Tern host's `address` when it is a plain `user@host`. Otherwise (a Tern
port, an iroh endpoint id, a host reached through a proxy) map it in `config.json`; with no usable
target the plugin shows "No SSH target for <host>" and leaves the link to Tern.

## Config

Optional `config.json` in the plugin's data directory
(`~/Library/Application Support/Tern/plugin-data/remote-open/config.json`). It is re-read on every
click, so edits need no reload.

```json
{
  "hosts": { "devbox": "you@devbox.lan" },
  "allowed_ports": [3000, 5173, 8765],
  "control_dir": "/Users/you/.cache/remote-open"
}
```

- `hosts`: ssh destination by Tern host name or address (`user@host` or an alias from `~/.ssh/config`).
- `allowed_ports`: when set, plain localhost links (not OAuth callbacks, not files) are forwarded only
  for these ports. An invalid entry makes the list refuse every port; it never widens access.
- `control_dir`: where the ssh control sockets live. Default: `cm/` in the data directory. macOS limits
  a socket path to about 100 bytes; if your data directory path is too long the plugin says so and
  this is the way out.

## How it works

- **Handler.** One `tern.route.link` handler. It only classifies the link and starts work; every
  slow step (scp, ssh, port probes) runs in a process callback, so the handler stays far under Tern's
  50 ms budget.
- **Forwards.** `ssh -f -T -M -S <control dir>/<port>.sock -L 127.0.0.1:PORT:<localhost>:PORT …`.
  The ssh process is also a ControlMaster on that socket. The socket is how the plugin later asks
  "is it alive?" (`-O check`) and ends exactly that process (`-O exit`). No process is ever matched by
  name or killed by pid, so **Stop forwards can only stop forwards this plugin started** (it also ends
  any leftover socket in its own control directory, for a forward whose record was lost). Forwards
  survive Tern reloads and quitting; they are recorded in the plugin's `tern.kv`, checked against
  their processes at load, and dead records are dropped.
- **Same port.** The local port is the remote port. If something else listens on it the plugin
  refuses with a toast naming the port. Our own live forward to the same host and port is reused.
- **OAuth forwards** run `sleep 600` as the remote command instead of `-N`, so ssh ends when that
  ends. Connections still open at that moment finish cleanly: measured with a stream that spans the
  expiry (all bytes delivered, clean EOF, then the listener closed). A new sign-in replaces the timer.
  Nothing connects through such a forward before the sign-in page opens (a one-shot callback server
  must not mistake a probe for the callback).
- **Files.** `scp -s` (SFTP, so the remote path is data) into `cache/` in the data directory, named
  `<hash>-<cleaned basename>`; copies older than 7 days are deleted at load.

### How the page opens in Tern (measured, Tern 0.7.0 and 0.7.1)

| Tried | Result |
| --- | --- |
| `cx:open("file:///…")` | Tern's **source-code file block**, not a rendered page. |
| `cx.browser:call{op = "open", url = "file:///…"}` | Renders the file, but only over a pane of a **local** host; for a pane of a remote host: `no block … in this window's tabs`. |
| `cx:open("data:…")` | Handed to the system: "no application could open data:". |
| `cx:open("http://127.0.0.1:PORT/…")` beside a pane of a remote host | **Tern's browser block, rendered page, JavaScript runs.** |

So a fetched file is served for a few minutes by `serve.pl` (core Perl, `/usr/bin/perl`) on
`127.0.0.1`, one file, one random port, one unguessable path, and opened with `cx:open`. If that cannot
start (no Perl, no free port) the file opens in the macOS default browser with `/usr/bin/open`, and
the toast says so. `serve.pl` answers only `GET`/`HEAD` for that one path, only for a `127.0.0.1` or
`localhost` `Host` header with its own port, sets `nosniff`/`no-store`, serves one connection at a time with a
20 s limit, and exits after 10 minutes without a connection. A page is a single file: relative
references to other files on the remote host do not resolve.

## Security notes

- A Tern plugin runs as you with no permission system. This one is small enough to read: `lib/`.
- argv only, never a shell string; absolute binary paths (`/usr/bin/ssh`, `scp`, `nc`, `open`, `perl`,
  `uuidgen`, `find`); every port is validated (digits, 1–65535), every path must be absolute with no
  control characters, ssh targets may not start with `-`, and each value stays one argv element after `--`.
- Links and remote file names are untrusted text. The remote host is not trusted to name a local file:
  the cache name is a hash plus a character-restricted basename.
- Forwards bind `127.0.0.1` only. Be aware that any process of any user on your Mac can connect to a
  loopback port, so a forward exposes the remote service on that port to local processes for as long
  as it runs. That is why OAuth forwards expire and why `allowed_ports` exists. The control sockets are
  mode 600.
- The plugin acts only on a click you made, and only for a connected remote host. It never types into
  a pane (`cx:run` is not used) and logs no secrets (URLs, which may carry OAuth state, are not logged).

## Limitations

- macOS only (`/usr/bin/open`, `nc`, `uuidgen`, the BSD `find`). Remote host: anything with an SSH server.
- ⌘-click in Tern follows `link_target`; set it to `"Tern"` to get the browser block. With `"Browser"`,
  the page opens in your default browser (a loopback URL there still works).
- OAuth URLs that your terminal soft-wraps over several rows may reach Tern cut; that is a link
  detection matter outside this plugin (not tested here).
- A web page is one file (see above). PDFs load in the browser block; the test suite checks that they
  load without error, not how they look.
- Tern runs plugin code from the window, so the plugin must be installed on each Mac you attach from.
- **Stop forwards** ends the local ssh. The remote `sleep` of a timed (OAuth) forward is not signalled
  (no tty) and lingers on the remote host until its ten minutes are up; it holds nothing.
- Not exercised against a real `bao login`; the OAuth path was run live only against a stand-in
  callback server and a throwaway sign-in URL.

## Development

```sh
nix shell nixpkgs#luau nixpkgs#luau-lsp     # or the release binaries (see .github/workflows/ci.yml)
just types      # tern.d.luau from your Tern (or the published SDK)
just check      # luau-lsp analyze, strict
just test       # 160 unit tests with a stubbed `tern`, plus 39 checks of serve.pl
just neuter     # breaks the code 85 + 8 ways, one at a time; every one must turn the tests red
```

Layout: `window.luau` is thin glue; `lib/` holds pure helpers (`url`, `check`, `hosts`, `target`,
`config`, `classify`, `argv`, `registry`, `text`), the forward and serve state machines (`forward`,
`serve`, which take their effects through an `Env`) and `app` (the only module that touches `tern`).

## License

MIT
