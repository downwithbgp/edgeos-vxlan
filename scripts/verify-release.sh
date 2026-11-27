#!/bin/bash
# Independently verify a downloaded GitHub Release.
#
# Classifies the release using Debian version ordering:
#   * legacy    — below canonicalFrom, no candidate manifest
#   * canonical — manifest present or version >= canonicalFrom; requires
#                 manifest, SBOM, metadata, complete assets and attestation
#   * immutable — canonical plus the release API immutable flag
#
# The verifier always inspects downloaded release assets, never local build
# output. --draft skips published/immutable checks. --fixture is local-only and
# refuses a tag that exists on GitHub.
#
# Usage:
#   verify-release.sh --asset-dir DIR --source-dir DIR --tag TAG [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

ASSET_DIR=
SOURCE_DIR=
TAG=
POLICY=$ROOT/release/release-policy.json
DRAFT=no
FIXTURE=no
BUNDLE=
TRUSTED_ROOT=
GH_BIN=${GH_BIN:-gh}

usage()
{
    cat <<'EOF'
Usage: verify-release.sh --asset-dir DIR --source-dir DIR --tag TAG [options]

Options:
  --asset-dir DIR     Downloaded release assets
  --source-dir DIR    Tagged source tree (with Git history/tag)
  --tag TAG           Release tag (vMAJOR.MINOR.PATCH)
  --policy FILE       Release policy (default: release/release-policy.json)
  --draft             Verify a draft (skip published/immutable checks)
  --fixture           Local test fixture; refuses a tag that exists on GitHub
  --bundle FILE       Attestation bundle (default: <asset-dir>/release-attestation.jsonl)
  --trusted-root FILE Optional custom Sigstore trusted root
  -h, --help          Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --asset-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            ASSET_DIR=$2
            shift 2
            ;;
        --source-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_DIR=$2
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
        --draft)
            DRAFT=yes
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

if [ -z "$ASSET_DIR" ] || [ -z "$SOURCE_DIR" ] || [ -z "$TAG" ]; then
    usage >&2
    exit 2
fi
require_dir "$ASSET_DIR"
require_dir "$SOURCE_DIR"
require_file "$POLICY"
require_file "$SOURCE_DIR/install.sh"
require_cmd jq git sha256sum find sort awk sed cmp
is_release_tag "$TAG" || fail "invalid release tag: $TAG"

VERSION=${TAG#v}
CANONICAL_FROM=$(jq -r '.release.canonicalFrom' "$POLICY")
IMMUTABLE_FROM=$(jq -r '.release.immutableFrom' "$POLICY")
REPO=$(jq -r '.project.repository' "$POLICY")

is_canonical=no
if [ -f "$ASSET_DIR/release-candidate.json" ]; then
    is_canonical=yes
elif dpkg --compare-versions "$VERSION" ge "$CANONICAL_FROM"; then
    fail "canonical release $TAG is missing release-candidate.json"
else
    is_canonical=no
fi

if [ "$FIXTURE" = "yes" ]; then
    [ -d "$ASSET_DIR" ] || fail "fixture requires an explicit asset directory"
    if "$GH_BIN" api "repos/$REPO/releases/tags/$TAG" >/dev/null 2>&1; then
        fail "fixture tag $TAG resolves on GitHub; refusing local fixture mode"
    fi
fi

if [ "$DRAFT" = "yes" ] && [ "$FIXTURE" = "yes" ]; then
    fail "--draft and --fixture are mutually exclusive"
fi

if [ "$is_canonical" = "no" ]; then
    echo "Release class: legacy"
    RELEASE_TAG=$TAG "$ROOT/scripts/validate-published-release.sh" \
        "$ASSET_DIR" "$SOURCE_DIR"
    echo "Published release verification: PASS (legacy)"
    exit 0
fi

echo "Release class: canonical"
MANIFEST=$ASSET_DIR/release-candidate.json
check_candidate_id "$MANIFEST"

manifest_tag=$(manifest_get "$MANIFEST" '.project.releaseTag')
[ "$manifest_tag" = "$TAG" ] ||
    fail "manifest tag $manifest_tag != requested tag $TAG"
manifest_version=$(manifest_get "$MANIFEST" '.project.packageVersion')
[ "${manifest_version%%+*}" = "$VERSION" ] ||
    fail "manifest package version $manifest_version does not match tag $TAG"

SOURCE_COMMIT=$(manifest_get "$MANIFEST" '.source.commit')
require_commit_field "source commit" "$SOURCE_COMMIT"

# Tag B, ancestry and pin-only contract.
TAG_COMMIT=$(git -C "$SOURCE_DIR" rev-parse --verify --quiet "${TAG}^{commit}") ||
    fail "tag $TAG is not present in the tagged source checkout"
git -C "$SOURCE_DIR" merge-base --is-ancestor "$SOURCE_COMMIT" "$TAG_COMMIT" ||
    fail "candidate source commit $SOURCE_COMMIT is not an ancestor of tag commit $TAG_COMMIT"
A_PACKAGING=$("$ROOT/scripts/packaging-inputs.sh" --repo "$SOURCE_DIR" --rev "$SOURCE_COMMIT") ||
    fail "cannot compute packaging inputs for $SOURCE_COMMIT"
B_PACKAGING=$("$ROOT/scripts/packaging-inputs.sh" --repo "$SOURCE_DIR" --rev "$TAG_COMMIT") ||
    fail "cannot compute packaging inputs for $TAG_COMMIT"
[ "$A_PACKAGING" = "$B_PACKAGING" ] ||
    fail "packaging inputs differ between candidate commit A and tag commit B"
"$ROOT/scripts/update-release-pins.sh" \
    --candidate "$MANIFEST" --repo "$SOURCE_DIR" --check >/dev/null ||
    fail "tagged source pins do not match the candidate manifest"

"$ROOT/scripts/validate-candidate.sh" \
    --candidate-dir "$ASSET_DIR" \
    --source-root "$SOURCE_DIR" \
    --rev "$SOURCE_COMMIT" \
    --release

# Package-only view for the historical artifact validator.
PKG_VIEW=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-release-view.XXXXXX")
trap 'rm -rf "$PKG_VIEW"' EXIT HUP INT TERM
INTEGRATION="edgeos-vxlan_${manifest_version}_all.deb"
KMOD="edgeos-vxlan-kmod_${manifest_version}_mipsel.deb"
BUILDINFO="edgeos-vxlan_${manifest_version}_mipsel.buildinfo"
CHANGES="edgeos-vxlan_${manifest_version}_mipsel.changes"
for name in "$INTEGRATION" "$KMOD" "$BUILDINFO" "$CHANGES" SHA256SUMS; do
    cp "$ASSET_DIR/$name" "$PKG_VIEW/$name"
done
RELEASE_TAG=$TAG "$ROOT/scripts/validate-published-release.sh" \
    "$PKG_VIEW" "$SOURCE_DIR"

# Full canonical asset set.
expected=$(jq -r --arg v "$manifest_version" '
    .release.requiredAssets[] | gsub("\\{packageVersion\\}"; $v)
' "$POLICY" | LC_ALL=C sort)
actual=$(find "$ASSET_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' |
    LC_ALL=C sort)
extra=$(LC_ALL=C comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$expected" |
    grep -v '^build-environment-image.spdx.json$' || true) || true)
missing=$(LC_ALL=C comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$expected") || true)
[ -z "$missing" ] || fail "canonical release is missing assets:
$missing"
[ -z "$extra" ] || fail "canonical release has unexpected assets:
$extra"

for package in "$INTEGRATION" "$KMOD"; do
    python3 "$ROOT/scripts/build-sbom.py" validate \
        --sbom "$ASSET_DIR/sbom-${package%%_*}.spdx.json" \
        --package "$ASSET_DIR/$package" \
        --source-root "$SOURCE_DIR" ||
        fail "SBOM validation failed for $package"
done

python3 "$ROOT/scripts/validate-build-metadata.py" "$ASSET_DIR" "$SOURCE_DIR" ||
    fail "build metadata validation failed"

[ "$(sha256_file "$ASSET_DIR/build-environment-qualification.json")" = \
  "$(manifest_get "$MANIFEST" '.buildEnvironment.qualificationSha256')" ] ||
    fail "environment qualification hash mismatch"

if [ -f "$ASSET_DIR/build-environment-image.spdx.json" ]; then
    [ "$(sha256_file "$ASSET_DIR/build-environment-image.spdx.json")" = \
      "$(manifest_get "$MANIFEST" '.buildEnvironment.imageSbomSha256')" ] ||
        fail "image SBOM hash mismatch"
fi

if [ "$FIXTURE" = "no" ]; then
    [ -n "$BUNDLE" ] || BUNDLE=$ASSET_DIR/release-attestation.jsonl
    require_file "$BUNDLE"
    "$ROOT/scripts/verify-attestations.sh" \
        --candidate-dir "$ASSET_DIR" \
        --bundle "$BUNDLE" \
        ${TRUSTED_ROOT:+--trusted-root "$TRUSTED_ROOT"} ||
        fail "attestation verification failed"
fi

if [ "$DRAFT" = "no" ] && [ "$FIXTURE" = "no" ]; then
    release_json=$("$GH_BIN" api "repos/$REPO/releases/tags/$TAG") ||
        fail "cannot read published release $TAG"
    immutable=$(jq -r '.immutable // false' <<<"$release_json")
    if dpkg --compare-versions "$VERSION" ge "$IMMUTABLE_FROM"; then
        [ "$immutable" = "true" ] ||
            fail "release $TAG is not immutable (required from $IMMUTABLE_FROM)"
    fi
fi

echo "Published release verification: PASS"
echo "Class:             canonical"
echo "Tag:               $TAG"
echo "Candidate ID:      $(manifest_get "$MANIFEST" '.candidate.id')"
echo "Source commit:     $SOURCE_COMMIT"
echo "Tag commit:        $TAG_COMMIT"
echo "Draft:             $DRAFT"
echo "Fixture:           $FIXTURE"
