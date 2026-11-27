#!/bin/bash
# Verify that an attested SBOM predicate corresponds to the expected SBOM.
#
# Signature, issuer, signer and subject-digest verification is performed
# separately by verify-attestations.sh via `gh attestation verify`. This script
# proves the remaining property: the predicate carried by the bundle is bound
# to the exact package subject and is the exact SBOM document shipped with the
# candidate. The bundle is treated as untrusted data.
#
# Usage:
#   verify-sbom-predicate.sh --bundle FILE --package FILE --sbom FILE \
#     [--predicate-type URI]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

BUNDLE=
PACKAGE=
SBOM=
PREDICATE=https://spdx.dev/Document/v2.3

usage()
{
    cat <<'EOF'
Usage: verify-sbom-predicate.sh --bundle FILE --package FILE --sbom FILE \
         [--predicate-type URI]

Options:
  --bundle FILE         Attestation bundle (JSON or JSONL), untrusted data
  --package FILE        Package the SBOM attestation must be bound to
  --sbom FILE           Expected SBOM document
  --predicate-type URI  Expected SBOM predicate type
  -h, --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            BUNDLE=$2
            shift 2
            ;;
        --package)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            PACKAGE=$2
            shift 2
            ;;
        --sbom)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SBOM=$2
            shift 2
            ;;
        --predicate-type)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            PREDICATE=$2
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

if [ -z "$BUNDLE" ] || [ -z "$PACKAGE" ] || [ -z "$SBOM" ]; then
    usage >&2
    exit 2
fi
require_file "$BUNDLE"
require_file "$PACKAGE"
require_file "$SBOM"
require_cmd jq sha256sum

case "$PREDICATE" in
    https://spdx.dev/Document/v*) ;;
    *) fail "unsupported SBOM predicate type: $PREDICATE" ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-sbom-predicate.XXXXXX") ||
    fail "cannot create temporary directory"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

NAME=$(basename "$PACKAGE")
DIGEST=$(sha256_file "$PACKAGE")

# A bundle file may hold one JSON document or a JSONL stream. Select exactly
# the statement whose predicate type and subject (name + digest) match.
jq -s --arg pt "$PREDICATE" --arg name "$NAME" --arg digest "$DIGEST" '
    [ .[]
      | select(.dsseEnvelope != null)
      | select(.dsseEnvelope.payloadType == "application/vnd.in-toto+json")
      | (.dsseEnvelope.payload | @base64d | fromjson)
      | select(.predicateType == $pt)
      | select(any(.subject[]?; .name == $name and .digest.sha256 == $digest))
      | .predicate ]
' "$BUNDLE" > "$TMP/predicates.json" 2>"$TMP/jq.err" ||
    { cat "$TMP/jq.err" >&2; fail "cannot parse the attestation bundle"; }

COUNT=$(jq 'length' "$TMP/predicates.json")
[ "$COUNT" -eq 1 ] ||
    fail "expected exactly one $PREDICATE predicate for $NAME, found $COUNT"

jq -S -c '.[0]' "$TMP/predicates.json" > "$TMP/attested.json"
jq -S -c . "$SBOM" > "$TMP/expected.json"
cmp -s "$TMP/attested.json" "$TMP/expected.json" ||
    fail "attested SBOM predicate does not match $(basename "$SBOM")"

echo "SBOM predicate verification: PASS"
echo "Package:                     $NAME"
echo "Package SHA-256:             $DIGEST"
echo "Predicate type:              $PREDICATE"
echo "SBOM:                        $(basename "$SBOM")"
