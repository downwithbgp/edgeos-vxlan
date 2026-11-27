#!/bin/bash
# Contract tests for scripts/build-reproducible.sh.
# No package build is performed here; the independent reproducibility job
# exercises the full build.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/scripts/build-reproducible.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
    [ -s "$TMP/err" ] && sed 's/^/    err: /' "$TMP/err" | tail -6
}

run_expect() { # run_expect <want_rc> <description> <command...>
    local want=$1 desc=$2
    shift 2
    "$@" >"$TMP/out" 2>"$TMP/err"
    local rc=$?
    if [ "$rc" = "$want" ]; then ok; else bad "$desc (rc=$rc want=$want)"; fi
}

run_expect 0 "help exits successfully" "$BUILD" --help
if grep -q 'source-rev' "$TMP/out"; then
    ok
else
    bad "help documents --source-rev"
fi

run_expect 2 "unknown option is rejected" "$BUILD" --nonsense
run_expect 1 "invalid source revision is rejected" \
    "$BUILD" --source-rev no-such-revision --output-dir "$TMP/invalid"

# Minimal Git repository: output-directory and dirty-worktree guards must
# reject before any archive/build work.
REPO=$TMP/repo
mkdir -p "$REPO/scripts" "$REPO/debian"
cp "$BUILD" "$REPO/scripts/build-reproducible.sh"
printf 'edgeos-vxlan (0.0.0) unstable; urgency=medium\n\n  * test\n\n -- Test <test@example.com>  Thu, 01 Jan 1970 00:00:00 +0000\n' \
    >"$REPO/debian/changelog"
printf 'tracked\n' >"$REPO/file.txt"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" add .
git -C "$REPO" commit -qm initial

mkdir -p "$TMP/nonempty"
printf 'x\n' >"$TMP/nonempty/file"
run_expect 1 "non-empty output directory is rejected" \
    "$REPO/scripts/build-reproducible.sh" --output-dir "$TMP/nonempty"
if grep -q 'not empty' "$TMP/err"; then
    ok
else
    bad "non-empty output error is diagnostic"
fi

archive=$TMP/empty.tar
: >"$archive"
run_expect 1 "archive without commit is rejected" \
    "$BUILD" --source-archive "$archive" --output-dir "$TMP/archive-no-commit"
run_expect 1 "archive without hash is rejected" \
    "$BUILD" --source-archive "$archive" --source-commit 0123456789abcdef0123456789abcdef01234567 \
    --output-dir "$TMP/archive-no-hash"
run_expect 1 "archive hash mismatch is rejected" \
    "$BUILD" --source-archive "$archive" \
    --source-commit 0123456789abcdef0123456789abcdef01234567 \
    --source-archive-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
    --output-dir "$TMP/archive-bad-hash"

printf 'dirty\n' >>"$REPO/file.txt"
run_expect 1 "dirty HEAD build is rejected" \
    "$REPO/scripts/build-reproducible.sh" --output-dir "$TMP/dirty-out"
if grep -q 'tracked changes' "$TMP/err"; then
    ok
else
    bad "dirty-worktree error is diagnostic"
fi

echo "unit-build: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
