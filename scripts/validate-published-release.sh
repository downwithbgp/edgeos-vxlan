#!/bin/sh
set -eu

CI_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASSET_DIR=${1:-.}
SOURCE_ROOT=${2:-$CI_ROOT}

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

VERSION=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$SOURCE_ROOT/install.sh")
PKG_VERSION=$(sed -n 's/^PKG_VERSION="\([^"]*\)"/\1/p' "$SOURCE_ROOT/install.sh")

EXPECTED_KMOD_SHA=$(
    sed -n 's/^KMOD_SHA256="\([^"]*\)"/\1/p' "$SOURCE_ROOT/install.sh"
)

EXPECTED_INTEGRATION_SHA=$(
    sed -n 's/^INTEGRATION_SHA256="\([^"]*\)"/\1/p' "$SOURCE_ROOT/install.sh"
)

KMOD="edgeos-vxlan-kmod_${PKG_VERSION}_mipsel.deb"
INTEGRATION="edgeos-vxlan_${PKG_VERSION}_all.deb"

[ -f "$ASSET_DIR/$KMOD" ] ||
    fail "missing published $KMOD"

[ -f "$ASSET_DIR/$INTEGRATION" ] ||
    fail "missing published $INTEGRATION"

[ -f "$ASSET_DIR/SHA256SUMS" ] ||
    fail "missing published SHA256SUMS"

ACTUAL_KMOD_SHA=$(
    sha256sum "$ASSET_DIR/$KMOD" | awk '{print $1}'
)

ACTUAL_INTEGRATION_SHA=$(
    sha256sum "$ASSET_DIR/$INTEGRATION" | awk '{print $1}'
)

[ "$EXPECTED_KMOD_SHA" = "$ACTUAL_KMOD_SHA" ] ||
    fail "published kmod SHA256 does not match install.sh"

[ "$EXPECTED_INTEGRATION_SHA" = "$ACTUAL_INTEGRATION_SHA" ] ||
    fail "published integration SHA256 does not match install.sh"

grep -Fx "$EXPECTED_KMOD_SHA  $KMOD" "$ASSET_DIR/SHA256SUMS" >/dev/null ||
    fail "kmod hash missing or incorrect in published SHA256SUMS"

grep -Fx "$EXPECTED_INTEGRATION_SHA  $INTEGRATION" "$ASSET_DIR/SHA256SUMS" >/dev/null ||
    fail "integration hash missing or incorrect in published SHA256SUMS"

cmp "$SOURCE_ROOT/SHA256SUMS" "$ASSET_DIR/SHA256SUMS" ||
    fail "published SHA256SUMS differs from tagged repository"

[ "$(dpkg-deb -f "$ASSET_DIR/$KMOD" Version)" = "$PKG_VERSION" ] ||
    fail "published kmod package version mismatch"

[ "$(dpkg-deb -f "$ASSET_DIR/$KMOD" Architecture)" = "mipsel" ] ||
    fail "published kmod architecture mismatch"

[ "$(dpkg-deb -f "$ASSET_DIR/$INTEGRATION" Version)" = "$PKG_VERSION" ] ||
    fail "published integration package version mismatch"

[ "$(dpkg-deb -f "$ASSET_DIR/$INTEGRATION" Architecture)" = "all" ] ||
    fail "published integration architecture mismatch"

echo
echo "Published release validation: PASS"
echo "Release:             v$VERSION"
echo "Package version:     $PKG_VERSION"
echo "Kmod SHA256:         $ACTUAL_KMOD_SHA"
echo "Integration SHA256:  $ACTUAL_INTEGRATION_SHA"
