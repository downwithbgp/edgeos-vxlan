#!/bin/bash
# Unit tests for OCI image identity extraction and verification.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-oci-test.XXXXXX")
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

make_layout()
{
    local layout=$1
    local tag=${2:-test}
    local config_json='{"architecture":"amd64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}'
    local config_sha manifest_json manifest_sha config_size manifest_size

    mkdir -p "$layout/blobs/sha256"
    printf '%s' "$config_json" > "$TMP/config.json"
    config_sha=$(sha256sum "$TMP/config.json" | awk '{print $1}')
    config_size=$(stat -c '%s' "$TMP/config.json")
    mv "$TMP/config.json" "$layout/blobs/sha256/$config_sha"

    manifest_json=$(jq -cn \
        --arg configSha "sha256:$config_sha" \
        --argjson configSize "$config_size" \
        '{schemaVersion:2,
          mediaType:"application/vnd.oci.image.manifest.v1+json",
          config:{mediaType:"application/vnd.oci.image.config.v1+json",
                  digest:$configSha,size:$configSize},
          layers:[]}')
    printf '%s' "$manifest_json" > "$TMP/manifest.json"
    manifest_sha=$(sha256sum "$TMP/manifest.json" | awk '{print $1}')
    manifest_size=$(stat -c '%s' "$TMP/manifest.json")
    mv "$TMP/manifest.json" "$layout/blobs/sha256/$manifest_sha"

    jq -n \
        --arg manifestSha "sha256:$manifest_sha" \
        --argjson manifestSize "$manifest_size" \
        --arg tag "$tag" \
        '{schemaVersion:2,
          mediaType:"application/vnd.oci.image.index.v1+json",
          manifests:[
            {mediaType:"application/vnd.oci.image.manifest.v1+json",
             digest:$manifestSha,size:$manifestSize,
             platform:{architecture:"amd64",os:"linux"},
             annotations:{"org.opencontainers.image.ref.name":$tag}},
            {mediaType:"application/vnd.oci.image.manifest.v1+json",
             digest:"sha256:1111111111111111111111111111111111111111111111111111111111111111",
             size:1,
             annotations:{"vnd.docker.reference.type":"attestation-manifest"},
             platform:{architecture:"unknown",os:"unknown"}}
          ]}' > "$layout/index.json"

    tar -cf "$layout.tar" -C "$layout" .
    printf '%s %s\n' "$manifest_sha" "$config_sha" > "$TMP/expected"
}

make_layout "$TMP/layout"
read -r expected_manifest expected_config < "$TMP/expected"
IDENTITY=$("$ROOT/scripts/oci-image-identity.sh" --archive "$TMP/layout.tar" --json)
if [ "$(jq -r '.manifestDigest' <<<"$IDENTITY")" = "sha256:$expected_manifest" ]; then
    ok
else
    bad "manifest digest"
fi
if [ "$(jq -r '.configDigest' <<<"$IDENTITY")" = "sha256:$expected_config" ]; then
    ok
else
    bad "config digest"
fi
if [ "$(jq -r '.archiveSha256' <<<"$IDENTITY")" = "$(sha256sum "$TMP/layout.tar" | awk '{print $1}')" ]; then
    ok
else
    bad "archive digest"
fi

# --output-dir keeps the layout.
"$ROOT/scripts/oci-image-identity.sh" --archive "$TMP/layout.tar" \
    --output-dir "$TMP/keep" --json >/dev/null
if [ -f "$TMP/keep/index.json" ]; then
    ok
else
    bad "--output-dir did not keep the layout"
fi

# Tampered config blob.
cp -a "$TMP/layout" "$TMP/tampered"
printf 'x' >> "$TMP/tampered/blobs/sha256/$expected_config"
tar -cf "$TMP/tampered.tar" -C "$TMP/tampered" .
expect_fail_with "config blob hash mismatch" \
    "$ROOT/scripts/oci-image-identity.sh" --archive "$TMP/tampered.tar"

# Missing manifest blob.
cp -a "$TMP/layout" "$TMP/missing"
rm -f "$TMP/missing/blobs/sha256/$expected_manifest"
tar -cf "$TMP/missing.tar" -C "$TMP/missing" .
expect_fail_with "manifest blob is missing" \
    "$ROOT/scripts/oci-image-identity.sh" --archive "$TMP/missing.tar"

# Two platform manifests are ambiguous.
cp -a "$TMP/layout" "$TMP/ambiguous"
jq '.manifests[1] = (.manifests[0] | .digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222" | .annotations = {} | .platform = {architecture:"amd64",os:"linux"})' \
    "$TMP/ambiguous/index.json" > "$TMP/ambiguous/index.new"
mv "$TMP/ambiguous/index.new" "$TMP/ambiguous/index.json"
tar -cf "$TMP/ambiguous.tar" -C "$TMP/ambiguous" .
expect_fail_with "expected exactly one linux/amd64 image manifest" \
    "$ROOT/scripts/oci-image-identity.sh" --archive "$TMP/ambiguous.tar"

# Unsafe archive path.
mkdir -p "$TMP/unsafe/sub"
printf 'x\n' > "$TMP/unsafe/file"
tar -cf "$TMP/unsafe.tar" -C "$TMP/unsafe" --transform='s|^file$|../evil|' file
expect_fail_with "path traversal" \
    "$ROOT/scripts/oci-image-identity.sh" --archive "$TMP/unsafe.tar"

echo "unit-image-qualification: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
