#!/bin/bash
# Candidate-bound IPv6 qualification evidence contract tests.
#
# The fixture is deliberately synthetic: it exercises the binding/identity
# checks, not the network qualification itself. The network suite produces the
# real summary consumed by the same validator.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VALIDATOR="$ROOT/scripts/validate-ipv6-qualification-evidence.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
    [ -s "$TMP/err" ] && sed 's/^/    err: /' "$TMP/err" | tail -6
}

valid_case()
{
    local dir=$1
    mkdir -p "$dir/captures"
    printf 'summary\n' >"$dir/summary.txt"
    printf 'topology\n' >"$dir/topology-after.txt"
    printf 'underlay\n' >"$dir/captures/underlay.pcap"
    printf 'overlay\n' >"$dir/captures/overlay.pcap"
    printf 'analysis\n' >"$dir/captures/analysis.txt"
    printf 'reconciler\n' >"$dir/reconciler-evidence.txt"
    python3 - "$dir" <<'PY'
import hashlib
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])


def sha(name):
    return hashlib.sha256((directory / name).read_bytes()).hexdigest()


checks = [
    {"id": "ipv6-only-isolation", "status": "passed",
     "evidenceFile": "summary.txt", "evidenceSha256": sha("summary.txt")},
    {"id": "ipv6-only-dataplane", "status": "passed",
     "evidenceFile": "topology-after.txt", "evidenceSha256": sha("topology-after.txt")},
    {"id": "ipv6-only-capture", "status": "passed",
     "evidenceFile": "captures/analysis.txt", "evidenceSha256": sha("captures/analysis.txt")},
    {"id": "ipv6-only-reconciler", "status": "passed",
     "evidenceFile": "reconciler-evidence.txt", "evidenceSha256": sha("reconciler-evidence.txt")},
]
payload = {
    "schemaVersion": "edgeos-vxlan.ipv6-only-qualification/v1",
    "suite": "test/ipv6-only-netns.sh",
    "commit": "b" * 40,
    "branch": "ci/ipv6-native-qualification",
    "generatedAt": "2026-11-27T00:00:00Z",
    "level": "B",
    "evidenceClasses": ["N6", "N6-R", "N6-R-P"],
    "result": "passed",
    "counts": {"pass": 113, "fail": 0, "skip": 1},
    "checks": checks,
    "capture": {
        "status": "executed",
        "underlaySha256": sha("captures/underlay.pcap"),
        "overlaySha256": sha("captures/overlay.pcap"),
        "analysisSha256": sha("captures/analysis.txt"),
    },
    "reconciler": {
        "status": "executed",
        "evidenceFile": "reconciler-evidence.txt",
        "evidenceSha256": sha("reconciler-evidence.txt"),
    },
    "candidate": {
        "id": "sha256:" + "a" * 64,
        "sourceCommit": "b" * 40,
        "package": "edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb",
        "packageSha256": "c" * 64,
        "packageExecuted": True,
        "reconcilerSha256": "d" * 64,
        "addrHelperSha256": "e" * 64,
    },
    "workflow": {
        "runId": "123456789",
        "runAttempt": "1",
        "repository": "downwithbgp/edgeos-vxlan",
        "path": "downwithbgp/edgeos-vxlan/.github/workflows/ci.yml@refs/heads/main",
        "ref": "refs/heads/main",
        "commit": "b" * 40,
    },
    "harness": {
        "commit": "f" * 40,
        "path": "test/ipv6-only-netns.sh",
        "version": "1",
    },
    "skips": ["host-global-ipv6-escape-unavailable: host has no global IPv6 address"],
    "workarounds": [{"id": "iproute2-json-normalization", "applied": True}],
    "hardware": {"status": "not-qualified", "required": False, "evidence": []},
    "limitations": ["Synthetic fixture; not hardware evidence."],
}
(directory / "summary.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

validator_args()
{
    printf '%s\0' \
        --summary "$1/summary.json" \
        --expected-source-commit "$(printf 'b%.0s' {1..40})" \
        --expected-candidate-id "sha256:$(printf 'a%.0s' {1..64})" \
        --expected-package-sha256 "$(printf 'c%.0s' {1..64})" \
        --expected-workflow-run-id 123456789 \
        --expected-workflow-run-attempt 1 \
        --expected-workflow-path 'downwithbgp/edgeos-vxlan/.github/workflows/ci.yml@refs/heads/main' \
        --expected-workflow-ref refs/heads/main \
        --expected-workflow-commit "$(printf 'b%.0s' {1..40})" \
        --expected-harness-commit "$(printf 'f%.0s' {1..40})" \
        --require-workflow-binding \
        --require-package-execution \
        --allow-skip host-global-ipv6-escape-unavailable \
        --allow-workaround iproute2-json-normalization
}

run_pass()
{
    local desc=$1 dir=$2
    mapfile -d '' -t argv < <(validator_args "$dir")
    if python3 "$VALIDATOR" "${argv[@]}" >"$TMP/out" 2>"$TMP/err"; then
        ok
    else
        bad "$desc (expected pass)"
    fi
}

run_fail()
{
    local desc=$1 dir=$2
    shift 2
    mapfile -d '' -t argv < <(validator_args "$dir")
    if python3 "$VALIDATOR" "${argv[@]}" "$@" >"$TMP/out" 2>"$TMP/err"; then
        bad "$desc (expected failure)"
    elif grep -q 'ERROR:' "$TMP/err"; then
        ok
    else
        bad "$desc (failure had no diagnostic)"
    fi
}

mutate()
{
    local dir=$1 script=$2
    python3 - "$dir/summary.json" "$script" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
script = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
if script == "failed":
    data["result"] = "failed"
    for check in data["checks"]:
        if check["id"] == "ipv6-only-isolation":
            check["status"] = "failed"
elif script == "no-capture":
    data["capture"]["status"] = "skipped"
elif script == "no-reconciler":
    data["reconciler"]["status"] = "not-performed"
elif script == "unexpected-skip":
    data["skips"].append("unexpected-required-check: not run")
    data["counts"]["skip"] += 1
elif script == "missing-check":
    data["checks"] = [c for c in data["checks"] if c["id"] != "ipv6-only-reconciler"]
elif script == "no-package":
    data["candidate"]["packageExecuted"] = False
elif script == "unallowed-workaround":
    data["workarounds"].append({"id": "unexpected-workaround", "applied": True})
else:
    raise SystemExit(f"unknown mutation: {script}")
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

VALID="$TMP/valid"
valid_case "$VALID"
run_pass "valid candidate-bound evidence with permitted skip/workaround" "$VALID"

run_fail "missing qualification summary" "$TMP/missing"
cp -a "$VALID/." "$TMP/failed"; mutate "$TMP/failed" failed
run_fail "failed isolation assertion" "$TMP/failed"
cp -a "$VALID/." "$TMP/no-capture"; mutate "$TMP/no-capture" no-capture
run_fail "missing mandatory packet capture" "$TMP/no-capture"
cp -a "$VALID/." "$TMP/no-reconciler"; mutate "$TMP/no-reconciler" no-reconciler
run_fail "missing required reconciler execution" "$TMP/no-reconciler"
run_fail "wrong source commit" "$VALID" --expected-source-commit "$(printf '9%.0s' {1..40})"
run_fail "wrong candidate id" "$VALID" --expected-candidate-id "sha256:$(printf '9%.0s' {1..64})"
run_fail "wrong candidate package digest" "$VALID" --expected-package-sha256 "$(printf '9%.0s' {1..64})"
cp -a "$VALID/." "$TMP/modified"; printf 'modified\n' >>"$TMP/modified/summary.txt"
run_fail "modified evidence file" "$TMP/modified"
cp -a "$VALID/." "$TMP/wrong-run"; python3 - "$TMP/wrong-run/summary.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["workflow"]["runId"] = "999"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
run_fail "evidence from an unrelated workflow run" "$TMP/wrong-run"
cp -a "$VALID/." "$TMP/unexpected-skip"; mutate "$TMP/unexpected-skip" unexpected-skip
run_fail "unexpected skipped required check" "$TMP/unexpected-skip"
cp -a "$VALID/." "$TMP/missing-check"; mutate "$TMP/missing-check" missing-check
run_fail "missing required check entry" "$TMP/missing-check"
cp -a "$VALID/." "$TMP/no-package"; mutate "$TMP/no-package" no-package
run_fail "required candidate-package execution absent" "$TMP/no-package"
cp -a "$VALID/." "$TMP/bad-workaround"; mutate "$TMP/bad-workaround" unallowed-workaround
run_fail "unreported compatibility workaround" "$TMP/bad-workaround"
cp -a "$VALID/." "$TMP/malformed"; printf '{' >"$TMP/malformed/summary.json"
run_fail "malformed qualification summary" "$TMP/malformed"
run_fail "wrong harness commit" "$VALID" --expected-harness-commit "$(printf '9%.0s' {1..40})"

echo "unit-ipv6-evidence: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
