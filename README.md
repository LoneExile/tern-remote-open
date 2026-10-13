# Remote Open

A [Tern](https://stencil.so) plugin that makes links in **remote** panes work on your Mac.

When a program on a remote host prints `file:///home/you/report.html`, `http://localhost:8765`,
or an OAuth sign-in URL whose callback is `http://localhost:8250/…`, Tern opens it on the Mac,
where the file does not exist and nothing listens on that port. Remote Open fixes that over plain
`ssh`, and it can show an HTML file you have open in Tern as a page.

| You do | Remote Open |
| --- | --- |
| ⌘-click a `file://` link to an `html htm svg pdf png jpg jpeg gif webp` file | Copies the file with `scp` and shows it in Tern's browser block. |
| ⌘-click an image (`png jpg jpeg gif webp`), as a `file://` link or a plain path | Shows it in a small viewer with **Copy image** and **Save to Downloads** buttons. |
| ⌘-click `http(s)://localhost`, `127.0.0.1` or `[::1]` with a port | Forwards that port over `ssh -L`, waits for it, and opens the link in Tern's browser block. |
| ⌘-click a sign-in URL with `redirect_uri=http://localhost:PORT/…` (OAuth/OIDC) | Forwards the callback port for **10 minutes**, then opens the sign-in page. |
| Run **Render in browser** on an `.html` file open in Tern | Shows the page in Tern's browser block; the file stays open for editing. |

Nothing is installed on the remote host: the plugin runs in Tern on your Mac.

## Contents

- [Install](#install)
- [Before you start](#before-you-start)
- [Use it](#use-it)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Security](#security)
- [Contributing](#contributing)

## Install

Pick one. Each Mac you open Tern on needs its own copy.

**From a release** (a fixed version). Download `remote-open-X.Y.Z.tar.gz` from the
[latest release](https://github.com/LoneExile/tern-remote-open/releases/latest), then:

```sh
tar -xzf remote-open-X.Y.Z.tar.gz
tern plugin install ./remote-open-X.Y.Z
tern plugin list          # remote-open X.Y.Z … ready
```

**From GitHub** (the latest `main`):

```sh
tern plugin install github.com/LoneExile/tern-remote-open
```

**With Home Manager** (macOS), pinned to a release tag:

```nix
{ pkgs, ... }: {
  home.file."Library/Application Support/Tern/plugins/remote-open".source = pkgs.fetchFromGitHub {
    owner = "LoneExile";
    repo = "tern-remote-open";
    rev = "v0.3.0";
    hash = "";   # build once; Nix prints the hash to put here
  };
}
```

To **update**, install again with `--force` (for example
`tern plugin install github.com/LoneExile/tern-remote-open --force`). To **remove** it:
`tern plugin remove remote-open`.

## Before you start

**ssh must work without questions.** Remote Open runs `ssh` and `scp` so that they never prompt:

- Your key must be usable without typing a passphrase: loaded in `ssh-agent`, or in the macOS
  Keychain (`AddKeysToAgent yes` and `UseKeychain yes` in `~/.ssh/config`).
- The remote host's key must already be in `~/.ssh/known_hosts`. Connect once with
  `ssh you@devbox`. An unknown or changed host key is an error, never a question.

Remote Open connects to the Tern host's address when it is a plain `user@host`. For anything else
(a Tern port, an iroh endpoint id, a host behind a proxy), add the host to [Settings](#settings).

**Open links in Tern.** Tern sends ⌘-clicked links where its `link_target` setting says. Set it to
`"Tern"` to get the browser block; with `"Browser"`, pages open in your default browser, which also
works.

## Use it

### Links in a remote pane

⌘-click a link that a program printed in a pane of a **connected remote host**. Remote Open acts
only there; links in local panes and on disconnected hosts stay Tern's. Hold **⌥** while you click
to get Tern's normal handling of any link.

An image path printed without `file://` works too, and always opens in the viewer.

### The image viewer

- **Copy image** puts the image on the clipboard as PNG and TIFF, so ⌘V pastes it into Slack,
  Mail, Notes, Preview and the like. A PNG goes on byte for byte; JPEG, GIF and WebP are converted.
- **Save to Downloads** copies the file into `~/Downloads` under its own name, or as
  `name (2).png`, `name (3).png` … when that name is taken. It never overwrites a file, and the
  status line names the file it wrote.
- Click the image to switch between fit-to-window and actual size.

### Render in browser

Tern shows an `.html` file as source code. To see it as a page, focus the file and run
**Remote Open: Render in browser** from the command palette. The page opens in Tern's browser
block beside the file, which stays open for editing.

- It works for `.html` and `.htm` files, on the Mac and on a connected remote host.
- The palette lists the command only while an HTML file has focus.
- It shows the file as saved on disk: save first to see your edit. Each run opens a new browser
  block.

The command has no key of its own. To press a key instead, add one to `keybinds` in Tern's
`settings.json`, for example:

```json
{ "keybinds": { "ctrl+a>v": "plugin.remote-open.render" } }
```

### Palette commands

- **Remote Open: Render in browser**: see above.
- **Remote Open: List forwards**: the port forwards running now, with the time left on sign-in ones.
- **Remote Open: Stop forwards**: ends every forward Remote Open started (and nothing else).

## Settings

Settings are optional. Put them in
`~/Library/Application Support/Tern/plugin-data/remote-open/config.json`. The file is read again on
every click, so a change needs no reload.

```json
{
  "hosts": { "devbox": "you@devbox.lan" },
  "allowed_ports": [3000, 5173, 8765],
  "control_dir": "/Users/you/.cache/remote-open"
}
```

| Setting | What it does |
| --- | --- |
| `hosts` | The ssh destination for a Tern host, by its name or address: `user@host`, or a `Host` alias from `~/.ssh/config`. |
| `allowed_ports` | When set, plain localhost links are forwarded only for these ports (sign-in callbacks and files are not affected). An invalid entry makes it refuse every port; it never allows more. |
| `control_dir` | Where ssh keeps its control sockets. Default: `cm/` in the plugin's data folder. macOS limits a socket path to about 100 characters; if yours is longer, Remote Open says so, and this setting is the way out. |

## Troubleshooting

### Nothing happens at all

If a ⌘-click shows no Remote Open toast and the palette has no **Remote Open** commands, Tern may
have switched the plugin off while loading it. Tern gives a plugin 50 ms to load, and a very busy
Mac (for example during a Home Manager switch) can go past that. Check Tern's log:

```sh
grep remote-open ~/Library/Logs/Tern/tern.log | tail -3   # "load exceeded 50 ms" means this happened
```

Run **Reload plugins** from the command palette, or restart Tern. `tern plugin list` still says
`ready` in this case: it reports the session daemon, not the window.

### Messages

| Message | What to do |
| --- | --- |
| **No SSH target for devbox** | The host's address is not a plain `user@host`. Add it under `hosts` in [Settings](#settings). Tern then handles the link as usual. |
| **Timed out connecting to devbox**, **Could not fetch …**, **Could not forward port …** | Check that `ssh you@devbox` works with no prompt (see [Before you start](#before-you-start)). |
| **Port 8765 is already in use on this Mac** | Something on the Mac listens on that port. Stop it, or hold ⌥ and click to let Tern open the link. |
| **Port 8765 did not answer** | The forward is up, but nothing on the remote host accepted the connection. Is the server running? |
| **Port 8765 is not allowed** | The port is not in `allowed_ports`. |
| **Opened … in the default browser** | The local preview server could not start (or Tern's browser block refused the page), so the page went to your default browser. |
| **Data directory path is too long for ssh** | Set `control_dir` to a shorter path. |
| **Not an HTML file** | Render in browser needs an `.html` or `.htm` file block in focus. |
| **devbox is not connected** | Render in browser fetches a remote file over ssh; reconnect the host in Tern first. |
| **Cannot tell which machine holds this file** | Tern did not list the file's block under any host. Please [open an issue](https://github.com/LoneExile/tern-remote-open/issues) with your Tern version. |

Anything Remote Open does not handle is left to Tern, so when in doubt, hold ⌥ and click. (An image
path printed without `file://` is the exception: it always opens in the viewer.)

## Limitations

- macOS only. The remote host can be anything with an SSH server.
- A page is one file: images, fonts, scripts or styles it loads from other files on the remote host
  do not appear (this applies to Render in browser too). For such a page, serve its **folder** on the
  remote host and ⌘-click the localhost link, which Remote Open forwards:

  ```sh
  npx http-server ~/site -p 8080        # the folder, not the .html file
  echo http://127.0.0.1:8080/page.html  # ⌘-click this
  ```
- The viewer's buttons work for 10 minutes after the last use; after that they say so, and clicking
  the link again brings them back.
- A sign-in URL that your terminal wraps over several rows may reach Tern cut short.
- **Stop forwards** ends the ssh process on the Mac. On the remote host, a sign-in forward leaves a
  `sleep` that ends by itself within its 10 minutes; it holds nothing.

## Security

A Tern plugin runs as you, with no permission system. Remote Open is small enough to read (`lib/`):
it runs no shell commands, only fixed programs under `/usr/bin`, with every value checked first; it
acts only on clicks and commands you make; forwards listen on `127.0.0.1` only; and it never types
into a pane or logs URLs. Any program on your Mac can reach a forwarded port while it runs, which is
why sign-in forwards expire and why `allowed_ports` exists. The details are in
[docs/how-it-works.md](docs/how-it-works.md#security).

## Contributing

How it works: [docs/how-it-works.md](docs/how-it-works.md). Building, testing and releasing:
[CONTRIBUTING.md](CONTRIBUTING.md). Changes: [CHANGELOG.md](CHANGELOG.md).

## License

MIT
