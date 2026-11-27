#!/bin/sh
# Install the pinned release/supply-chain tools into a destination directory.
#
# Every archive is verified against a pinned SHA-256 before use. Updating a
# tool means updating its version and checksum in the same reviewable commit.
#
# Usage: install-supply-chain-tools.sh <destination>
set -eu

DEST=${1:?usage: install-supply-chain-tools.sh <destination>}

GH_VERSION=2.106.0
GH_SHA256=a476449fa9625413c54a3734eded62e9e480e49f421ff08e7f3b3879c059a033
SYFT_VERSION=1.57.2
SYFT_SHA256=ad92bd3ec1b94a3df01d4d0aec199afa9c42b72e86da436ff5f837914d32706b
GRYPE_VERSION=0.122.1
GRYPE_SHA256=f1ba7e2917ee1395618de20a98da0aa7c0fb1788927797651047c50502a37538
CRANE_VERSION=0.22.1
CRANE_SHA256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        ;;
    *)
        fail "unsupported release-tool platform: $(uname -s) $(uname -m)"
        ;;
esac

for cmd in curl tar sha256sum install mktemp uname; do
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
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    "$TMP/gh.tar.gz" "$GH_SHA256"
tar -xzf "$TMP/gh.tar.gz" -C "$TMP"
install -m 0755 "$TMP/gh_${GH_VERSION}_linux_amd64/bin/gh" "$DEST/gh"

download_verified \
    "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz" \
    "$TMP/syft.tar.gz" "$SYFT_SHA256"
tar -xzf "$TMP/syft.tar.gz" -C "$TMP" syft
install -m 0755 "$TMP/syft" "$DEST/syft"

download_verified \
    "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_amd64.tar.gz" \
    "$TMP/grype.tar.gz" "$GRYPE_SHA256"
tar -xzf "$TMP/grype.tar.gz" -C "$TMP" grype
install -m 0755 "$TMP/grype" "$DEST/grype"

download_verified \
    "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
    "$TMP/crane.tar.gz" "$CRANE_SHA256"
tar -xzf "$TMP/crane.tar.gz" -C "$TMP" crane
install -m 0755 "$TMP/crane" "$DEST/crane"

"$DEST/gh" version | sed -n '1p'
"$DEST/syft" version | sed -n '1,2p'
"$DEST/grype" version | sed -n '1,2p'
"$DEST/crane" version
