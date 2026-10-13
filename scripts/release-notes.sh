#!/bin/sh
# Prints the body of the GitHub release for one version: its section of
# CHANGELOG.md, then how to install that release. The release workflow posts
# exactly this, so `just release-notes 0.3.0` shows what will be published.
#
#     scripts/release-notes.sh 0.3.0      # a leading v (v0.3.0) is accepted
#
# Exits 1 when CHANGELOG.md has no section for the version, or an empty one, so
# a release cannot go out without notes. POSIX sh and awk only.
set -eu

version=${1:?usage: release-notes.sh VERSION}
version=${version#v}
root=$(cd "$(dirname "$0")/.." && pwd)

# The lines after "## VERSION" (anything may follow the number on that line, such
# as a date), up to the next "## ", without the blank lines around them.
section=$(awk -v v="$version" '
	/^## / {
		if (inside) exit
		split($0, f, " ")
		if (f[2] == v) { inside = 1; next }
	}
	inside {
		if ($0 ~ /^[[:space:]]*$/) { if (started) blanks++; next }
		for (; blanks > 0; blanks--) print ""
		started = 1
		print
	}
' "$root/CHANGELOG.md")

if [ -z "$section" ]; then
	echo "release-notes.sh: CHANGELOG.md has no notes under \"## $version\"" >&2
	exit 1
fi

printf '%s\n' "$section"
cat <<EOF

### Install

Download \`remote-open-$version.tar.gz\` below, then:

\`\`\`sh
tar -xzf remote-open-$version.tar.gz
tern plugin install ./remote-open-$version --force   # --force replaces an installed copy
tern plugin list                                    # remote-open $version … ready
\`\`\`

Check the download with \`shasum -a 256 -c remote-open-$version.tar.gz.sha256\`.
EOF
