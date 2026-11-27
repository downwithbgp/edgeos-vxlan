#!/bin/sh
# Enforce the pin-only A -> B release preparation contract.
#
# B may update installer pins, the package checksum manifest and release
# documentation, but it must not change package-affecting inputs. The
# packaging-inputs digest is the secondary equality proof.
#
# Usage: check-pin-commit.sh [--repo DIR] <A> <B>
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/release-common.sh"

REPO=$ROOT
if [ "${1:-}" = "--repo" ]; then
    [ $# -ge 3 ] || { echo "ERROR: --repo requires a directory" >&2; exit 2; }
    REPO=$2
    shift 2
fi

[ $# -eq 2 ] || { echo "Usage: $0 [--repo DIR] <A> <B>" >&2; exit 2; }
A=$1
B=$2

require_cmd git
require_file "$ROOT/scripts/packaging-inputs.sh"

REPO=$(CDPATH='' cd -- "$REPO" && pwd) || fail "cannot resolve repo: $REPO"
A_COMMIT=$(git -C "$REPO" rev-parse --verify --quiet "${A}^{commit}") ||
    fail "cannot resolve A: $A"
B_COMMIT=$(git -C "$REPO" rev-parse --verify --quiet "${B}^{commit}") ||
    fail "cannot resolve B: $B"

[ "$A_COMMIT" != "$B_COMMIT" ] ||
    fail "A and B are the same commit; a pin commit must add the release pins"

git -C "$REPO" merge-base --is-ancestor "$A_COMMIT" "$B_COMMIT" ||
    fail "A ($A_COMMIT) is not an ancestor of B ($B_COMMIT)"

bad=
while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
        install.sh|SHA256SUMS|README.md|docs/*|.github/*|spec/*|test/*)
            ;;
        *)
            bad="${bad}${bad:+
}$path"
            ;;
    esac
done <<EOF
$(git -C "$REPO" diff --name-only --no-renames "$A_COMMIT" "$B_COMMIT")
EOF

[ -z "$bad" ] ||
    fail "pin commit B changes package-affecting or unapproved paths:
$bad"

A_DIGEST=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$A_COMMIT") ||
    fail "cannot compute packaging-inputs digest for A"
B_DIGEST=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$B_COMMIT") ||
    fail "cannot compute packaging-inputs digest for B"

[ "$A_DIGEST" = "$B_DIGEST" ] ||
    fail "packaging-inputs digest differs: A=$A_DIGEST B=$B_DIGEST"

echo "Pin commit contract: PASS"
echo "A:                   $A_COMMIT"
echo "B:                   $B_COMMIT"
echo "Packaging inputs:    $A_DIGEST"
