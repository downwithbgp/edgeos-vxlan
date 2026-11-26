#!/bin/sh
# Validate the packages built from this source tree.
#
# Usage: validate-release.sh [artifact-dir]
#
# The default artifact directory is the parent of the repository, which is
# where dpkg-buildpackage writes the .deb files.  Prerelease builds (`~` in the
# changelog version) skip the install.sh pin cross-check: install.sh keeps the
# hashes of the last published release until the release commit updates them.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACT_DIR=${1:-"$ROOT/.."}
CHANGELOG_VERSION=$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

case "$CHANGELOG_VERSION" in
    *~*)
        [ "${GITHUB_REF_TYPE:-}" != "tag" ] ||
            fail "refusing to validate prerelease $CHANGELOG_VERSION for tag ${GITHUB_REF_NAME:-unknown}"

        echo "NOTE: prerelease $CHANGELOG_VERSION; skipping the install.sh pin check." >&2
        "$ROOT/scripts/validate-artifacts.sh" --build --skip-install-pins \
            "$ARTIFACT_DIR" "$ROOT"
        ;;
    *)
        "$ROOT/scripts/validate-artifacts.sh" --build \
            "$ARTIFACT_DIR" "$ROOT"
        ;;
esac

echo
echo "Release validation: PASS"
