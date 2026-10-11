# Changelog

## 0.2.0

- Image viewer: an image (`png jpg jpeg gif webp`) from a remote pane opens in a small page
  with **Copy image** (the macOS clipboard, as PNG and TIFF) and **Save to Downloads**
  (`~/Downloads`, never overwriting a file) buttons. Click the image for actual size.
  `serve.pl` carries out both on the Mac (`copy-image.js` through `osascript`), only for a
  `POST` carrying `X-Remote-Open: 1` from its own origin.
- An image path printed in a remote pane (no `file://`) opens in the same viewer, through a
  `tern.route.open` handler that takes only clicks (origin `link`) on a connected remote host.
- SVG, PDF and HTML are served as before, without the viewer.

## 0.1.0

First release.

- Remote files: ⌘-click a `file://` link to an `html htm svg pdf png jpg jpeg gif webp`
  file in a pane of a connected remote host. The file is copied with `scp` and shown in
  Tern's browser block through a short-lived loopback server (`serve.pl`).
- Localhost links: `http(s)://localhost|127.0.0.1|[::1]:PORT` links in a remote pane
  start an `ssh -L` forward and open in Tern's browser block.
- OAuth loopback sign-ins: a link whose `redirect_uri` is a loopback URL starts a forward
  for the callback port that closes by itself after ten minutes.
- Palette commands: **Remote Open: List forwards**, **Remote Open: Stop forwards**.
- `config.json`: `hosts` (ssh target per Tern host), `allowed_ports`, `control_dir`.
