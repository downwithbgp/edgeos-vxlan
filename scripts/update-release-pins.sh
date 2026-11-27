#!/bin/bash
# Render or check install.sh pins and the package-only SHA256SUMS from a
# release candidate manifest.
#
# The installer pins are not packaged, so updating them in the release pin
# commit does not change package bytes. Canonical verification uses the
# manifest as authority; the pins support the legacy one-command install.
#
# Usage:
#   update-release-pins.sh --candidate FILE [--repo DIR] --check|--write
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/release-common.sh"

REPO=$ROOT
MANIFEST=
MODE=

usage()
{
    cat <<'EOF'
Usage: update-release-pins.sh --candidate FILE [--repo DIR] --check|--write

Options:
  --candidate FILE  Release candidate manifest
  --repo DIR        Repository to update (default: this repository)
  --check           Verify the repository matches the candidate pins
  --write           Write the pins
  -h, --help        Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --candidate)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            MANIFEST=$2
            shift 2
            ;;
        --repo)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            REPO=$2
            shift 2
            ;;
        --check)
            MODE="check"
            shift
            ;;
        --write)
            MODE="write"
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

if [ -z "$MANIFEST" ] || [ -z "$MODE" ]; then
    usage >&2
    exit 2
fi
require_file "$MANIFEST"
require_cmd jq sha256sum grep sed awk sort cmp diff
REPO=$(cd "$REPO" && pwd) || fail "cannot resolve repo: $REPO"
require_file "$REPO/install.sh"
require_file "$REPO/SHA256SUMS"

check_candidate_id "$MANIFEST"

TAG=$(manifest_get "$MANIFEST" '.project.releaseTag')
PKG_VERSION=$(manifest_get "$MANIFEST" '.project.packageVersion')
is_release_tag "$TAG" || fail "manifest releaseTag is not a release tag: $TAG"

VERSION=${TAG#v}
INTEGRATION_NAME="edgeos-vxlan_${PKG_VERSION}_all.deb"
KMOD_NAME="edgeos-vxlan-kmod_${PKG_VERSION}_mipsel.deb"

artifact_sha()
{
    jq -er --arg n "$1" '
        [.artifacts[] | select(.name == $n) | .sha256]
        | if length == 1 then .[0] else error("expected exactly one artifact named " + $n) end
    ' "$MANIFEST"
}

INTEGRATION_SHA=$(artifact_sha "$INTEGRATION_NAME") ||
    fail "candidate manifest has no unique $INTEGRATION_NAME"
KMOD_SHA=$(artifact_sha "$KMOD_NAME") ||
    fail "candidate manifest has no unique $KMOD_NAME"
require_sha256_field "integration pin" "$INTEGRATION_SHA"
require_sha256_field "kmod pin" "$KMOD_SHA"

if command -v dpkg-parsechangelog >/dev/null 2>&1 &&
   [ -f "$REPO/debian/changelog" ]; then
    CHANGELOG_VERSION=$(dpkg-parsechangelog -l "$REPO/debian/changelog" -S Version)
    [ "$CHANGELOG_VERSION" = "$PKG_VERSION" ] ||
        fail "changelog version $CHANGELOG_VERSION != candidate package version $PKG_VERSION"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-pins.XXXXXX") ||
    fail "cannot create temporary directory"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

for var in VERSION PKG_VERSION KMOD_SHA256 INTEGRATION_SHA256; do
    count=$(grep -c "^$var=" "$REPO/install.sh" || true)
    [ "$count" -eq 1 ] ||
        fail "expected exactly one $var assignment in install.sh, found $count"
done

sed \
    -e "s|^VERSION=\".*\"$|VERSION=\"$VERSION\"|" \
    -e "s|^PKG_VERSION=\".*\"$|PKG_VERSION=\"$PKG_VERSION\"|" \
    -e "s|^KMOD_SHA256=\".*\"$|KMOD_SHA256=\"$KMOD_SHA\"|" \
    -e "s|^INTEGRATION_SHA256=\".*\"$|INTEGRATION_SHA256=\"$INTEGRATION_SHA\"|" \
    "$REPO/install.sh" > "$TMP/install.sh"

grep -Fx "VERSION=\"$VERSION\"" "$TMP/install.sh" >/dev/null ||
    fail "failed to render VERSION"
grep -Fx "PKG_VERSION=\"$PKG_VERSION\"" "$TMP/install.sh" >/dev/null ||
    fail "failed to render PKG_VERSION"
grep -Fx "KMOD_SHA256=\"$KMOD_SHA\"" "$TMP/install.sh" >/dev/null ||
    fail "failed to render KMOD_SHA256"
grep -Fx "INTEGRATION_SHA256=\"$INTEGRATION_SHA\"" "$TMP/install.sh" >/dev/null ||
    fail "failed to render INTEGRATION_SHA256"

printf '%s  %s\n' "$INTEGRATION_SHA" "$INTEGRATION_NAME" \
    "$KMOD_SHA" "$KMOD_NAME" |
    LC_ALL=C sort -k2 > "$TMP/SHA256SUMS"

if [ "$MODE" = "check" ]; then
    if ! cmp -s "$REPO/install.sh" "$TMP/install.sh"; then
        diff -u "$REPO/install.sh" "$TMP/install.sh" >&2 || true
        fail "install.sh pins do not match the candidate manifest"
    fi
    if ! cmp -s "$REPO/SHA256SUMS" "$TMP/SHA256SUMS"; then
        diff -u "$REPO/SHA256SUMS" "$TMP/SHA256SUMS" >&2 || true
        fail "SHA256SUMS does not match the candidate manifest"
    fi
    echo "Release pins: PASS"
else
    cp "$TMP/install.sh" "$REPO/install.sh"
    cp "$TMP/SHA256SUMS" "$REPO/SHA256SUMS"
    echo "Release pins updated from $MANIFEST"
fi

echo "Tag:         $TAG"
echo "Version:     $PKG_VERSION"
echo "Kmod:        $KMOD_SHA"
echo "Integration: $INTEGRATION_SHA"
