#!/bin/bash
# Tests for staged image publication.
#
# The registry is never contacted: crane is a recording fake. These tests pin
# the ordering that makes staged publication safe: never replace a tag, never
# promote an unverified push, verify the promoted digest, and always remove the
# staging marker.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-image-publish.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0
STATE=$TMP/state
LOG=$TMP/crane.log
mkdir -p "$STATE"
: > "$LOG"

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
        bad "expected success"
        sed 's/^/    /' "$TMP/err" | tail -8 >&2
    fi
}
expect_fail_with()
{
    local pattern=$1
    shift
    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        bad "expected failure ($pattern)"
    elif grep -Fq -- "$pattern" "$TMP/err"; then
        ok
    else
        bad "failed for the wrong reason; wanted '$pattern'"
        sed 's/^/    /' "$TMP/err" | tail -8 >&2
    fi
}

FAKE_CRANE=$TMP/fake-crane
cat > "$FAKE_CRANE" <<'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$FAKE_CRANE_LOG"
case "$1" in
    digest)
        tag=${2##*:}
        [ -f "$FAKE_CRANE_STATE/$tag" ] || exit 1
        cat "$FAKE_CRANE_STATE/$tag"
        ;;
    push)
        [ "${FAKE_PUSH_FAIL:-}" = "yes" ] && exit 1
        printf '%s\n' "$FAKE_PUSH_DIGEST" > "$FAKE_CRANE_STATE/${3##*:}"
        ;;
    copy)
        [ "${FAKE_COPY_FAIL:-}" = "yes" ] && exit 1
        printf '%s\n' "${FAKE_COPY_DIGEST:-${2##*@}}" > "$FAKE_CRANE_STATE/${3##*:}"
        ;;
    delete)
        rm -f "$FAKE_CRANE_STATE/${2##*:}"
        [ "${FAKE_DELETE_FAIL:-}" = "yes" ] && exit 1
        ;;
    manifest)
        printf '{"manifests":[{"digest":"%s"}]}\n' "${FAKE_INDEX_CONTAINS:-}"
        ;;
    *)
        echo "unexpected crane call: $*" >&2
        exit 9
        ;;
esac
EOF
chmod +x "$FAKE_CRANE"

QUALIFIED="sha256:1111111111111111111111111111111111111111111111111111111111111111"
OTHER="sha256:2222222222222222222222222222222222222222222222222222222222222222"
ARCHIVE=$TMP/image.oci.tar
printf 'archive\n' > "$ARCHIVE"
QUAL=$TMP/qualification.json
jq -n --arg d "$QUALIFIED" '{manifestDigest:$d}' > "$QUAL"

publish()
{
    env FAKE_CRANE_STATE="$STATE" FAKE_CRANE_LOG="$LOG" \
        FAKE_PUSH_DIGEST="${FAKE_PUSH_DIGEST:-$QUALIFIED}" \
        FAKE_INDEX_CONTAINS="${FAKE_INDEX_CONTAINS:-}" \
        FAKE_PUSH_FAIL="${FAKE_PUSH_FAIL:-no}" \
        FAKE_COPY_FAIL="${FAKE_COPY_FAIL:-no}" \
        FAKE_COPY_DIGEST="${FAKE_COPY_DIGEST:-}" \
        FAKE_DELETE_FAIL="${FAKE_DELETE_FAIL:-no}" \
        "$ROOT/scripts/publish-image-staged.sh" \
        --oci-archive "$ARCHIVE" --qualification "$QUAL" \
        --image ghcr.io/owner/repo-build \
        --staging-tag staging-1 --target-tag target-1 \
        --digest-out "$TMP/digest.txt" --crane "$FAKE_CRANE" \
        "$@"
}

reset()
{
    rm -f "$STATE"/* "$TMP/digest.txt"
    : > "$LOG"
}

# --- happy path: push, verify, promote, clean up --------------------------
reset
expect_pass publish
[ "$(cat "$STATE/target-1")" = "$QUALIFIED" ] && ok || bad "target not promoted"
[ ! -e "$STATE/staging-1" ] && ok || bad "staging tag not removed"
[ "$(cat "$TMP/digest.txt")" = "$QUALIFIED" ] && ok || bad "digest output wrong"
grep -q '^push ' "$LOG" && ok || bad "no push recorded"
grep -q '^copy ' "$LOG" && ok || bad "no copy recorded"
grep -q '^delete ' "$LOG" && ok || bad "no cleanup recorded"

# --- never promote an unverified push ------------------------------------
reset
FAKE_PUSH_DIGEST="$OTHER" FAKE_INDEX_CONTAINS="$OTHER" \
    expect_fail_with "does not contain the qualified manifest" publish
grep -q '^copy ' "$LOG" && bad "promoted despite digest mismatch" || ok
[ ! -e "$STATE/staging-1" ] && ok || bad "staging marker left after failure"

# --- an index containing the qualified manifest is acceptable ------------
reset
FAKE_PUSH_DIGEST="$OTHER" FAKE_INDEX_CONTAINS="$QUALIFIED" expect_pass publish
[ "$(cat "$STATE/target-1")" = "$OTHER" ] && ok || bad "verified index not promoted"

# --- never replace an existing target tag -------------------------------
reset
printf '%s\n' "$OTHER" > "$STATE/target-1"
expect_fail_with "refusing to replace" publish
grep -q '^push ' "$LOG" && bad "pushed despite a conflicting target tag" || ok
[ "$(cat "$STATE/target-1")" = "$OTHER" ] && ok || bad "existing target was modified"

# --- idempotent when the target already matches ------------------------
reset
printf '%s\n' "$QUALIFIED" > "$STATE/target-1"
expect_pass publish
grep -q '^push ' "$LOG" && bad "pushed although already published" || ok
grep -q "already published" "$TMP/out" && ok || bad "idempotent path not reported"

# --- promotion failure is surfaced and the marker is cleaned ----------
reset
FAKE_COPY_FAIL=yes expect_fail_with "cannot promote" publish
[ ! -e "$STATE/staging-1" ] && ok || bad "staging marker left after promotion failure"

# --- a promoted digest that does not match is rejected ----------------
reset
FAKE_COPY_DIGEST="$OTHER" expect_fail_with "does not match the verified" publish

# --- dry run mutates nothing -----------------------------------------
reset
expect_pass publish --dry-run
[ -s "$LOG" ] && bad "dry run invoked crane" || ok
grep -q "DRY-RUN" "$TMP/out" && ok || bad "dry run did not report its plan"

# --- argument validation ---------------------------------------------
reset
expect_fail_with "must differ" publish --staging-tag same --target-tag same
expect_fail_with "invalid image name" publish --image 'UPPER/Bad'
expect_fail_with "required file not found" \
    env FAKE_CRANE_STATE="$STATE" FAKE_CRANE_LOG="$LOG" \
        "$ROOT/scripts/publish-image-staged.sh" \
        --oci-archive "$ARCHIVE" --qualification "$TMP/nope.json" \
        --image ghcr.io/owner/repo-build \
        --staging-tag a --target-tag b --crane "$FAKE_CRANE"

# --- no unconditional registry mutation path -------------------------
if grep -qE '(^|[[:space:]])crane (push|copy|delete)' "$ROOT/scripts/publish-image-staged.sh"; then
    bad "script invokes crane directly instead of the staged flow"
else
    ok
fi

echo "unit-release-image-publish: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
