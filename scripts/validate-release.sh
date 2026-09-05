#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

VERSION=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' install.sh)
INSTALLER_PKG_VERSION=$(sed -n 's/^PKG_VERSION="\([^"]*\)"/\1/p' install.sh)
CHANGELOG_VERSION=$(dpkg-parsechangelog -S Version)

[ -n "$VERSION" ] || fail "could not read VERSION from install.sh"
[ -n "$INSTALLER_PKG_VERSION" ] || fail "could not read PKG_VERSION from install.sh"

[ "$INSTALLER_PKG_VERSION" = "$CHANGELOG_VERSION" ] ||
    fail "install.sh PKG_VERSION ($INSTALLER_PKG_VERSION) != changelog ($CHANGELOG_VERSION)"

case "$CHANGELOG_VERSION" in
    "$VERSION"+edgeos3.0.1.e50) ;;
    *) fail "package version $CHANGELOG_VERSION does not match release version $VERSION" ;;
esac

KMOD="../edgeos-vxlan-kmod_${CHANGELOG_VERSION}_mipsel.deb"
INTEGRATION="../edgeos-vxlan_${CHANGELOG_VERSION}_all.deb"

[ -f "$KMOD" ] || fail "missing $KMOD"
[ -f "$INTEGRATION" ] || fail "missing $INTEGRATION"

[ "$(dpkg-deb -f "$KMOD" Version)" = "$CHANGELOG_VERSION" ] ||
    fail "kmod package version mismatch"

[ "$(dpkg-deb -f "$KMOD" Architecture)" = "mipsel" ] ||
    fail "kmod architecture is not mipsel"

[ "$(dpkg-deb -f "$INTEGRATION" Version)" = "$CHANGELOG_VERSION" ] ||
    fail "integration package version mismatch"

[ "$(dpkg-deb -f "$INTEGRATION" Architecture)" = "all" ] ||
    fail "integration architecture is not all"

ACTUAL_KMOD_SHA=$(sha256sum "$KMOD" | awk '{print $1}')
ACTUAL_INTEGRATION_SHA=$(sha256sum "$INTEGRATION" | awk '{print $1}')

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

dpkg-deb -x "$KMOD" "$TMP/kmod"

VXLAN="$TMP/kmod/lib/modules/4.14.54-UBNT/extra/vxlan.ko"
UDP="$TMP/kmod/lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko"

[ -f "$VXLAN" ] || fail "vxlan.ko missing from kmod package"
[ -f "$UDP" ] || fail "udp_tunnel.ko missing from kmod package"

EXPECTED_VXLAN_SHA="7c346342bf00202820e8581bfdfc28851add052d2b0e5dde1560819f90bf82b6"
EXPECTED_UDP_SHA="6d58ee597d8ae50898efe90ec61a4803ae4f0549f29fba9c4132ca92260405cc"

[ "$(sha256sum "$VXLAN" | awk '{print $1}')" = "$EXPECTED_VXLAN_SHA" ] ||
    fail "packaged vxlan.ko hash mismatch"

[ "$(sha256sum "$UDP" | awk '{print $1}')" = "$EXPECTED_UDP_SHA" ] ||
    fail "packaged udp_tunnel.ko hash mismatch"

if [ -n "${GITHUB_REF_TYPE:-}" ] && [ "$GITHUB_REF_TYPE" = "tag" ]; then
    TAG_VERSION=${GITHUB_REF_NAME#v}

    [ "$GITHUB_REF_NAME" = "v$VERSION" ] ||
        fail "tag $GITHUB_REF_NAME does not match VERSION=$VERSION"

    [ "$TAG_VERSION" = "$VERSION" ] ||
        fail "tag version does not match installer version"
fi

echo
echo "Release validation: PASS"
echo "Version:             $VERSION"
echo "Package version:     $CHANGELOG_VERSION"
echo "Kmod SHA256:         $ACTUAL_KMOD_SHA"
echo "Integration SHA256:  $ACTUAL_INTEGRATION_SHA"
