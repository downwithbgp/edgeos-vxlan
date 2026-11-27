#!/bin/bash
# Repository test runner. Runs off-device: no root, no network, no real /sys.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

echo "== static: perl syntax =="
perl -c "$ROOT/src/vyatta-vxlan-addr" >/dev/null

echo "== static: shell syntax =="
while IFS= read -r f; do
    bash -n "$f"
done < <(find "$ROOT/src" "$ROOT/test" \( -name '*.sh' -o -name 'vyatta-vxlan' -o -name 'vyatta-vxlan-bridge' -o -name 'vyatta-vxlan-firewall' \) | sort)

echo "== unit: build script =="
bash "$ROOT/test/unit-build.sh"

echo "== unit: helper =="
bash "$ROOT/test/unit-helper.sh"

echo "== unit: firewall helper =="
bash "$ROOT/test/unit-firewall.sh"

echo "== unit: templates =="
bash "$ROOT/test/unit-templates.sh"

if [ -f "$ROOT/test/mock.sh" ]; then
    echo "== mock: reconciliation =="
    bash "$ROOT/test/mock.sh"
fi

echo "== unit: IPv6 qualification evidence =="
bash "$ROOT/test/unit-ipv6-evidence.sh"

echo "ALL TESTS PASSED"
