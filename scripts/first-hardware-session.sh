#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# first-hardware-session.sh - bounded helper for the first RC3 hardware
# qualification session.
#
# Phases:
#   inventory      read-only capture of firmware, packages, interfaces,
#                  firewall, runtime-only state and the manual vxlan41913 rules
#   backup         inventory plus config.boot and /config archive, checksummed
#   stage          verify the staged RC3 .deb artifacts (SHA-256, metadata, disk)
#   install        install the kmod and integration packages in one dpkg
#                  transaction (requires --execute) and compare pre/post state
#   verify         structural verification of the isolated vxlan903 dispatch
#   cleanup        print the configuration blocks that remove vxlan903 and its
#                  rulesets; never applies them
#   cleanup-check  verify that vxlan903, its rules and its rulesets are gone
#
# This helper never saves the configuration, reboots, removes packages, or
# touches vxlan41913.  Run it as root on the router.
set -euo pipefail

PROG=${0##*/}
PHASE=""
SESSION=""
ARTIFACTS=""
EXECUTE=0
TEST_IF=vxlan903
PROD_IF=vxlan41913

# Exact RC3 artifact identity.  The package payload is unchanged by the
# qualification-tooling corrections; these values are the recorded RC3
# artifacts and must not drift without a new artifact record.
RC3_VERSION="0.3.0~rc3+edgeos3.0.1.e50"
RC3_KMOD_PACKAGE=edgeos-vxlan-kmod
RC3_MAIN_PACKAGE=edgeos-vxlan
RC3_KMOD_ARCH=mipsel
RC3_MAIN_ARCH=all
RC3_KMOD_SHA=9d1621392d38ed9201ee21f3aa9f3e04ffbcc0a8d00015200c7f9b9b2fe35e06
RC3_MAIN_SHA=7d3eb867f91161167f7308731459294cf30aeb57dd1069d496ca03bb262a2ad6

# Evidence is kept under /config so it survives, but the backup archive
# excludes this tree (and any explicit session outside it) to avoid
# self-inclusion of the growing archive.
SESSION_ROOT=/config/rc3-sessions

INTERFACE_TARGET=/opt/vyatta/share/perl5/Vyatta/Interface.pm
INTERFACE_DIVERT=$INTERFACE_TARGET.edgeos-vxlan-original

KMOD_DEB=""
MAIN_DEB=""

usage() {
    cat <<EOF
usage: $PROG <phase> [options]

phases:
  inventory      capture firmware, packages, interfaces, firewall and
                 runtime-only state (read-only)
  backup         capture the inventory and a checksummed /config backup
  stage          verify a staged RC3 artifact directory (read-only)
  install        install the kmod then integration package (--execute needed)
  verify         verify the isolated vxlan903 dispatch structurally (read-only)
  cleanup        print the two configuration blocks that remove vxlan903
  cleanup-check  verify that vxlan903 and its rules are gone (read-only)

options:
  --session DIR     session directory (default /config/rc3-sessions/<UTC>)
  --artifacts DIR   directory containing the RC3 .deb files (stage/install)
  --test-if IFACE   isolated test interface (default $TEST_IF)
  --execute         required for the install phase
  -h, --help        show this help

The helper never saves, reboots, removes packages, or touches $PROD_IF.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

note() {
    printf '%s\n' "$*" | tee -a "$SESSION/session.log"
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run this phase as root"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

session_init() {
    if [ -z "$SESSION" ]; then
        SESSION="$SESSION_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$SESSION"/{inventory,backup,stage,install,verify,cleanup}
    chmod 700 "$SESSION"
    printf '# %s %s %s\n' "$(date -u +%FT%TZ)" "$PROG" "$PHASE" \
        >>"$SESSION/session.log"
}

show_cfg() {
    if [ -x /opt/vyatta/bin/vyatta-op-cmd-wrapper ]; then
        /opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands \
            2>/dev/null || true
    elif [ -x /bin/vbash ]; then
        /bin/vbash -c 'show configuration commands' 2>/dev/null || true
    elif [ -f /config/config.boot ]; then
        cat /config/config.boot
    fi
}

vxlan_links() {
    ip -o link show type vxlan 2>/dev/null ||
        ip -o link show 2>/dev/null | grep -E 'vxlan' || true
}

# Remove the volatile parts of iptables-save output before comparing it:
# the generated header comment and the per-chain packet/byte counters.
# Raw captures are kept separately.
normalize_fw_save() {
    sed -e '/^#/d' \
        -e 's/\[[0-9][0-9]*:[0-9][0-9]*\]/[0:0]/g' "$1"
}

# Exact administrative UP flag, not a substring match: LOWER_UP must not pass.
iface_admin_up() {
    ip -o link show dev "$1" 2>/dev/null |
        awk -F'[<>]' 'NF > 1 { print $2; exit }' |
        tr ',' '\n' |
        grep -qx 'UP'
}

phase_inventory() {
    need_root
    session_init
    local out="$SESSION/inventory"
    {
        echo "# date"
        date -u
        echo "# firmware"
        cat /etc/version 2>/dev/null || true
        echo "# kernel"
        uname -a
        echo "# packages"
        dpkg -l 2>/dev/null |
            grep -E '^ii +(edgeos-vxlan|vyatta-cfg-firewall|vyatta-cfg-system|iptables|libvyatta-cfg1)' ||
            true
        echo "# diversions"
        dpkg-divert --list 2>/dev/null |
            grep -E 'Interface.pm|udp_tunnel.ko' || true
        echo "# vxlan interfaces"
        vxlan_links
        echo "# all links (JSON)"
        ip -j -d link show 2>/dev/null || true
        echo "# configuration"
        show_cfg
        echo "# filter v4"
        iptables-save -t filter 2>/dev/null || true
        echo "# filter v6"
        ip6tables-save -t filter 2>/dev/null || true
        echo "# IPv6 policy routing"
        ip -6 rule show 2>/dev/null || true
        echo "# IPv6 routes (all tables)"
        ip -6 route show table all 2>/dev/null || true
        echo "# loopback IPv6 addresses"
        ip -6 addr show dev lo 2>/dev/null || true
        echo "# forwarding/per-interface sysctls"
        sysctl -a 2>/dev/null |
            grep -E '^net\.(ipv4|ipv6)\.(ip_forward|conf\.)' || true
        echo "# modules"
        lsmod 2>/dev/null | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)' || true
        echo "# disk"
        df -h / /config 2>/dev/null || true
    } >"$out/inventory.txt"

    grep -E "$PROD_IF|HEv6" "$out/inventory.txt" \
        >"$out/vxlan41913-rules-all.txt" || true

    # Raw and normalized firewall captures.  The normalized files are used for
    # stable comparisons; the raw files remain the evidence.
    iptables-save -t filter >"$out/fw4.raw"
    ip6tables-save -t filter >"$out/fw6.raw"
    normalize_fw_save "$out/fw4.raw" >"$out/fw4.norm"
    normalize_fw_save "$out/fw6.raw" >"$out/fw6.norm"
    grep -hE "$PROD_IF|HEv6" "$out/fw4.norm" "$out/fw6.norm" \
        >"$out/vxlan41913-rules.txt" || true

    note "inventory: $out/inventory.txt"
    note "raw firewall captures: $out/fw4.raw $out/fw6.raw"
    note "normalized captures:   $out/fw4.norm $out/fw6.norm"
    note "manual $PROD_IF/HEv6 lines: $(wc -l <"$out/vxlan41913-rules.txt")"
    note "review $out/vxlan41913-rules.txt before any change"
}

phase_backup() {
    need_root
    session_init
    phase_inventory
    local out="$SESSION/backup"
    local rel=""
    local -a tar_excludes=(--exclude='./rc3-sessions')
    [ -f /config/config.boot ] || die "/config/config.boot not found"

    cp -a /config/config.boot "$out/config.boot"
    cp -a "$SESSION/inventory/inventory.txt" "$out/inventory.txt"
    cp -a "$SESSION/inventory/fw4.raw" "$out/fw4.raw"
    cp -a "$SESSION/inventory/fw6.raw" "$out/fw6.raw"
    cp -a "$SESSION/inventory/fw4.norm" "$out/fw4.norm"
    cp -a "$SESSION/inventory/fw6.norm" "$out/fw6.norm"
    cp -a "$SESSION/inventory/vxlan41913-rules.txt" \
        "$out/vxlan41913-rules.txt"

    case "$SESSION" in
        /config/*) rel="./${SESSION#/config/}" ;;
    esac
    if [ -n "$rel" ]; then
        tar_excludes+=(--exclude="$rel")
    fi
    tar -C /config "${tar_excludes[@]}" -czf "$out/config-dir.tar.gz" . ||
        die "could not archive /config; the backup is incomplete"

    # The archive must contain the complete configuration and must restore.
    # The evidence tree (including the growing archive) is excluded above.
    tar -tzf "$out/config-dir.tar.gz" >"$out/config-dir.list"
    grep -q '^\./config\.boot$' "$out/config-dir.list" ||
        die "the /config archive does not contain config.boot"
    if grep -qF -- 'rc3-sessions' "$out/config-dir.list"; then
        die "the /config archive includes the session evidence tree"
    fi
    mkdir -p "$out/restore-check"
    tar -C "$out/restore-check" -xzf "$out/config-dir.tar.gz" ./config.boot ||
        die "the /config archive could not restore config.boot"
    cmp -s "$out/restore-check/config.boot" "$out/config.boot" ||
        die "the restored config.boot differs from the live copy"
    rm -rf "$out/restore-check"

    (
        cd "$out"
        sha256sum config.boot config-dir.tar.gz config-dir.list \
            inventory.txt fw4.raw fw6.raw fw4.norm fw6.norm \
            vxlan41913-rules.txt >SHA256SUMS
    )

    note "backup: $out (config archive excludes rc3-sessions; config.boot restore verified)"
    note "copy it off-router now, for example:"
    note "  scp -r root@<router>:$out <workstation>/rc3-backup"
}

resolve_artifacts() {
    [ -n "$ARTIFACTS" ] || die "--artifacts DIR is required"
    [ -d "$ARTIFACTS" ] || die "artifact directory not found: $ARTIFACTS"

    ARTIFACTS=$(cd "$ARTIFACTS" && pwd)
    KMOD_DEB="$ARTIFACTS/${RC3_KMOD_PACKAGE}_${RC3_VERSION}_${RC3_KMOD_ARCH}.deb"
    MAIN_DEB="$ARTIFACTS/${RC3_MAIN_PACKAGE}_${RC3_VERSION}_${RC3_MAIN_ARCH}.deb"

    [ -f "$KMOD_DEB" ] || die "expected RC3 kmod artifact not found: $KMOD_DEB"
    [ -f "$MAIN_DEB" ] || die "expected RC3 integration artifact not found: $MAIN_DEB"
}

check_artifact() { # check_artifact <file> <package> <version> <arch> <sha256>
    local file=$1 pkg=$2 version=$3 arch=$4 sha=$5 got

    [ -f "$file" ] || die "artifact missing: $file"
    [ "$(dpkg-deb -f "$file" Package)" = "$pkg" ] ||
        die "$file is not package $pkg"
    [ "$(dpkg-deb -f "$file" Version)" = "$version" ] ||
        die "$file has the wrong version (expected $version)"
    [ "$(dpkg-deb -f "$file" Architecture)" = "$arch" ] ||
        die "$file has the wrong architecture (expected $arch)"
    got=$(sha256sum "$file" | awk '{print $1}')
    [ "$got" = "$sha" ] ||
        die "$file has the wrong SHA-256 (expected $sha, got $got)"
}

phase_stage() {
    session_init
    resolve_artifacts
    need_cmd sha256sum
    need_cmd dpkg-deb
    local out="$SESSION/stage"

    check_artifact "$KMOD_DEB" "$RC3_KMOD_PACKAGE" "$RC3_VERSION" \
        "$RC3_KMOD_ARCH" "$RC3_KMOD_SHA"
    check_artifact "$MAIN_DEB" "$RC3_MAIN_PACKAGE" "$RC3_VERSION" \
        "$RC3_MAIN_ARCH" "$RC3_MAIN_SHA"

    {
        echo "# artifacts"
        printf '%s\n' "$KMOD_DEB" "$MAIN_DEB"
        echo "# expected identity"
        echo "$RC3_KMOD_PACKAGE $RC3_VERSION $RC3_KMOD_ARCH $RC3_KMOD_SHA"
        echo "$RC3_MAIN_PACKAGE $RC3_VERSION $RC3_MAIN_ARCH $RC3_MAIN_SHA"
        echo "# sha256"
        sha256sum "$KMOD_DEB" "$MAIN_DEB"
        echo "# metadata"
        dpkg-deb -f "$KMOD_DEB" Package Version Architecture
        dpkg-deb -f "$MAIN_DEB" Package Version Architecture
        echo "# disk"
        df -h / /config 2>/dev/null || true
    } >"$out/stage.txt" 2>&1

    if [ -f "$ARTIFACTS/SHA256SUMS" ]; then
        (cd "$ARTIFACTS" && sha256sum -c SHA256SUMS) |
            tee -a "$out/stage.txt"
    else
        note "WARNING: $ARTIFACTS/SHA256SUMS is absent; the exact RC3 hashes were still verified against the pinned record"
    fi

    note "stage report: $out/stage.txt"
    note "verified exact RC3 package, version, architecture and recorded SHA-256"
}

phase_install() {
    [ "$EXECUTE" -eq 1 ] || die "refusing to install without --execute"
    need_root
    need_cmd dpkg
    session_init
    [ -n "$ARTIFACTS" ] || die "--artifacts DIR is required"
    [ -f "$ARTIFACTS/SHA256SUMS" ] ||
        die "refusing to install without $ARTIFACTS/SHA256SUMS; cross-check the RC3 artifact record"
    phase_stage
    local out="$SESSION/install"
    local pre_vxlan="$out/pre-vxlan.txt"
    local fail=0

    vxlan_links >"$pre_vxlan"
    iptables-save -t filter >"$out/pre-fw4.raw"
    ip6tables-save -t filter >"$out/pre-fw6.raw"
    normalize_fw_save "$out/pre-fw4.raw" >"$out/pre-fw4.norm"
    normalize_fw_save "$out/pre-fw6.raw" >"$out/pre-fw6.norm"
    dpkg -l >"$out/pre-dpkg.txt"
    sha256sum "$INTERFACE_TARGET" "$INTERFACE_DIVERT" \
        >"$out/pre-interface.sha256" 2>/dev/null || true
    grep -hE "$PROD_IF|HEv6" "$out/pre-fw4.norm" "$out/pre-fw6.norm" \
        >"$out/pre-manual-rules.txt" || true

    note "installing $(basename "$KMOD_DEB") then $(basename "$MAIN_DEB")"
    if ! dpkg -i "$KMOD_DEB" "$MAIN_DEB" 2>&1 | tee "$out/dpkg.log"; then
        note "INSTALL FAILED. Do not remove packages. Capture $out and stop."
        exit 1
    fi

    dpkg-query -W -f='${Package} ${Version} ${Status}\n' \
        edgeos-vxlan edgeos-vxlan-kmod >"$out/post-dpkg-query.txt"
    dpkg-divert --list "$INTERFACE_TARGET" >"$out/diversion.txt" 2>&1 || true
    sha256sum "$INTERFACE_TARGET" "$INTERFACE_DIVERT" \
        >"$out/post-interface.sha256" 2>/dev/null || true
    vxlan_links >"$out/post-vxlan.txt"
    iptables-save -t filter >"$out/post-fw4.raw"
    ip6tables-save -t filter >"$out/post-fw6.raw"
    normalize_fw_save "$out/post-fw4.raw" >"$out/post-fw4.norm"
    normalize_fw_save "$out/post-fw6.raw" >"$out/post-fw6.norm"
    grep -hE "$PROD_IF|HEv6" "$out/post-fw4.norm" "$out/post-fw6.norm" \
        >"$out/post-manual-rules.txt" || true

    if ! dpkg-query -W -f='${Status}\n' edgeos-vxlan-kmod 2>/dev/null |
        grep -q 'install ok installed'; then
        note "FAIL: edgeos-vxlan-kmod is not installed"
        fail=1
    fi
    if ! dpkg-query -W -f='${Status}\n' edgeos-vxlan 2>/dev/null |
        grep -q 'install ok installed'; then
        note "FAIL: edgeos-vxlan is not installed"
        fail=1
    fi
    if ! grep -qF "$INTERFACE_DIVERT" "$out/diversion.txt"; then
        note "FAIL: the $INTERFACE_TARGET diversion is missing"
        fail=1
    fi
    if ! diff -u "$pre_vxlan" "$out/post-vxlan.txt" >"$out/vxlan.diff"; then
        note "FAIL: existing VXLAN interfaces changed during install"
        fail=1
    fi
    if ! diff -u "$out/pre-fw4.norm" "$out/post-fw4.norm" \
        >"$out/fw4.diff"; then
        note "FAIL: the IPv4 filter table changed during install (normalized compare; raw captures retained)"
        fail=1
    fi
    if ! diff -u "$out/pre-fw6.norm" "$out/post-fw6.norm" \
        >"$out/fw6.diff"; then
        note "FAIL: the IPv6 filter table changed during install (normalized compare; raw captures retained)"
        fail=1
    fi
    if ! diff -u "$out/pre-manual-rules.txt" "$out/post-manual-rules.txt" \
        >"$out/manual.diff"; then
        note "FAIL: the manual $PROD_IF/HEv6 rules changed during install"
        fail=1
    fi

    if [ "$fail" -ne 0 ]; then
        note "INSTALL VERIFICATION FAILED. Do not remove packages. Capture $out and stop."
        exit 1
    fi
    note "install verified: both packages installed, diversion present, existing interfaces and firewall unchanged"
}

check_terminal() { # check_terminal <cmd> <chain> <policy> <target>
    local cmd=$1 chain=$2 policy=$3 target=$4 last

    last=$("$cmd" -S "$chain" 2>/dev/null |
        awk '$1 == "-A" { line = $0 } END { print line }')
    case "$last" in
        *"-m comment --comment \"$chain-"*" default-action $policy\" -j $target")
            return 0
            ;;
    esac
    return 1
}

check_dispatch() { # check_dispatch <cmd> <hook> <flag> <iface> <target>
    local cmd=$1 hook=$2 flag=$3 iface=$4 target=$5 count

    count=$("$cmd" -S "$hook" 2>/dev/null |
        grep -cF -- "-A $hook $flag $iface -j $target" || true)
    [ "$count" -eq 1 ]
}

check_hook() { # check_hook <cmd> <base> <hook>
    local cmd=$1 base=$2 hook=$3

    "$cmd" -S "$base" 2>/dev/null | grep -qF -- "-A $base -j $hook"
}

phase_verify() {
    need_root
    need_cmd iptables
    need_cmd ip6tables
    session_init
    local out="$SESSION/verify"
    local fail=0

    if ! ip -o link show dev "$TEST_IF" >"$out/link.txt" 2>/dev/null; then
        note "FAIL: $TEST_IF does not exist"
        fail=1
    elif ! iface_admin_up "$TEST_IF"; then
        note "FAIL: $TEST_IF is not administratively up (exact UP flag)"
        fail=1
    fi

    show_cfg >"$out/configuration.txt"
    for needle in \
        "set interfaces vxlan $TEST_IF firewall in name VXLAN903_IN" \
        "set interfaces vxlan $TEST_IF firewall in ipv6-name VXLAN903_IN6" \
        "set interfaces vxlan $TEST_IF firewall local name VXLAN903_LOCAL_IN" \
        "set interfaces vxlan $TEST_IF firewall local ipv6-name VXLAN903_LOCAL_IN6" \
        "set interfaces vxlan $TEST_IF firewall out name VXLAN903_OUT" \
        "set interfaces vxlan $TEST_IF firewall out ipv6-name VXLAN903_OUT6"; do
        if ! grep -qF -- "$needle" "$out/configuration.txt"; then
            note "FAIL: missing configuration: $needle"
            fail=1
        fi
    done

    iptables-save -t filter >"$out/fw4.raw"
    ip6tables-save -t filter >"$out/fw6.raw"
    normalize_fw_save "$out/fw4.raw" >"$out/fw4.norm"
    normalize_fw_save "$out/fw6.raw" >"$out/fw6.norm"

    check_dispatch iptables VYATTA_FW_IN_HOOK -i "$TEST_IF" VXLAN903_IN ||
        { note "FAIL: v4 in dispatch"; fail=1; }
    check_dispatch iptables VYATTA_FW_OUT_HOOK -o "$TEST_IF" VXLAN903_OUT ||
        { note "FAIL: v4 out dispatch"; fail=1; }
    check_dispatch iptables VYATTA_FW_LOCAL_HOOK -i "$TEST_IF" VXLAN903_LOCAL_IN ||
        { note "FAIL: v4 local dispatch"; fail=1; }
    check_dispatch ip6tables VYATTA_FW_IN_HOOK -i "$TEST_IF" VXLAN903_IN6 ||
        { note "FAIL: v6 in dispatch"; fail=1; }
    check_dispatch ip6tables VYATTA_FW_OUT_HOOK -o "$TEST_IF" VXLAN903_OUT6 ||
        { note "FAIL: v6 out dispatch"; fail=1; }
    check_dispatch ip6tables VYATTA_FW_LOCAL_HOOK -i "$TEST_IF" VXLAN903_LOCAL_IN6 ||
        { note "FAIL: v6 local dispatch"; fail=1; }

    check_hook iptables INPUT VYATTA_FW_LOCAL_HOOK ||
        { note "FAIL: INPUT does not reach VYATTA_FW_LOCAL_HOOK"; fail=1; }
    check_hook iptables FORWARD VYATTA_FW_IN_HOOK ||
        { note "FAIL: FORWARD does not reach VYATTA_FW_IN_HOOK"; fail=1; }
    check_hook iptables FORWARD VYATTA_FW_OUT_HOOK ||
        { note "FAIL: FORWARD does not reach VYATTA_FW_OUT_HOOK"; fail=1; }
    check_hook ip6tables INPUT VYATTA_FW_LOCAL_HOOK ||
        { note "FAIL: IPv6 INPUT does not reach VYATTA_FW_LOCAL_HOOK"; fail=1; }
    check_hook ip6tables FORWARD VYATTA_FW_IN_HOOK ||
        { note "FAIL: IPv6 FORWARD does not reach VYATTA_FW_IN_HOOK"; fail=1; }
    check_hook ip6tables FORWARD VYATTA_FW_OUT_HOOK ||
        { note "FAIL: IPv6 FORWARD does not reach VYATTA_FW_OUT_HOOK"; fail=1; }

    check_terminal iptables VXLAN903_IN drop DROP ||
        { note "FAIL: VXLAN903_IN terminal default"; fail=1; }
    check_terminal iptables VXLAN903_LOCAL_IN drop DROP ||
        { note "FAIL: VXLAN903_LOCAL_IN terminal default"; fail=1; }
    check_terminal iptables VXLAN903_OUT drop DROP ||
        { note "FAIL: VXLAN903_OUT terminal default"; fail=1; }
    check_terminal ip6tables VXLAN903_IN6 drop DROP ||
        { note "FAIL: VXLAN903_IN6 terminal default"; fail=1; }
    check_terminal ip6tables VXLAN903_OUT6 drop DROP ||
        { note "FAIL: VXLAN903_OUT6 terminal default"; fail=1; }
    check_terminal ip6tables VXLAN903_LOCAL_IN6 drop DROP ||
        { note "FAIL: VXLAN903_LOCAL_IN6 terminal default"; fail=1; }

    if grep -Eq -- "-A (INPUT|FORWARD|OUTPUT).*$TEST_IF" "$out/fw4.norm"; then
        note "FAIL: a manual IPv4 rule for $TEST_IF exists in a base chain"
        fail=1
    fi
    if grep -Eq -- "-A (INPUT|FORWARD|OUTPUT).*$TEST_IF" "$out/fw6.norm"; then
        note "FAIL: a manual IPv6 rule for $TEST_IF exists in a base chain"
        fail=1
    fi

    if [ -f "$SESSION/inventory/vxlan41913-rules.txt" ]; then
        grep -hE "$PROD_IF|HEv6" "$out/fw4.norm" "$out/fw6.norm" \
            >"$out/prod-rules.txt" || true
        if ! diff -u "$SESSION/inventory/vxlan41913-rules.txt" \
            "$out/prod-rules.txt" >"$out/prod-rules.diff"; then
            note "FAIL: the manual $PROD_IF/HEv6 rules changed"
            fail=1
        fi
    else
        note "NOTE: no inventory capture in this session; compare the $PROD_IF rules manually"
    fi

    if [ "$fail" -ne 0 ]; then
        printf 'overall: FAIL\n' >"$out/summary.txt"
        note "verify: FAIL (see $out)"
        exit 1
    fi
    printf 'overall: PASS\n' >"$out/summary.txt"
    note "verify: PASS (see $out)"
    note "run vyatta-vxlan-firewall --verify-all $TEST_IF in a configuration session for the authoritative gate"
}

phase_cleanup() {
    session_init
    local out="$SESSION/cleanup/cleanup.conf"
    cat <<EOF | tee "$out"
# commit 1: remove the isolated interface; the reconciler removes its dispatch
configure
delete interfaces vxlan $TEST_IF
commit
exit

# commit 2: remove the isolated rulesets
configure
delete firewall name VXLAN903_IN
delete firewall name VXLAN903_LOCAL_IN
delete firewall name VXLAN903_OUT
delete firewall ipv6-name VXLAN903_IN6
delete firewall ipv6-name VXLAN903_LOCAL_IN6
delete firewall ipv6-name VXLAN903_OUT6
commit
exit
EOF
    note "cleanup blocks: $out"
    note "apply them interactively, then run: $PROG cleanup-check"
    note "do not save; the saved configuration must remain the pre-session baseline"
}

phase_cleanup_check() {
    need_root
    session_init
    local out="$SESSION/cleanup/check.txt"
    local fail=0

    {
        if ip -o link show dev "$TEST_IF" 2>/dev/null; then
            echo "FAIL: $TEST_IF still exists"
            fail=1
        fi
        if iptables-save -t filter 2>/dev/null | grep -qF -- "$TEST_IF"; then
            echo "FAIL: $TEST_IF still appears in the IPv4 filter table"
            fail=1
        fi
        if ip6tables-save -t filter 2>/dev/null | grep -qF -- "$TEST_IF"; then
            echo "FAIL: $TEST_IF still appears in the IPv6 filter table"
            fail=1
        fi
        if show_cfg | grep -qF -- "$TEST_IF"; then
            echo "FAIL: $TEST_IF still appears in the configuration"
            fail=1
        fi
        if iptables-save -t filter 2>/dev/null | grep -qE '^:VXLAN903_|^-N VXLAN903_'; then
            echo "FAIL: an IPv4 VXLAN903 ruleset chain still exists"
            fail=1
        fi
        if ip6tables-save -t filter 2>/dev/null | grep -qE '^:VXLAN903_|^-N VXLAN903_'; then
            echo "FAIL: an IPv6 VXLAN903 ruleset chain still exists"
            fail=1
        fi
        if [ "$fail" -eq 0 ]; then
            echo "PASS: $TEST_IF and its rulesets are gone"
        fi
    } >"$out" 2>&1
    cat "$out"

    if [ "$fail" -ne 0 ]; then
        note "cleanup-check: FAIL (see $out)"
        exit 1
    fi
    note "cleanup-check: PASS (see $out)"
    note "the saved configuration was not changed; do not save in this session"
}

main() {
    [ $# -gt 0 ] || {
        usage >&2
        exit 2
    }
    PHASE=$1
    shift

    while [ $# -gt 0 ]; do
        case "$1" in
            --session)
                SESSION=${2:?--session needs a directory}
                shift 2
                ;;
            --artifacts)
                ARTIFACTS=${2:?--artifacts needs a directory}
                shift 2
                ;;
            --test-if)
                TEST_IF=${2:?--test-if needs an interface}
                shift 2
                ;;
            --execute)
                EXECUTE=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done

    case "$TEST_IF" in
        vxlan[0-9]*) ;;
        *) die "test interface must be a vxlanN name: $TEST_IF" ;;
    esac
    [ "$TEST_IF" != "$PROD_IF" ] ||
        die "refusing to use the production interface $PROD_IF as the test interface"

    case "$PHASE" in
        inventory) phase_inventory ;;
        backup) phase_backup ;;
        stage) phase_stage ;;
        install) phase_install ;;
        verify) phase_verify ;;
        cleanup) phase_cleanup ;;
        cleanup-check) phase_cleanup_check ;;
        -h | --help) usage ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
