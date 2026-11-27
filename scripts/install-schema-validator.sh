#!/bin/sh
# Ensure the pinned Ubuntu JSON Schema validator is available.
#
# Ubuntu 24.04 provides python3-jsonschema 4.10.3-2ubuntu1. Installing from
# the signed distribution archive keeps the implementation pinned and
# verified; a different version fails closed.
set -eu

EXPECTED_PREFIX=4.10.3
PACKAGE_VERSION=4.10.3-2ubuntu1

version()
{
    python3 -c 'import importlib.metadata; print(importlib.metadata.version("jsonschema"))' 2>/dev/null || true
}

current=$(version)
case "$current" in
    "$EXPECTED_PREFIX"*)
        echo "jsonschema $current"
        exit 0
        ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    SUDO=
else
    SUDO=sudo
fi

"$SUDO" ./scripts/apt-update-ubuntu-only.sh >/dev/null
"$SUDO" apt-get install -y --no-install-recommends \
    "python3-jsonschema=$PACKAGE_VERSION" >/dev/null

current=$(version)
case "$current" in
    "$EXPECTED_PREFIX"*)
        echo "jsonschema $current"
        ;;
    *)
        echo "ERROR: expected jsonschema $EXPECTED_PREFIX, found ${current:-missing}" >&2
        exit 1
        ;;
esac
