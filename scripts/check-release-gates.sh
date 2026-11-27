#!/bin/bash
# Fail-closed publication authorization gates.
#
# Real publication requires: a workflow_dispatch from main, the protected
# environment name, the repository enable variable, an immutable-release proof
# (admin token query or maintainer confirmation + post-publish check), and the
# exact confirmation string.
#
# Usage: check-release-gates.sh --tag TAG --confirm VALUE [--dry-run]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

TAG=
CONFIRM=
DRY_RUN=no
POLICY=$ROOT/release/release-policy.json

usage()
{
    cat <<'EOF'
Usage: check-release-gates.sh --tag TAG --confirm VALUE [--dry-run]

Options:
  --tag TAG       Release tag
  --confirm V     Exact confirmation value
  --dry-run       Report the gates without requiring publication state
  -h, --help      Show this help
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
[ "${RELEASE_PUBLICATION_ENABLED:-}" = "true" ] ||
    fail "repository variable $ENABLE_VAR is not true"
[ "$CONFIRM" = "$EXPECTED_CONFIRM" ] ||
    fail "confirmation value does not match the policy"

if [ -n "${IMMUTABLE_RELEASES_ADMIN_TOKEN:-}" ]; then
    fail "administrative immutable-release tokens are not accepted in the publication path"
fi
[ "${IMMUTABLE_RELEASES_CONFIRMED:-}" = "true" ] ||
    fail "set $IMMUTABLE_VAR=true only after enabling immutable releases"
note "immutable state is confirmed by the maintainer variable; post-publish verification is mandatory"

echo "Release gates: PASS"
echo "Tag:           $TAG"
echo "Environment:   $ENVIRONMENT"
