#!/bin/sh
set -eu

zig_exe=${1:?usage: normalize_archive.sh /path/to/zig input-archive output-archive}
input=${2:?usage: normalize_archive.sh /path/to/zig input-archive output-archive}
output=${3:?usage: normalize_archive.sh /path/to/zig input-archive output-archive}

input=$(cd "$(dirname "$input")" && pwd)/$(basename "$input")
output=$(cd "$(dirname "$output")" && pwd)/$(basename "$output")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zsql-normalize-archive.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

(
    cd "$tmp"
    "$zig_exe" ar x "$input"
    set -- ./*
    if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
        echo "expected exactly one object member in $input" >&2
        exit 1
    fi

    case "$output" in
        *.lib) canonical=zsql_zcu.obj ;;
        *) canonical=libzsql_zcu.o ;;
    esac
    if [ "$1" != "./$canonical" ]; then
        mv "$1" "$canonical"
    fi
    chmod u+rw "$canonical"
    "$zig_exe" ar rcs "$output" "$canonical"
)
