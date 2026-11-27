#!/bin/bash
# Verify, preflight, dry-run or publish an explicitly identified candidate.
#
# This script is trusted executable tooling. The release tag/source is data:
# the script never executes scripts from --source-root.
#
# Modes:
#   --qualification --dry-run   Non-release candidate -> printed plan only.
#   --preflight --dry-run       Production checks -> promotion-verification.json.
#   --dry-run                   Production checks -> printed plan only.
#   default                     Authorized draft -> verify -> publish.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

DIR=
TAG=
CANDIDATE_ID=
MANIFEST_SHA=
ARTIFACT_ID=
ARTIFACT_DIGEST=
SOURCE_ROOT=$ROOT
POLICY=$ROOT/release/release-policy.json
DRY_RUN=no
FIXTURE=no
QUALIFICATION=no
PREFLIGHT=no
PREFLIGHT_FILE=
EXPECTED_TAG_COMMIT=
EXPECTED_SOURCE_COMMIT=
EXPECTED_WORKFLOW_COMMIT=
BUNDLE=
TRUSTED_ROOT=
GH_BIN=${GH_BIN:-gh}

usage()
{
    cat <<'EOF'
Usage: promote-release.sh --candidate-dir DIR --candidate-id ID \
         --manifest-sha256 SHA [options]

Options:
  --candidate-dir DIR           Downloaded candidate artifact
  --candidate-id ID             Expected candidate ID
  --manifest-sha256 SHA         Expected candidate manifest SHA-256
  --artifact-id ID              Candidate Actions artifact ID
  --artifact-digest DIGEST      Candidate ZIP digest (sha256:<hex>)
  --tag TAG                     Release tag (production modes)
  --source-root DIR             Tagged source checkout as data (production modes)
  --dry-run                     Verify and print the plan only
  --qualification               Non-release candidate qualification plan
  --preflight                   Write promotion-verification.json (requires --dry-run)
  --preflight-file FILE         Validate a preflight result before publishing
  --expected-tag-commit SHA     Expected tag commit
  --expected-source-commit SHA  Expected candidate source commit
  --expected-workflow-commit SHA Expected trusted workflow commit
  --fixture                     Local test mode; no GitHub/attestation/gates
  --bundle FILE                 Attestation bundle
  --trusted-root FILE           Optional custom Sigstore trusted root
  -h, --help                    Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --candidate-dir) [ $# -ge 2 ] || { usage >&2; exit 2; }; DIR=$2; shift 2 ;;
        --tag) [ $# -ge 2 ] || { usage >&2; exit 2; }; TAG=$2; shift 2 ;;
        --candidate-id) [ $# -ge 2 ] || { usage >&2; exit 2; }; CANDIDATE_ID=$2; shift 2 ;;
        --manifest-sha256) [ $# -ge 2 ] || { usage >&2; exit 2; }; MANIFEST_SHA=$2; shift 2 ;;
        --artifact-id) [ $# -ge 2 ] || { usage >&2; exit 2; }; ARTIFACT_ID=$2; shift 2 ;;
        --artifact-digest) [ $# -ge 2 ] || { usage >&2; exit 2; }; ARTIFACT_DIGEST=$2; shift 2 ;;
        --source-root) [ $# -ge 2 ] || { usage >&2; exit 2; }; SOURCE_ROOT=$2; shift 2 ;;
        --dry-run) DRY_RUN=yes; shift ;;
        --qualification) QUALIFICATION=yes; shift ;;
        --preflight) PREFLIGHT=yes; shift ;;
        --preflight-file) [ $# -ge 2 ] || { usage >&2; exit 2; }; PREFLIGHT_FILE=$2; shift 2 ;;
        --expected-tag-commit) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECTED_TAG_COMMIT=$2; shift 2 ;;
        --expected-source-commit) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECTED_SOURCE_COMMIT=$2; shift 2 ;;
        --expected-workflow-commit) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECTED_WORKFLOW_COMMIT=$2; shift 2 ;;
        --fixture) FIXTURE=yes; shift ;;
        --bundle) [ $# -ge 2 ] || { usage >&2; exit 2; }; BUNDLE=$2; shift 2 ;;
        --trusted-root) [ $# -ge 2 ] || { usage >&2; exit 2; }; TRUSTED_ROOT=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [ -z "$DIR" ] || [ -z "$CANDIDATE_ID" ] || [ -z "$MANIFEST_SHA" ]; then
    usage >&2
    exit 2
fi
require_dir "$DIR"
require_file "$DIR/release-candidate.json"
require_file "$POLICY"
require_cmd jq git sha256sum find sort awk sed cmp

if [ -n "$ARTIFACT_DIGEST" ]; then
    ARTIFACT_DIGEST=$(normalize_digest "$ARTIFACT_DIGEST") ||
        fail "artifact digest must be sha256:<hex> or a bare 64-character hex"
fi

MANIFEST=$DIR/release-candidate.json
check_manifest_sha256 "$MANIFEST" "$MANIFEST_SHA"
check_candidate_id "$MANIFEST"
actual_id=$(manifest_get "$MANIFEST" '.candidate.id')
[ "$actual_id" = "$CANDIDATE_ID" ] ||
    fail "candidate ID $actual_id != requested $CANDIDATE_ID"

SOURCE_COMMIT=$(manifest_get "$MANIFEST" '.source.commit')
WORKFLOW_COMMIT=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.commit')
WORKFLOW_REF=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.ref')
NON_RELEASE=$(manifest_get "$MANIFEST" '.candidate.nonRelease')
if [ -n "$EXPECTED_SOURCE_COMMIT" ]; then
    [ "$SOURCE_COMMIT" = "$EXPECTED_SOURCE_COMMIT" ] ||
        fail "candidate source commit mismatch"
fi
if [ -n "$EXPECTED_WORKFLOW_COMMIT" ]; then
    [ "$WORKFLOW_COMMIT" = "$EXPECTED_WORKFLOW_COMMIT" ] ||
        fail "candidate workflow commit mismatch"
fi

if [ -z "$BUNDLE" ] && [ -f "$DIR/release-attestation.jsonl" ]; then
    BUNDLE=$DIR/release-attestation.jsonl
fi

ASSETS=$(find "$DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' |
    grep -Fvx 'source.tar' | LC_ALL=C sort)

asset_json()
{
    local name=$1
    jq -n --arg name "$name" \
        --argjson size "$(stat -c '%s' "$DIR/$name")" \
        --arg sha256 "$(sha256_file "$DIR/$name")" \
        '{name:$name, size:$size, sha256:$sha256}'
}

write_plan()
{
    local mode=$1 tag=${2:-} tag_commit=${3:-}
    local entries=""
    while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        entries="${entries}${entries:+,}$(asset_json "$asset")"
    done <<EOF
$ASSETS
EOF
    jq -n \
        --arg mode "$mode" \
        --arg tag "$tag" \
        --arg tagCommit "$tag_commit" \
        --arg candidateId "$CANDIDATE_ID" \
        --arg manifestSha "$MANIFEST_SHA" \
        --arg artifactId "$ARTIFACT_ID" \
        --arg artifactDigest "$ARTIFACT_DIGEST" \
        --arg sourceCommit "$SOURCE_COMMIT" \
        --arg workflowCommit "$WORKFLOW_COMMIT" \
        --arg workflowRef "$WORKFLOW_REF" \
        --argjson assets "[$entries]" \
        '{mode:$mode, tag:$tag, tagCommit:$tagCommit,
          candidateId:$candidateId, manifestSha256:$manifestSha,
          artifactId:$artifactId, artifactDigest:$artifactDigest,
          sourceCommit:$sourceCommit, workflowCommit:$workflowCommit,
          workflowRef:$workflowRef, assets:$assets}' > "$DIR/promotion-plan.json"
}

verify_bundle()
{
    [ "$FIXTURE" = "yes" ] && return 0
    [ -n "$BUNDLE" ] || fail "attestation bundle is required"
    require_file "$BUNDLE"
    "$ROOT/scripts/verify-attestations.sh" \
        --candidate-dir "$DIR" --bundle "$BUNDLE" \
        ${TRUSTED_ROOT:+--trusted-root "$TRUSTED_ROOT"}
}

if [ "$QUALIFICATION" = "yes" ]; then
    [ "$DRY_RUN" = "yes" ] || fail "--qualification requires --dry-run"
    [ "$NON_RELEASE" = "true" ] ||
        fail "--qualification is only for nonRelease candidates"
    [ -n "$TAG" ] || TAG=$(manifest_get "$MANIFEST" '.project.releaseTag')
    is_release_tag "$TAG" || fail "invalid release tag: $TAG"
    is_sha256 "$MANIFEST_SHA" || fail "invalid manifest SHA-256"
    if [ -n "$ARTIFACT_ID" ]; then
        printf '%s' "$ARTIFACT_ID" | grep -Eq '^[0-9]+$' ||
            fail "invalid artifact ID"
    fi
    if [ -n "$ARTIFACT_DIGEST" ]; then
        is_digest "$ARTIFACT_DIGEST" || fail "invalid artifact digest"
    fi
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$DIR"
    verify_bundle
    write_plan "qualification-dry-run" "$TAG" ""
    echo "Qualification dry-run: PASS"
    echo "Candidate ID:          $CANDIDATE_ID"
    echo "Manifest SHA-256:      $MANIFEST_SHA"
    echo "Plan:                  $DIR/promotion-plan.json"
    exit 0
fi

if [ -z "$TAG" ] || [ -z "$SOURCE_ROOT" ]; then
    usage >&2
    exit 2
fi
require_dir "$SOURCE_ROOT"
is_release_tag "$TAG" || fail "invalid release tag: $TAG"
is_sha256 "$MANIFEST_SHA" || fail "invalid manifest SHA-256"
if [ "$FIXTURE" = "no" ]; then
    [ "$NON_RELEASE" = "false" ] ||
        fail "refusing to promote a nonRelease candidate"
    [ -n "$ARTIFACT_ID" ] || fail "--artifact-id is required"
    is_digest "$ARTIFACT_DIGEST" || fail "--artifact-digest must be sha256:<hex>"
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$DIR" \
        --source-root "$SOURCE_ROOT" --rev "$SOURCE_COMMIT" --production
else
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$DIR" \
        --source-root "$SOURCE_ROOT" --rev "$SOURCE_COMMIT"
fi

TAG_COMMIT=$(git -C "$SOURCE_ROOT" rev-parse --verify --quiet "${TAG}^{commit}") ||
    fail "tag $TAG is absent from the source checkout"
if [ -n "$EXPECTED_TAG_COMMIT" ]; then
    [ "$TAG_COMMIT" = "$EXPECTED_TAG_COMMIT" ] ||
        fail "tag commit $TAG_COMMIT != expected $EXPECTED_TAG_COMMIT"
fi
git -C "$SOURCE_ROOT" merge-base --is-ancestor "$SOURCE_COMMIT" "$TAG_COMMIT" ||
    fail "candidate source commit $SOURCE_COMMIT is not an ancestor of tag commit $TAG_COMMIT"
A_PACKAGING=$("$ROOT/scripts/packaging-inputs.sh" --repo "$SOURCE_ROOT" --rev "$SOURCE_COMMIT")
B_PACKAGING=$("$ROOT/scripts/packaging-inputs.sh" --repo "$SOURCE_ROOT" --rev "$TAG_COMMIT")
[ "$A_PACKAGING" = "$B_PACKAGING" ] ||
    fail "tag commit B changes packaging inputs; rebuild a new candidate"
"$ROOT/scripts/update-release-pins.sh" --candidate "$MANIFEST" \
    --repo "$SOURCE_ROOT" --check >/dev/null ||
    fail "tagged install.sh/SHA256SUMS do not match the candidate"

verify_bundle

if [ -n "$PREFLIGHT_FILE" ]; then
    require_file "$PREFLIGHT_FILE" ||
        fail "preflight file not found: $PREFLIGHT_FILE"
    for check in \
        '.candidateId == "'"$CANDIDATE_ID"'"' \
        '.manifestSha256 == "'"$MANIFEST_SHA"'"' \
        '.artifactId == "'"$ARTIFACT_ID"'"' \
        '.artifactDigest == "'"$ARTIFACT_DIGEST"'"' \
        '.sourceCommit == "'"$SOURCE_COMMIT"'"' \
        '.workflowCommit == "'"$WORKFLOW_COMMIT"'"' \
        '.tag == "'"$TAG"'"' \
        '.tagCommit == "'"$TAG_COMMIT"'"'; do
        jq -e "$check" "$PREFLIGHT_FILE" >/dev/null ||
            fail "preflight verification does not match: $check"
    done
fi

write_plan "dry-run" "$TAG" "$TAG_COMMIT"

if [ "$PREFLIGHT" = "yes" ]; then
    [ "$DRY_RUN" = "yes" ] || fail "--preflight requires --dry-run"
    verification=$DIR/promotion-verification.json
    jq -n \
        --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg candidateId "$CANDIDATE_ID" \
        --arg manifestSha "$MANIFEST_SHA" \
        --arg artifactId "$ARTIFACT_ID" \
        --arg artifactDigest "$ARTIFACT_DIGEST" \
        --arg sourceCommit "$SOURCE_COMMIT" \
        --arg workflowCommit "$WORKFLOW_COMMIT" \
        --arg workflowRef "$WORKFLOW_REF" \
        --arg tag "$TAG" \
        --arg tagCommit "$TAG_COMMIT" \
        --arg bundleSha "$( [ -n "$BUNDLE" ] && sha256_file "$BUNDLE" || true )" \
        --slurpfile plan "$DIR/promotion-plan.json" \
        '{schemaVersion:1, createdAt:$createdAt, candidateId:$candidateId,
          manifestSha256:$manifestSha, artifactId:$artifactId,
          artifactDigest:$artifactDigest, sourceCommit:$sourceCommit,
          workflowCommit:$workflowCommit, workflowRef:$workflowRef,
          tag:$tag, tagCommit:$tagCommit,
          attestationBundleSha256:$bundleSha,
          assets:$plan[0].assets}' > "$verification"
fi

if [ "$DRY_RUN" = "yes" ]; then
    echo "Promotion dry-run: PASS"
    echo "Tag:               $TAG"
    echo "Tag commit:        $TAG_COMMIT"
    echo "Candidate ID:      $CANDIDATE_ID"
    echo "Manifest SHA-256:  $MANIFEST_SHA"
    echo "Plan:              $DIR/promotion-plan.json"
    exit 0
fi

[ "$FIXTURE" = "no" ] || fail "--fixture is only valid with --dry-run"
[ -n "$PREFLIGHT_FILE" ] || fail "--preflight-file is required for publication"
artifact_json=$("$GH_BIN" api "repos/$(jq -r '.project.repository' "$POLICY")/actions/artifacts/$ARTIFACT_ID") ||
    fail "cannot read candidate artifact $ARTIFACT_ID"
[ "$(jq -r '.expired' <<<"$artifact_json")" = "false" ] ||
    fail "candidate artifact has expired; abandon the release"
[ "$(jq -r '.digest' <<<"$artifact_json")" = "$ARTIFACT_DIGEST" ] ||
    fail "candidate artifact digest mismatch"

"$ROOT/scripts/check-release-gates.sh" --tag "$TAG" \
    --confirm "${CONFIRM_PUBLISH:-}"

REPO=$(jq -r '.project.repository' "$POLICY")
find_release()
{
    "$GH_BIN" api "repos/$REPO/releases?per_page=100" |
        jq -c --arg t "$TAG" '.[] | select(.tag_name == $t)'
}

release_json=$(find_release)
if [ -z "$release_json" ]; then
    "$GH_BIN" release create "$TAG" --repo "$REPO" --draft \
        --title "$TAG" --notes "Release candidate $CANDIDATE_ID" >/dev/null ||
        fail "cannot create draft release $TAG"
    release_json=$(find_release)
    [ -n "$release_json" ] || fail "draft release $TAG was not created"
fi

release_id=$(jq -r '.id' <<<"$release_json")
is_draft=$(jq -r '.draft' <<<"$release_json")
if [ "$is_draft" = "false" ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-published.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    "$GH_BIN" release download "$TAG" --repo "$REPO" --dir "$tmp" ||
        fail "cannot download published release $TAG"
    "$ROOT/scripts/verify-release.sh" --asset-dir "$tmp" \
        --source-dir "$SOURCE_ROOT" --tag "$TAG" \
        ${TRUSTED_ROOT:+--trusted-root "$TRUSTED_ROOT"} ||
        fail "existing published release does not match the candidate"
    echo "Release $TAG is already published and verified; no mutation performed."
    exit 0
fi

for asset in $ASSETS; do
    remote=$(jq -c --arg n "$asset" '.assets[] | select(.name == $n)' <<<"$release_json")
    if [ -n "$remote" ]; then
        remote_digest=$(jq -r '.digest' <<<"$remote")
        remote_size=$(jq -r '.size' <<<"$remote")
        local_digest="sha256:$(sha256_file "$DIR/$asset")"
        [ "$remote_digest" = "$local_digest" ] ||
            fail "draft asset $asset differs from the candidate; refusing to clobber"
        [ "$remote_size" = "$(stat -c '%s' "$DIR/$asset")" ] ||
            fail "draft asset $asset size differs"
    else
        "$GH_BIN" release upload "$TAG" "$DIR/$asset" --repo "$REPO" ||
            fail "cannot upload $asset"
    fi
done

release_json=$(find_release)
remote_extra=$(jq -r '.assets[].name' <<<"$release_json" |
    LC_ALL=C sort | comm -23 - <(printf '%s\n' "$ASSETS") || true)
[ -z "$remote_extra" ] || fail "draft has unexpected assets: $remote_extra"

DRAFT=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-draft.XXXXXX")
trap 'rm -rf "$DRAFT"' EXIT HUP INT TERM
while IFS=$'\t' read -r asset_id name; do
    "$GH_BIN" api -H 'Accept: application/octet-stream' \
        "repos/$REPO/releases/assets/$asset_id" > "$DRAFT/$name" ||
        fail "cannot download draft asset $name"
done < <(jq -r '.assets[] | [.id, .name] | @tsv' <<<"$release_json")

"$ROOT/scripts/verify-release.sh" --asset-dir "$DRAFT" \
    --source-dir "$SOURCE_ROOT" --tag "$TAG" --draft \
    --bundle "$DRAFT/release-attestation.jsonl" \
    ${TRUSTED_ROOT:+--trusted-root "$TRUSTED_ROOT"} ||
    fail "draft verification failed; refusing publication"

"$GH_BIN" api -X PATCH "repos/$REPO/releases/$release_id" -f draft=false >/dev/null ||
    fail "cannot publish draft release $TAG"

immutable=$("$GH_BIN" api "repos/$REPO/releases/$release_id" --jq '.immutable // false')
[ "$immutable" = "true" ] ||
    fail "release $TAG published but is not immutable; investigate immediately"

echo "Release publication: PASS"
echo "Tag:                 $TAG"
echo "Candidate ID:        $CANDIDATE_ID"
echo "Immutable:           $immutable"
