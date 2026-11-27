#!/bin/sh
# Independently validate the assets distributed through a GitHub Release.
#
# Usage:
#   RELEASE_TAG=v0.2.2 validate-published-release.sh <asset-dir> <tagged-source>
#
# Trust model:
#   * The validation logic executing here is current trusted CI code.
#   * The expected version, checksums and SHA256SUMS come from the tagged
#     source tree (second argument), treated as read-only data.
#   * The artifacts are the files downloaded from the GitHub Release (first
#     argument).
#
# The tagged source is never built or executed.  Downloaded packages are
# inspected with dpkg-deb, readelf, modinfo, sha256sum and cmp only; their
# maintainer scripts are syntax-checked, not run.
#
# This supports historical releases: the tagged tree does not need to contain
# this validator.  For tags that predate the committed SHA256SUMS file, the
# published manifest is checked against the tagged install.sh pins instead.
# RELEASE_TAG is optional when the version is unambiguous.

set -eu

CI_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ASSET_DIR=${1:-}
SOURCE_ROOT=${2:-}
RELEASE_TAG=${RELEASE_TAG:-}

if [ -z "$ASSET_DIR" ] || [ -z "$SOURCE_ROOT" ]; then
    echo "ERROR: usage: $0 <asset-dir> <tagged-source>" >&2
    exit 2
fi

if [ ! -d "$ASSET_DIR" ]; then
    echo "ERROR: asset directory not found: $ASSET_DIR" >&2
    exit 1
fi

if [ ! -f "$SOURCE_ROOT/install.sh" ]; then
    echo "ERROR: tagged source not found: $SOURCE_ROOT" >&2
    exit 1
fi

if [ -n "$RELEASE_TAG" ]; then
    "$CI_ROOT/scripts/validate-artifacts.sh" --published --tag "$RELEASE_TAG" \
        "$ASSET_DIR" "$SOURCE_ROOT"
else
    "$CI_ROOT/scripts/validate-artifacts.sh" --published \
        "$ASSET_DIR" "$SOURCE_ROOT"
fi

echo
echo "Published release validation: PASS"
