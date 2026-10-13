# Changelog

All notable changes to Remote Open. Versions follow the `version` in `plugin.toml`; each one is a
[GitHub release](https://github.com/LoneExile/tern-remote-open/releases) with a ready-to-install
archive.

## 0.3.0 - 2026-10-13

### Added

- **Render in browser.** Tern shows an `.html` file as source code. The new palette command
  **Remote Open: Render in browser** shows the page of the focused file block (`html`, `htm`) in
  Tern's browser block, and leaves the file block open for editing. A file on a connected remote
  host is copied with `scp` first, the way a clicked `file://` link is; a file on the Mac is shown
  where it is. The palette lists the command only while an HTML file block has focus. It has no
  default key: bind the action `plugin.remote-open.render` in Tern's `settings.json`, for example
  `"keybinds": { "ctrl+a>v": "plugin.remote-open.render" }`.
- **Release archives.** Each GitHub release carries `remote-open-X.Y.Z.tar.gz` (the plugin, its
  README, changelog and license) and a `.sha256` file, so you can install a fixed version.

### Changed

- The README is now a user guide. How the plugin works, its security model and what has been
  measured moved to [docs/how-it-works.md](https://github.com/LoneExile/tern-remote-open/blob/main/docs/how-it-works.md);
  building, testing and releasing moved to [CONTRIBUTING.md](https://github.com/LoneExile/tern-remote-open/blob/main/CONTRIBUTING.md).

## 0.2.0 - 2026-10-11

### Added

- **Image viewer.** An image (`png jpg jpeg gif webp`) from a remote pane opens in a small page with
  two buttons: **Copy image** (onto the macOS clipboard, as PNG and TIFF) and **Save to Downloads**
  (into `~/Downloads`, never overwriting a file). Click the image to switch to actual size.
  `serve.pl` carries out both buttons on the Mac (`copy-image.js` through `osascript`), and only
  for a `POST` carrying `X-Remote-Open: 1` from its own origin.
- An image **path** printed in a remote pane (no `file://`) opens in the same viewer, through a
  `tern.route.open` handler that takes only clicks (origin `link`) on a connected remote host.

### Unchanged

- SVG, PDF and HTML are served as before, without the viewer.

## 0.1.0 - 2026-10-11

First release.

### Added

- **Remote files.** ⌘-click a `file://` link to an `html htm svg pdf png jpg jpeg gif webp` file
  in a pane of a connected remote host. The file is copied with `scp` and shown in Tern's browser
  block through a short-lived loopback server (`serve.pl`).
- **Localhost links.** `http(s)://localhost|127.0.0.1|[::1]:PORT` links in a remote pane start an
  `ssh -L` forward and open in Tern's browser block.
- **OAuth loopback sign-ins.** A link whose `redirect_uri` is a loopback URL starts a forward for
  the callback port that closes by itself after ten minutes.
- Palette commands: **Remote Open: List forwards**, **Remote Open: Stop forwards**.
- `config.json`: `hosts` (the ssh target of a Tern host), `allowed_ports`, `control_dir`.
