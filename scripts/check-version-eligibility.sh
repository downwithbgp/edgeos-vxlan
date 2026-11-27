#!/bin/bash
# Decide whether a version may be published now.
#
# Publication eligibility is not the same question as release classification.
# `release.baselinePublishedVersion` classifies historical releases and is a
# coarse floor at candidate construction time; this script answers the current
# question: may this version become the next published stable release?
#
# Sources of truth, all read from the repository rather than assumed:
#   * releases with draft=false and prerelease=false, whose tag is vX.Y.Z,
#     raise the published stable version;
#   * draft releases do not raise it (an interrupted publication may resume);
#   * prereleases do not raise it (they are not stable releases);
#   * tags without a release do not raise it.
#
# Rules:
#   V <  latest published stable  -> reject (version regression)
#   V == latest published stable  -> allow only when the tag already has a
#                                    release (resume, or idempotent
#                                    verification of an already-published one)
#   V >  latest published stable  -> allow
#
# There is no implicit backport exception. A future maintenance-branch
# exception must be added as a separate, explicitly reviewed change; this
# script deliberately has no bypass flag.
#
# Usage:
#   check-version-eligibility.sh --repo OWNER/REPO --tag vX.Y.Z [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

REPO=
TAG=
POLICY=$ROOT/release/release-policy.json
GH_BIN=${GH_BIN:-gh}

usage()
{
    cat <<'EOF'
Usage: check-version-eligibility.sh --repo OWNER/REPO --tag vX.Y.Z [options]

Options:
  --repo OWNER/REPO   Repository whose releases define eligibility
  --tag TAG           Candidate release tag (vMAJOR.MINOR.PATCH)
  --policy FILE       Release policy (default: release/release-policy.json)
  --gh PATH           GitHub CLI binary (default: gh)
  -h, --help          Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            REPO=$2
            shift 2
            ;;
        --tag)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            TAG=$2
            shift 2
            ;;
        --policy)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            POLICY=$2
            shift 2
            ;;
        --gh)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            GH_BIN=$2
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

[ -n "$REPO" ] && [ -n "$TAG" ] || { usage >&2; exit 2; }
require_file "$POLICY"
require_cmd jq dpkg
command -v "$GH_BIN" >/dev/null 2>&1 || fail "GitHub CLI not found: $GH_BIN"
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ||
    fail "invalid repository: $REPO"
is_release_tag "$TAG" || fail "invalid release tag: $TAG"
VERSION=${TAG#v}

# Both endpoints are paginated; gh emits one JSON array per page, so slurp and
# concatenate. A failure here is a hard stop: eligibility must not be guessed.
require_json_array()
{
    [ -n "$2" ] || fail "empty $1 response for $REPO"
    printf '%s' "$2" | jq -e -s 'all(.[]; type == "array")' >/dev/null 2>&1 ||
        fail "unexpected $1 response for $REPO: not a JSON array"
}

RELEASES=$("$GH_BIN" api --paginate "repos/$REPO/releases?per_page=100" 2>/dev/null) ||
    fail "cannot read published releases for $REPO"
require_json_array "releases" "$RELEASES"
TAGS=$("$GH_BIN" api --paginate "repos/$REPO/tags?per_page=100" 2>/dev/null) ||
    fail "cannot read tags for $REPO"
require_json_array "tags" "$TAGS"

BASELINE=$(jq -r '.release.baselinePublishedVersion' "$POLICY")
printf '%s' "$BASELINE" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
    fail "policy baselinePublishedVersion is not a release version: $BASELINE"

# Highest published stable version. Debian comparison semantics, not lexical
# order, so 0.10.0 > 0.9.0.
IGNORED=$(printf '%s' "$RELEASES" | jq -sr '
    [ .[] | .[]?
      | select(.draft == false and .prerelease == false)
      | .tag_name
      | select(type == "string" and (test("^v[0-9]+\\.[0-9]+\\.[0-9]+$") | not))
    ] | .[]' 2>/dev/null || true)
[ -z "$IGNORED" ] ||
    note "published releases with non-release tags are not considered: $(printf '%s' "$IGNORED" | tr '\n' ' ')"

LATEST=$BASELINE
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if dpkg --compare-versions "$candidate" gt "$LATEST"; then
        LATEST=$candidate
    fi
done <<EOF
$(printf '%s' "$RELEASES" | jq -sr '
    [ .[] | .[]?
      | select(.draft == false and .prerelease == false)
      | .tag_name
      | select(type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
      | ltrimstr("v") ] | .[]
')
EOF

TARGET_STATE=$(printf '%s' "$RELEASES" | jq -sr --arg tag "$TAG" '
    [ .[] | .[]? | select(.tag_name == $tag) ]
    | if length == 0 then "none"
      elif any(.[]; .draft == true) then "draft"
      elif any(.[]; .prerelease == true) then "prerelease"
      else "published" end
')
TAG_EXISTS=$(printf '%s' "$TAGS" | jq -sr --arg t "$TAG" '
    [ .[] | .[]? | select(.name == $t) ] | length > 0
')

# V < latest published stable: regression. Never acceptable, regardless of tags.
if dpkg --compare-versions "$VERSION" lt "$LATEST"; then
    fail "version regression: $VERSION is below the newest published stable version $LATEST"
fi

# V == latest published stable: only a resume of that exact tag is eligible.
if dpkg --compare-versions "$VERSION" eq "$LATEST"; then
    # Only a release that already exists may be resumed. A bare tag is not a
    # publication, so reusing the newest published version with a tag alone
    # would be an implicit reuse exception -- reject it.
    [ "$TARGET_STATE" != "none" ] ||
        fail "version reuse: $VERSION is the newest published stable version and tag $TAG has no release"
    note "resuming $TAG at the newest published stable version $LATEST ($TARGET_STATE)"
fi

echo "Version eligibility: PASS"
echo "Tag:                 $TAG"
echo "Version:             $VERSION"
echo "Latest published:    $LATEST"
echo "Target release:      $TARGET_STATE"
echo "Target tag exists:   $TAG_EXISTS"
