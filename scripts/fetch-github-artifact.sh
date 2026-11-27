#!/bin/bash
# Fetch and verify a GitHub Actions artifact by its immutable ID/digest.
#
# Verifies repository identity, artifact ID, expiry, expected digest, workflow
# run identity/revision/path and the actual downloaded ZIP digest before safe
# extraction. Never extracts directly over trusted tooling.
#
# Usage:
#   fetch-github-artifact.sh --repo OWNER/REPO --artifact-id ID \
#     --expected-digest sha256:HEX --destination DIR [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

REPO=
ARTIFACT_ID=
EXPECTED_DIGEST=
DESTINATION=
EXPECTED_RUN_ID=
EXPECTED_HEAD_SHA=
EXPECTED_WORKFLOW_PATH=
EXPECTED_NAME=
MAX_BYTES=2147483648
GH_BIN=${GH_BIN:-gh}

usage()
{
    cat <<'EOF'
Usage: fetch-github-artifact.sh --repo OWNER/REPO --artifact-id ID \
         --expected-digest sha256:HEX --destination DIR [options]

Options:
  --repo OWNER/REPO             Repository
  --artifact-id ID              GitHub Actions artifact ID
  --expected-digest DIGEST      Expected ZIP digest (sha256:<hex>)
  --destination DIR             Empty/absent extraction directory
  --expected-run-id ID          Expected workflow run ID
  --expected-head-sha SHA       Expected workflow head SHA
  --expected-workflow-path P    Expected workflow path (e.g. .github/workflows/release.yml)
  --expected-name NAME          Expected artifact name
  --max-uncompressed-bytes N    Extract size limit (default 2 GiB)
  --gh PATH                     GitHub CLI binary
  -h, --help                    Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || { usage >&2; exit 2; }; REPO=$2; shift 2 ;;
        --artifact-id) [ $# -ge 2 ] || { usage >&2; exit 2; }; ARTIFACT_ID=$2; shift 2 ;;
        --expected-digest) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECTED_DIGEST=$2; shift 2 ;;
        --destination) [ $# -ge 2 ] || { usage >&2; exit 2; }; DESTINATION=$2; shift 2 ;;
        --expected-run-id) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECTED_RUN_ID=$2; shift 2 ;;
        --expected-head-sha) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECTED_HEAD_SHA=$2; shift 2 ;;
        --expected-workflow-path) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECTED_WORKFLOW_PATH=$2; shift 2 ;;
        --expected-name) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECTED_NAME=$2; shift 2 ;;
        --max-uncompressed-bytes) [ $# -ge 2 ] || { usage >&2; exit 2; }; MAX_BYTES=$2; shift 2 ;;
        --gh) [ $# -ge 2 ] || { usage >&2; exit 2; }; GH_BIN=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[ -n "$REPO" ] && [ -n "$ARTIFACT_ID" ] && [ -n "$EXPECTED_DIGEST" ] &&
    [ -n "$DESTINATION" ] || { usage >&2; exit 2; }
require_cmd jq sha256sum python3 mktemp
command -v "$GH_BIN" >/dev/null 2>&1 || fail "GitHub CLI not found: $GH_BIN"
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ||
    fail "invalid repository: $REPO"
printf '%s' "$ARTIFACT_ID" | grep -Eq '^[0-9]+$' ||
    fail "invalid artifact ID: $ARTIFACT_ID"
is_digest "$EXPECTED_DIGEST" ||
    fail "expected digest must be sha256:<hex>: $EXPECTED_DIGEST"
if [ -n "$EXPECTED_RUN_ID" ]; then
    printf '%s' "$EXPECTED_RUN_ID" | grep -Eq '^[0-9]+$' ||
        fail "invalid expected run ID: $EXPECTED_RUN_ID"
fi
if [ -n "$EXPECTED_HEAD_SHA" ]; then
    is_commit "$EXPECTED_HEAD_SHA" ||
        fail "invalid expected head SHA: $EXPECTED_HEAD_SHA"
fi
case "$MAX_BYTES" in
    ''|*[!0-9]*) fail "max-uncompressed-bytes must be an integer" ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-artifact.XXXXXX") ||
    fail "cannot create temporary directory"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

REPO_ID=$("$GH_BIN" api "repos/$REPO" --jq '.id') ||
    fail "cannot resolve repository identity: $REPO"
ARTIFACT=$("$GH_BIN" api "repos/$REPO/actions/artifacts/$ARTIFACT_ID") ||
    fail "cannot read artifact $ARTIFACT_ID"

[ "$(jq -r '.id' <<<"$ARTIFACT")" = "$ARTIFACT_ID" ] ||
    fail "artifact ID mismatch"
[ "$(jq -r '.expired' <<<"$ARTIFACT")" = "false" ] ||
    fail "artifact $ARTIFACT_ID has expired"
[ "$(jq -r '.digest // empty' <<<"$ARTIFACT")" = "$EXPECTED_DIGEST" ] ||
    fail "artifact API digest does not match the expected digest"
if [ -n "$EXPECTED_NAME" ]; then
    [ "$(jq -r '.name' <<<"$ARTIFACT")" = "$EXPECTED_NAME" ] ||
        fail "artifact name is not $EXPECTED_NAME"
fi

RUN_ID=$(jq -r '.workflow_run.id // empty' <<<"$ARTIFACT")
HEAD_SHA=$(jq -r '.workflow_run.head_sha // empty' <<<"$ARTIFACT")
[ -n "$RUN_ID" ] || fail "artifact has no workflow run identity"
[ -n "$HEAD_SHA" ] || fail "artifact has no workflow head SHA"
[ "$(jq -r '.workflow_run.repository_id // empty' <<<"$ARTIFACT")" = "$REPO_ID" ] ||
    fail "artifact workflow repository ID does not match $REPO"
[ "$(jq -r '.workflow_run.head_repository_id // empty' <<<"$ARTIFACT")" = "$REPO_ID" ] ||
    fail "artifact head repository ID does not match $REPO"
if [ -n "$EXPECTED_RUN_ID" ]; then
    [ "$RUN_ID" = "$EXPECTED_RUN_ID" ] || fail "artifact workflow run ID mismatch"
fi
if [ -n "$EXPECTED_HEAD_SHA" ]; then
    [ "$HEAD_SHA" = "$EXPECTED_HEAD_SHA" ] || fail "artifact workflow head SHA mismatch"
fi

RUN=$("$GH_BIN" api "repos/$REPO/actions/runs/$RUN_ID") ||
    fail "cannot read artifact workflow run $RUN_ID"
[ "$(jq -r '.status' <<<"$RUN")" = "completed" ] ||
    fail "artifact workflow run is not completed"
[ "$(jq -r '.conclusion' <<<"$RUN")" = "success" ] ||
    fail "artifact workflow run did not succeed"
[ "$(jq -r '.head_repository.full_name // empty' <<<"$RUN")" = "$REPO" ] ||
    fail "artifact workflow run repository mismatch"
[ "$(jq -r '.head_sha' <<<"$RUN")" = "$HEAD_SHA" ] ||
    fail "artifact workflow run head SHA mismatch"
if [ -n "$EXPECTED_WORKFLOW_PATH" ]; then
    [ "$(jq -r '.path' <<<"$RUN")" = "$EXPECTED_WORKFLOW_PATH" ] ||
        fail "artifact workflow path is not $EXPECTED_WORKFLOW_PATH"
fi

ZIP=$TMP/artifact.zip
"$GH_BIN" api "repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" > "$ZIP" ||
    fail "cannot download artifact $ARTIFACT_ID"
ACTUAL="sha256:$(sha256_file "$ZIP")"
[ "$ACTUAL" = "$EXPECTED_DIGEST" ] ||
    fail "downloaded artifact digest $ACTUAL != expected $EXPECTED_DIGEST"

python3 "$ROOT/scripts/validate-zip-archive.py" \
    --archive "$ZIP" \
    --destination "$DESTINATION" \
    --max-uncompressed-bytes "$MAX_BYTES"

echo "Artifact acquisition: PASS"
echo "Repository:           $REPO ($REPO_ID)"
echo "Artifact ID/digest:   $ARTIFACT_ID $ACTUAL"
echo "Workflow run/head:    $RUN_ID $HEAD_SHA"
