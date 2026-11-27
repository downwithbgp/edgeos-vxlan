#!/bin/bash
# Build and qualify the controlled reproducible build image.
#
# The image is built from the version-controlled Dockerfile into an OCI
# archive, loaded for local execution, inventoried, SBOM'd, vulnerability
# scanned, and described by a qualification record. The OCI index, platform
# manifest and config digests are deliberately recorded separately.
#
# Usage: build-environment.sh --output-dir DIR [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/release-common.sh"

OUTPUT_DIR=
IMAGE_NAME=${BUILD_IMAGE_NAME:-edgeos-vxlan-reproducible:qualified}
CONTEXT=${BUILD_CONTEXT:-"$ROOT/containers/reproducible-build"}
SKIP_VULNERABILITY=no
EXCEPTIONS=${VULNERABILITY_EXCEPTIONS:-"$ROOT/containers/reproducible-build/vulnerability-exceptions.json"}
POLICY="$ROOT/release/release-policy.json"

usage()
{
    cat <<'EOF'
Usage: build-environment.sh --output-dir DIR [options]

Options:
  --output-dir DIR        Empty/absent output directory
  --image-name NAME       Local image name (default: edgeos-vxlan-reproducible:qualified)
  --context DIR           Docker build context (default: containers/reproducible-build)
  --skip-vulnerability    Skip Grype (test-only; recorded as skipped)
  --exceptions FILE       Vulnerability exceptions JSON
  -h, --help              Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            OUTPUT_DIR=$2
            shift 2
            ;;
        --image-name)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            IMAGE_NAME=$2
            shift 2
            ;;
        --context)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            CONTEXT=$2
            shift 2
            ;;
        --skip-vulnerability)
            SKIP_VULNERABILITY=yes
            shift
            ;;
        --exceptions)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXCEPTIONS=$2
            shift 2
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

[ -n "$OUTPUT_DIR" ] || { usage >&2; exit 2; }
require_cmd docker jq sha256sum tar stat find sort awk sed dpkg-query
require_file "$CONTEXT/Dockerfile"
require_file "$CONTEXT/ca-certificates.crt"
require_file "$EXCEPTIONS"
require_file "$POLICY"
docker buildx version >/dev/null 2>&1 || fail "docker buildx is required"

if [ -e "$OUTPUT_DIR" ]; then
    [ -d "$OUTPUT_DIR" ] || fail "output path is not a directory: $OUTPUT_DIR"
    [ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        fail "output directory is not empty: $OUTPUT_DIR"
else
    mkdir -p "$OUTPUT_DIR"
fi
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

DOCKERFILE=$CONTEXT/Dockerfile
SNAPSHOT=$(sed -n 's/^ARG UBUNTU_SNAPSHOT=//p' "$DOCKERFILE" | head -1)
[ -n "$SNAPSHOT" ] || fail "Dockerfile has no UBUNTU_SNAPSHOT build argument"
printf '%s\n' "$SNAPSHOT" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' ||
    fail "invalid UBUNTU_SNAPSHOT: $SNAPSHOT"

echo "Building controlled image: $IMAGE_NAME"
echo "Context:                  $CONTEXT"
echo "Snapshot:                 $SNAPSHOT"

if ! docker buildx build \
    --output "type=oci,dest=$OUTPUT_DIR/image.oci.tar" \
    --output "type=docker,dest=$OUTPUT_DIR/image.docker.tar" \
    --metadata-file "$OUTPUT_DIR/build-metadata.json" \
    --build-arg "UBUNTU_SNAPSHOT=$SNAPSHOT" \
    --tag "$IMAGE_NAME" \
    "$CONTEXT" 2>&1 | tee "$OUTPUT_DIR/image-build.log" >/dev/null; then
    cat "$OUTPUT_DIR/image-build.log" >&2
    fail "Buildx image build failed"
fi

[ -f "$OUTPUT_DIR/image.oci.tar" ] ||
    fail "Buildx did not produce image.oci.tar"
[ -f "$OUTPUT_DIR/image.docker.tar" ] ||
    fail "Buildx did not produce image.docker.tar"

"$ROOT/scripts/oci-image-identity.sh" \
    --archive "$OUTPUT_DIR/image.oci.tar" \
    --json > "$OUTPUT_DIR/image-identity.json"

OCI_INDEX_DIGEST=$(jq -r '.ociIndexDigest' "$OUTPUT_DIR/image-identity.json")
MANIFEST_DIGEST=$(jq -r '.manifestDigest' "$OUTPUT_DIR/image-identity.json")
CONFIG_DIGEST=$(jq -r '.configDigest' "$OUTPUT_DIR/image-identity.json")
OCI_ARCHIVE_SHA256=$(jq -r '.archiveSha256' "$OUTPUT_DIR/image-identity.json")

require_digest_field "OCI index digest" "$OCI_INDEX_DIGEST"
require_digest_field "manifest digest" "$MANIFEST_DIGEST"
require_digest_field "config digest" "$CONFIG_DIGEST"
require_sha256_field "OCI archive checksum" "$OCI_ARCHIVE_SHA256"

docker load -i "$OUTPUT_DIR/image.docker.tar" > "$OUTPUT_DIR/docker-load.log" 2>&1 ||
    { cat "$OUTPUT_DIR/docker-load.log" >&2; fail "docker load failed for $OUTPUT_DIR/image.docker.tar"; }

RUN_REF=$(resolve_loaded_image_ref "$IMAGE_NAME" "$MANIFEST_DIGEST" "$CONFIG_DIGEST") ||
    fail "loaded image cannot be bound to the qualified manifest/config digest"
[ -n "$RUN_REF" ] ||
    fail "loaded image has no verified execution reference"

docker image inspect "$RUN_REF" >/dev/null 2>&1 ||
    fail "loaded image cannot be inspected by manifest digest: $RUN_REF"

echo "Running dependency inventory"
docker run --rm --pull=never --network none --read-only \
    --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:rw,mode=1777 \
    "$RUN_REF" \
    dpkg-query -W -f='${Package} ${Version}\n' |
    LC_ALL=C sort > "$OUTPUT_DIR/dependency-inventory.txt"

DEPENDENCY_INVENTORY_SHA256=$(sha256_file "$OUTPUT_DIR/dependency-inventory.txt")
DOCKERFILE_SHA256=$(sha256_file "$DOCKERFILE")
CA_BUNDLE_SHA256=$(sha256_file "$CONTEXT/ca-certificates.crt")
IMAGE_CONFIG_JSON_SHA256=$(
    docker image inspect "$RUN_REF" --format '{{json .Config}}' |
        sha256sum | awk '{print $1}'
)

grep '^FROM ' "$DOCKERFILE" > "$OUTPUT_DIR/base-image.txt"
grep '^ARG UBUNTU_SNAPSHOT' "$DOCKERFILE" > "$OUTPUT_DIR/dependency-snapshot.txt"
sha256sum "$DOCKERFILE" > "$OUTPUT_DIR/Dockerfile.sha256"
sha256sum "$CONTEXT/ca-certificates.crt" > "$OUTPUT_DIR/ca-certificates.sha256"
printf '%s\n' "$OCI_INDEX_DIGEST" > "$OUTPUT_DIR/oci-index-digest.txt"
printf '%s\n' "$MANIFEST_DIGEST" > "$OUTPUT_DIR/manifest-digest.txt"
printf '%s\n' "$CONFIG_DIGEST" > "$OUTPUT_DIR/config-digest.txt"
printf '%s\n' "$OCI_ARCHIVE_SHA256" > "$OUTPUT_DIR/oci-archive.sha256"

docker_archive_sha=$(sha256_file "$OUTPUT_DIR/image.docker.tar")
printf '%s\n' "$docker_archive_sha" > "$OUTPUT_DIR/docker-archive.sha256"

require_cmd syft
echo "Generating image SBOM"
syft scan "oci-archive:$OUTPUT_DIR/image.oci.tar" \
    -o "spdx-json=$OUTPUT_DIR/image.spdx.json" -q
IMAGE_SBOM_SHA256=$(sha256_file "$OUTPUT_DIR/image.spdx.json")

VULNERABILITY_SCAN=completed
CRITICAL_COUNT=0
VULNERABILITY_REPORT_SHA256=
VULNERABILITY_EXCEPTIONS='[]'

if [ "$SKIP_VULNERABILITY" = "yes" ]; then
    VULNERABILITY_SCAN=skipped
    printf '{"skipped":true,"matches":[]}\n' > "$OUTPUT_DIR/image-vulnerabilities.json"
else
    require_cmd grype
    echo "Scanning image vulnerabilities"
    grype "sbom:$OUTPUT_DIR/image.spdx.json" -o json \
        > "$OUTPUT_DIR/image-vulnerabilities.json"

    TODAY=$(date -u +%F)
    VULNERABILITY_EXCEPTIONS=$(jq -c '.exceptions // []' "$EXCEPTIONS")

    critical_ids=$(jq -r '
        [.matches[]?
         | select(((.vulnerability.severity // "") | ascii_downcase) == "critical")
         | .vulnerability.id]
        | unique | .[]
    ' "$OUTPUT_DIR/image-vulnerabilities.json")

    while IFS= read -r id; do
        [ -n "$id" ] || continue
        CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
        excepted=$(jq -r --arg id "$id" --arg today "$TODAY" '
            [.exceptions[]?
             | select(.id == $id and (.expires // "") >= $today)]
            | length
        ' "$EXCEPTIONS")
        [ "$excepted" -ge 1 ] ||
            fail "critical vulnerability $id has no unexpired reviewed exception"
    done <<EOF
$critical_ids
EOF
fi

VULNERABILITY_REPORT_SHA256=$(sha256_file "$OUTPUT_DIR/image-vulnerabilities.json")
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BASE_IMAGE=$(sed -n '1p' "$OUTPUT_DIR/base-image.txt")

jq -n \
    --arg imageName "$IMAGE_NAME" \
    --arg runRef "$RUN_REF" \
    --arg ociIndexDigest "$OCI_INDEX_DIGEST" \
    --arg manifestDigest "$MANIFEST_DIGEST" \
    --arg configDigest "$CONFIG_DIGEST" \
    --arg ociArchiveSha256 "$OCI_ARCHIVE_SHA256" \
    --arg dockerArchiveSha256 "$docker_archive_sha" \
    --arg dockerfileSha256 "$DOCKERFILE_SHA256" \
    --arg caBundleSha256 "$CA_BUNDLE_SHA256" \
    --arg baseImage "$BASE_IMAGE" \
    --arg dependencySnapshot "$SNAPSHOT" \
    --arg dependencyInventorySha256 "$DEPENDENCY_INVENTORY_SHA256" \
    --arg imageConfigJsonSha256 "$IMAGE_CONFIG_JSON_SHA256" \
    --arg imageSbomSha256 "$IMAGE_SBOM_SHA256" \
    --arg vulnerabilityReportSha256 "$VULNERABILITY_REPORT_SHA256" \
    --arg vulnerabilityScan "$VULNERABILITY_SCAN" \
    --argjson criticalVulnerabilities "$CRITICAL_COUNT" \
    --argjson vulnerabilityExceptions "$VULNERABILITY_EXCEPTIONS" \
    --arg createdAt "$CREATED_AT" \
    '{
        schemaVersion: 1,
        imageName: $imageName,
        runRef: $runRef,
        ociIndexDigest: $ociIndexDigest,
        manifestDigest: $manifestDigest,
        configDigest: $configDigest,
        ociArchiveSha256: $ociArchiveSha256,
        dockerArchiveSha256: $dockerArchiveSha256,
        dockerfileSha256: $dockerfileSha256,
        caBundleSha256: $caBundleSha256,
        baseImage: $baseImage,
        dependencySnapshot: $dependencySnapshot,
        dependencyInventorySha256: $dependencyInventorySha256,
        imageConfigJsonSha256: $imageConfigJsonSha256,
        imageSbomSha256: $imageSbomSha256,
        vulnerabilityReportSha256: $vulnerabilityReportSha256,
        vulnerabilityScan: $vulnerabilityScan,
        criticalVulnerabilities: $criticalVulnerabilities,
        vulnerabilityExceptions: $vulnerabilityExceptions,
        qualified: true,
        createdAt: $createdAt
    }
    + (if $dockerArchiveSha256 == "" then {} else {dockerArchiveSha256: $dockerArchiveSha256} end)
    ' > "$OUTPUT_DIR/build-environment-qualification.json"

echo
echo "Build environment qualification: PASS"
echo "Image:                 $IMAGE_NAME"
echo "Run reference:         $RUN_REF"
echo "OCI index digest:      $OCI_INDEX_DIGEST"
echo "Manifest digest:       $MANIFEST_DIGEST"
echo "Config digest:         $CONFIG_DIGEST"
echo "OCI archive SHA-256:   $OCI_ARCHIVE_SHA256"
echo "Inventory SHA-256:     $DEPENDENCY_INVENTORY_SHA256"
echo "Critical vulnerabilities: $CRITICAL_COUNT"
echo "Output:                $OUTPUT_DIR"
