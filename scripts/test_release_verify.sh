#!/bin/sh
set -eu

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zsql-release-verify.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fake_zig="$tmp/zig"
cat > "$fake_zig" <<'EOF'
#!/bin/sh
if [ "$*" = "build test" ]; then
    exit 42
fi
exit 0
EOF
chmod +x "$fake_zig"

if sh scripts/release_verify.sh "$fake_zig" >/dev/null 2>&1; then
    echo "release verifier ignored a failing constituent command" >&2
    exit 1
fi
