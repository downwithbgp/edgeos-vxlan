#!/bin/sh
# Capture build-environment metadata for provenance and troubleshooting.
#
# Usage: capture-build-environment.sh <output-file>

set -eu

OUT=${1:?usage: capture-build-environment.sh <output-file>}
mkdir -p "$(dirname -- "$OUT")"

{
    echo "captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "runner_arch=${RUNNER_ARCH:-unknown}"
    echo "runner_os=${RUNNER_OS:-unknown}"
    echo "runner_image_os=${ImageOS:-unknown}"
    echo "runner_image_version=${ImageVersion:-unknown}"
    echo "uname=$(uname -a)"
    echo "dpkg=$(dpkg --version | sed -n '1p')"
    echo "dpkg_deb=$(dpkg-deb --version | sed -n '1p')"
    echo "dpkg_architecture=$(dpkg --print-architecture)"
    echo "source_date_epoch=${SOURCE_DATE_EPOCH:-unset}"
    echo "changelog_date=$(dpkg-parsechangelog -S Date)"
    echo "changelog_timestamp=$(dpkg-parsechangelog -S Timestamp)"

    for package in build-essential debhelper fakeroot dpkg-dev kmod lintian; do
        version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null ||
            echo missing)
        echo "package.$package=$version"
    done

    echo "gcc=$(gcc --version | sed -n '1p')"
    echo "make=$(make --version | sed -n '1p')"
} >"$OUT"
