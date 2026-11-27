#!/bin/sh
# Install the pinned CI analysis tools into a destination directory.
#
# Usage: install-ci-tools.sh <destination>
#
# Every archive is verified against a pinned SHA-256 before use.  Updating a
# version means updating both the version and the checksum, in the same
# reviewable commit.

set -eu

DEST=${1:?usage: install-ci-tools.sh <destination>}
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ZIZMOR_VERSION=1.33.1
ZIZMOR_SHA256=3e6a301c7a820a2501915f5a9de8c0486da82bdec7965f068477538a98743d43
SHELLCHECK_VERSION=0.11.0
SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        ;;
    *)
        fail "unsupported CI tool platform: $(uname -s) $(uname -m)"
        ;;
esac

for cmd in curl tar sha256sum install mktemp; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "required command not found: $cmd"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$DEST"

download_verified()
{
    url=$1
    output=$2
    expected=$3

    curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --retry-delay 2 -fsSL -o "$output" "$url"

    actual=$(sha256sum "$output" | awk '{print $1}')
    [ "$actual" = "$expected" ] ||
        fail "checksum mismatch for $url: $actual != $expected"
}

download_verified \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
    "$TMP/actionlint.tar.gz" "$ACTIONLINT_SHA256"
tar -xzf "$TMP/actionlint.tar.gz" -C "$DEST" actionlint
chmod 0755 "$DEST/actionlint"

download_verified \
    "https://github.com/zizmorcore/zizmor/releases/download/v${ZIZMOR_VERSION}/zizmor-x86_64-unknown-linux-gnu.tar.gz" \
    "$TMP/zizmor.tar.gz" "$ZIZMOR_SHA256"
tar -xzf "$TMP/zizmor.tar.gz" -C "$DEST" zizmor
chmod 0755 "$DEST/zizmor"

download_verified \
    "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    "$TMP/shellcheck.tar.xz" "$SHELLCHECK_SHA256"
tar -xJf "$TMP/shellcheck.tar.xz" -C "$TMP"
install -m 0755 "$TMP/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" \
    "$DEST/shellcheck"

"$DEST/actionlint" --version | sed -n '1p'
"$DEST/zizmor" --version
"$DEST/shellcheck" --version | sed -n '2p'
