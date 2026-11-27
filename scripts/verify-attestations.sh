#!/bin/bash
# Verify GitHub artifact attestations for a candidate or release asset set.
#
# The bundle is treated as offline evidence. The verifier binds the repository,
# signer workflow revision, source commit/ref, subject digest and OIDC issuer,
# and checks the certificate's repository identifier (names alone are not
# sufficient for an offline bundle).
#
# Usage:
#   verify-attestations.sh --candidate-dir DIR --bundle FILE [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

DIR=
BUNDLE=
TRUSTED_ROOT=
GH_BIN=${GH_BIN:-gh}
REPO=
WORKFLOW=
SIGNER_DIGEST=
SOURCE_DIGEST=
SOURCE_REF=
PREDICATE=https://slsa.dev/provenance/v1
VERIFY_SBOM=yes

usage()
{
    cat <<'EOF'
Usage: verify-attestations.sh --candidate-dir DIR --bundle FILE [options]

Options:
  --candidate-dir DIR   Candidate directory with release-candidate.json
  --bundle FILE         Offline attestation bundle (JSON/JSONL)
  --trusted-root FILE   Optional custom Sigstore trusted root
  --repo OWNER/REPO     Override repository
  --workflow PATH       Override signer workflow
  --signer-digest SHA   Override signer workflow digest
  --source-digest SHA   Override source commit digest
  --source-ref REF      Override source ref
  --predicate-type URI  Provenance predicate type
  --no-sbom             Do not verify the SBOM attestation
  -h, --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --candidate-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            DIR=$2
            shift 2
            ;;
        --bundle)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            BUNDLE=$2
            shift 2
            ;;
        --trusted-root)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            TRUSTED_ROOT=$2
            shift 2
            ;;
        --repo)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            REPO=$2
            shift 2
            ;;
        --workflow)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            WORKFLOW=$2
            shift 2
            ;;
        --signer-digest)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SIGNER_DIGEST=$2
            shift 2
            ;;
        --source-digest)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_DIGEST=$2
            shift 2
            ;;
        --source-ref)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_REF=$2
            shift 2
            ;;
        --predicate-type)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            PREDICATE=$2
            shift 2
            ;;
        --no-sbom)
            VERIFY_SBOM=no
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

if [ -z "$DIR" ] || [ -z "$BUNDLE" ]; then
    usage >&2
    exit 2
fi
require_dir "$DIR"
require_file "$DIR/release-candidate.json"
require_file "$BUNDLE"
require_cmd "$GH_BIN" jq sha256sum
command -v "$GH_BIN" >/dev/null 2>&1 || fail "GitHub CLI not found: $GH_BIN"

MANIFEST=$DIR/release-candidate.json
POLICY=$ROOT/release/release-policy.json
[ -z "$REPO" ] && REPO=$(jq -r '.project.repository' "$POLICY")
[ -z "$WORKFLOW" ] && WORKFLOW="$REPO/$(jq -r '.attestation.workflowPath' "$POLICY")"
[ -z "$SIGNER_DIGEST" ] && SIGNER_DIGEST=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.commit')
[ -z "$SOURCE_DIGEST" ] && SOURCE_DIGEST=$(manifest_get "$MANIFEST" '.source.commit')
[ -z "$SOURCE_REF" ] && SOURCE_REF=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.ref')
EXPECTED_REPO_ID=$(jq -r '.project.repositoryId' "$POLICY")

require_commit_field "signer digest" "$SIGNER_DIGEST"
require_commit_field "source digest" "$SOURCE_DIGEST"
printf '%s\n' "$SOURCE_REF" | grep -Eq '^refs/(heads|tags)/' ||
    fail "invalid source ref: $SOURCE_REF"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-attest.XXXXXX") ||
    fail "cannot create temporary directory"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

verify_subject()
{
    local subject=$1
    local predicate=$2
    local output=$TMP/verify.json

    set -- "$GH_BIN" attestation verify "$subject" \
        --repo "$REPO" \
        --bundle "$BUNDLE" \
        --signer-workflow "$WORKFLOW" \
        --signer-digest "$SIGNER_DIGEST" \
        --source-digest "$SOURCE_DIGEST" \
        --source-ref "$SOURCE_REF" \
        --cert-oidc-issuer https://token.actions.githubusercontent.com \
        --deny-self-hosted-runners \
        --predicate-type "$predicate" \
        --format json
    if [ -n "$TRUSTED_ROOT" ]; then
        set -- "$@" --custom-trusted-root "$TRUSTED_ROOT"
    fi

    "$@" > "$output" ||
        fail "attestation verification failed for $(basename "$subject") ($predicate)"

    repo_ids=$(jq -r '
        .[]?.verificationResult.signature.certificate.sourceRepositoryIdentifier //
        empty
    ' "$output" | LC_ALL=C sort -u)
    [ -n "$repo_ids" ] ||
        fail "attestation certificate exposes no repository identifier for $(basename "$subject")"
    [ "$(printf '%s\n' "$repo_ids" | wc -l)" -eq 1 ] ||
        fail "multiple repository identifiers for $(basename "$subject")"
    [ "$repo_ids" = "$EXPECTED_REPO_ID" ] ||
        fail "attestation repository ID $repo_ids != expected $EXPECTED_REPO_ID"
}

verify_subject "$MANIFEST" "$PREDICATE"

while IFS= read -r name; do
    [ -n "$name" ] || continue
    verify_subject "$DIR/$name" "$PREDICATE"
done < <(jq -r '.artifacts[].name' "$MANIFEST")

if [ "$VERIFY_SBOM" = "yes" ]; then
    PKG_VERSION=$(manifest_get "$MANIFEST" '.project.packageVersion')
    INTEGRATION="edgeos-vxlan_${PKG_VERSION}_all.deb"
    KMOD="edgeos-vxlan-kmod_${PKG_VERSION}_mipsel.deb"
    for package in "$INTEGRATION" "$KMOD"; do
        [ -f "$DIR/$package" ] || fail "missing package for SBOM attestation: $package"
        verify_subject "$DIR/$package" "https://spdx.dev/Document"
    done
fi

echo "Attestation verification: PASS"
echo "Repository:               $REPO"
echo "Signer workflow:          $WORKFLOW"
echo "Signer digest:            $SIGNER_DIGEST"
echo "Source commit/ref:        $SOURCE_DIGEST $SOURCE_REF"
