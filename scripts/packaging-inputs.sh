#!/bin/bash
# Compute the package-affecting input digest for a Git revision/tree.
#
# The digest covers every tracked blob except the documented non-package
# allowlist. It includes .gitattributes, release policy/schema files,
# scripts, containers, debian, src, templates and modules. Installer pins,
# documentation, workflows, specs and tests are excluded.
#
# Usage:
#   packaging-inputs.sh [--repo DIR] [--rev REV] [--list]
#
# Output: one lowercase SHA-256 (or the included path list with --list).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$ROOT
REV=HEAD
LIST=no

usage()
{
    cat <<'EOF'
Usage: packaging-inputs.sh [options]

Options:
  --repo DIR   Git repository (default: this repository)
  --rev REV    Revision to inspect (default: HEAD)
  --list       Print included paths instead of the digest
  -h, --help   Show this help
EOF
}

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            REPO=$2
            shift 2
            ;;
        --rev)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            REV=$2
            shift 2
            ;;
        --list)
            LIST=yes
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

for cmd in git sha256sum awk; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "required command not found: $cmd"
done

[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] ||
    fail "not a Git checkout: $REPO"
REPO=$(cd "$REPO" && pwd)

COMMIT=$(git -C "$REPO" rev-parse --verify --quiet "${REV}^{commit}") ||
    fail "cannot resolve revision: $REV"

# Keep this list identical to release/release-policy.json
# packagingInputs.exclude. A test asserts the two lists agree.
is_excluded()
{
    case "$1" in
        install.sh|SHA256SUMS|README.md|docs/*|.github/*|spec/*|test/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

emit_entry()
{
    local entry=$1
    local meta path mode rest type object size

    meta=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    mode=${meta%% *}
    rest=${meta#* }
    type=${rest%% *}
    object=${rest#* }

    [ "$type" = "blob" ] ||
        fail "unsupported Git object type '$type' for $path"

    is_excluded "$path" && return 0

    if [ "$LIST" = "yes" ]; then
        printf '%s %s\n' "$mode" "$path"
        return 0
    fi

    size=$(git -C "$REPO" cat-file -s "$object") ||
        fail "cannot read blob size for $path"
    printf '%s\0%s\0%s\0' "$mode" "$size" "$path"
    git -C "$REPO" cat-file blob "$object" ||
        fail "cannot read blob for $path"
    printf '\0'
}

if [ "$LIST" = "yes" ]; then
    while IFS= read -r -d '' entry; do
        emit_entry "$entry"
    done < <(git -C "$REPO" ls-tree -r -z --full-tree "$COMMIT")
    exit 0
fi

while IFS= read -r -d '' entry; do
    emit_entry "$entry"
done < <(git -C "$REPO" ls-tree -r -z --full-tree "$COMMIT") |
    sha256sum | awk '{print $1}'
