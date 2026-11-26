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
  --session DIR     session directory (default /config/rc3-session-<UTC>)
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
        SESSION="/config/rc3-session-$(date -u +%Y%m%dT%H%M%SZ)"
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

    # A stable-format capture for later comparisons: the full firewall saves
    # and the production/manual-rule subset without filename prefixes.
    iptables-save -t filter >"$out/fw4.txt"
    ip6tables-save -t filter >"$out/fw6.txt"
    grep -hE "$PROD_IF|HEv6" "$out/fw4.txt" "$out/fw6.txt" \
        >"$out/vxlan41913-rules.txt" || true

    note "inventory: $out/inventory.txt"
    note "manual $PROD_IF/HEv6 lines: $(wc -l <"$out/vxlan41913-rules.txt")"
    note "review $out/vxlan41913-rules.txt before any change"
}

phase_backup() {
    need_root
    session_init
    phase_inventory
    local out="$SESSION/backup"
    [ -f /config/config.boot ] || die "/config/config.boot not found"

    cp -a /config/config.boot "$out/config.boot"
    cp -a "$SESSION/inventory/inventory.txt" "$out/inventory.txt"
    cp -a "$SESSION/inventory/fw4.txt" "$out/fw4.txt"
    cp -a "$SESSION/inventory/fw6.txt" "$out/fw6.txt"
    cp -a "$SESSION/inventory/vxlan41913-rules.txt" \
        "$out/vxlan41913-rules.txt"
    tar -C /config -czf "$out/config-dir.tar.gz" . ||
        die "could not archive /config; the backup is incomplete"
    (
        cd "$out"
        sha256sum config.boot config-dir.tar.gz inventory.txt fw4.txt \
            fw6.txt vxlan41913-rules.txt >SHA256SUMS
    )

    note "backup: $out"
    note "copy it off-router now, for example:"
    note "  scp -r root@<router>:$out <workstation>/rc3-backup"
}

resolve_artifacts() {
    [ -n "$ARTIFACTS" ] || die "--artifacts DIR is required"
    [ -d "$ARTIFACTS" ] || die "artifact directory not found: $ARTIFACTS"

    KMOD_DEB=$(find "$ARTIFACTS" -maxdepth 1 -type f \
        -name 'edgeos-vxlan-kmod_*_mipsel.deb' -print -quit)
    MAIN_DEB=$(find "$ARTIFACTS" -maxdepth 1 -type f \
        -name 'edgeos-vxlan_*_all.deb' -print -quit)

    [ -n "$KMOD_DEB" ] || die "kmod .deb not found in $ARTIFACTS"
    [ -n "$MAIN_DEB" ] || die "integration .deb not found in $ARTIFACTS"

    KMOD_DEB=$(cd "$(dirname "$KMOD_DEB")" && pwd)/$(basename "$KMOD_DEB")
    MAIN_DEB=$(cd "$(dirname "$MAIN_DEB")" && pwd)/$(basename "$MAIN_DEB")
}

phase_stage() {
    session_init
    resolve_artifacts
    need_cmd sha256sum
    need_cmd dpkg-deb
    local out="$SESSION/stage"

    {
        echo "# artifacts"
        printf '%s\n' "$KMOD_DEB" "$MAIN_DEB"
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
        note "WARNING: $ARTIFACTS/SHA256SUMS is absent; compare the computed hashes with the RC3 artifact record"
    fi

    note "stage report: $out/stage.txt"
    note "cross-check the hashes against docs/v0.3.0-rc3-artifacts.md before install"
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
    iptables-save -t filter >"$out/pre-fw4"
    ip6tables-save -t filter >"$out/pre-fw6"
    dpkg -l >"$out/pre-dpkg.txt"
    sha256sum "$INTERFACE_TARGET" "$INTERFACE_DIVERT" \
        >"$out/pre-interface.sha256" 2>/dev/null || true
    grep -hE "$PROD_IF|HEv6" "$out/pre-fw4" "$out/pre-fw6" \
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
    iptables-save -t filter >"$out/post-fw4"
    ip6tables-save -t filter >"$out/post-fw6"
    grep -hE "$PROD_IF|HEv6" "$out/post-fw4" "$out/post-fw6" \
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
    if ! diff -u "$out/pre-fw4" "$out/post-fw4" >"$out/fw4.diff"; then
        note "FAIL: the IPv4 filter table changed during install"
        fail=1
    fi
    if ! diff -u "$out/pre-fw6" "$out/post-fw6" >"$out/fw6.diff"; then
        note "FAIL: the IPv6 filter table changed during install"
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
    elif ! grep -q 'UP' "$out/link.txt"; then
        note "FAIL: $TEST_IF is not administratively up"
        fail=1
    fi

    show_cfg >"$out/configuration.txt"
    for needle in \
        "set interfaces vxlan $TEST_IF firewall in name VXLAN903_IN" \
        "set interfaces vxlan $TEST_IF firewall in ipv6-name VXLAN903_IN6" \
        "set interfaces vxlan $TEST_IF firewall local name VXLAN903_LOCAL_IN" \
        "set interfaces vxlan $TEST_IF firewall local ipv6-name VXLAN903_LOCAL_IN6" \
        "set interfaces vxlan $TEST_IF firewall out name VXLAN903_OUT"; do
        if ! grep -qF -- "$needle" "$out/configuration.txt"; then
            note "FAIL: missing configuration: $needle"
            fail=1
        fi
    done

    iptables-save -t filter >"$out/fw4.txt"
    ip6tables-save -t filter >"$out/fw6.txt"

    check_dispatch iptables VYATTA_FW_IN_HOOK -i "$TEST_IF" VXLAN903_IN ||
        { note "FAIL: v4 in dispatch"; fail=1; }
    check_dispatch iptables VYATTA_FW_OUT_HOOK -o "$TEST_IF" VXLAN903_OUT ||
        { note "FAIL: v4 out dispatch"; fail=1; }
    check_dispatch iptables VYATTA_FW_LOCAL_HOOK -i "$TEST_IF" VXLAN903_LOCAL_IN ||
        { note "FAIL: v4 local dispatch"; fail=1; }
    check_dispatch ip6tables VYATTA_FW_IN_HOOK -i "$TEST_IF" VXLAN903_IN6 ||
        { note "FAIL: v6 in dispatch"; fail=1; }
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

    check_terminal iptables VXLAN903_IN drop DROP ||
        { note "FAIL: VXLAN903_IN terminal default"; fail=1; }
    check_terminal iptables VXLAN903_LOCAL_IN drop DROP ||
        { note "FAIL: VXLAN903_LOCAL_IN terminal default"; fail=1; }
    check_terminal iptables VXLAN903_OUT drop DROP ||
        { note "FAIL: VXLAN903_OUT terminal default"; fail=1; }
    check_terminal ip6tables VXLAN903_IN6 drop DROP ||
        { note "FAIL: VXLAN903_IN6 terminal default"; fail=1; }
    check_terminal ip6tables VXLAN903_LOCAL_IN6 drop DROP ||
        { note "FAIL: VXLAN903_LOCAL_IN6 terminal default"; fail=1; }

    if grep -Eq -- "-A (INPUT|FORWARD|OUTPUT).*$TEST_IF" "$out/fw4.txt"; then
        note "FAIL: a manual IPv4 rule for $TEST_IF exists in a base chain"
        fail=1
    fi
    if grep -Eq -- "-A (INPUT|FORWARD|OUTPUT).*$TEST_IF" "$out/fw6.txt"; then
        note "FAIL: a manual IPv6 rule for $TEST_IF exists in a base chain"
        fail=1
    fi

    if [ -f "$SESSION/inventory/vxlan41913-rules.txt" ]; then
        grep -hE "$PROD_IF|HEv6" "$out/fw4.txt" "$out/fw6.txt" \
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
