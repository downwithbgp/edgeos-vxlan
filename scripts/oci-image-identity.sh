#!/bin/sh
# Read and verify the distinct identities of an OCI image archive.
#
# An OCI layout has an index (possibly containing attestation manifests), a
# platform image manifest, and a config blob. This script selects the
# linux/amd64 image manifest, verifies every digest against the archive
# contents, and prints the identities separately.
#
# Usage:
#   oci-image-identity.sh --archive FILE [--output-dir DIR] [--json]
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/release-common.sh"

ARCHIVE=
OUTPUT_DIR=
JSON=no

usage()
{
    cat <<'EOF'
Usage: oci-image-identity.sh --archive FILE [options]

Options:
  --archive FILE    OCI archive tar
  --output-dir DIR  Keep the extracted layout in DIR (must be empty/absent)
  --json            Emit JSON instead of key=value lines
  -h, --help        Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --archive)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            ARCHIVE=$2
            shift 2
            ;;
        --output-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            OUTPUT_DIR=$2
            shift 2
            ;;
        --json)
            JSON=yes
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

[ -n "$ARCHIVE" ] || { usage >&2; exit 2; }
require_cmd tar jq sha256sum awk
require_file "$ARCHIVE"

# Reject unsafe archive paths before extraction.
tar -tf "$ARCHIVE" >/dev/null 2>&1 ||
    fail "not a readable tar archive: $ARCHIVE"
while IFS= read -r entry; do
    case "/$entry/" in
        */../*)
            fail "OCI archive contains a path traversal entry: $entry"
            ;;
        //*)
            fail "OCI archive contains an absolute path entry: $entry"
            ;;
    esac
done <<EOF
$(tar -tf "$ARCHIVE")
EOF

if [ -n "$OUTPUT_DIR" ]; then
    if [ -e "$OUTPUT_DIR" ]; then
        [ -d "$OUTPUT_DIR" ] || fail "output path is not a directory: $OUTPUT_DIR"
        [ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
            fail "output directory is not empty: $OUTPUT_DIR"
    else
        mkdir -p "$OUTPUT_DIR"
    fi
    LAYOUT=$OUTPUT_DIR
    CLEANUP=no
else
    LAYOUT=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-oci.XXXXXX") ||
        fail "cannot create temporary directory"
    CLEANUP=yes
fi

cleanup()
{
    if [ "$CLEANUP" = "yes" ]; then
        rm -rf "$LAYOUT"
    fi
}
trap cleanup EXIT HUP INT TERM

tar -xf "$ARCHIVE" -C "$LAYOUT" ||
    fail "cannot extract OCI archive"

[ -f "$LAYOUT/index.json" ] || fail "OCI archive has no index.json"

INDEX_SHA=$(sha256_file "$LAYOUT/index.json")
INDEX_DIGEST="sha256:$INDEX_SHA"

MANIFEST_DIGEST=$(jq -er '
    [.manifests[]
     | select((.annotations["vnd.docker.reference.type"] // "") != "attestation-manifest")
     | select((.platform.os // "linux") == "linux")
     | select((.platform.architecture // "amd64") == "amd64")
     | .digest]
    | if length == 1 then .[0]
      else error("expected exactly one linux/amd64 image manifest, found " + (length|tostring))
      end
' "$LAYOUT/index.json") || fail "cannot select the linux/amd64 image manifest"

is_digest "$MANIFEST_DIGEST" || fail "invalid manifest digest: $MANIFEST_DIGEST"

blob_path()
{
    printf '%s/blobs/sha256/%s\n' "$LAYOUT" "${1#sha256:}"
}

MANIFEST_BLOB=$(blob_path "$MANIFEST_DIGEST")
[ -f "$MANIFEST_BLOB" ] || fail "manifest blob is missing: $MANIFEST_DIGEST"
MANIFEST_SHA=$(sha256_file "$MANIFEST_BLOB")
[ "$MANIFEST_SHA" = "${MANIFEST_DIGEST#sha256:}" ] ||
    fail "manifest blob hash mismatch: $MANIFEST_SHA != ${MANIFEST_DIGEST#sha256:}"

CONFIG_DIGEST=$(jq -er '.config.digest' "$MANIFEST_BLOB") ||
    fail "manifest has no config digest"
is_digest "$CONFIG_DIGEST" || fail "invalid config digest: $CONFIG_DIGEST"

CONFIG_BLOB=$(blob_path "$CONFIG_DIGEST")
[ -f "$CONFIG_BLOB" ] || fail "config blob is missing: $CONFIG_DIGEST"
CONFIG_SHA=$(sha256_file "$CONFIG_BLOB")
[ "$CONFIG_SHA" = "${CONFIG_DIGEST#sha256:}" ] ||
    fail "config blob hash mismatch: $CONFIG_SHA != ${CONFIG_DIGEST#sha256:}"

ARCHIVE_SHA=$(sha256_file "$ARCHIVE")
MANIFEST_SIZE=$(stat -c '%s' "$MANIFEST_BLOB")
CONFIG_SIZE=$(stat -c '%s' "$CONFIG_BLOB")

if [ "$JSON" = "yes" ]; then
    jq -n \
        --arg archiveSha256 "$ARCHIVE_SHA" \
        --arg ociIndexDigest "$INDEX_DIGEST" \
        --arg manifestDigest "$MANIFEST_DIGEST" \
        --arg configDigest "$CONFIG_DIGEST" \
        --argjson manifestSize "$MANIFEST_SIZE" \
        --argjson configSize "$CONFIG_SIZE" \
        '{
            archiveSha256: $archiveSha256,
            ociIndexDigest: $ociIndexDigest,
            manifestDigest: $manifestDigest,
            configDigest: $configDigest,
            manifestSize: $manifestSize,
            configSize: $configSize
        }'
else
    printf 'archive_sha256=%s\n' "$ARCHIVE_SHA"
    printf 'oci_index_digest=%s\n' "$INDEX_DIGEST"
    printf 'manifest_digest=%s\n' "$MANIFEST_DIGEST"
    printf 'config_digest=%s\n' "$CONFIG_DIGEST"
    printf 'manifest_size=%s\n' "$MANIFEST_SIZE"
    printf 'config_size=%s\n' "$CONFIG_SIZE"
fi
