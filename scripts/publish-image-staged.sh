#!/bin/bash
# Stage a qualified OCI image and promote only the verified digest.
#
# Permanent registry publication is not authorised. This script defines the
# staged boundary that a future activation must use, and it is exercised only
# against a mocked CLI in the test suite: it never touches a real registry here.
#
# Order of operations (the order is the control):
#   1. Resolve the qualified manifest digest from the qualification evidence.
#   2. Refuse to replace an existing target tag whose digest differs.
#   3. If the target already resolves to the qualified digest, succeed without
#      pushing anything (idempotent retry).
#   4. Push the archive under a candidate-specific *staging* tag.
#   5. Verify the remotely stored staging digest contains the qualified
#      manifest. Never promote an unverified push.
#   6. Promote exactly the verified staging digest to the approved target tag.
#   7. Re-read the target digest and require it to match what was promoted.
#   8. Delete the staging tag.
#
# Interrupted publication: the staging tag is the recovery marker. A re-run
# re-pushes it and continues; a run that fails between push and promote leaves
# only the staging tag, which the next run overwrites or deletes. If the target
# tag exists but does not match the qualified digest the run stops and never
# replaces it, so a partially promoted tag can only be removed deliberately by
# a maintainer.
#
# Usage:
#   publish-image-staged.sh --oci-archive FILE --qualification FILE \
#     --image REGISTRY/REPO --staging-tag TAG --target-tag TAG [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

ARCHIVE=
QUALIFICATION=
IMAGE=
STAGING_TAG=
TARGET_TAG=
CRANE_BIN=${CRANE_BIN:-crane}
DIGEST_OUT=
DRY_RUN=no

usage()
{
    cat <<'EOF'
Usage: publish-image-staged.sh --oci-archive FILE --qualification FILE \
         --image REGISTRY/REPO --staging-tag TAG --target-tag TAG [options]

Options:
  --oci-archive FILE    Qualified OCI archive to push
  --qualification FILE  build-environment-qualification.json
  --image REGISTRY/REPO Image name without a tag
  --staging-tag TAG     Candidate-specific temporary tag
  --target-tag TAG      Approved operational tag
  --crane PATH          crane binary (default: crane)
  --digest-out FILE     Write the published digest to FILE
  --dry-run             Print the plan; perform no registry mutation
  -h, --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --oci-archive)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            ARCHIVE=$2
            shift 2
            ;;
        --qualification)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            QUALIFICATION=$2
            shift 2
            ;;
        --image)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            IMAGE=$2
            shift 2
            ;;
        --staging-tag)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            STAGING_TAG=$2
            shift 2
            ;;
        --target-tag)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            TARGET_TAG=$2
            shift 2
            ;;
        --crane)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            CRANE_BIN=$2
            shift 2
            ;;
        --digest-out)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            DIGEST_OUT=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=yes
            shift
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

[ -n "$ARCHIVE" ] && [ -n "$QUALIFICATION" ] && [ -n "$IMAGE" ] &&
    [ -n "$STAGING_TAG" ] && [ -n "$TARGET_TAG" ] || { usage >&2; exit 2; }
require_file "$QUALIFICATION"
printf '%s' "$IMAGE" | grep -Eq '^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$' ||
    fail "invalid image name: $IMAGE"
printf '%s' "$STAGING_TAG" | grep -Eq '^[A-Za-z0-9._-]+$' ||
    fail "invalid staging tag: $STAGING_TAG"
printf '%s' "$TARGET_TAG" | grep -Eq '^[A-Za-z0-9._-]+$' ||
    fail "invalid target tag: $TARGET_TAG"
[ "$STAGING_TAG" != "$TARGET_TAG" ] ||
    fail "staging and target tag must differ"
command -v "$CRANE_BIN" >/dev/null 2>&1 || fail "crane not found: $CRANE_BIN"

QUALIFIED=$(jq -er '.manifestDigest' "$QUALIFICATION") ||
    fail "qualification has no manifestDigest"
is_digest "$QUALIFIED" || fail "qualified manifestDigest is not a digest: $QUALIFIED"

if [ ! -f "$ARCHIVE" ] && [ "$DRY_RUN" = "no" ]; then
    fail "OCI archive not found: $ARCHIVE"
fi

STAGING_REF="$IMAGE:$STAGING_TAG"
TARGET_REF="$IMAGE:$TARGET_TAG"

# The staging tag must never survive a failure that prevented promotion.
cleanup_staging()
{
    "$CRANE_BIN" delete "$STAGING_REF" >/dev/null 2>&1 || true
}

if [ "$DRY_RUN" = "yes" ]; then
    echo "Image staging: DRY-RUN"
    echo "Image:         $IMAGE"
    echo "Qualified:     $QUALIFIED"
    echo "Staging tag:   $STAGING_TAG"
    echo "Target tag:    $TARGET_TAG"
    echo "Plan: push -> verify staging -> copy verified digest -> verify target -> delete staging"
    exit 0
fi

# 1. Never replace a target tag that points somewhere else.
EXISTING=$("$CRANE_BIN" digest "$TARGET_REF" 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
    if [ "$EXISTING" = "$QUALIFIED" ]; then
        echo "Image staging: PASS (already published)"
        echo "Target:        $TARGET_REF"
        echo "Digest:        $EXISTING"
        [ -z "$DIGEST_OUT" ] || printf '%s\n' "$EXISTING" > "$DIGEST_OUT"
        exit 0
    fi
    fail "refusing to replace $TARGET_REF: it resolves to $EXISTING, not the qualified $QUALIFIED"
fi

# 2. Push under the candidate-specific staging tag.
trap cleanup_staging EXIT HUP INT TERM
"$CRANE_BIN" push "$ARCHIVE" "$STAGING_REF" >/dev/null ||
    fail "cannot push $ARCHIVE to $STAGING_REF"

# 3. Verify what the registry actually stored before promoting anything.
REMOTE=$("$CRANE_BIN" digest "$STAGING_REF" 2>/dev/null) ||
    fail "cannot read the staging digest for $STAGING_REF"
is_digest "$REMOTE" || fail "staging digest is not a digest: $REMOTE"
if [ "$REMOTE" != "$QUALIFIED" ]; then
    # An index whose entries include the qualified manifest is acceptable.
    "$CRANE_BIN" manifest "$STAGING_REF" 2>/dev/null |
        jq -e --arg d "$QUALIFIED" '[.manifests[]?.digest] | index($d)' >/dev/null ||
        fail "staged image $REMOTE does not contain the qualified manifest $QUALIFIED"
fi

# 4. Promote exactly the verified digest, then re-read the target.
"$CRANE_BIN" copy "$IMAGE@$REMOTE" "$TARGET_REF" >/dev/null ||
    fail "cannot promote $REMOTE to $TARGET_REF"
PROMOTED=$("$CRANE_BIN" digest "$TARGET_REF" 2>/dev/null) ||
    fail "cannot read the promoted digest for $TARGET_REF"
[ "$PROMOTED" = "$REMOTE" ] ||
    fail "promoted digest $PROMOTED does not match the verified $REMOTE"

# 5. Success: remove the staging marker.
trap - EXIT HUP INT TERM
cleanup_staging

echo "Image staging: PASS"
echo "Image:         $IMAGE"
echo "Qualified:     $QUALIFIED"
echo "Published as:  $TARGET_REF"
echo "Digest:        $PROMOTED"
[ -z "$DIGEST_OUT" ] || printf '%s\n' "$PROMOTED" > "$DIGEST_OUT"
