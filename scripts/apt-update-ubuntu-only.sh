#!/bin/sh
# Update APT metadata using Ubuntu sources only.
#
# GitHub's ubuntu-24.04 runner image includes a Microsoft repository that has
# intermittently returned 403. The product has no Microsoft dependency, so
# temporarily mask only sources that reference packages.microsoft.com, run
# apt-get update, and restore the masked files on exit. Signature and TLS
# verification remain enabled.
#
# Usage: apt-update-ubuntu-only.sh
set -eu

if [ "$(id -u)" -eq 0 ]; then
    SUDO=
else
    SUDO=sudo
fi

MASKED=$(mktemp) || {
    echo "ERROR: cannot create mask list" >&2
    exit 1
}

restore()
{
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        $SUDO mv "$file.disabled" "$file" 2>/dev/null || true
    done < "$MASKED"
    rm -f "$MASKED"
}
trap restore EXIT HUP INT TERM

for file in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [ -f "$file" ] || continue
    if grep -q 'packages\.microsoft\.com' "$file"; then
        echo "Temporarily masking non-Ubuntu APT source: $file" >&2
        $SUDO mv "$file" "$file.disabled"
        printf '%s\n' "$file" >> "$MASKED"
    fi
done

$SUDO apt-get update
