#!/bin/sh
# Validate the packages built from this source tree.
#
# Usage: validate-release.sh [artifact-dir]
#
# The default artifact directory is the parent of the repository, which is
# where dpkg-buildpackage writes the .deb files.  Prerelease builds (`~` in the
# changelog version) skip the install.sh version agreement: install.sh keeps
# the last published version/pins until the release commit updates them.
#
# A stable development version may also be newer than the installer pins: the
# documented release-preparation commit A carries the new changelog version
# while install.sh still pins the published baseline. That state is accepted
# here and remains rejected for tags and published assets.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACT_DIR=${1:-"$ROOT/.."}

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

CHANGELOG_VERSION=$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)
command -v jq >/dev/null 2>&1 || fail "required command not found: jq"
INSTALLER_VERSION=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$ROOT/install.sh")
[ -n "$INSTALLER_VERSION" ] ||
    fail "cannot read VERSION from $ROOT/install.sh"
[ "$(printf '%s\n' "$INSTALLER_VERSION" | wc -l)" -eq 1 ] ||
    fail "expected exactly one VERSION assignment in $ROOT/install.sh"
BASELINE=$(jq -r '.release.baselinePublishedVersion' "$ROOT/release/release-policy.json") ||
    fail "cannot read release.baselinePublishedVersion"
[ -n "$BASELINE" ] && [ "$BASELINE" != "null" ] ||
    fail "release.baselinePublishedVersion is missing"

case "$CHANGELOG_VERSION" in
    *~*)
        [ "${GITHUB_REF_TYPE:-}" != "tag" ] ||
            fail "refusing to validate prerelease $CHANGELOG_VERSION for tag ${GITHUB_REF_NAME:-unknown}"

        echo "NOTE: prerelease $CHANGELOG_VERSION; skipping the install.sh pin check." >&2
        "$ROOT/scripts/validate-artifacts.sh" --build --skip-install-pins \
            "$ARTIFACT_DIR" "$ROOT"
        ;;
    *)
        CHANGELOG_BASE=${CHANGELOG_VERSION%%+*}
        if dpkg --compare-versions "$CHANGELOG_BASE" eq "$INSTALLER_VERSION"; then
            "$ROOT/scripts/validate-artifacts.sh" --build \
                "$ARTIFACT_DIR" "$ROOT"
        elif dpkg --compare-versions "$CHANGELOG_BASE" gt "$INSTALLER_VERSION"; then
            [ "$INSTALLER_VERSION" = "$BASELINE" ] ||
                fail "installer pins $INSTALLER_VERSION, but the published baseline is $BASELINE"
            echo "NOTE: development version $CHANGELOG_BASE; install.sh pins remain at published $INSTALLER_VERSION." >&2
            "$ROOT/scripts/validate-artifacts.sh" --build \
                --development-baseline "$INSTALLER_VERSION" \
                "$ARTIFACT_DIR" "$ROOT"
        else
            fail "installer version $INSTALLER_VERSION is newer than the source version $CHANGELOG_BASE"
        fi
        ;;
esac

echo
echo "Release validation: PASS"
