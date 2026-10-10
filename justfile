# Tools: luau, luau-lsp (and optionally tern, perl, python3, gh).
#   nix shell nixpkgs#luau nixpkgs#luau-lsp

sdk := "3627b34350935c44cb89f6e793e95ad3d08ad75a"

default: check test

# Type definitions for the `tern` module: from the installed Tern, else the published SDK.
types:
    mkdir -p types
    if command -v tern >/dev/null 2>&1; then tern plugin types types; \
    else gh api "repos/stencil-hq/tern-sdk/contents/plugins/tern.d.luau?ref={{sdk}}" --jq .content | base64 -d > types/tern.d.luau; fi

# Strict type check of the plugin (needs `just types` once).
check:
    luau-lsp analyze --platform=standard --definitions=@tern=types/tern.d.luau window.luau lib

# Unit tests (stubbed `tern`) and the serve.pl tests.
test:
    luau tests/run.luau
    bash tests/serve.sh

# Break the code on purpose, one behaviour at a time: every mutation must turn the tests red.
neuter:
    python3 scripts/neuter.py
    python3 scripts/neuter_serve.py
