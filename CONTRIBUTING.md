# Contributing to Remote Open

How to build, test, try and release the plugin. How it works inside is in
[docs/how-it-works.md](docs/how-it-works.md).

## Tools

- [`luau`](https://github.com/luau-lang/luau) and [`luau-lsp`](https://github.com/JohnnyMorganz/luau-lsp):
  `nix shell nixpkgs#luau nixpkgs#luau-lsp`, or the release binaries that
  [CI](.github/workflows/ci.yml) installs (it pins their versions).
- [`just`](https://github.com/casey/just), `perl` (for `serve.pl` and its tests), `python3` (the
  mutation harness).
- Optional: `tern` (to try changes and to generate the type definitions), `gh`.

## Check, test, neuter

```sh
just types      # types/tern.d.luau from your Tern, else the published SDK (gitignored)
just check      # luau-lsp analyze, strict
just test       # the unit tests with a stubbed `tern`, then the serve.pl tests
just neuter     # breaks the code on purpose, one behaviour at a time
```

`just neuter` runs `scripts/neuter.py` and `scripts/neuter_serve.py`. Each mutation replaces one
exact piece of text in a throwaway copy of the repo and runs the suite, which must go **red with a
failing assertion** (a `FAIL` line), not because the mutated code stops parsing. A mutation whose
search text is missing or appears twice aborts the run, so a mutation that changes nothing cannot
pass as caught.

When you add a guard or a behaviour, add a test for it **and** a mutation that removes it, and check
that `just neuter` reports every mutation caught. CI type-checks against the `tern-sdk` commit in
`justfile` (`sdk`) and `ci.yml` (`TERN_SDK_SHA`); an API you use must exist there too.

Code layout is described in [docs/how-it-works.md](docs/how-it-works.md#handlers-and-the-command):
`app.luau` is the only module that touches `tern`; everything it decides comes from pure modules
that the tests drive directly.

## Try a change in Tern

Link your checkout instead of installing a copy, so edits load on `tern plugin reload`:

```sh
tern plugin remove remote-open          # an installed copy and a link with one id clash
tern plugin link ./tern-remote-open
tern plugin list                        # remote-open … ready
```

With Home Manager (macOS), point Tern at the checkout with a `.path` file (Tern accepts a folder, a
symlink to one, or a `<name>.path` file holding the directory):

```nix
{ config, ... }: {
  home.file."Library/Application Support/Tern/plugins/remote-open.path".text =
    "${config.home.homeDirectory}/src/tern-remote-open";
}
```

Do not keep both a linked checkout and an installed copy: two packages with the same id are a
duplicate-id error.

### A throwaway Tern, away from your own sessions

To try the plugin without touching your running Tern, start a second window with its own settings
folder and daemon. Headless `tern serve` does not run window plugins, so it cannot be used for this.

```sh
X=$(mktemp -d)
mkdir -p "$X/cfg" && echo '{"plugins": true}' > "$X/cfg/settings.json"
export TERN_CONFIG_DIR="$X/cfg" TERN_DAEMON_SOCKET="$X/d.sock"
tern plugin link "$PWD"
/Applications/Tern.app/Contents/MacOS/tern --control "$X/w.sock" "$PWD/README.md" & W=$!
sleep 5                                               # until it prints "control on …"
tern ctl --control "$X/w.sock" state                  # what the window shows
tern browser '{"op":"blocks"}'                         # its browser blocks and their URLs
kill "$W"; sleep 2                                    # close the window (ctl quit may stop at a confirm dialog)
pkill -f "tern daemon --socket $X/d.sock"             # and its daemon, which outlives it
```

`tern ctl --control … click SELECTOR`, `type '"text"'` and `key Enter` drive the window (for
example the command palette, `.tb-cmdk`); `tern help dev` lists the rest.

## Pull requests

- One change per pull request, with its tests and mutations; `just check test neuter` green.
- User-facing changes get a line in [CHANGELOG.md](CHANGELOG.md) under the next version, and the
  [README](README.md) says how to use them. Internals go in
  [docs/how-it-works.md](docs/how-it-works.md), including what was measured live and what was not.

## Releasing

A release is a tag `vX.Y.Z`. Pushing it runs [`release.yml`](.github/workflows/release.yml): the
whole CI gate, then a GitHub release whose notes are the version's section of `CHANGELOG.md` plus
install steps, with `remote-open-X.Y.Z.tar.gz` (the plugin files, README, CHANGELOG, LICENSE) and
its `.sha256` attached.

1. Set `version` in `plugin.toml` to `X.Y.Z`.
2. Add `## X.Y.Z - YYYY-MM-DD` to `CHANGELOG.md`, with what a user notices first. Use absolute
   GitHub links: the notes are also shown on the release page, where relative links break.
3. Check what will be published:

   ```sh
   just release-notes X.Y.Z    # the release body; fails if the section is missing
   just package X.Y.Z          # dist/remote-open-X.Y.Z.tar.gz from HEAD; fails if plugin.toml disagrees
   ```

4. Commit, push `main`, wait for CI, then tag and push the tag:

   ```sh
   git tag -a vX.Y.Z -m "Remote Open X.Y.Z"
   git push origin vX.Y.Z
   ```

Never move or reuse a published tag: anyone pinned to it (for example with `fetchFromGitHub`) has
its hash.
