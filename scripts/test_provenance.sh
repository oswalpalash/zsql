#!/bin/sh
set -eu

zig_exe=${1:?usage: test_provenance.sh /path/to/zig}
root=$(mktemp -d "${TMPDIR:-/tmp}/zsql-provenance-test.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM
cache="$root/cache"

valid_64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
"$zig_exe" build --help \
    -Dsource-revision="$valid_64" \
    --cache-dir "$cache" >/dev/null

expect_rejected() {
    value=$1
    if "$zig_exe" build --help \
        -Dsource-revision="$value" \
        --cache-dir "$cache" >/dev/null 2>&1
    then
        echo "accepted invalid source revision: $value" >&2
        exit 1
    fi
}

expect_rejected 0123456789abcdef
expect_rejected 0123456789ABCDEF0123456789ABCDEF01234567
expect_rejected 0123456789abcdef0123456789abcdef0123456g
