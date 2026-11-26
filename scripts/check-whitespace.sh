#!/bin/sh
# Check the change set under validation for whitespace errors.
#
# A clean checkout makes `git diff --check` meaningless.  This script selects
# a meaningful range for the event that triggered the workflow:
#
#   pull_request      the PR merge commit against its base parent
#   push (branch)     the pushed range; new branches are compared with the
#                     merge base of the default branch
#   push (tag)        the tagged commit against its parent
#   release/manual    the checked-out commit against its parent
#
# The checkout is deliberately shallow.  Deeper history is fetched only when
# the event requires it.

set -eu

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

is_sha()
{
    case "$1" in
        *[!0-9a-f]*)
            return 1
            ;;
    esac

    [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

ensure_parent()
{
    if git rev-parse --verify --quiet 'HEAD^' >/dev/null; then
        return 0
    fi

    case "${GITHUB_REF:-}" in
        refs/*)
            git fetch --no-tags --quiet --deepen=2 origin "$GITHUB_REF" ||
                fail "cannot deepen history for $GITHUB_REF"
            ;;
        *)
            fail "HEAD has no parent and GITHUB_REF is not set"
            ;;
    esac

    git rev-parse --verify --quiet 'HEAD^' >/dev/null ||
        fail "HEAD still has no parent after deepening history"
}

check_range()
{
    first=$1
    second=$2

    git rev-parse --verify --quiet "${first}^{commit}" >/dev/null ||
        fail "commit $first is unavailable"
    git rev-parse --verify --quiet "${second}^{commit}" >/dev/null ||
        fail "commit $second is unavailable"

    echo "Checking whitespace in $first..$second"
    git diff --check "$first" "$second" --
}

check_new_branch()
{
    default_branch=${DEFAULT_BRANCH:-main}

    # A new branch has no before commit.  Fetch a complete history so the
    # merge base cannot silently be a shallow graft; this is the only case
    # that needs more than the deliberately shallow checkout.
    git fetch --no-tags --quiet --unshallow origin 2>/dev/null || true
    git fetch --no-tags --quiet origin \
        "refs/heads/$default_branch:refs/remotes/origin/$default_branch" ||
        fail "cannot fetch default branch $default_branch"

    base=$(git merge-base "refs/remotes/origin/$default_branch" HEAD 2>/dev/null || true)

    [ -n "$base" ] ||
        fail "cannot determine a merge base with $default_branch"
    check_range "$base" HEAD
}

case "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is not set}" in
    pull_request)
        ensure_parent
        check_range 'HEAD^' HEAD
        ;;
    push)
        if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
            ensure_parent
            check_range 'HEAD^' HEAD
        else
            before=${PUSH_BEFORE_SHA:-}
            zero=0000000000000000000000000000000000000000

            if [ -n "$before" ] && [ "$before" != "$zero" ]; then
                is_sha "$before" || fail "invalid push before SHA: $before"
                git fetch --no-tags --quiet --depth=1 origin "$before" ||
                    fail "cannot fetch pushed-from commit $before"
                check_range FETCH_HEAD HEAD
            else
                check_new_branch
            fi
        fi
        ;;
    release|workflow_dispatch)
        ensure_parent
        check_range 'HEAD^' HEAD
        ;;
    *)
        ensure_parent
        check_range 'HEAD^' HEAD
        ;;
esac
