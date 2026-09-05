#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

VERSION="0.2.0"
PKG_VERSION="0.2.0+edgeos3.0.1.e50"
REPO="downwithbgp/edgeos-vxlan"

KMOD="edgeos-vxlan-kmod_${PKG_VERSION}_mipsel.deb"
INTEGRATION="edgeos-vxlan_${PKG_VERSION}_all.deb"

KMOD_SHA256="383b219316b7705abe74894c2ab9161e1636834ad5ad289f5981fce585f80307"
INTEGRATION_SHA256="edeea3d7040f587f3dc9fe218e891cbc4afe74e76d4bb410aef5837e4b1d58c3"

BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"

SUPPORTED_FIRMWARE="EdgeRouter.ER-e50.v3.0.1.5862409.*"
SUPPORTED_KERNEL="4.14.54-UBNT"

usage() {
    cat <<EOF
Usage: install.sh [--check] [--help]

Install edgeos-vxlan v${VERSION} on a supported Ubiquiti EdgeRouter X.

Options:
  --check   Check firmware and kernel compatibility without installing
  --help    Show this help
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

check_compatibility() {
    FIRMWARE="$(cat /etc/version 2>/dev/null || true)"
    KERNEL="$(uname -r)"

    echo "edgeos-vxlan v${VERSION}"
    echo
    echo "Detected firmware: ${FIRMWARE:-unknown}"
    echo "Detected kernel:   ${KERNEL}"
    echo

    case "$FIRMWARE" in
        EdgeRouter.ER-e50.v3.0.1.5862409.*)
            ;;
        *)
            echo "Compatibility check: FAILED"
            echo
            echo "Supported firmware:"
            echo "  ${SUPPORTED_FIRMWARE}"
            return 1
            ;;
    esac

    if [ "$KERNEL" != "$SUPPORTED_KERNEL" ]; then
        echo "Compatibility check: FAILED"
        echo
        echo "Required kernel:"
        echo "  ${SUPPORTED_KERNEL}"
        return 1
    fi

    echo "Compatibility check: PASSED"
    return 0
}

MODE="install"

case "${1:-}" in
    "")
        ;;
    --check)
        MODE="check"
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

need_command uname

if ! check_compatibility; then
    exit 1
fi

if [ "$MODE" = "check" ]; then
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    die "Installation must be run as root. Use sudo sh install.sh."
fi

need_command curl
need_command sha256sum
need_command dpkg
need_command mktemp

TMPDIR="$(mktemp -d /tmp/edgeos-vxlan.XXXXXX)"

cleanup() {
    rm -rf "$TMPDIR"
}

trap cleanup EXIT HUP INT TERM

echo
echo "Downloading release assets..."

curl -fL \
    "${BASE_URL}/${KMOD}" \
    -o "${TMPDIR}/${KMOD}"

curl -fL \
    "${BASE_URL}/${INTEGRATION}" \
    -o "${TMPDIR}/${INTEGRATION}"

cd "$TMPDIR"

echo
echo "Verifying SHA-256 checksums..."

printf '%s  %s\n' \
    "$KMOD_SHA256" \
    "$KMOD" |
    sha256sum -c -

printf '%s  %s\n' \
    "$INTEGRATION_SHA256" \
    "$INTEGRATION" |
    sha256sum -c -

echo
echo "Installing kernel module package..."

dpkg -i "$KMOD"

echo
echo "Installing EdgeOS integration package..."

dpkg -i "$INTEGRATION"

echo
echo "Installation complete."
echo
echo "Verify with:"
echo
echo "  lsmod | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)'"
echo
echo
echo "Example configuration:"
echo
echo "  configure"
echo "  set interfaces vxlan vxlan42 vni 42"
echo "  set interfaces vxlan vxlan42 local-ip 192.0.2.1"
echo "  set interfaces vxlan vxlan42 remote-ip 192.0.2.2"
echo "  set interfaces vxlan vxlan42 address 198.51.100.1/30"
echo "  set interfaces vxlan vxlan42 port 4789"
echo "  set interfaces vxlan vxlan42 mtu 1450"
echo "  commit"
echo "  save"
echo "  exit"
