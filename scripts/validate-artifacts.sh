#!/bin/sh
# Shared artifact validation for edgeos-vxlan.
#
# Validates a directory of Debian packages against the source tree that is
# supposed to have produced them.  It never executes package maintainer
# scripts or any other downloaded content: packages are inspected with
# dpkg-deb, readelf, modinfo, sha256sum and cmp only.
#
# Usage:
#   validate-artifacts.sh [options] --build <artifact-dir> <source-root>
#   validate-artifacts.sh [options] --published <asset-dir> <source-root>
#
# --build      expects the two package files.  A SHA256SUMS file is validated
#              when present.  Build-mode package hashes are reported but not
#              compared to install.sh pins; that policy is pending review.
# --published  expects the required packages and SHA256SUMS, allows optional
#              .buildinfo/.changes provenance, and requires package hashes to
#              match install.sh pins.
#
# The source root is read-only data.  In published mode it is normally the
# tagged source tree, while this script comes from current trusted CI code.
#
# --skip-install-pins relaxes the install.sh version agreement for prerelease
# builds; published assets are always pin-verified.

set -eu

MODE=
TAG=
SKIP_PINS=no

usage()
{
    cat <<'EOF'
Usage: validate-artifacts.sh [options] --build|--published <artifact-dir> <source-root>

Options:
  --tag <tag>            Require the release tag to match install.sh VERSION
  --skip-install-pins    Skip the install.sh version agreement (prerelease builds)
  -h, --help             Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build|--published)
            MODE=${1#--}
            shift
            ;;
        --tag)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            TAG=$2
            shift 2
            ;;
        --skip-install-pins)
            SKIP_PINS=yes
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            usage >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

[ -n "$MODE" ] && [ $# -eq 2 ] || { usage >&2; exit 2; }

ARTIFACT_DIR=$1
SOURCE_ROOT=$2

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

note()
{
    echo "NOTE: $*" >&2
}

for cmd in dpkg-deb dpkg-parsechangelog readelf modinfo sha256sum md5sum cmp \
           gzip find sort awk sed grep stat diff wc head; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "required command not found: $cmd"
done

[ -d "$ARTIFACT_DIR" ] || fail "artifact directory not found: $ARTIFACT_DIR"
[ -d "$SOURCE_ROOT" ] || fail "source root not found: $SOURCE_ROOT"

ARTIFACT_DIR=$(CDPATH='' cd -- "$ARTIFACT_DIR" && pwd) ||
    fail "cannot resolve artifact directory: $ARTIFACT_DIR"
SOURCE_ROOT=$(CDPATH='' cd -- "$SOURCE_ROOT" && pwd) ||
    fail "cannot resolve source root: $SOURCE_ROOT"

[ -f "$SOURCE_ROOT/install.sh" ] || fail "missing $SOURCE_ROOT/install.sh"
[ -f "$SOURCE_ROOT/debian/changelog" ] ||
    fail "missing $SOURCE_ROOT/debian/changelog"
[ -f "$SOURCE_ROOT/debian/copyright" ] ||
    fail "missing $SOURCE_ROOT/debian/copyright"
[ -f "$SOURCE_ROOT/debian/control" ] ||
    fail "missing $SOURCE_ROOT/debian/control"

read_install_var()
{
    value=$(sed -n "s/^$1=\"\\([^\"]*\\)\"/\\1/p" "$SOURCE_ROOT/install.sh")
    count=$(printf '%s\n' "$value" | grep -c . || true)

    [ "$count" -eq 1 ] ||
        fail "expected exactly one $1 assignment in install.sh"

    printf '%s\n' "$value"
}

VERSION=$(read_install_var VERSION)
INSTALLER_PKG_VERSION=$(read_install_var PKG_VERSION)
REPO=$(read_install_var REPO)
KMOD_PIN=$(read_install_var KMOD_SHA256)
INTEGRATION_PIN=$(read_install_var INTEGRATION_SHA256)

[ -n "$VERSION" ] || fail "could not read VERSION from install.sh"
[ -n "$INSTALLER_PKG_VERSION" ] ||
    fail "could not read PKG_VERSION from install.sh"
[ -n "$KMOD_PIN" ] || fail "could not read KMOD_SHA256 from install.sh"
[ -n "$INTEGRATION_PIN" ] ||
    fail "could not read INTEGRATION_SHA256 from install.sh"

printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
    fail "VERSION is not a release version: $VERSION"
[ "$REPO" = "downwithbgp/edgeos-vxlan" ] ||
    fail "unexpected release repository in install.sh: $REPO"

if [ "$SKIP_PINS" = "no" ]; then
    [ "$INSTALLER_PKG_VERSION" = "$VERSION+edgeos3.0.1.e50" ] ||
        fail "PKG_VERSION ($INSTALLER_PKG_VERSION) does not match VERSION ($VERSION)"
fi

for pin in "$KMOD_PIN" "$INTEGRATION_PIN"; do
    printf '%s\n' "$pin" | grep -Eq '^[0-9a-f]{64}$' ||
        fail "malformed SHA256 pin in install.sh: $pin"
done

PKG_VERSION=$(dpkg-parsechangelog -l "$SOURCE_ROOT/debian/changelog" -S Version)

if [ "$SKIP_PINS" = "no" ]; then
    [ "$PKG_VERSION" = "$INSTALLER_PKG_VERSION" ] ||
        fail "changelog version ($PKG_VERSION) != install.sh PKG_VERSION ($INSTALLER_PKG_VERSION)"
    [ "$PKG_VERSION" = "$VERSION+edgeos3.0.1.e50" ] ||
        fail "package version $PKG_VERSION does not match release version $VERSION"
else
    [ "$MODE" = "build" ] ||
        fail "published validation cannot skip install pins"

    printf '%s\n' "$PKG_VERSION" |
        grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+~[A-Za-z0-9.+]+$' ||
        fail "prerelease package version is not a recognised prerelease: $PKG_VERSION"
    printf '%s\n' "$PKG_VERSION" |
        grep -Eq '\+edgeos3\.0\.1\.e50$' ||
        fail "prerelease package version lacks the edgeos3.0.1.e50 suffix: $PKG_VERSION"
fi

if [ -z "$TAG" ] && [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    TAG=${GITHUB_REF_NAME:-}
fi

if [ "$SKIP_PINS" = "yes" ] && [ -n "$TAG" ]; then
    fail "refusing to validate prerelease $PKG_VERSION for tag $TAG"
fi

if [ -n "$TAG" ]; then
    lines=$(printf '%s\n' "$TAG" | wc -l)
    [ "$lines" -eq 1 ] ||
        fail "release tag must be a single line"

    printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
        fail "release tag does not match vMAJOR.MINOR.PATCH: $TAG"
    [ "$TAG" = "v$VERSION" ] ||
        fail "release tag $TAG does not match install.sh VERSION=$VERSION"

    if [ "${GITHUB_REF_TYPE:-}" = "tag" ] &&
       [ -n "${GITHUB_REF_NAME:-}" ] && [ "$TAG" != "$GITHUB_REF_NAME" ]; then
        fail "requested tag $TAG != checked-out tag $GITHUB_REF_NAME"
    fi
fi

INTEGRATION_PKG=edgeos-vxlan
KMOD_PKG=edgeos-vxlan-kmod
INTEGRATION_DEB=${INTEGRATION_PKG}_${PKG_VERSION}_all.deb
KMOD_DEB=${KMOD_PKG}_${PKG_VERSION}_mipsel.deb

check_artifact_set()
{
    if [ "$MODE" = "published" ]; then
        required=$(printf '%s\n' "$INTEGRATION_DEB" "$KMOD_DEB" SHA256SUMS |
            LC_ALL=C sort)
        actual=$(find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' |
            LC_ALL=C sort)

        while IFS= read -r asset; do
            [ -n "$asset" ] || continue

            case "$asset" in
                "$INTEGRATION_DEB"|"$KMOD_DEB"|SHA256SUMS)
                    ;;
                "edgeos-vxlan_${PKG_VERSION}_mipsel.buildinfo"|"edgeos-vxlan_${PKG_VERSION}_mipsel.changes")
                    ;;
                *)
                    fail "unexpected release asset: $asset"
                    ;;
            esac
        done <<EOF
$actual
EOF

        while IFS= read -r asset; do
            [ -n "$asset" ] || continue
            [ -f "$ARTIFACT_DIR/$asset" ] ||
                fail "missing release asset: $asset"
        done <<EOF
$required
EOF
    else
        [ -f "$ARTIFACT_DIR/$INTEGRATION_DEB" ] ||
            fail "missing $INTEGRATION_DEB"
        [ -f "$ARTIFACT_DIR/$KMOD_DEB" ] ||
            fail "missing $KMOD_DEB"

        unexpected=$(find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -type f \
            -name '*.deb' -printf '%f\n' |
            grep -Fvx -e "$INTEGRATION_DEB" -e "$KMOD_DEB" || true)

        [ -z "$unexpected" ] ||
            fail "unexpected package(s) in artifact directory (use a clean build output directory): $unexpected"
    fi
}

deb_field()
{
    dpkg-deb -f "$1" "$2" 2>/dev/null
}

normalize_depends()
{
    printf '%s\n' "$1" | tr ',' '\n' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
        sed '/^$/d' | LC_ALL=C sort
}

source_control_field()
{
    package=$1
    field=$2

    awk -v pkg="$package" -v field="$field" '
        BEGIN { in_pkg = 0; capture = 0 }
        /^Package:[ \t]/ {
            in_pkg = ($2 == pkg)
            capture = 0
            next
        }
        in_pkg && capture && /^[ \t]/ {
            sub(/^[ \t]+/, " ")
            printf "%s", $0
            next
        }
        in_pkg && capture { exit }
        in_pkg && index($0, field ":") == 1 {
            sub("^" field ":[ \t]*", "")
            printf "%s", $0
            capture = 1
            next
        }
    ' "$SOURCE_ROOT/debian/control"
}

resolve_control_field()
{
    package=$1
    field=$2
    raw=$(source_control_field "$package" "$field")
    resolved=$(printf '%s\n' "$raw" |
        sed -e "s/\${binary:Version}/$PKG_VERSION/g" \
            -e "s/\${misc:Depends}//g" \
            -e "s/\${shlibs:Depends}//g" \
            -e "s/\${python3:Depends}//g" \
            -e "s/\${perl:Depends}//g")

    case "$resolved" in
        *"\${"*)
            fail "unsupported substvar in debian/control $field: $resolved"
            ;;
    esac

    printf '%s\n' "$resolved"
}

check_package_metadata()
{
    deb=$1
    package=$2
    architecture=$3

    dpkg-deb -I "$deb" >/dev/null 2>&1 ||
        fail "not a readable Debian package: $deb"

    [ "$(deb_field "$deb" Package)" = "$package" ] ||
        fail "$deb: package name is not $package"

    [ "$(deb_field "$deb" Version)" = "$PKG_VERSION" ] ||
        fail "$deb: package version is not $PKG_VERSION"

    [ "$(deb_field "$deb" Architecture)" = "$architecture" ] ||
        fail "$deb: package architecture is not $architecture"

    for field in Depends Pre-Depends Conflicts Breaks Replaces Provides; do
        expected=$(normalize_depends "$(resolve_control_field "$package" "$field")")
        actual=$(normalize_depends "$(deb_field "$deb" "$field")")

        [ "$actual" = "$expected" ] ||
            fail "$deb: $field relationships differ from debian/control"
    done

    for field in Essential Multi-Arch; do
        expected=$(resolve_control_field "$package" "$field" |
            sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        actual=$(deb_field "$deb" "$field" |
            sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        if [ "$field" = "Essential" ] || [ "$field" = "Multi-Arch" ]; then
            [ -n "$expected" ] || expected=no
            [ -n "$actual" ] || actual=no
        fi

        [ "$actual" = "$expected" ] ||
            fail "$deb: $field is not derived from debian/control"
    done
}

check_control_archive()
{
    deb=$1
    package=$2
    ctl=$3

    dpkg-deb -e "$deb" "$ctl" ||
        fail "$deb: cannot extract the control archive"

    expected_scripts=
    for script in preinst postinst prerm postrm; do
        if [ -f "$SOURCE_ROOT/debian/$package.$script" ]; then
            expected_scripts="$expected_scripts $script"
        fi
    done

    # shellcheck disable=SC2086
    expected=$(printf '%s\n' control md5sums $expected_scripts | LC_ALL=C sort)
    actual=$(find "$ctl" -mindepth 1 -maxdepth 1 -printf '%f\n' |
        LC_ALL=C sort)

    if [ "$actual" != "$expected" ]; then
        echo "Expected control files:" >&2
        printf '%s\n' "$expected" | sed 's/^/  /' >&2
        echo "Actual control files:" >&2
        printf '%s\n' "$actual" | sed 's/^/  /' >&2
        fail "$deb: unexpected control archive contents"
    fi

    [ "$(stat -c '%a' "$ctl/control")" = "644" ] ||
        fail "$deb: control file mode is not 0644"
    [ "$(stat -c '%a' "$ctl/md5sums")" = "644" ] ||
        fail "$deb: md5sums mode is not 0644"

    for script in $expected_scripts; do
        [ "$(stat -c '%a' "$ctl/$script")" = "755" ] ||
            fail "$deb: maintainer script $script mode is not 0755"

        sh -n "$ctl/$script" ||
            fail "$deb: maintainer script $script has a shell syntax error"

        grep -Eq '^set -e' "$ctl/$script" ||
            fail "$deb: maintainer script $script does not enable set -e"

        cmp -s "$ctl/$script" "$SOURCE_ROOT/debian/$package.$script" ||
            fail "$deb: maintainer script $script does not match the source tree"
    done
}

symbolic_file_mode()
{
    if [ -x "$1" ]; then
        printf '%s\n' '-rwxr-xr-x'
    else
        printf '%s\n' '-rw-r--r--'
    fi
}

# Derive both the expected data contents and the packaged-file -> source-file
# mapping from the source tree's debian/*.install definitions.  Expectations
# therefore come from the tagged tree, not from a release-specific table in
# this branch.
build_expected_contents()
{
    package=$1
    expected=$2
    source_map=$3
    install_file=$SOURCE_ROOT/debian/$package.install
    files=$expected.files
    maps=$source_map.files
    src_list=$expected.src-list

    [ -f "$install_file" ] ||
        fail "missing packaging definition: $install_file"

    : > "$files"
    : > "$maps"

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s\n' "$line" |
            sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$line" ] || continue

        case "$line" in
            \#*) continue ;;
        esac

        src=$(printf '%s\n' "$line" | awk '{print $1}')
        dest=$(printf '%s\n' "$line" | awk '{print $2}')
        extra=$(printf '%s\n' "$line" | awk '{print $3}')

        [ -n "$src" ] && [ -n "$dest" ] && [ -z "$extra" ] ||
            fail "unsupported packaging line in $install_file: $line"

        dest=${dest%/}
        [ -n "$dest" ] || dest=.
        base=${src##*/}

        if [ -d "$SOURCE_ROOT/$src" ]; then
            [ -z "$(find "$SOURCE_ROOT/$src" -type l -print -quit)" ] ||
                fail "$install_file: symlink packaging is not supported: $src"

            find "$SOURCE_ROOT/$src" -type f -printf '%P\n' > "$src_list" ||
                fail "cannot enumerate source directory: $src"
            LC_ALL=C sort -o "$src_list" "$src_list" ||
                fail "cannot sort source directory listing: $src"

            while IFS= read -r rel; do
                path=$SOURCE_ROOT/$src/$rel
                mode=$(symbolic_file_mode "$path")
                printf '%s root/root %s/%s/%s\n' \
                    "$mode" "$dest" "$base" "$rel" >> "$files"
                printf '%s\t%s\n' "$dest/$base/$rel" "$src/$rel" >> "$maps"
            done < "$src_list"
        elif [ -f "$SOURCE_ROOT/$src" ]; then
            mode=$(symbolic_file_mode "$SOURCE_ROOT/$src")
            printf '%s root/root %s/%s\n' \
                "$mode" "$dest" "$base" >> "$files"
            printf '%s\t%s\n' "$dest/$base" "$src" >> "$maps"
        else
            fail "$install_file: missing source path: $src"
        fi
    done < "$install_file"

    {
        printf '%s root/root usr/share/doc/%s/changelog.gz\n' \
            '-rw-r--r--' "$package"
        printf '%s root/root usr/share/doc/%s/copyright\n' \
            '-rw-r--r--' "$package"
    } >> "$files"

    {
        printf 'usr/share/doc/%s/changelog.gz\tdebian/changelog\n' "$package"
        printf 'usr/share/doc/%s/copyright\tdebian/copyright\n' "$package"
    } >> "$maps"

    dirs=$expected.dirs
    {
        printf 'drwxr-xr-x root/root .\n'

        awk '{print $3}' "$files" |
            while IFS= read -r path; do
                dir=$path
                while :; do
                    case "$dir" in
                        */*) dir=${dir%/*} ;;
                        *) break ;;
                    esac
                    printf 'drwxr-xr-x root/root %s\n' "$dir"
                done
            done
    } > "$dirs"

    LC_ALL=C sort -u "$files" "$dirs" > "$expected"
    LC_ALL=C sort -u "$maps" > "$source_map"
    rm -f "$files" "$maps" "$dirs" "$src_list"
}

check_contents()
{
    deb=$1
    package=$2
    data=$3
    tmp=$4
    max_doc_bytes=16777216

    dpkg-deb -x "$deb" "$data" ||
        fail "$deb: cannot extract the data archive"

    expected=$tmp/expected-$package.txt
    source_map=$tmp/source-map-$package.txt
    build_expected_contents "$package" "$expected" "$source_map"

    listing=$tmp/listing-$package.txt
    parsed=$tmp/parsed-$package.txt
    actual=$tmp/contents-$package.txt

    LC_ALL=C dpkg-deb -c "$deb" > "$listing" ||
        fail "$deb: cannot list package contents"
    awk '{p=$6; sub(/^\.\//,"",p); sub(/\/$/,"",p); if (p=="") p="."; print $1, $2, p}' \
        "$listing" > "$parsed" ||
        fail "$deb: cannot parse package contents"
    LC_ALL=C sort "$parsed" > "$actual" ||
        fail "$deb: cannot sort package contents"

    if ! cmp -s "$expected" "$actual"; then
        diff -u "$expected" "$actual" >&2 || true
        fail "$deb: package contents, permissions or ownership differ from the contract"
    fi

    tab=$(printf '\t')
    while IFS="$tab" read -r rel src; do
        [ -n "$rel" ] || continue

        case "$rel" in
            *.gz)
                gzip -dc "$data/$rel" 2>/dev/null |
                    head -c $((max_doc_bytes + 1)) > "$tmp/decompressed"
                size=$(wc -c < "$tmp/decompressed")
                [ "$size" -le "$max_doc_bytes" ] ||
                    fail "$deb: decompressed $rel exceeds $max_doc_bytes bytes"
                cmp -s "$tmp/decompressed" "$SOURCE_ROOT/$src" ||
                    fail "packaged $rel does not match $src"
                ;;
            *)
                cmp -s "$data/$rel" "$SOURCE_ROOT/$src" ||
                    fail "packaged $rel does not match $src"
                ;;
        esac
    done < "$source_map"

    expected_files=$tmp/expected-files-$package.txt
    actual_md5_files=$tmp/md5sums-$package.txt
    awk '$1 ~ /^-/ { print $3 }' "$expected" |
        LC_ALL=C sort > "$expected_files" ||
        fail "$deb: cannot derive expected file list"
    awk 'NF != 2 || length($1) != 32 || $1 ~ /[^0-9a-f]/ { exit 1 } { print $2 }' \
        "$tmp/control-$package/md5sums" > "$tmp/md5-names" ||
        fail "$deb: malformed md5sums"
    LC_ALL=C sort "$tmp/md5-names" > "$actual_md5_files" ||
        fail "$deb: cannot sort md5sums"

    cmp -s "$expected_files" "$actual_md5_files" ||
        fail "$deb: packaged md5sums do not cover exactly the packaged files"

    ( cd "$data" && md5sum --strict --quiet -c "$tmp/control-$package/md5sums" ) ||
        fail "$deb: packaged md5sums do not verify"
}

elf_field()
{
    readelf -h "$1" 2>/dev/null | sed -n "s/^ *$2: *//p" | head -1
}

check_module()
{
    ko=$1
    name=$2
    depends=$3
    expected_sha=$4
    tmp=$5

    [ -f "$ko" ] || fail "missing kernel module: $ko"

    actual_sha=$(sha256sum "$ko" | awk '{print $1}')
    [ "$actual_sha" = "$expected_sha" ] ||
        fail "$ko: module hash $actual_sha != expected $expected_sha"

    [ "$(elf_field "$ko" Class)" = "ELF32" ] ||
        fail "$ko: not an ELF32 object"

    case "$(elf_field "$ko" Data)" in
        *"little endian") ;;
        *) fail "$ko: not little-endian" ;;
    esac

    case "$(elf_field "$ko" Type)" in
        REL*) ;;
        *) fail "$ko: not a relocatable object" ;;
    esac

    [ "$(elf_field "$ko" Machine)" = "MIPS R3000" ] ||
        fail "$ko: not a MIPS object"

    flags=$(elf_field "$ko" Flags)
    flags_num=${flags%%,*}
    [ "$flags_num" = "0x70001001" ] ||
        fail "$ko: unexpected MIPS ABI flags: $flags"

    readelf -A "$ko" > "$tmp/abi" 2>/dev/null ||
        fail "$ko: cannot read MIPS ABI attributes"
    grep -Fq 'ISA: MIPS32r2' "$tmp/abi" ||
        fail "$ko: ABI is not MIPS32r2"
    grep -Fq 'GPR size: 32' "$tmp/abi" ||
        fail "$ko: ABI is not 32-bit"
    grep -Fq 'FP ABI: Soft float' "$tmp/abi" ||
        fail "$ko: ABI is not soft-float"

    [ "$(modinfo -F name "$ko" | sed 's/[[:space:]]*$//')" = "$name" ] ||
        fail "$ko: module name is not $name"
    [ "$(modinfo -F vermagic "$ko" | sed 's/[[:space:]]*$//')" = "4.14.54-UBNT SMP mod_unload MIPS32_R2 32BIT" ] ||
        fail "$ko: vermagic does not match kernel 4.14.54-UBNT"
    [ "$(modinfo -F depends "$ko" | sed 's/[[:space:]]*$//')" = "$depends" ] ||
        fail "$ko: module dependencies are not '$depends'"
}

check_manifest()
{
    manifest=$ARTIFACT_DIR/SHA256SUMS
    [ -f "$manifest" ] || fail "missing checksum manifest: $manifest"

    awk 'NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ { exit 1 }' "$manifest" ||
        fail "malformed checksum manifest: $manifest"

    duplicates=$(LC_ALL=C sort "$manifest" | uniq -d)
    [ -z "$duplicates" ] ||
        fail "checksum manifest contains duplicate entries"

    expected_names=$(printf '%s\n' "$INTEGRATION_DEB" "$KMOD_DEB" |
        LC_ALL=C sort)
    actual_names=$(awk '{print $2}' "$manifest" | LC_ALL=C sort)
    [ "$actual_names" = "$expected_names" ] ||
        fail "checksum manifest does not list exactly the expected packages"

    ( cd "$ARTIFACT_DIR" && sha256sum --strict --quiet -c SHA256SUMS ) ||
        fail "checksum manifest verification failed"

    if [ "$MODE" = "published" ]; then
        if [ -f "$SOURCE_ROOT/SHA256SUMS" ]; then
            cmp -s "$SOURCE_ROOT/SHA256SUMS" "$manifest" ||
                fail "published SHA256SUMS differs from the tagged source tree"
        else
            note "tagged source has no committed SHA256SUMS; verifying against install.sh pins"

            grep -Fx "$KMOD_PIN  $KMOD_DEB" "$manifest" >/dev/null ||
                fail "published SHA256SUMS does not contain the install.sh kmod pin"
            grep -Fx "$INTEGRATION_PIN  $INTEGRATION_DEB" "$manifest" >/dev/null ||
                fail "published SHA256SUMS does not contain the install.sh integration pin"
        fi
    fi
}

check_published_pins()
{
    [ "$MODE" = "published" ] || return 0

    [ "$ACTUAL_KMOD_SHA" = "$KMOD_PIN" ] ||
        fail "kmod SHA256 $ACTUAL_KMOD_SHA != install.sh pin $KMOD_PIN"
    [ "$ACTUAL_INTEGRATION_SHA" = "$INTEGRATION_PIN" ] ||
        fail "integration SHA256 $ACTUAL_INTEGRATION_SHA != install.sh pin $INTEGRATION_PIN"
}

check_host_paths()
{
    data=$1
    list=$TMP/host-files-${data##*/}
    matches=

    find "$data" -type f ! -name '*.gz' -print > "$list" ||
        fail "cannot enumerate package files for host-path scanning"

    while IFS= read -r file; do
        for path in "$SOURCE_ROOT" "${GITHUB_WORKSPACE:-}" "${RUNNER_TEMP:-}" "${HOME:-}"; do
            [ -n "$path" ] || continue

            if grep -a -q -F -- "$path" "$file"; then
                matches="${matches}${matches:+
}$file (contains $path)"
            else
                rc=$?
                [ "$rc" -le 1 ] ||
                    fail "cannot scan $file for build-host paths"
            fi
        done

        if fixed_line=$(grep -a -n -E '/(home/runner|github/workspace|__w|workspace)/|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_' "$file"); then
            matches="${matches}${matches:+
}$fixed_line"
        else
            rc=$?
            [ "$rc" -le 1 ] ||
                fail "cannot scan $file for secret material"
        fi
    done < "$list"

    [ -z "$matches" ] || {
        printf '%s\n' "$matches" >&2
        fail "package contains an unintended build-host path or secret material"
    }
}

check_artifact_set

ACTUAL_KMOD_SHA=$(sha256sum "$ARTIFACT_DIR/$KMOD_DEB" | awk '{print $1}')
ACTUAL_INTEGRATION_SHA=$(sha256sum "$ARTIFACT_DIR/$INTEGRATION_DEB" | awk '{print $1}')

if [ "$MODE" = "published" ]; then
    check_published_pins
else
    note "build-mode package hashes are not compared to install.sh pins; published assets are pinned"
fi

check_package_metadata "$ARTIFACT_DIR/$INTEGRATION_DEB" "$INTEGRATION_PKG" all
check_package_metadata "$ARTIFACT_DIR/$KMOD_DEB" "$KMOD_PKG" mipsel

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/control-$INTEGRATION_PKG" "$TMP/control-$KMOD_PKG"
mkdir -p "$TMP/data-$INTEGRATION_PKG" "$TMP/data-$KMOD_PKG"

check_control_archive "$ARTIFACT_DIR/$INTEGRATION_DEB" "$INTEGRATION_PKG" \
    "$TMP/control-$INTEGRATION_PKG"
check_control_archive "$ARTIFACT_DIR/$KMOD_DEB" "$KMOD_PKG" \
    "$TMP/control-$KMOD_PKG"

check_contents "$ARTIFACT_DIR/$INTEGRATION_DEB" "$INTEGRATION_PKG" \
    "$TMP/data-$INTEGRATION_PKG" "$TMP"
check_contents "$ARTIFACT_DIR/$KMOD_DEB" "$KMOD_PKG" \
    "$TMP/data-$KMOD_PKG" "$TMP"

VXLAN_KO="$TMP/data-$KMOD_PKG/lib/modules/4.14.54-UBNT/extra/vxlan.ko"
UDP_KO="$TMP/data-$KMOD_PKG/lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko"

[ -f "$VXLAN_KO" ] ||
    fail "kernel-module package is missing vxlan.ko"
check_module "$VXLAN_KO" vxlan "udp_tunnel,ip6_udp_tunnel" \
    7c346342bf00202820e8581bfdfc28851add052d2b0e5dde1560819f90bf82b6 "$TMP"

case "$PKG_VERSION" in
    0.0.*|0.1.*)
        # v0.1.x predates the patched udp_tunnel payload.
        if [ -f "$UDP_KO" ]; then
            check_module "$UDP_KO" udp_tunnel "" \
                6d58ee597d8ae50898efe90ec61a4803ae4f0549f29fba9c4132ca92260405cc "$TMP"
        fi
        ;;
    *)
        [ -f "$UDP_KO" ] ||
            fail "kernel-module package is missing udp_tunnel.ko"
        check_module "$UDP_KO" udp_tunnel "" \
            6d58ee597d8ae50898efe90ec61a4803ae4f0549f29fba9c4132ca92260405cc "$TMP"
        ;;
esac

if [ "$MODE" = "published" ] || [ -f "$ARTIFACT_DIR/SHA256SUMS" ]; then
    check_manifest
fi

check_host_paths "$TMP/data-$INTEGRATION_PKG"
check_host_paths "$TMP/data-$KMOD_PKG"

echo "Artifact contract: PASS"
echo "Mode:              $MODE"
echo "Version:           $VERSION"
echo "Package version:   $PKG_VERSION"
echo "Release tag:       ${TAG:-not supplied}"
echo "Kmod SHA256:       $ACTUAL_KMOD_SHA"
echo "Integration SHA256: $ACTUAL_INTEGRATION_SHA"
