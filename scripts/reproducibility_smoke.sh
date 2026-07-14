#!/bin/sh
set -eu

zig_exe=${1:?usage: reproducibility_smoke.sh /path/to/zig}
root=$(mktemp -d "${TMPDIR:-/tmp}/zsql-reproducibility-smoke.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM
source_revision=0123456789abcdef0123456789abcdef01234567

build_release() {
    prefix=$1
    cache=$2
    "$zig_exe" build \
        -Doptimize=ReleaseSafe \
        -Dstrip=true \
        -Dsource-revision="$source_revision" \
        -p "$prefix" \
        --cache-dir "$cache"
}

build_release "$root/out-a" "$root/cache-a" &
pid_a=$!
build_release "$root/out-b" "$root/cache-b" &
pid_b=$!

status=0
wait "$pid_a" || status=$?
wait "$pid_b" || status=$?
test "$status" -eq 0

test -x "$root/out-a/bin/zsql"
test -f "$root/out-a/lib/libzsql.a"
test -f "$root/out-a/share/zsql/build.zon"
test -x "$root/out-b/bin/zsql"
test -f "$root/out-b/lib/libzsql.a"
test -f "$root/out-b/share/zsql/build.zon"
cmp "$root/out-a/bin/zsql" "$root/out-b/bin/zsql"
cmp "$root/out-a/lib/libzsql.a" "$root/out-b/lib/libzsql.a"
cmp "$root/out-a/share/zsql/build.zon" "$root/out-b/share/zsql/build.zon"
grep -q "^[[:space:]]*\\.source_revision = \"$source_revision\",[[:space:]]*$" \
    "$root/out-a/share/zsql/build.zon"
doctor_output=$("$root/out-a/bin/zsql" doctor)
actual_revision=$(printf '%s\n' "$doctor_output" | sed -n 's/^  source revision: //p')
test "$actual_revision" = "$source_revision"
"$root/out-a/bin/zsql" doctor --zon > "$root/doctor.zon"
cmp "$root/out-a/share/zsql/build.zon" "$root/doctor.zon"
