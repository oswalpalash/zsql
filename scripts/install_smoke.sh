#!/bin/sh
set -eu

zig_exe=${1:?usage: install_smoke.sh /path/to/zig}
expected_version=$(sh scripts/check_version_sync.sh)
prefix=$(mktemp -d "${TMPDIR:-/tmp}/zsql-install-smoke.XXXXXX")
trap 'rm -rf "$prefix"' EXIT HUP INT TERM

"$zig_exe" build install --prefix "$prefix"
test -x "$prefix/bin/zsql"
test -f "$prefix/lib/libzsql.a"
provenance="$prefix/share/zsql/build.zon"
test -f "$provenance"
provenance_version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",[[:space:]]*$/\1/p' "$provenance")
provenance_sqlite=$(sed -n 's/^[[:space:]]*\.sqlite = "\([^"]*\)",[[:space:]]*$/\1/p' "$provenance")
test "$provenance_version" = "$expected_version"
test "$provenance_sqlite" = "disabled"
grep -q '^[[:space:]]*\.optimize = "Debug",[[:space:]]*$' "$provenance"
grep -q '^[[:space:]]*\.strip = false,[[:space:]]*$' "$provenance"
doctor_output=$("$prefix/bin/zsql" doctor)
actual_version=$(printf '%s\n' "$doctor_output" | sed -n 's/^  version: //p')
if [ "$actual_version" != "$expected_version" ]; then
    echo "installed CLI version mismatch: manifest=$expected_version doctor=$actual_version" >&2
    exit 1
fi
printf '%s\n' "$doctor_output"
