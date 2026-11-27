#!/bin/sh
# Run the canonical reproducible build inside the controlled container.
#
# Usage:
#   build-reproducible-container.sh [--source-rev REV] [--output-dir DIR]
#                                   [--image IMAGE] [--snapshot SNAPSHOT]
#                                   [--no-build]
#
# The image is built from containers/reproducible-build/Dockerfile with a
# digest-pinned Ubuntu base and a fixed snapshot.  The build runs with no
# network, a read-only repository mount, a writable output directory and a
# writable tmpfs.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_REV=HEAD
OUTPUT_DIR=${BUILD_OUTPUT_DIR:-"$ROOT/../edgeos-vxlan-reproducible-build"}
IMAGE=${BUILD_IMAGE:-edgeos-vxlan-reproducible:24.04-20261127}
SNAPSHOT=${UBUNTU_SNAPSHOT:-20261127T000000Z}
BUILD_IMAGE=yes

usage()
{
    cat <<'EOF'
Usage: build-reproducible-container.sh [options]

Options:
  --source-rev REV    Git revision to build (default: HEAD)
  --output-dir DIR    Empty/absent output directory
  --image IMAGE       Container image tag/name
  --snapshot STAMP    Ubuntu snapshot timestamp
  --no-build          Use an existing image instead of building it
  -h, --help          Show this help
EOF
}

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --source-rev)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_REV=$2
            shift 2
            ;;
        --output-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            OUTPUT_DIR=$2
            shift 2
            ;;
        --image)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            IMAGE=$2
            shift 2
            ;;
        --snapshot)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SNAPSHOT=$2
            shift 2
            ;;
        --no-build)
            BUILD_IMAGE=no
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

for cmd in docker git id; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "required command not found: $cmd"
done

if [ -e "$OUTPUT_DIR" ]; then
    [ -d "$OUTPUT_DIR" ] || fail "output path is not a directory: $OUTPUT_DIR"
    [ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        fail "output directory is not empty: $OUTPUT_DIR"
else
    mkdir -p "$OUTPUT_DIR" || fail "cannot create output directory: $OUTPUT_DIR"
fi
OUTPUT_DIR=$(CDPATH='' cd -- "$OUTPUT_DIR" && pwd) ||
    fail "cannot resolve output directory"

if [ "$BUILD_IMAGE" = "yes" ]; then
    echo "Building controlled image: $IMAGE"
    docker build \
        --build-arg "UBUNTU_SNAPSHOT=$SNAPSHOT" \
        --tag "$IMAGE" \
        "$ROOT/containers/reproducible-build"
else
    docker image inspect "$IMAGE" >/dev/null 2>&1 ||
        fail "container image not found: $IMAGE"
fi

echo "Running canonical build in controlled container..."
docker run --rm \
    --network none \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" \
    --tmpfs /tmp:rw,mode=1777 \
    -e HOME=/tmp \
    -v "$ROOT:/src:ro" \
    -v "$OUTPUT_DIR:/out" \
    -w /src \
    "$IMAGE" \
    /src/scripts/build-reproducible.sh \
        --source-rev "$SOURCE_REV" \
        --output-dir /out

echo
echo "Controlled build complete: $OUTPUT_DIR"
sha256sum "$OUTPUT_DIR"/*.deb
