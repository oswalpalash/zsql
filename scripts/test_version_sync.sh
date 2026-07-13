#!/bin/sh
set -eu

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zsql-version-sync.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cp build.zig.zon "$tmp/build.zig.zon"
sed 's/"package_version", "[^"]*"/"package_version", "999.999.999"/' build.zig > "$tmp/build.zig"

if sh scripts/check_version_sync.sh "$tmp/build.zig.zon" "$tmp/build.zig" >/dev/null 2>&1; then
    echo "version sync checker accepted intentionally mismatched metadata" >&2
    exit 1
fi
