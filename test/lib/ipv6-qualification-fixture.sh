#!/bin/bash
# Synthetic IPv6-only qualification fixture for release-gate tests.
#
# This helper writes a retained evidence directory and emits the manifest
# fragment (`checks[]` entries and the `qualification.ipv6` block) that the
# release validator enforces. It exercises the binding/gate logic only; it is
# not network qualification evidence.

ipv6_fixture_write()
{
    local dir=$1 identity=$2 commit=$3 package=$4 package_sha=$5
    local evidence=$dir/qualification/ipv6-only
    mkdir -p "$evidence/captures"
    printf 'summary\n' > "$evidence/summary.txt"
    printf 'topology\n' > "$evidence/topology-after.txt"
    printf 'underlay\n' > "$evidence/captures/underlay.pcap"
    printf 'overlay\n' > "$evidence/captures/overlay.pcap"
    printf 'analysis\n' > "$evidence/captures/analysis.txt"
    printf 'reconciler\n' > "$evidence/reconciler-evidence.txt"

    python3 - "$evidence" "$identity" "$commit" "$package" "$package_sha" >/dev/null <<'PY'
import hashlib
import json
import pathlib
import sys

evidence = pathlib.Path(sys.argv[1])
identity = sys.argv[2]
commit = sys.argv[3]
package = sys.argv[4]
package_sha = sys.argv[5]


def sha(name):
    return hashlib.sha256((evidence / name).read_bytes()).hexdigest()


payload = {
    "schemaVersion": "edgeos-vxlan.ipv6-only-qualification/v1",
    "suite": "test/ipv6-only-netns.sh",
    "commit": commit,
    "branch": "main",
    "generatedAt": "2026-11-27T00:00:00Z",
    "level": "B",
    "evidenceClasses": ["N6", "N6-R", "N6-R-P"],
    "result": "passed",
    "counts": {"pass": 113, "fail": 0, "skip": 2},
    "checks": [
        {"id": "ipv6-only-isolation", "status": "passed",
         "evidenceFile": "summary.txt", "evidenceSha256": sha("summary.txt")},
        {"id": "ipv6-only-dataplane", "status": "passed",
         "evidenceFile": "topology-after.txt", "evidenceSha256": sha("topology-after.txt")},
        {"id": "ipv6-only-capture", "status": "passed",
         "evidenceFile": "captures/analysis.txt", "evidenceSha256": sha("captures/analysis.txt")},
        {"id": "ipv6-only-reconciler", "status": "passed",
         "evidenceFile": "reconciler-evidence.txt", "evidenceSha256": sha("reconciler-evidence.txt")},
    ],
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
        "id": "",
        "buildIdentity": identity,
        "sourceCommit": commit,
        "package": package,
        "packageSha256": package_sha,
        "packageExecuted": True,
        "reconcilerSha256": "d" * 64,
        "addrHelperSha256": "e" * 64,
    },
    "workflow": {
        "runId": "123456789",
        "runAttempt": "1",
        "repository": "downwithbgp/edgeos-vxlan",
        "path": "downwithbgp/edgeos-vxlan/.github/workflows/release.yml@refs/heads/main",
        "ref": "refs/heads/main",
        "commit": commit,
    },
    "harness": {
        "commit": commit,
        "path": "test/ipv6-only-netns.sh",
        "version": "1",
    },
    "skips": ["host-global-ipv6-escape-unavailable: host has no global IPv6 address",
              "iproute2-json-normalization: normalized a modern iproute2 JSON diagnostic"],
    "workarounds": [{"id": "iproute2-json-normalization", "applied": True}],
    "hardware": {"status": "not-qualified", "required": False, "evidence": []},
    "limitations": ["Synthetic fixture; not hardware evidence."],
}
(evidence / "summary.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

    local summary_sha
    summary_sha=$(sha256sum "$evidence/summary.json" | awk '{print $1}')

    jq -n \
        --arg identity "$identity" \
        --arg commit "$commit" \
        --arg package "$package" \
        --arg packageSha "$package_sha" \
        --arg summarySha "$summary_sha" \
        --slurpfile summary "$evidence/summary.json" \
        '{
          checks: ($summary[0].checks | map({id, status, evidenceFile, evidenceSha256})),
          ipv6: {
            status: "passed",
            level: "B",
            buildIdentity: $identity,
            sourceCommit: $commit,
            package: $package,
            packageSha256: $packageSha,
            reconcilerSha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            addrHelperSha256: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            workflow: {
              runId: "123456789",
              runAttempt: "1",
              repository: "downwithbgp/edgeos-vxlan",
              path: ".github/workflows/release.yml",
              ref: "refs/heads/main",
              commit: $commit
            },
            harness: {path: "test/ipv6-only-netns.sh", commit: $commit, version: "1"},
            evidence: {dir: "qualification/ipv6-only", summarySha256: $summarySha},
            capture: {
              status: "executed",
              underlaySha256: $summary[0].capture.underlaySha256,
              overlaySha256: $summary[0].capture.overlaySha256,
              analysisSha256: $summary[0].capture.analysisSha256
            },
            reconciler: {
              status: "executed",
              evidenceSha256: $summary[0].reconciler.evidenceSha256
            },
            skips: ["host-global-ipv6-escape-unavailable", "iproute2-json-normalization"],
            workarounds: [{id: "iproute2-json-normalization", applied: true}]
          }
        }' > "$dir/qualification/ipv6-fragment.json"
}
