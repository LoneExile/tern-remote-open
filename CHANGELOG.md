# Changelog

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
