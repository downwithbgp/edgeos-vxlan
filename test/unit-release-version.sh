#!/bin/bash
# Tests for publication version eligibility.
#
# Publication eligibility must consult the newest published stable release, not
# a static baseline, and must distinguish drafts, prereleases, tags without a
# release, interrupted publication and Debian version ordering. No production
# release is created: the GitHub API is mocked.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-version.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad()
{
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
}
expect_pass()
{
    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        ok
    else
        bad "expected success: $*"
        sed 's/^/    /' "$TMP/err" | tail -8 >&2
    fi
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
        bad "failed for the wrong reason; wanted '$pattern'"
        sed 's/^/    /' "$TMP/err" | tail -8 >&2
    fi
}

FAKE_GH=$TMP/fake-gh
cat > "$FAKE_GH" <<'EOF'
#!/bin/sh
set -eu
[ "${FAKE_FAIL:-}" = "yes" ] && exit 1
case "$*" in
    *"/releases"*) if [ "${FAKE_RELEASES_RAW_SET:-}" = "1" ]; then printf '%s' "${FAKE_RELEASES_RAW:-}"; else cat "$FAKE_RELEASES"; fi ;;
    *"/tags"*) if [ "${FAKE_TAGS_RAW_SET:-}" = "1" ]; then printf '%s' "${FAKE_TAGS_RAW:-}"; else cat "$FAKE_TAGS"; fi ;;
    *) echo "unexpected fake-gh call: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$FAKE_GH"

RELEASES=$TMP/releases.json
TAGS=$TMP/tags.json

# rel TAG DRAFT PRERELEASE -> one release object
rel()
{
    jq -n --arg tag "$1" --argjson draft "$2" --argjson pre "$3" \
        '{tag_name:$tag, draft:$draft, prerelease:$pre}'
}

check()
{
    FAKE_RELEASES="$RELEASES" FAKE_TAGS="$TAGS" \
        "$ROOT/scripts/check-version-eligibility.sh" \
        --repo owner/repo --tag "$1" --gh "$FAKE_GH"
}

# --- newest published stable is 0.3.0, candidate 0.3.1 ---------------------
rel v0.3.0 false false > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.3.0"}]' > "$TAGS"
expect_pass check v0.3.1
grep -q 'Latest published:    0.3.0' "$TMP/out" && ok || bad "latest published not reported as 0.3.0"

# --- regression below the newest published stable --------------------------
rel v0.4.0 false false > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.4.0"}]' > "$TAGS"
expect_fail_with "version regression: 0.3.5 is below" check v0.3.5

# --- Debian version semantics, not lexical order ---------------------------
rel v0.10.0 false false > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.10.0"}]' > "$TAGS"
expect_fail_with "version regression: 0.9.9 is below" check v0.9.9

# --- drafts do not raise the published version -----------------------------
{ rel v0.3.0 false false; rel v0.5.0 true false; } > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.3.0"},{name:"v0.5.0"}]' > "$TAGS"
expect_pass check v0.5.0
grep -q 'Latest published:    0.3.0' "$TMP/out" && ok || bad "a draft raised the published version"

# --- prereleases do not raise the published version ------------------------
{ rel v0.3.0 false false; rel v0.5.0 false true; } > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.3.0"},{name:"v0.5.0"}]' > "$TAGS"
expect_pass check v0.5.0
grep -q 'Latest published:    0.3.0' "$TMP/out" && ok || bad "a prerelease raised the published version"

# --- a tag without a release does not raise the published version ----------
rel v0.4.0 false false > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.4.0"},{name:"v0.5.0"}]' > "$TAGS"
expect_pass check v0.5.0
grep -q 'Latest published:    0.4.0' "$TMP/out" && ok || bad "a bare tag raised the published version"

# --- interrupted publication: draft of the next version resumes ------------
{ rel v0.3.0 false false; rel v0.3.1 true false; } > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.3.0"},{name:"v0.3.1"}]' > "$TAGS"
expect_pass check v0.3.1

# --- idempotent re-run against the newest published release ---------------
rel v0.3.1 false false > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.3.1"}]' > "$TAGS"
expect_pass check v0.3.1
grep -q 'resuming v0.3.1 at the newest published stable version 0.3.1' "$TMP/err" &&
    ok || bad "resume was not reported"

# --- V == P is allowed only because a release for the tag exists ----------
# The guard cannot be exercised by "no release" here: V == P implies a
# published release whose tag is vP, so the tag necessarily exists. Content
# substitution at an already-published version is caught later, when the
# published release is re-verified against the candidate. Assert the allowed
# path is taken for a published tag and that the reuse guard exists in code.
rel v0.3.1 false false > "$RELEASES.tmp"
jq -s . "$RELEASES.tmp" > "$RELEASES"
jq -n '[{name:"v0.3.1"}]' > "$TAGS"
expect_pass check v0.3.1
grep -q 'version reuse' "$ROOT/scripts/check-version-eligibility.sh" &&
    ok || bad "reuse guard missing from the eligibility script"

# --- reuse at the baseline floor with only a tag is rejected --------------
jq -n '[]' > "$RELEASES"
jq -n '[{name:"v0.3.0"}]' > "$TAGS"
expect_fail_with "version reuse: 0.3.0 is the newest published stable version" check v0.3.0

# --- unparseable payloads fail closed ------------------------------------
for raw in 'null' '{}' ''; do
    FAKE_RELEASES_RAW="$raw" expect_fail_with "releases response" \
        env FAKE_RELEASES="$RELEASES" FAKE_TAGS="$TAGS" \
            FAKE_RELEASES_RAW_SET=1 FAKE_RELEASES_RAW="$raw" \
            "$ROOT/scripts/check-version-eligibility.sh" \
            --repo owner/repo --tag v0.3.1 --gh "$FAKE_GH"
done
FAKE_TAGS_RAW='{}' expect_fail_with "tags response" \
    env FAKE_RELEASES="$RELEASES" FAKE_TAGS="$TAGS" \
        FAKE_TAGS_RAW_SET=1 FAKE_TAGS_RAW='{}' \
        "$ROOT/scripts/check-version-eligibility.sh" \
        --repo owner/repo --tag v0.3.1 --gh "$FAKE_GH"

# --- no releases at all: fall back to the policy baseline ------------------
jq -n '[]' > "$RELEASES"
jq -n '[]' > "$TAGS"
expect_pass check v0.3.1
grep -q 'Latest published:    0.3.0' "$TMP/out" && ok || bad "baseline fallback not used"

# --- releases with non-release tags are ignored ---------------------------
rel v1.0 false false > "$RELEASES.tmp"
rel v0.3.0 false false > "$RELEASES.tmp.2"
jq -s . "$RELEASES.tmp" "$RELEASES.tmp.2" > "$RELEASES"
jq -n '[]' > "$TAGS"
expect_pass check v0.3.1

# --- API failure must fail closed ----------------------------------------
FAKE_FAIL=yes expect_fail_with "cannot read published releases" \
    env FAKE_RELEASES="$RELEASES" FAKE_TAGS="$TAGS" FAKE_FAIL=yes \
        "$ROOT/scripts/check-version-eligibility.sh" \
        --repo owner/repo --tag v0.3.1 --gh "$FAKE_GH"

# --- tag validation -------------------------------------------------------
expect_fail_with "invalid release tag" check 0.3.1
expect_fail_with "invalid release tag" check v0.3
expect_fail_with "invalid repository" \
    "$ROOT/scripts/check-version-eligibility.sh" --repo nope --tag v0.3.1 --gh "$FAKE_GH"

# --- no implicit backport bypass -----------------------------------------
if grep -q -- '--allow-backport\|--force\|--skip-version' "$ROOT/scripts/check-version-eligibility.sh"; then
    bad "version eligibility exposes a bypass flag"
else
    ok
fi

echo "unit-release-version: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
