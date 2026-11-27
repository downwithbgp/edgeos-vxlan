#!/bin/bash
# Promote an explicitly identified candidate to a GitHub Release.
#
# Publication never compiles. It verifies the candidate identity, artifact
# hashes, source/tag binding, qualification evidence and attestations, then
# creates or resumes a draft, uploads only missing assets, verifies the draft,
# publishes it, and checks the immutable flag.
#
# Usage:
#   promote-release.sh --candidate-dir DIR --tag TAG --candidate-id ID \
#     --manifest-sha256 SHA --source-root DIR [options]
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
BUNDLE=
TRUSTED_ROOT=
GH_BIN=${GH_BIN:-gh}

usage()
{
    cat <<'EOF'
Usage: promote-release.sh --candidate-dir DIR --tag TAG --candidate-id ID \
       --manifest-sha256 SHA --source-root DIR [options]

Options:
  --candidate-dir DIR    Downloaded candidate artifact
  --tag TAG              Release tag
  --candidate-id ID      Expected candidate ID
  --manifest-sha256 SHA  Expected manifest SHA-256
  --artifact-id ID       GitHub Actions artifact ID (required for real publish)
  --artifact-digest SHA  GitHub Actions artifact ZIP digest (sha256:...)
  --source-root DIR      Tagged source checkout (with Git history)
  --dry-run              Verify and print the publication plan only
  --fixture              Local test mode; no GitHub API, attestation or gates
  --bundle FILE          Attestation bundle (default: candidate file)
  --trusted-root FILE    Optional custom Sigstore trusted root
  -h, --help             Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --candidate-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            DIR=$2
            shift 2
            ;;
        --tag)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            TAG=$2
            shift 2
            ;;
        --candidate-id)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            CANDIDATE_ID=$2
            shift 2
            ;;
        --manifest-sha256)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            MANIFEST_SHA=$2
            shift 2
            ;;
        --artifact-id)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            ARTIFACT_ID=$2
            shift 2
            ;;
        --artifact-digest)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            ARTIFACT_DIGEST=$2
            shift 2
            ;;
        --source-root)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_ROOT=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=yes
            shift
            ;;
        --fixture)
            FIXTURE=yes
            shift
            ;;
        --bundle)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            BUNDLE=$2
            shift 2
            ;;
        --trusted-root)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            TRUSTED_ROOT=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$DIR" ] || [ -z "$TAG" ] || [ -z "$CANDIDATE_ID" ] ||
   [ -z "$MANIFEST_SHA" ] || [ -z "$SOURCE_ROOT" ]; then
    usage >&2
    exit 2
fi
require_dir "$DIR"
require_file "$DIR/release-candidate.json"
require_file "$POLICY"
require_cmd jq git sha256sum find sort awk sed cmp
is_release_tag "$TAG" || fail "invalid release tag: $TAG"
is_candidate_id "$CANDIDATE_ID" || fail "invalid candidate ID: $CANDIDATE_ID"
is_sha256 "$MANIFEST_SHA" || fail "invalid manifest SHA-256: $MANIFEST_SHA"

MANIFEST=$DIR/release-candidate.json
check_manifest_sha256 "$MANIFEST" "$MANIFEST_SHA"
check_candidate_id "$MANIFEST"
actual_id=$(manifest_get "$MANIFEST" '.candidate.id')
[ "$actual_id" = "$CANDIDATE_ID" ] ||
    fail "candidate ID $actual_id != requested $CANDIDATE_ID"

if [ "$FIXTURE" = "no" ]; then
    [ "$(manifest_get "$MANIFEST" '.candidate.nonRelease')" = "false" ] ||
        fail "refusing to promote a nonRelease candidate"
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$DIR" \
        --source-root "$SOURCE_ROOT" --rev "$(manifest_get "$MANIFEST" '.source.commit')" \
        --production
else
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$DIR" \
        --source-root "$SOURCE_ROOT" --rev "$(manifest_get "$MANIFEST" '.source.commit')"
fi

SOURCE_COMMIT=$(manifest_get "$MANIFEST" '.source.commit')
TAG_COMMIT=$(git -C "$SOURCE_ROOT" rev-parse --verify --quiet "${TAG}^{commit}") ||
    fail "tag $TAG is absent from the source checkout"
git -C "$SOURCE_ROOT" merge-base --is-ancestor "$SOURCE_COMMIT" "$TAG_COMMIT" ||
    fail "source commit $SOURCE_COMMIT is not an ancestor of tag $TAG"
A_PACKAGING=$("$ROOT/scripts/packaging-inputs.sh" --repo "$SOURCE_ROOT" --rev "$SOURCE_COMMIT")
B_PACKAGING=$("$ROOT/scripts/packaging-inputs.sh" --repo "$SOURCE_ROOT" --rev "$TAG_COMMIT")
[ "$A_PACKAGING" = "$B_PACKAGING" ] ||
    fail "tag commit B changes packaging inputs; rebuild a new candidate"
"$ROOT/scripts/update-release-pins.sh" --candidate "$MANIFEST" \
    --repo "$SOURCE_ROOT" --check >/dev/null ||
    fail "tagged install.sh/SHA256SUMS do not match the candidate"

if [ -z "$BUNDLE" ] && [ -f "$DIR/release-attestation.jsonl" ]; then
    BUNDLE=$DIR/release-attestation.jsonl
fi
if [ "$FIXTURE" = "no" ]; then
    [ -n "$BUNDLE" ] || fail "candidate has no release-attestation.jsonl"
    "$ROOT/scripts/verify-attestations.sh" --candidate-dir "$DIR" \
        --bundle "$BUNDLE" ${TRUSTED_ROOT:+--trusted-root "$TRUSTED_ROOT"}
fi

REPO=$(jq -r '.project.repository' "$POLICY")

ASSETS=$(find "$DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' |
    grep -Fvx 'source.tar' | LC_ALL=C sort)

if [ "$DRY_RUN" = "yes" ]; then
    plan=$DIR/promotion-plan.json
    jq -n --arg tag "$TAG" --arg candidateId "$CANDIDATE_ID" \
        --arg manifestSha "$MANIFEST_SHA" --arg tagCommit "$TAG_COMMIT" \
        --arg artifacts "$ASSETS" \
        '{mode:"dry-run", tag:$tag, candidateId:$candidateId,
          manifestSha256:$manifestSha, tagCommit:$tagCommit,
          assets:($artifacts|split("\n")|map(select(length>0)))}' > "$plan"
    echo "Promotion dry-run: PASS"
    echo "Tag:               $TAG"
    echo "Candidate ID:      $CANDIDATE_ID"
    echo "Manifest SHA-256:  $MANIFEST_SHA"
    echo "Would upload:"
    printf '%s\n' "$ASSETS" | sed 's/^/  - /'
    echo "Plan:              $plan"
    exit 0
fi

[ "$FIXTURE" = "no" ] || fail "--fixture is only valid with --dry-run"
[ -n "$ARTIFACT_ID" ] || fail "--artifact-id is required for publication"
is_sha256 "$ARTIFACT_DIGEST" || fail "--artifact-digest must be sha256:<hex>"
artifact_json=$("$GH_BIN" api "repos/$REPO/actions/artifacts/$ARTIFACT_ID") ||
    fail "cannot read candidate artifact $ARTIFACT_ID"
[ "$(jq -r '.expired' <<<"$artifact_json")" = "false" ] ||
    fail "candidate artifact has expired; abandon the release and build a new version"
[ "$(jq -r '.digest' <<<"$artifact_json")" = "$ARTIFACT_DIGEST" ] ||
    fail "candidate artifact digest mismatch"

"$ROOT/scripts/check-release-gates.sh" --tag "$TAG" \
    --confirm "${CONFIRM_PUBLISH:-}"

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

# Compare and upload draft assets.
for asset in $ASSETS; do
    remote=$(jq -c --arg n "$asset" '.assets[] | select(.name == $n)' <<<"$release_json")
    if [ -n "$remote" ]; then
        remote_digest=$(jq -r '.digest' <<<"$remote")
        remote_size=$(jq -r '.size' <<<"$remote")
        local_digest="sha256:$(sha256_file "$DIR/$asset")"
        [ "$remote_digest" = "$local_digest" ] ||
            fail "draft asset $asset differs from the candidate; refusing to clobber"
        [ "$remote_size" = "$(stat -c '%s' "$DIR/$asset")" ] ||
            fail "draft asset $asset size differs from the candidate"
    else
        "$GH_BIN" release upload "$TAG" "$DIR/$asset" --repo "$REPO" ||
            fail "cannot upload $asset"
    fi
done

release_json=$(find_release)
remote_extra=$(jq -r '.assets[].name' <<<"$release_json" |
    LC_ALL=C sort |
    comm -23 - <(printf '%s\n' "$ASSETS") || true)
[ -z "$remote_extra" ] ||
    fail "draft has unexpected assets: $remote_extra"

# Download the draft by asset ID (GET /releases/tags does not return drafts).
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
