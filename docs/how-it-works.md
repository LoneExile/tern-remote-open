# How Remote Open works

The technical side of the plugin: how it decides what to do, what it runs, how the page gets into
Tern, why it is safe, and what has been measured. For using it, see the [README](../README.md); for
building and testing it, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Contents

- [What it reacts to](#what-it-reacts-to)
- [Handlers and the command](#handlers-and-the-command)
- [SSH](#ssh)
- [Forwards](#forwards)
- [Files](#files)
- [How the page opens in Tern](#how-the-page-opens-in-tern)
- [The image viewer](#the-image-viewer)
- [Security](#security)
- [What has been verified](#what-has-been-verified)

## What it reacts to

It acts only when the click came from a pane of a **connected remote host** and, for links, **⌥ is
not held**. Everything else (local panes, other links, other file types, a disconnected host) is
left to Tern. A plain path carries no modifiers, so an image path is always shown in the viewer.
SVG, PDF and HTML open as they are, without the viewer.

## Handlers and the command

- **Handlers.** One `tern.route.link` handler and one `tern.route.open` handler. The open handler
  takes only a click (origin `link`) on an image path of a connected remote host; it never sees the
  palette, the Files pane, drops, `tern open` or the system. Both only classify and start work;
  every slow step (scp, ssh, port probes) runs in a process callback, so a handler stays far under
  Tern's 50 ms budget.
- **Render in browser** is a command (`plugin.remote-open.render`), not a route: a file block opened
  from the Files pane stays a file block, and the page opens only when you ask. The file's machine
  is the host whose pane list holds the focused block; no host is a fallback. A remote file takes
  the same path as a clicked `file://` link (copy, then serve); a file on the Mac is served where
  it is, with no copy. The command's `available` check (focused pane is a `file` block whose path
  ends in `.html` or `.htm`) is what hides it from the palette elsewhere.
- **Layout.** `window.luau` is thin glue. `lib/` holds pure helpers (`url`, `check`, `hosts`,
  `target`, `config`, `classify`, `argv`, `registry`, `text`), the forward and serve state machines
  (`forward`, `serve`, which take their effects through an `Env`) and `app`, the only module that
  touches `tern`.

## SSH

Remote Open runs `/usr/bin/ssh` and `/usr/bin/scp` with `BatchMode=yes` and
`StrictHostKeyChecking=yes`, so a key that needs a passphrase, an unknown host key or a changed one
is a failure, never a prompt.

The ssh destination is the Tern host's `address` when it is a plain `user@host`. A Tern port, an
iroh endpoint id (a long run of hex digits) or anything else is not used; the `hosts` map in
`config.json` is looked up by address, then by name, then by name ignoring case. With no usable
target the plugin shows "No SSH target for <host>" and leaves the link to Tern.

## Forwards

- **Process.** `ssh -f -T -M -S <control dir>/<port>.sock -L 127.0.0.1:PORT:<localhost>:PORT …`.
  The ssh process is also a ControlMaster on that socket. The socket is how the plugin later asks
  "is it alive?" (`-O check`) and ends exactly that process (`-O exit`). No process is ever matched
  by name or killed by pid, so **Stop forwards can only stop forwards this plugin started** (it also
  ends any leftover socket in its own control directory, for a forward whose record was lost).
  Forwards survive Tern reloads and quitting; they are recorded in the plugin's `tern.kv`, checked
  against their processes at load, and dead records are dropped.
- **Same port.** The local port is the remote port. If something else listens on it the plugin
  refuses with a toast naming the port. Our own live forward to the same host and port is reused.
- **OAuth forwards** run `sleep 600` as the remote command instead of `-N`, so ssh ends when that
  ends. Connections still open at that moment finish cleanly: measured with a stream that spans
  the expiry (all bytes delivered, clean EOF, then the listener closed). A new sign-in replaces the
  timer. Nothing connects through such a forward before the sign-in page opens (a one-shot callback
  server must not mistake a probe for the callback).
- **Stop forwards** ends the local ssh. The remote `sleep` of a timed (OAuth) forward is not
  signalled (no tty) and lingers on the remote host until its ten minutes are up; it holds nothing.
- **Control sockets** live in `control_dir` (default `cm/` in the data directory), mode 600. macOS
  caps a socket path at about 100 bytes, so a long data directory path is refused with "Data
  directory path is too long for ssh".

## Files

`scp -s` (SFTP, so the remote path is data) into `cache/` in the data directory, named
`<hash>-<cleaned basename>`; copies older than 7 days are deleted at load.

## How the page opens in Tern

Measured on Tern 0.7.0 and 0.7.1:

| Tried | Result |
| --- | --- |
| `cx:open("file:///…")` | Tern's **source-code file block**, not a rendered page. |
| `cx.browser:call{op = "open", url = "file:///…"}` | Renders the file, but only over a pane of a **local** host; for a pane of a remote host: `no block … in this window's tabs`. |
| `cx:open("data:…")` | Handed to the system: "no application could open data:". |
| `cx:open("http://127.0.0.1:PORT/…")` beside a pane of a remote host | **Tern's browser block, rendered page, JavaScript runs.** |

So a file is served for a few minutes by `serve.pl` (core Perl, `/usr/bin/perl`) on `127.0.0.1`:
one file, one random port, one unguessable path, opened with `cx:open`. If that cannot start (no
Perl, no free port) the file opens in the macOS default browser with `/usr/bin/open`, and the toast
says so. `serve.pl` answers only `GET`/`HEAD` for that one path, only for a `127.0.0.1` or
`localhost` `Host` header with its own port, sets `nosniff`/`no-store`, serves one connection at a
time with a 20 s limit, and exits after 10 minutes without a connection. A page is a single file:
relative references to other files on the remote host do not resolve.

## The image viewer

For an image, `serve.pl` serves a viewer page at that path instead, the image itself at
`/TOKEN/raw/NAME`, and two actions, `POST /TOKEN/copy` and `POST /TOKEN/save`, which it carries out
on the Mac:

- **Copy** runs `osascript -l JavaScript copy-image.js FILE` (AppKit's pasteboard; a page cannot put
  an image on the clipboard itself).
- **Save** copies the file into `~/Downloads` with `O_EXCL`, so it never overwrites a file.

Measured in Tern 0.7.2's browser block: the page loads, both buttons work, and a JPEG lands on the
clipboard as PNG and TIFF. The buttons work while `serve.pl` runs; after its 10 idle minutes a
button says so, and clicking the link again starts a new one. Without a usable `HOME` (so no
`~/Downloads`) the image is served bare, without the viewer.

## Security

- A Tern plugin runs as you with no permission system. This one is small enough to read: `lib/`.
- argv only, never a shell string; absolute binary paths (`/usr/bin/ssh`, `scp`, `nc`, `open`,
  `perl`, `uuidgen`, `find`, `osascript`); every port is validated (digits, 1–65535), every path
  must be absolute with no control characters, ssh targets may not start with `-`, and each value
  stays one argv element after `--`.
- Links and remote file names are untrusted text. The remote host is not trusted to name a local
  file: the cache name is a hash plus a character-restricted basename.
- Forwards bind `127.0.0.1` only. Any process of any user on your Mac can connect to a loopback
  port, so a forward exposes the remote service on that port to local processes for as long as it
  runs. That is why OAuth forwards expire and why `allowed_ports` exists. The control sockets are
  mode 600.
- The viewer's two actions answer only a `POST` carrying `X-Remote-Open: 1`, a header that a page
  of another origin cannot send without a CORS preflight, which `serve.pl` never answers; an
  `Origin`, when sent, must be the server's own. They act on the one file the server was started
  for, and Save never overwrites a file. The page is static apart from the file name, which is
  `[A-Za-z0-9._-]`, under a `Content-Security-Policy` that allows only its own inline code, its own
  image and its own origin.
- The plugin acts only on a click you made or a command you ran, and only for a connected remote
  host (Render in browser also for a file on the Mac). It never types into a pane (`cx:run` is not
  used) and logs no secrets (URLs, which may carry OAuth state, are not logged).

## What has been verified

Beyond the unit tests and the mutation harness (see [CONTRIBUTING.md](../CONTRIBUTING.md)):

- PDFs load in the browser block; the test suite checks that they load without error, not how they
  look.
- Clicking an image that Tern itself draws (an inline image in an agent chat, a file block's
  preview) reaches this plugin only when Tern routes it as a file open of a remote path; not
  exercised.
- OAuth URLs that a terminal soft-wraps over several rows may reach Tern cut; that is a link
  detection matter outside this plugin (not tested here).
- Not exercised against a real `bao login`; the OAuth path was run live only against a stand-in
  callback server and a throwaway sign-in URL.
- **Render in browser** (Tern 0.8.3) was run live on a file on the Mac, from the palette and from a
  key bound in `settings.json`: the browser block showed the rendered page, served from the file in
  place. On a remote file it is covered by the unit tests and reuses the `file://` link path, but
  has not been run live; the one part only a live run can confirm is that Tern lists a remote file
  block under its host's panes (measured for that host's browser blocks). If it does not, the
  command says "Cannot tell which machine holds this file".
