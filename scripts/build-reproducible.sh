#!/bin/sh
# Canonical reproducible build entry point.
#
# Builds the two Debian packages from a clean archived Git revision in a
# temporary source tree whose file and directory mtimes are normalized to the
# changelog timestamp.  The developer's working tree is never touched.
#
# Usage:
#   build-reproducible.sh [--source-rev REV] [--output-dir DIR] [--keep-source]
#
# The output directory must be empty or absent.  It receives the .deb files,
# .buildinfo, .changes and a SHA256SUMS manifest.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_REV=HEAD
SOURCE_ARCHIVE=
SOURCE_COMMIT=
OUTPUT_DIR=${BUILD_OUTPUT_DIR:-"$ROOT/../edgeos-vxlan-reproducible-build"}
KEEP_SOURCE=no

usage()
{
    cat <<'EOF'
Usage: build-reproducible.sh [options]

Options:
  --source-rev REV    Git revision to archive (default: HEAD)
  --source-archive TAR  Pre-materialized source archive (container mode)
  --source-commit SHA   Exact commit represented by --source-archive
  --output-dir DIR    Empty/absent output directory
  --keep-source       Keep the materialized and normalized source tree
  -h, --help          Show this help
EOF
}

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

note()
{
    echo "NOTE: $*" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --source-rev)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_REV=$2
            shift 2
            ;;
        --source-archive)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_ARCHIVE=$2
            shift 2
            ;;
        --source-commit)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_COMMIT=$2
            shift 2
            ;;
        --output-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            OUTPUT_DIR=$2
            shift 2
            ;;
        --keep-source)
            KEEP_SOURCE=yes
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

for cmd in git tar find touch dpkg-parsechangelog dpkg-buildpackage \
           sha256sum awk sed; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "required command not found: $cmd"
done

if [ -n "$SOURCE_ARCHIVE" ]; then
    [ -f "$SOURCE_ARCHIVE" ] ||
        fail "source archive not found: $SOURCE_ARCHIVE"
    [ -n "$SOURCE_COMMIT" ] ||
        fail "--source-archive requires --source-commit"
    case "$SOURCE_COMMIT" in
        *[!0-9a-f]*) fail "invalid source commit: $SOURCE_COMMIT" ;;
    esac
    [ "${#SOURCE_COMMIT}" -eq 40 ] || [ "${#SOURCE_COMMIT}" -eq 64 ] ||
        fail "invalid source commit length: $SOURCE_COMMIT"
    COMMIT=$SOURCE_COMMIT
else
    git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
        fail "not a Git checkout: $ROOT"

    COMMIT=$(git -C "$ROOT" rev-parse --verify --quiet "${SOURCE_REV}^{commit}") ||
        fail "cannot resolve source revision: $SOURCE_REV"

    DIRTY=$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain --untracked-files=no)
    if [ -n "$DIRTY" ]; then
        if [ "$SOURCE_REV" = "HEAD" ]; then
            printf '%s\n' "$DIRTY" >&2
            fail "working tree has tracked changes; commit/stash them or pass --source-rev"
        fi
        note "working tree is dirty; building archived revision $SOURCE_REV, not the working tree"
    fi

    [ -z "$(git -C "$ROOT" submodule status 2>/dev/null)" ] ||
        fail "submodules are not supported by the canonical build"
fi

if [ -e "$OUTPUT_DIR" ]; then
    [ -d "$OUTPUT_DIR" ] || fail "output path is not a directory: $OUTPUT_DIR"
    [ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
        fail "output directory is not empty: $OUTPUT_DIR"
else
    mkdir -p "$OUTPUT_DIR" || fail "cannot create output directory: $OUTPUT_DIR"
fi
OUTPUT_DIR=$(CDPATH='' cd -- "$OUTPUT_DIR" && pwd) ||
    fail "cannot resolve output directory"

SRC=$OUTPUT_DIR/source
mkdir -p "$SRC" || fail "cannot create source directory: $SRC"

if [ -n "$SOURCE_ARCHIVE" ]; then
    tar -xf "$SOURCE_ARCHIVE" -C "$SRC" ||
        fail "cannot extract provided source archive"
else
    ARCHIVE=$OUTPUT_DIR/source.tar
    cleanup_archive()
    {
        rm -f "$ARCHIVE"
    }
    git -C "$ROOT" archive --format=tar "$COMMIT" > "$ARCHIVE" ||
        { cleanup_archive; fail "git archive failed for $COMMIT"; }
    tar -xf "$ARCHIVE" -C "$SRC" ||
        { cleanup_archive; fail "cannot extract source archive"; }
    cleanup_archive
fi

[ -f "$SRC/debian/changelog" ] ||
    fail "archived source has no debian/changelog"

EPOCH=$(dpkg-parsechangelog -l "$SRC/debian/changelog" -S Timestamp) ||
    fail "cannot derive SOURCE_DATE_EPOCH from debian/changelog"
case "$EPOCH" in
    ''|*[!0-9]*) fail "invalid changelog timestamp: $EPOCH" ;;
esac

if [ -n "${SOURCE_DATE_EPOCH:-}" ] && [ "$SOURCE_DATE_EPOCH" != "$EPOCH" ]; then
    fail "environment SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH differs from changelog timestamp $EPOCH"
fi

# Normalize payload files first, then directories, so touching a child cannot
# leave a parent directory with a newer mtime.
find "$SRC" \( -type f -o -type l \) -exec touch -h -d "@$EPOCH" {} + ||
    fail "cannot normalize source-file timestamps"
find "$SRC" -type d -exec touch -h -d "@$EPOCH" {} + ||
    fail "cannot normalize source-directory timestamps"

VERSION=$(dpkg-parsechangelog -l "$SRC/debian/changelog" -S Version) ||
    fail "cannot read package version"
KMOD="edgeos-vxlan-kmod_${VERSION}_mipsel.deb"
INTEGRATION="edgeos-vxlan_${VERSION}_all.deb"

echo "Source revision:   $SOURCE_REV"
echo "Source commit:     $COMMIT"
echo "SOURCE_DATE_EPOCH: $EPOCH ($(date -u -d "@$EPOCH" '+%Y-%m-%dT%H:%M:%SZ'))"
echo "Output:            $OUTPUT_DIR"
echo "Building..."

(
    umask 0022
    cd "$SRC"
    export LC_ALL=C LANG=C TZ=UTC SOURCE_DATE_EPOCH="$EPOCH"
    dpkg-buildpackage -us -uc -b -a mipsel
)

[ -f "$OUTPUT_DIR/$KMOD" ] ||
    fail "expected package not produced: $OUTPUT_DIR/$KMOD"
[ -f "$OUTPUT_DIR/$INTEGRATION" ] ||
    fail "expected package not produced: $OUTPUT_DIR/$INTEGRATION"

(
    cd "$OUTPUT_DIR"
    sha256sum -- "$KMOD" "$INTEGRATION" > SHA256SUMS
)

if [ "$KEEP_SOURCE" = "no" ]; then
    rm -rf "$SRC"
fi

echo
echo "Canonical build complete."
echo "Kmod SHA256:        $(awk -v n="$KMOD" '$2 == n { print $1 }' "$OUTPUT_DIR/SHA256SUMS")"
echo "Integration SHA256: $(awk -v n="$INTEGRATION" '$2 == n { print $1 }' "$OUTPUT_DIR/SHA256SUMS")"
