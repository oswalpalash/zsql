#!/bin/sh
set -eu

manifest_file=${1:-build.zig.zon}
build_file=${2:-build.zig}
manifest_version=$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)",[[:space:]]*$/\1/p' "$manifest_file")
build_version=$(sed -n 's/^.*options\.addOption(\[\]const u8, "package_version", "\([^"]*\)");.*$/\1/p' "$build_file")

if [ -z "$manifest_version" ] || [ "$(printf '%s\n' "$manifest_version" | wc -l | tr -d ' ')" -ne 1 ]; then
    echo "could not extract exactly one package version from $manifest_file" >&2
    exit 1
fi
if [ -z "$build_version" ] || [ "$(printf '%s\n' "$build_version" | wc -l | tr -d ' ')" -ne 1 ]; then
    echo "could not extract exactly one package_version option from $build_file" >&2
    exit 1
fi
if [ "$manifest_version" != "$build_version" ]; then
    echo "version mismatch: $manifest_file=$manifest_version $build_file=$build_version" >&2
    exit 1
fi

printf '%s\n' "$manifest_version"
