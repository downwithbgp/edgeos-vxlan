#!/bin/bash
# Tests for safe artifact archive validation and verified artifact fetching.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-artifact-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad()
{
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
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

make_zip()
{
    local path=$1
    shift
    python3 - "$path" "$@" <<'PY'
import sys, zipfile
path = sys.argv[1]
entries = sys.argv[2:]
with zipfile.ZipFile(path, "w") as z:
    for entry in entries:
        kind, name, value = entry.split(":", 2)
        if kind == "file":
            z.writestr(name, value)
        elif kind == "dir":
            z.writestr(name.rstrip("/") + "/", "")
        elif kind == "symlink":
            info = zipfile.ZipInfo(name)
            info.external_attr = (0o120777 << 16)
            z.writestr(info, value)
PY
}

VALIDATOR="$ROOT/scripts/validate-zip-archive.py"
GOOD="$TMP/good.zip"
make_zip "$GOOD" "file:release-candidate.json:hello" "file:dir/file.txt:world"
run_validator()
{
    python3 "$VALIDATOR" --archive "$1" --destination "$2" \
        ${3:+--max-uncompressed-bytes "$3"}
}

run_validator "$GOOD" "$TMP/extracted"
[ "$(cat "$TMP/extracted/release-candidate.json")" = "hello" ] &&
    ok || bad "good archive content"
[ "$(cat "$TMP/extracted/dir/file.txt")" = "world" ] &&
    ok || bad "good archive nested content"

BAD_TRAVERSAL="$TMP/traversal.zip"
make_zip "$BAD_TRAVERSAL" "file:../evil:bad"
expect_fail_with "escapes the destination" run_validator "$BAD_TRAVERSAL" "$TMP/traversal-out"

BAD_DUP="$TMP/dup.zip"
make_zip "$BAD_DUP" "file:a:one" "file:a:two"
expect_fail_with "duplicate archive member" run_validator "$BAD_DUP" "$TMP/dup-out"

BAD_LINK="$TMP/link.zip"
make_zip "$BAD_LINK" "symlink:link:/etc/passwd"
expect_fail_with "symlink archive member" run_validator "$BAD_LINK" "$TMP/link-out"

BAD_SIZE="$TMP/size.zip"
python3 - "$BAD_SIZE" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("big.bin", b"x" * 1000)
PY
expect_fail_with "exceeds limit" \
    python3 "$VALIDATOR" --archive "$BAD_SIZE" --destination "$TMP/size-out" \
    --max-uncompressed-bytes 100

EMPTY="$TMP/empty.zip"
python3 - "$EMPTY" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w"):
    pass
PY
expect_fail_with "archive is empty" run_validator "$EMPTY" "$TMP/empty-out"

# Verified fetch with a synthetic GitHub API.
SHA=0123456789abcdef0123456789abcdef01234567
ZIP=$TMP/artifact.zip
make_zip "$ZIP" "file:release-candidate.json:hello" "file:artifact.txt:data"
DIGEST="sha256:$(sha256sum "$ZIP" | awk '{print $1}')"
ARTIFACT_JSON=$TMP/artifact.json
RUN_JSON=$TMP/run.json
GOOD_ARTIFACT_JSON=$TMP/artifact.good.json
GOOD_RUN_JSON=$TMP/run.good.json
jq -n --arg digest "$DIGEST" --arg sha "$SHA" '{
    id: 42, name: "release-candidate", expired: false, digest: $digest,
    workflow_run: {id: 100, head_sha: $sha, repository_id: 1, head_repository_id: 1}
}' > "$GOOD_ARTIFACT_JSON"
jq -n --arg sha "$SHA" '{
    id: 100, status: "completed", conclusion: "success",
    path: ".github/workflows/release.yml", head_sha: $sha,
    head_repository: {full_name: "owner/repo"}
}' > "$GOOD_RUN_JSON"

FAKE_GH=$TMP/fake-gh
cat > "$FAKE_GH" <<EOF
#!/bin/sh
set -eu
case "\$*" in
    "api repos/owner/repo --jq .id") echo 1 ;;
    "api repos/owner/repo/actions/artifacts/42") cat "$ARTIFACT_JSON" ;;
    "api repos/owner/repo/actions/runs/100") cat "$RUN_JSON" ;;
    "api repos/owner/repo/actions/artifacts/42/zip") cat "$ZIP" ;;
    *) echo "unexpected fake-gh call: \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$FAKE_GH"

fetch()
{
    "$ROOT/scripts/fetch-github-artifact.sh" \
        --repo owner/repo --artifact-id 42 --expected-digest "$DIGEST" \
        --destination "$1" --expected-run-id 100 --expected-head-sha "$SHA" \
        --expected-workflow-path .github/workflows/release.yml \
        --expected-name release-candidate --gh "$FAKE_GH"
}

cp "$GOOD_ARTIFACT_JSON" "$ARTIFACT_JSON"
cp "$GOOD_RUN_JSON" "$RUN_JSON"
fetch "$TMP/fetched"
[ "$(cat "$TMP/fetched/release-candidate.json")" = "hello" ] &&
    ok || bad "fetched artifact content"

cp "$GOOD_ARTIFACT_JSON" "$ARTIFACT_JSON"
cp "$GOOD_RUN_JSON" "$RUN_JSON"
expect_fail_with "artifact name" \
    "$ROOT/scripts/fetch-github-artifact.sh" \
    --repo owner/repo --artifact-id 42 --expected-digest "$DIGEST" \
    --destination "$TMP/fetch-wrong-name" --expected-run-id 100 \
    --expected-head-sha "$SHA" --expected-workflow-path .github/workflows/release.yml \
    --expected-name wrong --gh "$FAKE_GH"

cp "$GOOD_ARTIFACT_JSON" "$ARTIFACT_JSON"
cp "$GOOD_RUN_JSON" "$RUN_JSON"
expect_fail_with "workflow path" \
    "$ROOT/scripts/fetch-github-artifact.sh" \
    --repo owner/repo --artifact-id 42 --expected-digest "$DIGEST" \
    --destination "$TMP/fetch-wrong-path" --expected-run-id 100 \
    --expected-head-sha "$SHA" --expected-workflow-path .github/workflows/other.yml \
    --gh "$FAKE_GH"

jq '.expired = true' "$GOOD_ARTIFACT_JSON" > "$ARTIFACT_JSON"
cp "$GOOD_RUN_JSON" "$RUN_JSON"
expect_fail_with "expired" \
    "$ROOT/scripts/fetch-github-artifact.sh" \
    --repo owner/repo --artifact-id 42 --expected-digest "$DIGEST" \
    --destination "$TMP/fetch-expired" --gh "$FAKE_GH"

cp "$GOOD_ARTIFACT_JSON" "$ARTIFACT_JSON"
jq '.conclusion = "failure"' "$GOOD_RUN_JSON" > "$RUN_JSON"
expect_fail_with "did not succeed" \
    "$ROOT/scripts/fetch-github-artifact.sh" \
    --repo owner/repo --artifact-id 42 --expected-digest "$DIGEST" \
    --destination "$TMP/fetch-failed-run" --gh "$FAKE_GH"

cp "$GOOD_ARTIFACT_JSON" "$ARTIFACT_JSON"
cp "$GOOD_RUN_JSON" "$RUN_JSON"
expect_fail_with "artifact API digest" \
    "$ROOT/scripts/fetch-github-artifact.sh" \
    --repo owner/repo --artifact-id 42 \
    --expected-digest sha256:0000000000000000000000000000000000000000000000000000000000000000 \
    --destination "$TMP/fetch-bad-digest" --gh "$FAKE_GH"

echo "unit-artifact-archive: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
