#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT

bash -n setup.sh lib/network.sh tests/check.sh
bash setup.sh plan > "$CHECK_DIR/plan"
grep -q 'No files' "$CHECK_DIR/plan"
bash setup.sh --dry-run > "$CHECK_DIR/dry-run"
cmp "$CHECK_DIR/plan" "$CHECK_DIR/dry-run"
if bash setup.sh nonsense > "$CHECK_DIR/error" 2>&1; then echo 'Unknown command was accepted'; exit 1; fi
if bash setup.sh apply --ssh-key > "$CHECK_DIR/error" 2>&1; then echo 'Missing value was accepted'; exit 1; fi

bash lib/network.sh render 192.0.2.53 > "$CHECK_DIR/pf-anchor"
for bad in '1.2.3' '256.0.0.1' 'a.b.c.d' '1.2.3.4;reboot' '1.2.3.4 port 22' '1.2.3.4/24' ''; do
    if bash lib/network.sh render "$bad" > "$CHECK_DIR/error" 2>&1; then
        printf 'Accepted invalid DNS input: %s\n' "$bad"; exit 1
    fi
done
bash lib/network.sh render-plist > "$CHECK_DIR/boot.plist"

if [ "$(uname -s)" = Darwin ]; then
    plutil -lint "$CHECK_DIR/boot.plist"
    sudo /sbin/pfctl -nf "$CHECK_DIR/pf-anchor"
else
    if bash setup.sh apply --ssh-key /does/not/exist > "$CHECK_DIR/error" 2>&1; then
        echo 'Linux apply was accepted'; exit 1
    fi
    grep -q 'requires macOS' "$CHECK_DIR/error"
fi
echo 'Checks passed.'
