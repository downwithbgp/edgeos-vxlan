#!/bin/bash
# Published-release fixture tests.
#
# Downloads a known published release and its tagged source, then verifies the
# positive contract and deliberately malformed asset sets. The fixtures are
# independent of local rebuild reproducibility; historical release assets are
# never modified, only copied.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RELEASE_TAG=${FIXTURE_RELEASE_TAG:-v0.3.0}
EXPECTED_TAG_COMMIT=5ed46fd946d0268c5785515798e2b902bfdd9060
EXPECTED_KMOD_SHA=c555a99a8626fc2212e5a7ee35916f66971f83b2661f9281dea24196e7754c5f
EXPECTED_INTEGRATION_SHA=73059ba2b7f6099efd9d39b6962391e923f86a9eaf120d839723dfff05646eca
REPO=downwithbgp/edgeos-vxlan

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0

[ -n "${GH_TOKEN:-}" ] || true

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

expect_pass()
{
    local desc=$1
    shift

    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (expected success)"
        sed 's/^/    /' "$TMP/err" | tail -10
    fi
}

expect_fail()
{
    local desc=$1
    local pattern=$2
    shift 2

    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (expected failure, validation passed)"
        return
    fi

    if grep -Fq -- "$pattern" "$TMP/err"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (failed for the wrong reason; wanted '$pattern')"
        sed 's/^/    /' "$TMP/err" | tail -10
    fi
}

new_assets()
{
    local dir=$TMP/assets-$1
    cp -a "$TMP/assets/." "$dir/"
    printf '%s\n' "$dir"
}

validate_assets()
{
    RELEASE_TAG="$RELEASE_TAG" \
        "$ROOT/scripts/validate-published-release.sh" "$1" "$TMP/source"
}

for cmd in gh git dpkg-deb sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

ACTUAL_COMMIT=$(git -C "$ROOT" rev-parse "${RELEASE_TAG}^{commit}") ||
    fail "tag not found: $RELEASE_TAG"
[ "$ACTUAL_COMMIT" = "$EXPECTED_TAG_COMMIT" ] ||
    fail "$RELEASE_TAG moved: $ACTUAL_COMMIT != $EXPECTED_TAG_COMMIT"

mkdir -p "$TMP/assets" "$TMP/source"
gh release download "$RELEASE_TAG" --repo "$REPO" --dir "$TMP/assets" ||
    fail "cannot download release $RELEASE_TAG"
git -C "$ROOT" archive "$RELEASE_TAG" | tar -xf - -C "$TMP/source" ||
    fail "cannot archive tagged source"

[ "$(sha256sum "$TMP/assets/edgeos-vxlan-kmod_0.3.0+edgeos3.0.1.e50_mipsel.deb" | cut -d ' ' -f1)" = "$EXPECTED_KMOD_SHA" ] ||
    fail "published kmod fixture hash changed"
[ "$(sha256sum "$TMP/assets/edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb" | cut -d ' ' -f1)" = "$EXPECTED_INTEGRATION_SHA" ] ||
    fail "published integration fixture hash changed"

expect_pass "published v0.3.0 fixture validates" validate_assets "$TMP/assets"

missing_manifest=$(new_assets missing-manifest)
rm -f "$missing_manifest/SHA256SUMS"
expect_fail "missing published manifest" "missing release asset" \
    validate_assets "$missing_manifest"

missing_package=$(new_assets missing-package)
rm -f "$missing_package/edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb"
expect_fail "missing published package" "missing release asset" \
    validate_assets "$missing_package"

extra_asset=$(new_assets extra-asset)
printf 'unexpected\n' >"$extra_asset/notes.txt"
expect_fail "unexpected published asset" "unexpected release asset" \
    validate_assets "$extra_asset"

corrupt_package=$(new_assets corrupt-package)
printf '\001' >>"$corrupt_package/edgeos-vxlan-kmod_0.3.0+edgeos3.0.1.e50_mipsel.deb"
expect_fail "corrupted published package" "install.sh pin" \
    validate_assets "$corrupt_package"

manifest_order=$(new_assets manifest-order)
tac "$TMP/source/SHA256SUMS" >"$manifest_order/SHA256SUMS"
expect_fail "published manifest differs from tagged source" \
    "differs from the tagged source tree" validate_assets "$manifest_order"

expect_fail "published tag/version mismatch" "does not match install.sh VERSION" \
    env RELEASE_TAG=v9.9.9 \
    "$ROOT/scripts/validate-published-release.sh" "$TMP/assets" "$TMP/source"

echo "published-release-fixtures: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
