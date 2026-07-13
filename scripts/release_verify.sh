#!/bin/sh
set -eu

zig_exe=${1:?usage: release_verify.sh /path/to/zig}

"$zig_exe" fmt --check .
"$zig_exe" build
"$zig_exe" build version-sync
"$zig_exe" build test
"$zig_exe" build test -Denable-sqlite=true
"$zig_exe" build test -Denable-sqlite=true -Dsqlite-system=true
"$zig_exe" build check-sql
"$zig_exe" build examples -Denable-sqlite=true
"$zig_exe" build consumer-smoke
"$zig_exe" build consumer-smoke-system
"$zig_exe" build install-smoke
"$zig_exe" build package-smoke
