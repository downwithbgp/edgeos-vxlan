#!/bin/sh
# Independent reproducibility verification for the canonical build.
#
# Usage:
#   verify-reproducible-build.sh [--source-rev REV] [--work-dir DIR] [--keep]
#
# Builds twice through scripts/build-reproducible.sh in different directories,
# with different host timezone/locale/umask contexts and a short delay, then
# compares every produced Debian package and the generated SHA256SUMS.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_REV=HEAD
WORK_DIR=
KEEP=no
SUCCESS=no

usage()
{
    cat <<'EOF'
Usage: verify-reproducible-build.sh [options]

Options:
  --source-rev REV    Git revision to build (default: HEAD)
  --work-dir DIR      Empty/absent working directory (default: mktemp)
  --keep              Keep the working directory and build logs
  -h, --help          Show this help
EOF
}

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

cleanup()
{
    if [ "$SUCCESS" = "yes" ] && [ "$KEEP" = "no" ] && [ -n "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT HUP INT TERM

while [ $# -gt 0 ]; do
    case "$1" in
        --source-rev)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_REV=$2
            shift 2
            ;;
        --work-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            WORK_DIR=$2
            shift 2
            ;;
        --keep)
            KEEP=yes
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

for cmd in cmp find sha256sum dpkg-deb tar; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "required command not found: $cmd"
done

if [ -n "$WORK_DIR" ]; then
    if [ -e "$WORK_DIR" ]; then
        [ -d "$WORK_DIR" ] || fail "work path is not a directory: $WORK_DIR"
        [ -z "$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
            fail "work directory is not empty: $WORK_DIR"
    else
        mkdir -p "$WORK_DIR" || fail "cannot create work directory: $WORK_DIR"
    fi
    WORK_DIR=$(CDPATH='' cd -- "$WORK_DIR" && pwd) ||
        fail "cannot resolve work directory"
else
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-repro.XXXXXX") ||
        fail "cannot create work directory"
fi

OUT_A=$WORK_DIR/build-a
OUT_B=$WORK_DIR/build-b
mkdir -p "$OUT_A" "$OUT_B" || fail "cannot create build directories"

unset SOURCE_DATE_EPOCH

echo "Building A..."
(
    TZ=UTC
    LC_ALL=C
    LANG=C
    export TZ LC_ALL LANG
    "$ROOT/scripts/build-reproducible.sh" \
        --source-rev "$SOURCE_REV" --output-dir "$OUT_A"
) > "$WORK_DIR/build-a.log" 2>&1 ||
    { cat "$WORK_DIR/build-a.log" >&2; fail "build A failed"; }

sleep 1

echo "Building B..."
(
    umask 0077
    TZ=America/New_York
    LC_ALL=C.UTF-8
    LANG=C.UTF-8
    export TZ LC_ALL LANG
    "$ROOT/scripts/build-reproducible.sh" \
        --source-rev "$SOURCE_REV" --output-dir "$OUT_B"
) > "$WORK_DIR/build-b.log" 2>&1 ||
    { cat "$WORK_DIR/build-b.log" >&2; fail "build B failed"; }

find "$OUT_A" -mindepth 1 -maxdepth 1 -name '*.deb' -printf '%f\n' |
    LC_ALL=C sort > "$WORK_DIR/a.debs"
find "$OUT_B" -mindepth 1 -maxdepth 1 -name '*.deb' -printf '%f\n' |
    LC_ALL=C sort > "$WORK_DIR/b.debs"

if ! cmp -s "$WORK_DIR/a.debs" "$WORK_DIR/b.debs"; then
    echo "Package name sets differ:" >&2
    diff -u "$WORK_DIR/a.debs" "$WORK_DIR/b.debs" >&2 || true
    fail "package name sets differ"
fi

[ -s "$WORK_DIR/a.debs" ] || fail "no packages were produced"

failed=no
while IFS= read -r deb; do
    if ! cmp -s "$OUT_A/$deb" "$OUT_B/$deb"; then
        failed=yes
        echo "DIFF: $deb" >&2
        if command -v diffoscope >/dev/null 2>&1; then
            diffoscope --text "$WORK_DIR/diffoscope-$deb.txt" \
                "$OUT_A/$deb" "$OUT_B/$deb" >/dev/null 2>&1 || true
            echo "  diffoscope: $WORK_DIR/diffoscope-$deb.txt" >&2
        else
            dpkg-deb --fsys-tarfile "$OUT_A/$deb" > "$WORK_DIR/a-data.tar" ||
                true
            dpkg-deb --fsys-tarfile "$OUT_B/$deb" > "$WORK_DIR/b-data.tar" ||
                true
            tar --full-time -tvf "$WORK_DIR/a-data.tar" > "$WORK_DIR/a-data.list" ||
                true
            tar --full-time -tvf "$WORK_DIR/b-data.tar" > "$WORK_DIR/b-data.list" ||
                true
            diff -u "$WORK_DIR/a-data.list" "$WORK_DIR/b-data.list" >&2 || true
        fi
    else
        echo "SAME: $deb"
    fi
done < "$WORK_DIR/a.debs"

if ! cmp -s "$OUT_A/SHA256SUMS" "$OUT_B/SHA256SUMS"; then
    failed=yes
    echo "DIFF: SHA256SUMS" >&2
    diff -u "$OUT_A/SHA256SUMS" "$OUT_B/SHA256SUMS" >&2 || true
fi

if [ "$failed" = "yes" ]; then
    fail "reproducibility verification failed; work directory: $WORK_DIR"
fi

SUCCESS=yes

echo
echo "Reproducibility verification: PASS"
echo "Source revision: $SOURCE_REV"
echo "Work directory:  $WORK_DIR"
while IFS= read -r deb; do
    sha256sum "$OUT_A/$deb"
done < "$WORK_DIR/a.debs"
