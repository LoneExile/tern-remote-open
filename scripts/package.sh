#!/bin/sh
# Builds the release archive of the plugin: the files Tern loads plus README,
# CHANGELOG and LICENSE, taken from a commit (default HEAD, so uncommitted edits
# never ship), into dist/ with its SHA-256.
#
#     scripts/package.sh 0.3.0 [REF]      # a leading v (v0.3.0) is accepted
#
# Exits 1 when plugin.toml at REF carries another version.
set -eu

version=${1:?usage: package.sh VERSION [REF]}
version=${version#v}
ref=${2:-HEAD}
root=$(cd "$(dirname "$0")/.." && pwd)

manifest=$(git -C "$root" show "$ref:plugin.toml" | sed -n 's/^version = "\(.*\)"$/\1/p')
if [ "$manifest" != "$version" ]; then
	echo "package.sh: plugin.toml at $ref has version \"$manifest\", not \"$version\"" >&2
	exit 1
fi

name="remote-open-$version"
mkdir -p "$root/dist"
git -C "$root" archive --format=tar --prefix="$name/" "$ref" \
	plugin.toml window.luau lib serve.pl copy-image.js README.md CHANGELOG.md LICENSE |
	gzip -n -9 >"$root/dist/$name.tar.gz"
(cd "$root/dist" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
echo "dist/$name.tar.gz"
