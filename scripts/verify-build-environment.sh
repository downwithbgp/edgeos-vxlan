#!/bin/bash
# Independently verify a qualified build-environment artifact set.
#
# The qualification JSON is not trusted by itself: the OCI archive is
# re-read, all digests are recomputed, the image is loaded and inventoried,
# and the Dockerfile/CA/snapshot inputs are checked against the source tree.
#
# Usage: verify-build-environment.sh --archive-dir DIR [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/release-common.sh"

ARCHIVE_DIR=
SOURCE_ROOT=$ROOT
TEST_BUILD=yes

usage()
{
    cat <<'EOF'
Usage: verify-build-environment.sh --archive-dir DIR [options]

Options:
  --archive-dir DIR   Directory containing image.oci.tar and evidence files
  --source-root DIR   Source tree for Dockerfile/CA/snapshot checks
  --skip-test-build   Do not run the image smoke test
  -h, --help          Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --archive-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            ARCHIVE_DIR=$2
            shift 2
            ;;
        --source-root)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_ROOT=$2
            shift 2
            ;;
        --skip-test-build)
            TEST_BUILD=no
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$ARCHIVE_DIR" ] || { usage >&2; exit 2; }
require_cmd docker jq sha256sum tar stat awk sed
require_dir "$ARCHIVE_DIR"
require_file "$ARCHIVE_DIR/image.oci.tar"
require_file "$ARCHIVE_DIR/build-environment-qualification.json"
require_file "$ARCHIVE_DIR/image.spdx.json"
require_file "$ARCHIVE_DIR/image-vulnerabilities.json"
require_file "$ARCHIVE_DIR/dependency-inventory.txt"
require_file "$SOURCE_ROOT/containers/reproducible-build/Dockerfile"
require_file "$SOURCE_ROOT/containers/reproducible-build/ca-certificates.crt"

QUAL="$ARCHIVE_DIR/build-environment-qualification.json"
IMAGE_NAME=$(jq -er '.imageName' "$QUAL")
MANIFEST_DIGEST=$(jq -er '.manifestDigest' "$QUAL")
CONFIG_DIGEST=$(jq -er '.configDigest' "$QUAL")
OCI_INDEX_DIGEST=$(jq -er '.ociIndexDigest' "$QUAL")
OCI_ARCHIVE_SHA256=$(jq -er '.ociArchiveSha256' "$QUAL")
DOCKERFILE_SHA256=$(jq -er '.dockerfileSha256' "$QUAL")
CA_BUNDLE_SHA256=$(jq -er '.caBundleSha256' "$QUAL")
BASE_IMAGE=$(jq -er '.baseImage' "$QUAL")
SNAPSHOT=$(jq -er '.dependencySnapshot' "$QUAL")
INVENTORY_SHA256=$(jq -er '.dependencyInventorySha256' "$QUAL")
IMAGE_SBOM_SHA256=$(jq -er '.imageSbomSha256' "$QUAL")
VULN_SHA256=$(jq -er '.vulnerabilityReportSha256' "$QUAL")
QUALIFIED=$(jq -er '.qualified' "$QUAL")
VULN_SCAN=$(jq -er '.vulnerabilityScan' "$QUAL")

[ "$QUALIFIED" = "true" ] || fail "qualification is not marked qualified"

require_digest_field "OCI index digest" "$OCI_INDEX_DIGEST"
require_digest_field "manifest digest" "$MANIFEST_DIGEST"
require_digest_field "config digest" "$CONFIG_DIGEST"
require_sha256_field "OCI archive checksum" "$OCI_ARCHIVE_SHA256"
require_sha256_field "Dockerfile checksum" "$DOCKERFILE_SHA256"
require_sha256_field "CA bundle checksum" "$CA_BUNDLE_SHA256"
require_sha256_field "inventory checksum" "$INVENTORY_SHA256"
require_sha256_field "image SBOM checksum" "$IMAGE_SBOM_SHA256"
require_sha256_field "vulnerability report checksum" "$VULN_SHA256"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-verify-image.XXXXXX") ||
    fail "cannot create temporary directory"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

"$ROOT/scripts/oci-image-identity.sh" \
    --archive "$ARCHIVE_DIR/image.oci.tar" \
    --json > "$TMP/identity.json"

[ "$(jq -r '.ociIndexDigest' "$TMP/identity.json")" = "$OCI_INDEX_DIGEST" ] ||
    fail "OCI index digest does not match the qualification"
[ "$(jq -r '.manifestDigest' "$TMP/identity.json")" = "$MANIFEST_DIGEST" ] ||
    fail "manifest digest does not match the qualification"
[ "$(jq -r '.configDigest' "$TMP/identity.json")" = "$CONFIG_DIGEST" ] ||
    fail "config digest does not match the qualification"
[ "$(jq -r '.archiveSha256' "$TMP/identity.json")" = "$OCI_ARCHIVE_SHA256" ] ||
    fail "OCI archive checksum does not match the qualification"

[ "$(sha256_file "$SOURCE_ROOT/containers/reproducible-build/Dockerfile")" = "$DOCKERFILE_SHA256" ] ||
    fail "Dockerfile hash does not match the qualification"
[ "$(sha256_file "$SOURCE_ROOT/containers/reproducible-build/ca-certificates.crt")" = "$CA_BUNDLE_SHA256" ] ||
    fail "CA bundle hash does not match the qualification"

SOURCE_BASE=$(grep '^FROM ' "$SOURCE_ROOT/containers/reproducible-build/Dockerfile" | head -1)
[ "$SOURCE_BASE" = "$BASE_IMAGE" ] ||
    fail "base image line does not match the qualification"
SOURCE_SNAPSHOT=$(sed -n 's/^ARG UBUNTU_SNAPSHOT=//p' \
    "$SOURCE_ROOT/containers/reproducible-build/Dockerfile" | head -1)
[ "$SOURCE_SNAPSHOT" = "$SNAPSHOT" ] ||
    fail "Ubuntu snapshot does not match the qualification"

[ "$(sha256_file "$ARCHIVE_DIR/image.spdx.json")" = "$IMAGE_SBOM_SHA256" ] ||
    fail "image SBOM hash does not match the qualification"
[ "$(sha256_file "$ARCHIVE_DIR/image-vulnerabilities.json")" = "$VULN_SHA256" ] ||
    fail "vulnerability report hash does not match the qualification"
[ "$(sha256_file "$ARCHIVE_DIR/dependency-inventory.txt")" = "$INVENTORY_SHA256" ] ||
    fail "inventory file hash does not match the qualification"

docker load -i "$ARCHIVE_DIR/image.oci.tar" > "$TMP/docker-load.log" 2>&1 ||
    fail "cannot load OCI archive"
RUN_REF=$(docker image inspect "$IMAGE_NAME" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null |
    awk -v d="$MANIFEST_DIGEST" 'index($0, d) { print; exit }')
[ -n "$RUN_REF" ] ||
    fail "loaded image has no repository digest for $MANIFEST_DIGEST"

docker run --rm --pull=never --network none --read-only \
    --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:rw,mode=1777 \
    "$RUN_REF" \
    dpkg-query -W -f='${Package} ${Version}\n' |
    LC_ALL=C sort > "$TMP/inventory.txt"
[ "$(sha256_file "$TMP/inventory.txt")" = "$INVENTORY_SHA256" ] ||
    fail "recomputed dependency inventory hash differs"

if [ "$VULN_SCAN" = "completed" ]; then
    TODAY=$(date -u +%F)
    CRITICAL_IDS=$(jq -r '
        [.matches[]?
         | select(((.vulnerability.severity // "") | ascii_downcase) == "critical")
         | .vulnerability.id]
        | unique | .[]
    ' "$ARCHIVE_DIR/image-vulnerabilities.json")
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        excepted=$(jq -r --arg id "$id" --arg today "$TODAY" '
            [.vulnerabilityExceptions[]?
             | select(.id == $id and (.expires // "") >= $today)]
            | length
        ' "$QUAL")
        [ "$excepted" -ge 1 ] ||
            fail "unresolved critical vulnerability in the image: $id"
    done <<EOF
$CRITICAL_IDS
EOF
fi

if [ "$TEST_BUILD" = "yes" ]; then
    docker run --rm --pull=never --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges \
        --tmpfs /tmp:rw,mode=1777 \
        "$RUN_REF" \
        sh -c 'command -v dpkg-buildpackage >/dev/null &&
               command -v fakeroot >/dev/null &&
               command -v git >/dev/null'
fi

echo "Build environment verification: PASS"
echo "Manifest digest:   $MANIFEST_DIGEST"
echo "Config digest:     $CONFIG_DIGEST"
echo "OCI archive:       $OCI_ARCHIVE_SHA256"
echo "Inventory:         $INVENTORY_SHA256"
