#!/bin/sh
set -eu

zig_exe=${1:?usage: package_smoke.sh /path/to/zig}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zsql-package-smoke.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# Snapshot the current worktree through a private Git index. This includes
# uncommitted candidate changes without touching the user's real index, while
# still honoring .gitignore and producing a clean archive with no build caches.
export GIT_INDEX_FILE="$tmp/index"
git read-tree HEAD
git add -A
tree=$(git write-tree)
mkdir "$tmp/source" "$tmp/package"
git archive "$tree" | tar -xf - -C "$tmp/source"

package_hash=$("$zig_exe" fetch --global-cache-dir "$tmp/fetch-cache" "$tmp/source")
package_archive="$tmp/fetch-cache/p/$package_hash.tar.gz"
test -f "$package_archive"
tar -xzf "$package_archive" -C "$tmp/package"
package_root="$tmp/package/$package_hash"

# These paths are consumed by build.zig gates and must survive manifest .paths.
test -f "$package_root/scripts/check_version_sync.sh"
test -f "$package_root/scripts/install_smoke.sh"
test -f "$package_root/tests/consumer/build.zig.zon"

(
    cd "$package_root"
    "$zig_exe" build test
    "$zig_exe" build consumer-smoke
    "$zig_exe" build install-smoke
)
