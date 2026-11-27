#!/bin/bash
# Tests for JSON Schema enforcement and duplicate-key rejection.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-schema-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0
SCHEMA="$ROOT/release/candidate-schema.json"
VALIDATOR="$ROOT/scripts/validate-candidate-schema.py"
HEX64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA1=0123456789abcdef0123456789abcdef01234567
SHA2=89abcdef0123456789abcdef0123456789abcdef

ok() { PASS=$((PASS + 1)); }
bad()
{
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
}

expect_pass()
{
    if "$@" >"$TMP/out" 2>"$TMP/err"; then ok; else bad "expected success: $*"; fi
}

expect_fail_with()
{
    local pattern=$1
    shift
    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        bad "expected failure ($pattern): $*"
    elif grep -Fq -- "$pattern" "$TMP/err"; then
        ok
    else
        bad "failed for the wrong reason; wanted '$pattern': $*"
        sed 's/^/    /' "$TMP/err" | tail -6 >&2
    fi
}

VALID=$TMP/valid.json
jq -n \
    --arg hex "$HEX64" \
    --arg sha1 "$SHA1" \
    --arg sha2 "$SHA2" \
    '{
      schemaVersion: "https://edgeos-vxlan.dev/release-candidate/v1",
      candidate: {
        id: ("sha256:" + $hex),
        createdAt: "2026-11-27T00:00:00Z",
        status: "qualified",
        nonRelease: false
      },
      project: {
        name: "edgeos-vxlan",
        repository: "downwithbgp/edgeos-vxlan",
        repositoryId: 1357738281,
        releaseTag: "v0.3.1",
        packageVersion: "0.3.1+edgeos3.0.1.e50",
        sourceDateEpoch: 1795743000,
        releasePolicySha256: $hex
      },
      source: {
        commit: $sha1,
        archiveSha256: $hex,
        packagingInputsSha256: $hex,
        trustedWorkflow: {
          repository: "downwithbgp/edgeos-vxlan",
          path: ".github/workflows/release.yml",
          ref: "refs/heads/main",
          commit: $sha2
        }
      },
      buildEnvironment: {
        image: "example",
        ociIndexDigest: ("sha256:" + $hex),
        manifestDigest: ("sha256:" + $hex),
        configDigest: ("sha256:" + $hex),
        ociArchiveSha256: $hex,
        dockerArchiveSha256: $hex,
        dockerfileSha256: $hex,
        caBundleSha256: $hex,
        dependencySnapshot: "20261127T000000Z",
        dependencyInventorySha256: $hex,
        qualificationSha256: $hex,
        imageSbomSha256: $hex
      },
      build: {
        buildType: "type",
        command: "command",
        reproducibility: {status: "passed", comparedArtifacts: ["a"]}
      },
      artifacts: [
        {name: "a", size: 1, sha256: $hex, role: "package"}
      ],
      qualification: {
        status: "passed",
        checks: [{id: "check", status: "passed", evidenceSha256: $hex}],
        hardware: {status: "not-required", required: false, evidence: []}
      },
      limitations: ["limited"]
    }' > "$VALID"

expect_pass python3 "$VALIDATOR" --manifest "$VALID" --schema "$SCHEMA"

DUPLICATE=$TMP/duplicate.json
python3 - "$VALID" "$DUPLICATE" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
# Duplicate the first object key at top level.
text = text.replace('{\n  "schemaVersion"', '{\n  "schemaVersion": "x",\n  "schemaVersion"', 1)
open(sys.argv[2], "w", encoding="utf-8").write(text)
PY
expect_fail_with "duplicate JSON object key" \
    python3 "$VALIDATOR" --manifest "$DUPLICATE" --schema "$SCHEMA"

printf '{' > "$TMP/malformed.json"
expect_fail_with "malformed candidate JSON" \
    python3 "$VALIDATOR" --manifest "$TMP/malformed.json" --schema "$SCHEMA"

jq '.candidate.nonRelease = "no"' "$VALID" > "$TMP/wrong-type.json"
expect_fail_with "schema violation" \
    python3 "$VALIDATOR" --manifest "$TMP/wrong-type.json" --schema "$SCHEMA"

jq '.extra = true' "$VALID" > "$TMP/extra.json"
expect_fail_with "schema violation" \
    python3 "$VALIDATOR" --manifest "$TMP/extra.json" --schema "$SCHEMA"

jq '.buildEnvironment.configDigest = "sha256:xyz"' "$VALID" > "$TMP/bad-digest.json"
expect_fail_with "schema violation" \
    python3 "$VALIDATOR" --manifest "$TMP/bad-digest.json" --schema "$SCHEMA"

jq '.schemaVersion = "https://edgeos-vxlan.dev/release-candidate/v2"' "$VALID" \
    > "$TMP/bad-version.json"
expect_fail_with "schema violation" \
    python3 "$VALIDATOR" --manifest "$TMP/bad-version.json" --schema "$SCHEMA"

echo "unit-candidate-schema: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
