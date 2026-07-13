#!/bin/sh
set -eu

zig_exe=${1:?usage: portability_smoke.sh /path/to/zig}
root=$(mktemp -d "${TMPDIR:-/tmp}/zsql-portability-smoke.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM

windows_prefix="$root/windows-x86_64"
linux_prefix="$root/linux-aarch64-musl"

"$zig_exe" build -Dtarget=x86_64-windows -p "$windows_prefix"
test -f "$windows_prefix/bin/zsql.exe"
test -f "$windows_prefix/lib/zsql.lib"

"$zig_exe" build -Dtarget=aarch64-linux-musl -p "$linux_prefix"
test -x "$linux_prefix/bin/zsql"
test -f "$linux_prefix/lib/libzsql.a"
