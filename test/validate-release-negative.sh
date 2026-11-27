#!/bin/bash
# Negative artifact-validation tests.
#
# Requires packages built from this tree:
#   bash test/validate-release-negative.sh [artifact-dir]
#
# The default artifact directory is the repository's parent, where
# dpkg-buildpackage writes the packages.  Each case deliberately breaks one
# property and asserts that validation fails for that reason, not by accident.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARTIFACT_DIR=${1:-"$ROOT/.."}
PKG_VERSION=$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)
INSTALL_VERSION=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$ROOT/install.sh")
KMOD="edgeos-vxlan-kmod_${PKG_VERSION}_mipsel.deb"
INTEGRATION="edgeos-vxlan_${PKG_VERSION}_all.deb"
case "$PKG_VERSION" in
    *~*) PRERELEASE=yes ;;
    *) PRERELEASE=no ;;
esac
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
rc_source=$TMP/rc-source
PASS=0
FAIL=0

[ -f "$ARTIFACT_DIR/$KMOD" ] ||
    { echo "ERROR: missing $ARTIFACT_DIR/$KMOD" >&2; exit 1; }
[ -f "$ARTIFACT_DIR/$INTEGRATION" ] ||
    { echo "ERROR: missing $ARTIFACT_DIR/$INTEGRATION" >&2; exit 1; }

new_dir()
{
    local name=$1
    local dir=$TMP/$name
    mkdir -p "$dir"
    printf '%s\n' "$dir"
}

copy_clean()
{
    local dir=$1
    cp "$ARTIFACT_DIR/$KMOD" "$ARTIFACT_DIR/$INTEGRATION" "$dir/"
}

make_manifest()
{
    local dir=$1
    (
        cd "$dir"
        sha256sum -- "$KMOD" "$INTEGRATION" > SHA256SUMS
    )
}


regenerate_md5sums()
{
    local work=$1
    (
        cd "$work"
        find . -type f ! -path './DEBIAN/*' -printf '%P\n' |
            LC_ALL=C sort |
            while IFS= read -r file; do
                md5sum -- "$file"
            done
    ) >"$work/DEBIAN/md5sums"
}

repack()
{
    local src=$1
    local dst=$2
    local edit=$3
    local work=$TMP/repack-work

    rm -rf "$work"
    mkdir -p "$work"
    dpkg-deb -R "$src" "$work"
    "$edit" "$work"
    regenerate_md5sums "$work"
    dpkg-deb --root-owner-group -b "$work" "$dst" >/dev/null
}

repack_with_md5sums()
{
    local src=$1
    local dst=$2
    local edit=$3
    local work=$TMP/repack-work

    rm -rf "$work"
    mkdir -p "$work"
    dpkg-deb -R "$src" "$work"
    "$edit" "$work"
    dpkg-deb --root-owner-group -b "$work" "$dst" >/dev/null
}

edit_version()
{
    sed -i 's/^Version: .*/Version: 9.9.9~rc9+edgeos3.0.1.e50/' "$1/DEBIAN/control"
}

edit_architecture()
{
    sed -i 's/^Architecture: .*/Architecture: all/' "$1/DEBIAN/control"
}

edit_depends()
{
    sed -i "s/^Depends: .*/Depends: edgeos-vxlan-kmod (= $PKG_VERSION), vyatta-cfg-system/" \
        "$1/DEBIAN/control"
}

add_control_field()
{
    printf 'Essential: yes\n' >>"$1/DEBIAN/control"
}

replace_file_with_symlink()
{
    rm -f "$1/opt/vyatta/sbin/vyatta-vxlan"
    ln -s /etc/passwd "$1/opt/vyatta/sbin/vyatta-vxlan"
}

write_unsafe_md5sums()
{
    printf '00000000000000000000000000000000  /etc/passwd\n' \
        >"$1/DEBIAN/md5sums"
}

add_unexpected_file()
{
    mkdir -p "$1/opt/vyatta/sbin"
    printf '#!/bin/sh\nexit 0\n' >"$1/opt/vyatta/sbin/unexpected"
    chmod 0755 "$1/opt/vyatta/sbin/unexpected"
}

change_file_mode()
{
    chmod 0666 "$1/opt/vyatta/sbin/vyatta-vxlan"
}

remove_module()
{
    rm -f "$1/lib/modules/4.14.54-UBNT/extra/vxlan.ko"
}

remove_udp_module()
{
    rm -f "$1/lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko"
}

add_control_file()
{
    printf 'unexpected\n' >"$1/DEBIAN/extra"
    chmod 0644 "$1/DEBIAN/extra"
}

corrupt_changelog()
{
    printf 'tampered\n' | gzip -9cn >"$1/usr/share/doc/edgeos-vxlan/changelog.gz"
}

edit_rc_version_integration()
{
    sed -i 's/^Version: .*/Version: 0.3.0~rc5+edgeos3.0.1.e50/' "$1/DEBIAN/control"
    sed -i 's/edgeos-vxlan-kmod (= [^)]*)/edgeos-vxlan-kmod (= 0.3.0~rc5+edgeos3.0.1.e50)/' \
        "$1/DEBIAN/control"
    gzip -9cn "$rc_source/debian/changelog" \
        >"$1/usr/share/doc/edgeos-vxlan/changelog.gz"
}

edit_rc_version_kmod()
{
    sed -i 's/^Version: .*/Version: 0.3.0~rc5+edgeos3.0.1.e50/' "$1/DEBIAN/control"
    gzip -9cn "$rc_source/debian/changelog" \
        >"$1/usr/share/doc/edgeos-vxlan-kmod/changelog.gz"
}

corrupt_module()
{
    printf '\001' >>"$1/lib/modules/4.14.54-UBNT/extra/vxlan.ko"
}

break_preinst()
{
    printf '\nif true; then\n' >>"$1/DEBIAN/preinst"
}

drift_preinst()
{
    printf '\n# unauthorised package drift\n' >>"$1/DEBIAN/preinst"
}

run_build()
{
    "$ROOT/scripts/validate-release.sh" "$1"
}


run_skip_pins()
{
    env GITHUB_REF_TYPE='' GITHUB_REF_NAME='' \
        "$ROOT/scripts/validate-artifacts.sh" --build --skip-install-pins \
        "$1" "$2"
}

run_rc_build()
{
    run_skip_pins "$1" "$rc_source"
}

expect_pass()
{
    local desc=$1
    shift

    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (expected success)"
        sed 's/^/    /' "$TMP/err" | tail -10
    fi
}

expect_fail()
{
    local desc=$1
    local pattern=$2
    shift 2

    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (expected failure, validation passed)"
        return
    fi

    if grep -Fq -- "$pattern" "$TMP/err"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (failed for the wrong reason; wanted '$pattern')"
        sed 's/^/    /' "$TMP/err" | tail -10
    fi
}

clean_build=$(new_dir clean-build)
copy_clean "$clean_build"

expect_pass "build validation accepts the real artifacts" run_build "$clean_build"

if [ "$PRERELEASE" = "no" ]; then
    expect_fail "skip-pins flag rejects a stable version" \
        "not a recognised prerelease" \
        run_skip_pins "$clean_build" "$ROOT"

    multiline_tag=$(printf 'v%s\nv9.9.9' "$INSTALL_VERSION")
    expect_fail "multiline release tag is rejected" "single line" \
        "$ROOT/scripts/validate-artifacts.sh" --build --tag "$multiline_tag" \
        "$clean_build" "$ROOT"
else
    expect_pass "skip-pins accepts a prerelease version" \
        run_skip_pins "$clean_build" "$ROOT"
fi

mkdir -p "$rc_source"
cp -a "$ROOT/install.sh" "$ROOT/debian" "$ROOT/src" "$ROOT/templates" \
    "$ROOT/modules" "$rc_source/"
sed -i '1s/^edgeos-vxlan ([^)]*)/edgeos-vxlan (0.3.0~rc5+edgeos3.0.1.e50)/' \
    "$rc_source/debian/changelog"
rc_artifacts=$TMP/rc-artifacts
mkdir -p "$rc_artifacts"
rc_kmod="edgeos-vxlan-kmod_0.3.0~rc5+edgeos3.0.1.e50_mipsel.deb"
rc_integration="edgeos-vxlan_0.3.0~rc5+edgeos3.0.1.e50_all.deb"
repack "$ARTIFACT_DIR/$KMOD" "$rc_artifacts/$rc_kmod" edit_rc_version_kmod
repack "$ARTIFACT_DIR/$INTEGRATION" "$rc_artifacts/$rc_integration" \
    edit_rc_version_integration
expect_pass "prerelease build skips the installer version cross-check" \
    run_rc_build "$rc_artifacts"

missing_kmod=$(new_dir missing-kmod)
cp "$ARTIFACT_DIR/$INTEGRATION" "$missing_kmod/"
expect_fail "missing kernel package" "missing $KMOD" run_build "$missing_kmod"

extra_deb=$(new_dir extra-deb)
copy_clean "$extra_deb"
printf 'not a package\n' >"$extra_deb/edgeos-vxlan_9.9.9_all.deb"
expect_fail "unexpected extra package" "unexpected package" run_build "$extra_deb"

bad_version=$(new_dir bad-version)
copy_clean "$bad_version"
repack "$ARTIFACT_DIR/$INTEGRATION" "$bad_version/$INTEGRATION" edit_version
expect_fail "wrong package version" "package version is not" run_build "$bad_version"

bad_arch=$(new_dir bad-arch)
copy_clean "$bad_arch"
repack "$ARTIFACT_DIR/$KMOD" "$bad_arch/$KMOD" edit_architecture
expect_fail "wrong package architecture" "package architecture is not mipsel" run_build "$bad_arch"

bad_depends=$(new_dir bad-depends)
copy_clean "$bad_depends"
repack "$ARTIFACT_DIR/$INTEGRATION" "$bad_depends/$INTEGRATION" edit_depends
expect_fail "wrong dependency relationships" "Depends relationships" run_build "$bad_depends"

unexpected_file=$(new_dir unexpected-file)
copy_clean "$unexpected_file"
repack "$ARTIFACT_DIR/$INTEGRATION" "$unexpected_file/$INTEGRATION" add_unexpected_file
expect_fail "unexpected packaged file" "package contents" run_build "$unexpected_file"

bad_mode=$(new_dir bad-mode)
copy_clean "$bad_mode"
repack "$ARTIFACT_DIR/$INTEGRATION" "$bad_mode/$INTEGRATION" change_file_mode
expect_fail "wrong packaged file mode" "package contents" run_build "$bad_mode"

missing_module=$(new_dir missing-module)
copy_clean "$missing_module"
repack "$ARTIFACT_DIR/$KMOD" "$missing_module/$KMOD" remove_module
expect_fail "missing kernel module" "package contents" run_build "$missing_module"

missing_udp_module=$(new_dir missing-udp-module)
copy_clean "$missing_udp_module"
repack "$ARTIFACT_DIR/$KMOD" "$missing_udp_module/$KMOD" remove_udp_module
expect_fail "missing udp_tunnel module" "package contents" \
    run_build "$missing_udp_module"

bad_module=$(new_dir bad-module)
copy_clean "$bad_module"
repack "$ARTIFACT_DIR/$KMOD" "$bad_module/$KMOD" corrupt_module
expect_fail "corrupted kernel module" "vxlan.ko does not match" run_build "$bad_module"

bad_script_syntax=$(new_dir bad-script-syntax)
copy_clean "$bad_script_syntax"
repack "$ARTIFACT_DIR/$INTEGRATION" "$bad_script_syntax/$INTEGRATION" break_preinst
expect_fail "maintainer script syntax error" "shell syntax error" run_build "$bad_script_syntax"

drifted_script=$(new_dir drifted-script)
copy_clean "$drifted_script"
repack "$ARTIFACT_DIR/$INTEGRATION" "$drifted_script/$INTEGRATION" drift_preinst
expect_fail "packaged script drift" "does not match the source tree" run_build "$drifted_script"

extra_control=$(new_dir extra-control)
copy_clean "$extra_control"
repack "$ARTIFACT_DIR/$INTEGRATION" "$extra_control/$INTEGRATION" add_control_file
expect_fail "unexpected control-archive file" "unexpected control archive contents" \
    run_build "$extra_control"

extra_control_field=$(new_dir extra-control-field)
copy_clean "$extra_control_field"
repack "$ARTIFACT_DIR/$INTEGRATION" "$extra_control_field/$INTEGRATION" add_control_field
expect_fail "smuggled Essential field" "Essential is not derived" \
    run_build "$extra_control_field"

symlink_member=$(new_dir symlink-member)
copy_clean "$symlink_member"
repack "$ARTIFACT_DIR/$INTEGRATION" "$symlink_member/$INTEGRATION" \
    replace_file_with_symlink
expect_fail "symlink member" "package contents" run_build "$symlink_member"

unsafe_md5sums=$(new_dir unsafe-md5sums)
copy_clean "$unsafe_md5sums"
repack_with_md5sums "$ARTIFACT_DIR/$INTEGRATION" \
    "$unsafe_md5sums/$INTEGRATION" write_unsafe_md5sums
expect_fail "unsafe md5sums path" "md5sums do not cover exactly" \
    run_build "$unsafe_md5sums"

bad_changelog=$(new_dir bad-changelog)
copy_clean "$bad_changelog"
repack "$ARTIFACT_DIR/$INTEGRATION" "$bad_changelog/$INTEGRATION" corrupt_changelog
expect_fail "tampered packaged changelog" "does not match debian/changelog" \
    run_build "$bad_changelog"

bad_manifest_name=$(new_dir bad-manifest-name)
copy_clean "$bad_manifest_name"
make_manifest "$bad_manifest_name"
printf '0000000000000000000000000000000000000000000000000000000000000000  unexpected.deb\n' \
    >>"$bad_manifest_name/SHA256SUMS"
expect_fail "unexpected manifest entry" "does not list exactly" run_build "$bad_manifest_name"

bad_manifest_hash=$(new_dir bad-manifest-hash)
copy_clean "$bad_manifest_hash"
(
    cd "$bad_manifest_hash"
    sha256sum -- "$KMOD" "$INTEGRATION" >SHA256SUMS
    sed -i '1s/^[0-9a-f]*/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
        SHA256SUMS
)
expect_fail "corrupted checksum manifest" "checksum manifest verification failed" \
    run_build "$bad_manifest_hash"

duplicate_manifest=$(new_dir duplicate-manifest)
copy_clean "$duplicate_manifest"
make_manifest "$duplicate_manifest"
last_manifest_line=$(tail -1 "$duplicate_manifest/SHA256SUMS")
printf '%s\n' "$last_manifest_line" >>"$duplicate_manifest/SHA256SUMS"
expect_fail "duplicate manifest entry" "duplicate entries" \
    run_build "$duplicate_manifest"

malformed_manifest=$(new_dir malformed-manifest)
copy_clean "$malformed_manifest"
make_manifest "$malformed_manifest"
sed -i '1s/^[0-9a-f]*/not-a-hash/' "$malformed_manifest/SHA256SUMS"
expect_fail "malformed manifest entry" "malformed checksum manifest" \
    run_build "$malformed_manifest"

echo "validate-release-negative: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
