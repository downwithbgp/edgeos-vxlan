#!/bin/sh
# Refresh only the distribution's own APT source file.
#
# The GitHub-hosted runner image enables additional third-party repositories.
# A plain `apt-get update` therefore depends on unrelated services (for
# example packages.microsoft.com) that are not required to install the
# project's build or dataplane tools.  A transient 403 from such a repository
# must not fail a source-validation job.
#
# This helper keeps the shared runner configuration unchanged: it passes
# transient APT options that read exactly one trusted distribution source
# file and disable the source-parts directory.  Signature verification and
# TLS behaviour are not changed.  If the distribution source itself is
# unavailable, the command fails; that is a real infrastructure failure and
# is not hidden.
#
# Usage: apt-update-ubuntu-only.sh [extra apt-get update options...]
set -eu

if [ "$(id -u)" -eq 0 ]; then
    apt_get()
    {
        apt-get "$@"
    }
else
    command -v sudo >/dev/null 2>&1 ||
        { echo "ERROR: sudo is required to refresh APT" >&2; exit 1; }
    apt_get()
    {
        sudo apt-get "$@"
    }
fi

if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    source=/etc/apt/sources.list.d/ubuntu.sources
elif [ -f /etc/apt/sources.list ]; then
    source=/etc/apt/sources.list
else
    echo "ERROR: no Ubuntu APT source file found" >&2
    exit 1
fi

echo "Refreshing only the distribution APT source: $source"
apt_get update \
    -o Dir::Etc::sourceparts="-" \
    -o Dir::Etc::sourcelist="$source" \
    "$@"
