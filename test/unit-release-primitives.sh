#!/bin/bash
# Contract tests for the release primitives.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-release-primitives.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0

ok()
{
    PASS=$((PASS + 1))
}

bad()
{
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
}

expect_true()
{
    if "$@"; then ok; else bad "expected success: $*"; fi
}

expect_false()
{
    if "$@"; then bad "expected failure: $*"; else ok; fi
}

expect_fail_with()
{
    local pattern=$1
    shift
    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        bad "expected failure ($pattern): $*"
    elif grep -Fq -- "$pattern" "$TMP/err"; then
        ok
    else
        bad "failed for the wrong reason; wanted '$pattern': $*"
        sed 's/^/    /' "$TMP/err" | tail -8 >&2
    fi
}

# --- tag/version helpers -------------------------------------------------

expect_true is_release_tag v0.3.1
expect_false is_release_tag v0.3.1-rc1
expect_false is_release_tag "v0.3.1
v0.3.2"
expect_true is_sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_false is_sha256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
expect_true is_candidate_id sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_false is_candidate_id sha256:abc
expect_true tag_version_at_least v0.3.1 0.3.1
expect_false tag_version_at_least v0.3.0 0.3.1
expect_false tag_version_at_least 'v0.3.1~rc1' 0.3.1

# --- packaging inputs and pin commit -------------------------------------

REPO=$TMP/repo
mkdir -p "$REPO"/{debian,src,scripts,docs,release,test,.github}
printf 'install\n' > "$REPO/install.sh"
printf 'sums\n' > "$REPO/SHA256SUMS"
printf 'readme\n' > "$REPO/README.md"
printf 'attrs\n' > "$REPO/.gitattributes"
printf 'source\n' > "$REPO/src/a"
printf 'build\n' > "$REPO/scripts/build.sh"
printf 'docs\n' > "$REPO/docs/readme.md"
printf 'policy\n' > "$REPO/release/release-policy.json"
printf 'test\n' > "$REPO/test/unit.sh"
printf 'workflow\n' > "$REPO/.github/workflows.yml"
printf 'edgeos-vxlan (1.0.0) unstable; urgency=medium\n\n  * test\n\n -- Test <test@example.com>  Thu, 01 Jan 1970 00:00:00 +0000\n' \
    > "$REPO/debian/changelog"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" add .
git -C "$REPO" commit -qm A
A=$(git -C "$REPO" rev-parse HEAD)
DIGEST_A=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$A")

# Non-package changes do not alter the digest.
printf 'docs changed\n' >> "$REPO/docs/readme.md"
printf 'install changed\n' >> "$REPO/install.sh"
printf 'sums changed\n' >> "$REPO/SHA256SUMS"
printf 'readme changed\n' >> "$REPO/README.md"
printf 'workflow changed\n' >> "$REPO/.github/workflows.yml"
git -C "$REPO" add .
git -C "$REPO" commit -qm B
B=$(git -C "$REPO" rev-parse HEAD)
DIGEST_B=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$B")
if [ "$DIGEST_A" = "$DIGEST_B" ]; then
    ok
else
    bad "non-package changes altered the digest"
fi
expect_true "$ROOT/scripts/check-pin-commit.sh" --repo "$REPO" "$A" "$B"

# A package-affecting change alters the digest and is rejected as a pin commit.
printf 'changed source\n' >> "$REPO/src/a"
git -C "$REPO" add src/a
git -C "$REPO" commit -qm C
C=$(git -C "$REPO" rev-parse HEAD)
DIGEST_C=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$C")
if [ "$DIGEST_A" != "$DIGEST_C" ]; then
    ok
else
    bad "package-affecting change kept the digest"
fi
expect_fail_with "package-affecting" \
    "$ROOT/scripts/check-pin-commit.sh" --repo "$REPO" "$A" "$C"

# .gitattributes is package-affecting.
printf '*.txt -text\n' >> "$REPO/.gitattributes"
git -C "$REPO" add .gitattributes
git -C "$REPO" commit -qm D
D=$(git -C "$REPO" rev-parse HEAD)
DIGEST_D=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$D")
if [ "$DIGEST_C" != "$DIGEST_D" ]; then
    ok
else
    bad ".gitattributes change kept the digest"
fi

# Every protected package-input category must be rejected as a pin-only change.
digest_prev=$DIGEST_D
for spec in \
    "debian/changelog:protected changelog" \
    "debian/rules:protected rules" \
    "modules/4.14.54-UBNT/vxlan.ko:protected module" \
    "containers/reproducible-build/Dockerfile:protected Dockerfile" \
    "containers/reproducible-build/ca-certificates.crt:protected CA" \
    "scripts/build-reproducible.sh:protected build script" \
    "release/release-policy.json:protected policy" \
    "templates/interfaces/vxlan/node.def:protected template" \
    "patches/4.14.54-UBNT/CVE-2022-50405.patch:protected patch" \
    "upstream/libvyatta-cfg1/Interface.pm:protected upstream" \
    "LICENSE:protected license"; do
    path=${spec%%:*}
    content=${spec#*:}
    mkdir -p "$(dirname "$REPO/$path")"
    printf '%s\n' "$content" >> "$REPO/$path"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "protect $path"
    rev=$(git -C "$REPO" rev-parse HEAD)
    digest_new=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$rev")
    if [ "$digest_new" != "$digest_prev" ]; then
        ok
    else
        bad "protected input $path kept the digest"
    fi
    expect_fail_with "package-affecting" \
        "$ROOT/scripts/check-pin-commit.sh" --repo "$REPO" "$A" "$rev"
    digest_prev=$digest_new
done

# --- candidate identity ------------------------------------------------

MANIFEST=$TMP/candidate.json
jq -n '{
    schemaVersion: "https://edgeos-vxlan.dev/release-candidate/v1",
    candidate: {id: "", createdAt: "2026-11-27T00:00:00Z", status: "qualified", nonRelease: false},
    project: {name: "edgeos-vxlan"},
    source: {commit: "a"},
    buildEnvironment: {image: "x"},
    build: {buildType: "x"},
    artifacts: [{name: "b", size: 2, sha256: "bbbb", role: "package"}, {name: "a", size: 1, sha256: "aaaa", role: "package"}],
    qualification: {status: "passed", checks: [], hardware: {status: "not-required", required: false, evidence: []}},
    limitations: ["x"]
}' > "$MANIFEST"
ID_A=$(candidate_id_from_manifest "$MANIFEST")
jq --arg id "$ID_A" '.candidate.id = $id' "$MANIFEST" > "$TMP/with-id.json"
mv "$TMP/with-id.json" "$MANIFEST"
expect_true check_candidate_id "$MANIFEST"

# Key ordering does not change the ID.
jq -S . "$MANIFEST" > "$TMP/reordered.json"
if [ "$(candidate_id_from_manifest "$TMP/reordered.json")" = "$ID_A" ]; then
    ok
else
    bad "key ordering changed the candidate ID"
fi

# Any identity change changes the ID.
jq '.candidate.nonRelease = true' "$MANIFEST" > "$TMP/nonrelease.json"
if [ "$(candidate_id_from_manifest "$TMP/nonrelease.json")" != "$ID_A" ]; then
    ok
else
    bad "nonRelease did not change the candidate ID"
fi

jq '.artifacts[0].sha256 = "cccc"' "$MANIFEST" > "$TMP/artifact-changed.json"
if [ "$(candidate_id_from_manifest "$TMP/artifact-changed.json")" != "$ID_A" ]; then
    ok
else
    bad "artifact hash did not change the candidate ID"
fi

# --- pin rendering ------------------------------------------------------

PINS=$TMP/pins
mkdir -p "$PINS/debian"
printf 'edgeos-vxlan (1.2.3+edgeos3.0.1.e50) unstable; urgency=medium\n\n  * test\n\n -- Test <test@example.com>  Thu, 01 Jan 1970 00:00:00 +0000\n' \
    > "$PINS/debian/changelog"
printf '%s\n' \
    '#!/bin/sh' \
    'VERSION="0.0.0"' \
    'PKG_VERSION="0.0.0+edgeos3.0.1.e50"' \
    'KMOD_SHA256="0000000000000000000000000000000000000000000000000000000000000000"' \
    'INTEGRATION_SHA256="0000000000000000000000000000000000000000000000000000000000000000"' \
    > "$PINS/install.sh"
printf '%s  %s\n' \
    0000000000000000000000000000000000000000000000000000000000000000 \
    'edgeos-vxlan_0.0.0+edgeos3.0.1.e50_all.deb' \
    > "$PINS/SHA256SUMS"

PIN_MANIFEST=$TMP/pin-manifest.json
jq -n '{
    schemaVersion: "https://edgeos-vxlan.dev/release-candidate/v1",
    candidate: {id: "", createdAt: "2026-11-27T00:00:00Z", status: "qualified", nonRelease: false},
    project: {releaseTag: "v1.2.3", packageVersion: "1.2.3+edgeos3.0.1.e50"},
    source: {commit: "a"},
    buildEnvironment: {image: "x"},
    build: {buildType: "x"},
    artifacts: [
        {name: "edgeos-vxlan_1.2.3+edgeos3.0.1.e50_all.deb", size: 1, sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", role: "package"},
        {name: "edgeos-vxlan-kmod_1.2.3+edgeos3.0.1.e50_mipsel.deb", size: 1, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", role: "package"}
    ],
    qualification: {status: "passed", checks: [], hardware: {status: "not-required", required: false, evidence: []}},
    limitations: []
}' > "$PIN_MANIFEST"
PIN_ID=$(candidate_id_from_manifest "$PIN_MANIFEST")
jq --arg id "$PIN_ID" '.candidate.id = $id' "$PIN_MANIFEST" > "$TMP/pin-with-id.json"
mv "$TMP/pin-with-id.json" "$PIN_MANIFEST"

expect_fail_with "pins do not match" \
    "$ROOT/scripts/update-release-pins.sh" --candidate "$PIN_MANIFEST" --repo "$PINS" --check
expect_true "$ROOT/scripts/update-release-pins.sh" --candidate "$PIN_MANIFEST" --repo "$PINS" --write
expect_true "$ROOT/scripts/update-release-pins.sh" --candidate "$PIN_MANIFEST" --repo "$PINS" --check
if grep -Fx 'VERSION="1.2.3"' "$PINS/install.sh" >/dev/null; then
    ok
else
    bad "VERSION not rendered"
fi
if grep -Fx 'PKG_VERSION="1.2.3+edgeos3.0.1.e50"' "$PINS/install.sh" >/dev/null; then
    ok
else
    bad "PKG_VERSION not rendered"
fi

echo "unit-release-primitives: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
