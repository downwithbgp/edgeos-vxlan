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

for cmd in docker git id sha256sum mktemp; do
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

COMMIT=$(git -C "$ROOT" rev-parse --verify --quiet "${SOURCE_REV}^{commit}") ||
    fail "cannot resolve source revision: $SOURCE_REV"
DIRTY=$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain --untracked-files=no)
if [ -n "$DIRTY" ]; then
    if [ "$SOURCE_REV" = "HEAD" ]; then
        printf '%s\n' "$DIRTY" >&2
        fail "working tree has tracked changes; commit/stash them or pass --source-rev"
    fi
    echo "NOTE: dirty working tree ignored for explicit source revision $SOURCE_REV" >&2
fi

ARCHIVE=$(mktemp "${TMPDIR:-/tmp}/edgeos-vxlan-source.XXXXXX.tar") ||
    fail "cannot create source archive path"
cleanup_archive()
{
    rm -f "$ARCHIVE"
}
trap cleanup_archive EXIT HUP INT TERM
git -C "$ROOT" archive --format=tar "$COMMIT" > "$ARCHIVE" ||
    fail "cannot archive source commit $COMMIT"
ARCHIVE_SHA=$(sha256sum "$ARCHIVE" | cut -d ' ' -f1)
echo "Source revision: $SOURCE_REV"
echo "Source commit:   $COMMIT"
echo "Source archive:  $ARCHIVE_SHA"

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
    -v "$ARCHIVE:/input/source.tar:ro" \
    -v "$OUTPUT_DIR:/out" \
    -w /src \
    "$IMAGE" \
    /src/scripts/build-reproducible.sh \
        --source-archive /input/source.tar \
        --source-commit "$COMMIT" \
        --source-rev "$SOURCE_REV" \
        --output-dir /out

echo
echo "Controlled build complete: $OUTPUT_DIR"
sha256sum "$OUTPUT_DIR"/*.deb
