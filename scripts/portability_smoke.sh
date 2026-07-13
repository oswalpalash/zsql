#!/bin/sh
set -eu

zig_exe=${1:?usage: portability_smoke.sh /path/to/zig}
root=$(mktemp -d "${TMPDIR:-/tmp}/zsql-portability-smoke.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM

windows_prefix="$root/windows-x86_64"
windows_sqlite_prefix="$root/windows-x86_64-sqlite"
linux_prefix="$root/linux-aarch64-musl"
linux_sqlite_prefix="$root/linux-aarch64-musl-sqlite"

"$zig_exe" build -Dtarget=x86_64-windows -p "$windows_prefix"
test -f "$windows_prefix/bin/zsql.exe"
test -f "$windows_prefix/lib/zsql.lib"

"$zig_exe" build -Dtarget=x86_64-windows -Denable-sqlite=true -p "$windows_sqlite_prefix"
test -f "$windows_sqlite_prefix/bin/zsql.exe"
test -f "$windows_sqlite_prefix/lib/zsql.lib"

"$zig_exe" build -Dtarget=aarch64-linux-musl -p "$linux_prefix"
test -x "$linux_prefix/bin/zsql"
test -f "$linux_prefix/lib/libzsql.a"

"$zig_exe" build -Dtarget=aarch64-linux-musl -Denable-sqlite=true -p "$linux_sqlite_prefix"
test -x "$linux_sqlite_prefix/bin/zsql"
test -f "$linux_sqlite_prefix/lib/libzsql.a"
