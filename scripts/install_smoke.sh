#!/bin/sh
set -eu

zig_exe=${1:?usage: install_smoke.sh /path/to/zig}
prefix=$(mktemp -d "${TMPDIR:-/tmp}/zsql-install-smoke.XXXXXX")
trap 'rm -rf "$prefix"' EXIT HUP INT TERM

"$zig_exe" build install --prefix "$prefix"
test -x "$prefix/bin/zsql"
test -f "$prefix/lib/libzsql.a"
"$prefix/bin/zsql" doctor
