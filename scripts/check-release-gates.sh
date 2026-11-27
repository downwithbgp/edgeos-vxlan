#!/bin/bash
# Fail-closed publication authorization gates.
#
# Real publication requires: a workflow_dispatch from main, the protected
# environment name, the repository enable variable, an immutable-release proof
# (admin token query or maintainer confirmation + post-publish check), and the
# exact confirmation string.
#
# When --candidate-dir is supplied the gate also requires that candidate to
# pass full candidate validation, including the mandatory IPv6-only
# qualification checks. The promotion path always supplies it, so a candidate
# that lost its qualification evidence cannot reach publication.
#
# Usage: check-release-gates.sh --tag TAG --confirm VALUE [--dry-run]
#                                [--candidate-dir DIR]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

TAG=
CONFIRM=
DRY_RUN=no
CANDIDATE_DIR=
POLICY=$ROOT/release/release-policy.json

usage()
{
    cat <<'EOF'
Usage: check-release-gates.sh --tag TAG --confirm VALUE [--dry-run]

Options:
  --tag TAG            Release tag
  --confirm V          Exact confirmation value
  --candidate-dir DIR  Extracted candidate; requires full validation,
                        including IPv6-only qualification, before publication
  --dry-run            Report the gates without requiring publication state
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            TAG=$2
            shift 2
            ;;
        --confirm)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            CONFIRM=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=yes
            shift
            ;;
        --candidate-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            CANDIDATE_DIR=$2
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

[ -n "$TAG" ] || { usage >&2; exit 2; }
is_release_tag "$TAG" || fail "invalid release tag: $TAG"
require_file "$POLICY"
ENVIRONMENT=$(jq -r '.publication.environment' "$POLICY")
ENABLE_VAR=$(jq -r '.publication.enableVariable' "$POLICY")
IMMUTABLE_VAR=$(jq -r '.publication.immutableConfirmedVariable' "$POLICY")
EXPECTED_CONFIRM=$(jq -r '.publication.confirmValue' "$POLICY")

if [ "$DRY_RUN" = "yes" ]; then
    echo "Release gates: DRY-RUN"
    echo "Tag:                 $TAG"
    echo "Environment:         $ENVIRONMENT (must be protected before activation)"
    echo "Enable variable:     $ENABLE_VAR=true"
    echo "Immutable proof:     $IMMUTABLE_VAR=true + post-publish check"
    echo "Confirmation:        $CONFIRM"
    echo "Candidate:           ${CANDIDATE_DIR:-(not supplied; qualification not re-checked)}"
    exit 0
fi

[ "${GITHUB_ACTIONS:-}" = "true" ] ||
    fail "publication must run in GitHub Actions"
[ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ] ||
    fail "publication must be a workflow_dispatch"
[ "${GITHUB_REF:-}" = "refs/heads/main" ] ||
    fail "publication must run from refs/heads/main"
[ "${RELEASE_ENVIRONMENT:-}" = "$ENVIRONMENT" ] ||
    fail "publication environment is not $ENVIRONMENT"
[ "${!ENABLE_VAR:-}" = "true" ] ||
    fail "variable $ENABLE_VAR is not true (expected in $ENVIRONMENT)"
[ "$CONFIRM" = "$EXPECTED_CONFIRM" ] ||
    fail "confirmation value does not match the policy"

if [ -n "${IMMUTABLE_RELEASES_ADMIN_TOKEN:-}" ]; then
    fail "administrative immutable-release tokens are not accepted in the publication path"
fi
[ "${!IMMUTABLE_VAR:-}" = "true" ] ||
    fail "set $IMMUTABLE_VAR=true only after enabling immutable releases"
note "immutable state is confirmed by the maintainer variable; post-publish verification is mandatory"

# The candidate must still satisfy the full qualification contract, including
# the mandatory IPv6-only checks, at publication time. This is independent of
# any earlier preflight validation.
if [ -n "$CANDIDATE_DIR" ]; then
    require_dir "$CANDIDATE_DIR"
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$CANDIDATE_DIR"         >/dev/null ||
        fail "candidate does not satisfy the publication qualification contract"
    note "candidate validation (including IPv6-only qualification) passed"
fi

echo "Release gates: PASS"
echo "Tag:           $TAG"
echo "Environment:   $ENVIRONMENT"
