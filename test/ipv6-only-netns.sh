#!/bin/bash
# Isolated IPv6-only qualification for the VXLAN dataplane.
#
# Evidence class N6: a deterministic Linux network-namespace topology with an
# IPv6-only routed underlay and IPv6-only overlays.  This is not an EdgeOS
# hardware test, an emulated EdgeOS configuration-engine test, or a claim of
# Level D (IPv6-only runner and control plane).
#
# Topology:
#
#   host-a --- vtep-a --- transit --- vtep-b --- host-b
#                  \                    /
#                   vxlan100 (VNI 100)  (VTEP-to-VTEP overlay)
#                   vxlan200 (VNI 200)  (routed host overlay)
#                   vxlan300 (VNI 300)  (generic Linux bridge feasibility)
#
# All network changes occur inside private network namespaces.  The script
# requires root/CAP_NET_ADMIN and iproute2, iputils-ping, python3, and
# coreutils.  tcpdump is optional for packet-capture evidence.
#
# Environment variables:
#   REQUIRE_NETNS_TEST=1   turn an unavailable environment into a failure
#   REQUIRE_CAPTURE=1      turn unavailable packet capture into a failure
#   REQUIRE_RECONCILER=1   turn an unavailable reconciler integration into a failure
#   EVIDENCE_DIR=DIR       write diagnostics and captures to DIR
#   IPV6_ONLY_SUFFIX=SFX   namespace/link suffix (alphanumeric, max 8 chars)
#
# Usage:
#   REQUIRE_NETNS_TEST=1 bash test/ipv6-only-netns.sh
#   EVIDENCE_DIR=/tmp/evidence bash test/ipv6-only-netns.sh
#   EVIDENCE_DIR=/tmp/evidence bash test/ipv6-only-netns.sh --cleanup
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/test/lib/ipv6-isolation.sh"
# shellcheck source=test/lib/ipv6-isolation.sh
. "$LIB"

REQUIRE_NETNS_TEST=${REQUIRE_NETNS_TEST:-0}
REQUIRE_CAPTURE=${REQUIRE_CAPTURE:-0}
REQUIRE_RECONCILER=${REQUIRE_RECONCILER:-0}
EVIDENCE_DIR=${EVIDENCE_DIR:-}
if [ -n "$EVIDENCE_DIR" ]; then
    EVIDENCE_DIR=${EVIDENCE_DIR%/}
    if [ -z "$EVIDENCE_DIR" ]; then
        echo "ERROR: EVIDENCE_DIR must not be the filesystem root" >&2
        exit 2
    fi
fi
SUFFIX=${IPV6_ONLY_SUFFIX:-$$}
MODE=run

case "${1:-}" in
    '' | run) ;;
    --cleanup | cleanup) MODE=cleanup ;;
    --help | -h)
        sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "usage: $0 [--help|--cleanup]" >&2
        exit 2
        ;;
esac

case "$SUFFIX" in
    '' | *[!A-Za-z0-9]*)
        echo "ERROR: IPV6_ONLY_SUFFIX must be alphanumeric: '$SUFFIX'" >&2
        exit 2
        ;;
esac
if [ "${#SUFFIX}" -gt 8 ]; then
    echo "ERROR: IPV6_ONLY_SUFFIX must be at most 8 characters: '$SUFFIX'" >&2
    exit 2
fi

NS_A="v6a$SUFFIX"
NS_B="v6b$SUFFIX"
NS_T="v6t$SUFFIX"
NS_HA="v6ha$SUFFIX"
NS_HB="v6hb$SUFFIX"
NS_V4A="v6c4a$SUFFIX"
NS_V4B="v6c4b$SUFFIX"
ALL_NS=("$NS_A" "$NS_B" "$NS_T" "$NS_HA" "$NS_HB" "$NS_V4A" "$NS_V4B")

L_TA="ta$SUFFIX"
L_UA="ua$SUFFIX"
L_TB="tb$SUFFIX"
L_UB="ub$SUFFIX"
L_HA="ha$SUFFIX"
L_HBA="hba$SUFFIX"
L_HB="hb$SUFFIX"
L_HBB="hbb$SUFFIX"
L_V4A="c4a$SUFFIX"
L_V4B="c4b$SUFFIX"
ALL_LINKS=("$L_TA" "$L_UA" "$L_TB" "$L_UB" "$L_HA" "$L_HBA" "$L_HB" "$L_HBB" "$L_V4A" "$L_V4B")

PASS=0
FAIL=0
SKIP=0
PIDS=()
CAPTURE_PIDS=()
CREATED_NS=()
CREATED_LINKS=()
PROBE_NS=
CAPTURE_STATUS=not-run
RECONCILER_STATUS=not-run
HARNESS=
WORK=

ok()
{
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$*"
}

bad()
{
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$*"
}

skip()
{
    SKIP=$((SKIP + 1))
    printf 'SKIP: %s\n' "$*"
}

die()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

nsrun()
{
    local ns=$1
    shift
    ip netns exec "$ns" "$@"
}

set_sysctl()
{
    local ns=$1 key=$2 value=$3
    nsrun "$ns" sysctl -qw "$key=$value" ||
        die "cannot set $key=$value in $ns"
}

cleanup()
{
    local pid ns link
    trap - EXIT INT TERM HUP
    if [ "${#PIDS[@]}" -gt 0 ]; then
        for pid in "${PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    if [ "${#CAPTURE_PIDS[@]}" -gt 0 ]; then
        for pid in "${CAPTURE_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    if [ "${#CREATED_NS[@]}" -gt 0 ]; then
        for ns in "${CREATED_NS[@]}"; do
            ip netns del "$ns" 2>/dev/null || true
        done
    fi
    if [ -n "$PROBE_NS" ]; then
        ip netns del "$PROBE_NS" 2>/dev/null || true
    fi
    if [ "${#CREATED_LINKS[@]}" -gt 0 ]; then
        for link in "${CREATED_LINKS[@]}"; do
            ip link del "$link" 2>/dev/null || true
        done
    fi
    if [ -n "$HARNESS" ]; then
        rm -rf "$HARNESS"
    fi
    if [ -n "$WORK" ]; then
        rm -rf "$WORK"
    fi
}

cleanup_from_evidence()
{
    local suffix ns link
    local ns_list=() link_list=()
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: --cleanup requires root/CAP_NET_ADMIN" >&2
        exit 1
    fi
    [ -n "$EVIDENCE_DIR" ] ||
        { echo "ERROR: EVIDENCE_DIR is required for --cleanup" >&2; exit 2; }
    if [ ! -d "$EVIDENCE_DIR" ]; then
        echo "No evidence directory at $EVIDENCE_DIR; nothing to clean."
        return 0
    fi
    [ ! -L "$EVIDENCE_DIR" ] ||
        { echo "ERROR: refusing to use a symlinked EVIDENCE_DIR" >&2; exit 2; }
    if [ ! -f "$EVIDENCE_DIR/run.env" ]; then
        echo "No recorded run.env in $EVIDENCE_DIR; nothing to clean."
        return 0
    fi

    # Reconstruct the exact names from the recorded suffix.  Do not delete
    # arbitrary names by prefix: a sudo-run cleanup must only touch the
    # objects this test created.
    suffix=$(sed -n 's/^IPV6_ONLY_SUFFIX=//p' "$EVIDENCE_DIR/run.env")
    case "$suffix" in
        '' | *[!A-Za-z0-9]*)
            echo "ERROR: invalid recorded suffix '$suffix'" >&2
            exit 2
            ;;
    esac
    if [ "${#suffix}" -gt 8 ]; then
        echo "ERROR: recorded suffix is too long: '$suffix'" >&2
        exit 2
    fi

    # Keep this list in sync with ALL_NS/ALL_LINKS above and the probe
    # namespace in preflight().
    ns_list=(
        "v6a$suffix" "v6b$suffix" "v6t$suffix"
        "v6ha$suffix" "v6hb$suffix"
        "v6c4a$suffix" "v6c4b$suffix"
        "v6probe$suffix"
    )
    link_list=(
        "ta$suffix" "ua$suffix" "tb$suffix" "ub$suffix"
        "ha$suffix" "hba$suffix" "hb$suffix" "hbb$suffix"
        "c4a$suffix" "c4b$suffix"
    )
    for ns in "${ns_list[@]}"; do
        ip netns del "$ns" 2>/dev/null || true
    done
    for link in "${link_list[@]}"; do
        ip link del "$link" 2>/dev/null || true
    done
}

if [ "$MODE" = "cleanup" ]; then
    cleanup_from_evidence
    exit 0
fi

if [ -z "$EVIDENCE_DIR" ]; then
    EVIDENCE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ipv6-only-evidence.XXXXXX") ||
        die "cannot create evidence directory"
fi
[ ! -L "$EVIDENCE_DIR" ] ||
    die "refusing to use a symlinked EVIDENCE_DIR: $EVIDENCE_DIR"
if [ -e "$EVIDENCE_DIR" ]; then
    [ -O "$EVIDENCE_DIR" ] ||
        die "EVIDENCE_DIR is not owned by the current user: $EVIDENCE_DIR"
fi
mkdir -p "$EVIDENCE_DIR/captures" ||
    die "cannot prepare evidence directory $EVIDENCE_DIR"
[ -O "$EVIDENCE_DIR" ] ||
    die "EVIDENCE_DIR is not owned by the current user: $EVIDENCE_DIR"
[ ! -L "$EVIDENCE_DIR/captures" ] ||
    die "refusing to use a symlinked captures directory"
for evidence_file in run.env namespaces.txt links.txt run.log; do
    [ ! -L "$EVIDENCE_DIR/$evidence_file" ] ||
        die "refusing to write through a symlinked $evidence_file"
done
printf 'IPV6_ONLY_SUFFIX=%s\n' "$SUFFIX" >"$EVIDENCE_DIR/run.env"
printf '%s\n' "${ALL_NS[@]}" >"$EVIDENCE_DIR/namespaces.txt"
printf '%s\n' "${ALL_LINKS[@]}" >"$EVIDENCE_DIR/links.txt"
exec > >(tee -a "$EVIDENCE_DIR/run.log") 2>&1

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

preflight()
{
    local cmd probe
    if [ "$(id -u)" -ne 0 ]; then
        echo "SKIP: root/CAP_NET_ADMIN required for isolated network namespaces"
        [ "$REQUIRE_NETNS_TEST" = "1" ] && exit 1
        exit 0
    fi
    for cmd in ip ping python3 timeout awk sed grep tr cat cut sort wc readlink sha256sum sysctl bridge env tee mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "SKIP: required command not available: $cmd"
            [ "$REQUIRE_NETNS_TEST" = "1" ] && exit 1
            exit 0
        fi
    done
    if ! command -v perl >/dev/null 2>&1 ||
        ! perl -MJSON::PP -e 1 >/dev/null 2>&1; then
        echo "NOTE: Perl JSON::PP unavailable; reconciler integration will be skipped"
    fi

    probe="v6probe$SUFFIX"
    if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$probe"; then
        echo "SKIP: probe namespace $probe already exists; refusing to delete it"
        [ "$REQUIRE_NETNS_TEST" = "1" ] && exit 1
        exit 0
    fi
    PROBE_NS=$probe
    if ! ip netns add "$PROBE_NS" 2>/dev/null; then
        echo "SKIP: network namespaces are unavailable (CAP_SYS_ADMIN or mount propagation)"
        [ "$REQUIRE_NETNS_TEST" = "1" ] && exit 1
        exit 0
    fi
    ip netns del "$PROBE_NS" 2>/dev/null || true
    PROBE_NS=

    if [ ! -d /sys/module/vxlan ]; then
        if command -v modprobe >/dev/null 2>&1; then
            modprobe vxlan 2>/dev/null || true
        fi
    fi
    if [ ! -d /sys/module/vxlan ]; then
        echo "SKIP: the vxlan kernel module is unavailable"
        [ "$REQUIRE_NETNS_TEST" = "1" ] && exit 1
        exit 0
    fi
}

record_environment()
{
    local host_v4_count host_v6_count
    host_v4_count=$(ip -4 -o addr show scope global 2>/dev/null |
        grep -c 'inet ' || true)
    host_v6_count=$(ip -6 -o addr show scope global 2>/dev/null |
        grep -c 'inet6 ' || true)
    {
        echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "uname=$(uname -a)"
        echo "ip=$(ip -V 2>&1)"
        echo "ping=$(ping -V 2>&1 | sed -n '1p')"
        echo "python3=$(python3 --version 2>&1)"
        if command -v tcpdump >/dev/null 2>&1; then
            echo "tcpdump=$(tcpdump --version 2>&1 | sed -n '1p')"
        else
            echo "tcpdump=unavailable"
        fi
        echo "vxlan_module=$( [ -d /sys/module/vxlan ] && echo present || echo absent )"
        if perl -MJSON::PP -e 1 >/dev/null 2>&1; then
            echo "perl_json_pp=available"
        else
            echo "perl_json_pp=unavailable"
        fi
        echo "host_ipv4_global_address_count=$host_v4_count"
        echo "host_ipv6_global_address_count=$host_v6_count"
        echo "host_ipv4_forwarding=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
        echo "host_ipv6_forwarding=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo unknown)"
    } >"$EVIDENCE_DIR/environment.txt" 2>&1
}

create_ns()
{
    local ns=$1
    ip netns add "$ns" || die "cannot create namespace $ns"
    CREATED_NS+=("$ns")
    nsrun "$ns" ip link set lo up || die "cannot bring up lo in $ns"
    set_sysctl "$ns" net.ipv4.conf.all.forwarding 0
    set_sysctl "$ns" net.ipv4.conf.default.forwarding 0
    set_sysctl "$ns" net.ipv6.conf.all.accept_ra 0
    set_sysctl "$ns" net.ipv6.conf.all.autoconf 0
    set_sysctl "$ns" net.ipv6.conf.all.accept_redirects 0
}

veth_pair()
{
    local h1=$1 ns1=$2 n1=$3 h2=$4 ns2=$5 n2=$6
    ip link add "$h1" type veth peer name "$h2" || return 1
    CREATED_LINKS+=("$h1" "$h2")
    ip link set "$h1" netns "$ns1" || return 1
    ip link set "$h2" netns "$ns2" || return 1
    ip -n "$ns1" link set "$h1" name "$n1" || return 1
    ip -n "$ns2" link set "$h2" name "$n2" || return 1
}

link_up()
{
    local ns=$1 iface=$2
    nsrun "$ns" ip link set "$iface" mtu 1500 up ||
        die "cannot bring up $iface in $ns"
}

addr6()
{
    local ns=$1 addr=$2 iface=$3
    nsrun "$ns" ip -6 addr replace "$addr" nodad dev "$iface" ||
        die "cannot add or replace $addr on $iface in $ns"
}

route6()
{
    local ns=$1 route=$2
    # shellcheck disable=SC2086 # route is a deliberately split argument list
    nsrun "$ns" ip -6 route add $route ||
        die "cannot add IPv6 route '$route' in $ns"
}

create_vxlan()
{
    local ns=$1 iface=$2 vni=$3 local=$4 remote=$5
    nsrun "$ns" ip link add "$iface" type vxlan \
        id "$vni" local "$local" remote "$remote" dstport 4789 ||
        die "cannot create $iface in $ns"
    nsrun "$ns" ip link set "$iface" mtu 1430 up ||
        die "cannot bring up $iface in $ns"
}

setup_topology()
{
    local ns link
    for ns in "${ALL_NS[@]}"; do
        if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns"; then
            die "refusing to reuse existing namespace $ns; use --cleanup with its evidence directory"
        fi
    done
    for link in "${ALL_LINKS[@]}"; do
        if ip link show dev "$link" >/dev/null 2>&1; then
            die "refusing to reuse existing host link $link"
        fi
    done
    for ns in "${ALL_NS[@]}"; do
        create_ns "$ns"
    done

    veth_pair "$L_TA" "$NS_T" "ta0" "$L_UA" "$NS_A" "eth0" ||
        die "cannot create the vtep-a transit link"
    veth_pair "$L_TB" "$NS_T" "tb0" "$L_UB" "$NS_B" "eth0" ||
        die "cannot create the vtep-b transit link"
    veth_pair "$L_HA" "$NS_A" "eth1" "$L_HBA" "$NS_HA" "eth0" ||
        die "cannot create the host-a link"
    veth_pair "$L_HB" "$NS_B" "eth1" "$L_HBB" "$NS_HB" "eth0" ||
        die "cannot create the host-b link"
    veth_pair "$L_V4A" "$NS_V4A" "eth0" "$L_V4B" "$NS_V4B" "eth0" ||
        die "cannot create the IPv4 control link"

    link_up "$NS_T" ta0
    link_up "$NS_T" tb0
    link_up "$NS_A" eth0
    link_up "$NS_A" eth1
    link_up "$NS_B" eth0
    link_up "$NS_B" eth1
    link_up "$NS_HA" eth0
    link_up "$NS_HB" eth0
    link_up "$NS_V4A" eth0
    link_up "$NS_V4B" eth0

    # Routed IPv6 underlay: two /64 links through an independent transit
    # namespace.  The VTEPs have default routes to the transit; the transit
    # has only connected routes and therefore no external IPv6 path.
    addr6 "$NS_T" 2001:db8:10:1::1/64 ta0
    addr6 "$NS_T" 2001:db8:10:2::1/64 tb0
    addr6 "$NS_A" 2001:db8:10:1::a1/64 eth0
    addr6 "$NS_B" 2001:db8:10:2::b1/64 eth0
    route6 "$NS_A" "default via 2001:db8:10:1::1 dev eth0"
    route6 "$NS_B" "default via 2001:db8:10:2::1 dev eth0"
    set_sysctl "$NS_T" net.ipv6.conf.all.forwarding 1
    set_sysctl "$NS_A" net.ipv6.conf.all.forwarding 1
    set_sysctl "$NS_B" net.ipv6.conf.all.forwarding 1

    # VTEP-to-VTEP overlay (VNI 100).
    create_vxlan "$NS_A" vxlan100 100 2001:db8:10:1::a1 2001:db8:10:2::b1
    create_vxlan "$NS_B" vxlan100 100 2001:db8:10:2::b1 2001:db8:10:1::a1
    addr6 "$NS_A" 2001:db8:100::a/64 vxlan100
    addr6 "$NS_B" 2001:db8:100::b/64 vxlan100

    # Routed host overlay (VNI 200).  Hosts use different /64s behind each
    # VTEP; the VTEPs route between the host /64 and the overlay /64.
    create_vxlan "$NS_A" vxlan200 200 2001:db8:10:1::a1 2001:db8:10:2::b1
    create_vxlan "$NS_B" vxlan200 200 2001:db8:10:2::b1 2001:db8:10:1::a1
    addr6 "$NS_A" 2001:db8:200::a/64 vxlan200
    addr6 "$NS_B" 2001:db8:200::b/64 vxlan200
    addr6 "$NS_A" 2001:db8:201::1/64 eth1
    addr6 "$NS_B" 2001:db8:202::1/64 eth1
    addr6 "$NS_HA" 2001:db8:201::a/64 eth0
    addr6 "$NS_HB" 2001:db8:202::b/64 eth0
    route6 "$NS_HA" "default via 2001:db8:201::1 dev eth0"
    route6 "$NS_HB" "default via 2001:db8:202::1 dev eth0"
    route6 "$NS_A" "2001:db8:202::/64 via 2001:db8:200::b dev vxlan200"
    route6 "$NS_B" "2001:db8:201::/64 via 2001:db8:200::a dev vxlan200"

    # Generic Linux bridge feasibility (VNI 300).  This is not the EdgeOS
    # bridged dataplane tracked by ENG-IPV6-04.
    nsrun "$NS_A" ip link add br300 type bridge || die "cannot create br300 in vtep-a"
    nsrun "$NS_B" ip link add br300 type bridge || die "cannot create br300 in vtep-b"
    nsrun "$NS_A" ip link set br300 mtu 1430 up || die "cannot bring up br300 in vtep-a"
    nsrun "$NS_B" ip link set br300 mtu 1430 up || die "cannot bring up br300 in vtep-b"
    create_vxlan "$NS_A" vxlan300 300 2001:db8:10:1::a1 2001:db8:10:2::b1
    create_vxlan "$NS_B" vxlan300 300 2001:db8:10:2::b1 2001:db8:10:1::a1
    nsrun "$NS_A" ip link set vxlan300 master br300 ||
        die "cannot attach vxlan300 to br300 in vtep-a"
    nsrun "$NS_B" ip link set vxlan300 master br300 ||
        die "cannot attach vxlan300 to br300 in vtep-b"
    addr6 "$NS_A" 2001:db8:300::a/64 br300
    addr6 "$NS_B" 2001:db8:300::b/64 br300

    # IPv4 control pair.  It is deliberately separate from the IPv6-only
    # topology and exists only to prove that the negative-control destination
    # is reachable in an IPv4-capable environment.
    nsrun "$NS_V4A" ip -4 addr add 198.51.100.1/24 dev eth0 ||
        die "cannot add the IPv4 control address in v4-a"
    nsrun "$NS_V4B" ip -4 addr add 198.51.100.2/24 dev eth0 ||
        die "cannot add the IPv4 control address in v4-b"

    sleep 1
}

record_topology()
{
    local file=$1 ns
    {
        for ns in "${ALL_NS[@]}"; do
            echo "### namespace $ns"
            nsrun "$ns" ip -d -o link show
            nsrun "$ns" ip -6 addr show
            nsrun "$ns" ip -6 route show table all
            nsrun "$ns" ip -4 addr show
            nsrun "$ns" ip -4 route show table all
            nsrun "$ns" ip -4 rule show
            echo
        done
    } >"$EVIDENCE_DIR/$file" 2>&1
}

expect_veth_peer()
{
    local phase=$1 ns=$2 iface=$3 expected=$4 actual
    actual=$(nsrun "$ns" ip -d -o link show dev "$iface" 2>/dev/null |
        grep -o 'link-netns [^ ]*' | awk '{print $2; exit}')
    if [ "$actual" = "$expected" ]; then
        ok "$phase veth peer $ns/$iface is $expected"
    else
        bad "$phase veth peer $ns/$iface is '${actual:-missing}', expected $expected"
    fi
}

check_host_sysctls()
{
    local current
    current=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)
    if [ "$current" = "$HOST_IPV4_FORWARDING_BEFORE" ]; then
        ok "host IPv4 forwarding unchanged ($current)"
    else
        bad "host IPv4 forwarding changed ($HOST_IPV4_FORWARDING_BEFORE -> $current)"
    fi
    current=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo unknown)
    if [ "$current" = "$HOST_IPV6_FORWARDING_BEFORE" ]; then
        ok "host IPv6 forwarding unchanged ($current)"
    else
        bad "host IPv6 forwarding changed ($HOST_IPV6_FORWARDING_BEFORE -> $current)"
    fi
}

check_isolation()
{
    local phase=$1 spec ns label
    for spec in \
        "$NS_A:vtep-a" \
        "$NS_B:vtep-b" \
        "$NS_T:transit" \
        "$NS_HA:host-a" \
        "$NS_HB:host-b"; do
        ns=${spec%%:*}
        label=${spec#*:}
        if ipv6_iso_assert "$ns" "$label"; then
            ok "$phase isolation: $label"
        else
            bad "$phase isolation: $label"
        fi
    done

    if ipv6_iso_loopback_present "$NS_A"; then
        ok "$phase IPv4 loopback present on lo in vtep-a (documented)"
    else
        bad "$phase IPv4 loopback is missing on lo in vtep-a"
    fi

    local transit_default
    if transit_default=$(nsrun "$NS_T" ip -6 route show default 2>/dev/null); then
        if [ -z "$transit_default" ]; then
            ok "$phase transit has no IPv6 default route"
        else
            bad "$phase transit has an IPv6 default route"
        fi
    else
        bad "$phase cannot read the transit IPv6 default route"
    fi

    if nsrun "$NS_A" ip -6 route get 2001:db8:10:2::b1 2>/dev/null |
        grep -q 'via 2001:db8:10:1::1'; then
        ok "$phase routed IPv6 underlay uses the transit"
    else
        bad "$phase routed IPv6 underlay is not via the transit"
    fi

    local inode_a inode_b inode_t inode_ha inode_hb inode_host unique
    inode_a=$(nsrun "$NS_A" readlink /proc/self/ns/net)
    inode_b=$(nsrun "$NS_B" readlink /proc/self/ns/net)
    inode_t=$(nsrun "$NS_T" readlink /proc/self/ns/net)
    inode_ha=$(nsrun "$NS_HA" readlink /proc/self/ns/net)
    inode_hb=$(nsrun "$NS_HB" readlink /proc/self/ns/net)
    inode_host=$(readlink /proc/self/ns/net)
    unique=$(printf '%s\n' \
        "$inode_a" "$inode_b" "$inode_t" "$inode_ha" "$inode_hb" |
        sort -u | wc -l)
    if [ "$unique" -eq 5 ] &&
        [ "$inode_a" != "$inode_host" ] &&
        [ "$inode_b" != "$inode_host" ] &&
        [ "$inode_t" != "$inode_host" ] &&
        [ "$inode_ha" != "$inode_host" ] &&
        [ "$inode_hb" != "$inode_host" ]; then
        ok "$phase namespace boundaries are distinct from the host"
    else
        bad "$phase namespace boundaries are not distinct from the host"
    fi

    expect_veth_peer "$phase" "$NS_A" eth0 "$NS_T"
    expect_veth_peer "$phase" "$NS_A" eth1 "$NS_HA"
    expect_veth_peer "$phase" "$NS_B" eth0 "$NS_T"
    expect_veth_peer "$phase" "$NS_B" eth1 "$NS_HB"
    expect_veth_peer "$phase" "$NS_T" ta0 "$NS_A"
    expect_veth_peer "$phase" "$NS_T" tb0 "$NS_B"
    expect_veth_peer "$phase" "$NS_HA" eth0 "$NS_A"
    expect_veth_peer "$phase" "$NS_HB" eth0 "$NS_B"
    expect_veth_peer "$phase" "$NS_V4A" eth0 "$NS_V4B"
    expect_veth_peer "$phase" "$NS_V4B" eth0 "$NS_V4A"

    local leftover=() link
    for link in "${ALL_LINKS[@]}"; do
        if ip link show dev "$link" >/dev/null 2>&1; then
            leftover+=("$link")
        fi
    done
    if [ "${#leftover[@]}" -eq 0 ]; then
        ok "$phase no host-side test veth remains"
    else
        bad "$phase host-side test veth remains: ${leftover[*]}"
    fi
}

test_host_escape()
{
    local host_v4 host_v6
    host_v4=$(ip -4 -o addr show scope global 2>/dev/null |
        awk '{print $4}' | cut -d/ -f1 | sed -n '1p')
    host_v6=$(ip -6 -o addr show scope global 2>/dev/null |
        awk '{print $4}' | cut -d/ -f1 | sed -n '1p')

    case "$host_v4" in
        192.0.2.* | 198.51.100.* | 203.0.113.*)
            skip "host IPv4 address is in a documentation range; escape control not applicable"
            host_v4=
            ;;
    esac
    if [ -n "$host_v4" ]; then
        if ping -4 -c 1 -W 1 -q "$host_v4" >/dev/null 2>&1; then
            ok "host IPv4 destination is reachable from the host"
        else
            skip "host IPv4 destination is not reachable from the host"
        fi
        if nsrun "$NS_A" ping -4 -c 1 -W 1 -q "$host_v4" >/dev/null 2>&1; then
            bad "vtep-a reached the host's IPv4 address"
        else
            ok "vtep-a cannot reach the host's IPv4 address"
        fi
    else
        skip "host has no global IPv4 address for the escape control"
    fi

    case "$host_v6" in
        2001:db8:*)
            skip "host IPv6 address is in a documentation range; escape control not applicable"
            host_v6=
            ;;
    esac
    if [ -n "$host_v6" ]; then
        if nsrun "$NS_A" ping -6 -c 1 -W 1 -q "$host_v6" >/dev/null 2>&1; then
            bad "vtep-a reached the host's global IPv6 address"
        else
            ok "vtep-a cannot reach the host's global IPv6 address"
        fi
    else
        skip "host has no global IPv6 address for the escape control"
    fi
}

test_ipv4_negative_controls()
{
    local out

    if ipv6_iso_violations "$NS_A" >/dev/null; then
        ok "isolation validator accepts the clean vtep-a"
    else
        bad "isolation validator rejects the clean vtep-a"
    fi

    nsrun "$NS_A" ip -4 addr add 192.0.2.99/32 dev eth0 ||
        bad "cannot introduce the IPv4 address canary"
    if ipv6_iso_violations "$NS_A" >/dev/null; then
        bad "isolation validator did not detect an introduced IPv4 address"
    else
        ok "isolation validator detects an introduced IPv4 address"
    fi
    nsrun "$NS_A" ip -4 addr del 192.0.2.99/32 dev eth0 2>/dev/null || true
    if ipv6_iso_violations "$NS_A" >/dev/null; then
        ok "isolation validator is clean after removing the IPv4 address canary"
    else
        bad "isolation validator is not clean after removing the IPv4 address canary"
    fi

    nsrun "$NS_A" ip -4 route add 203.0.113.0/24 dev eth0 ||
        bad "cannot introduce the IPv4 route canary"
    if ipv6_iso_violations "$NS_A" >/dev/null; then
        bad "isolation validator did not detect an introduced IPv4 route"
    else
        ok "isolation validator detects an introduced IPv4 route"
    fi
    nsrun "$NS_A" ip -4 route del 203.0.113.0/24 dev eth0 2>/dev/null || true

    nsrun "$NS_A" ip -4 rule add fwmark 1 lookup 100 ||
        bad "cannot introduce the IPv4 policy rule canary"
    nsrun "$NS_A" ip -4 route add 203.0.113.0/24 dev eth0 table 100 ||
        bad "cannot introduce the IPv4 policy route canary"
    if ipv6_iso_violations "$NS_A" >/dev/null; then
        bad "isolation validator did not detect an introduced IPv4 policy route"
    else
        ok "isolation validator detects an introduced IPv4 policy route"
    fi
    nsrun "$NS_A" ip -4 route del 203.0.113.0/24 dev eth0 table 100 2>/dev/null || true
    nsrun "$NS_A" ip -4 rule del fwmark 1 lookup 100 2>/dev/null || true

    if ipv6_iso_violations "$NS_A" >/dev/null; then
        ok "isolation validator is clean after removing all IPv4 canaries"
    else
        bad "isolation validator is not clean after removing all IPv4 canaries"
    fi

    if nsrun "$NS_V4A" ping -4 -c 1 -W 2 -q 198.51.100.2 >/dev/null 2>&1; then
        ok "IPv4 control destination is reachable in the IPv4 control pair"
    else
        bad "IPv4 control destination is not reachable in the IPv4 control pair"
    fi
    if nsrun "$NS_HA" ping -4 -c 1 -W 1 -q 198.51.100.2 >/dev/null 2>&1; then
        bad "host-a reached the IPv4 control destination"
    else
        ok "host-a cannot reach the otherwise reachable IPv4 destination"
    fi
    if out=$(nsrun "$NS_HA" ip -4 route get 198.51.100.2 2>&1); then
        bad "host-a has an IPv4 route to the control destination: $out"
    else
        ok "host-a has no IPv4 route to the control destination"
    fi

    if nsrun "$NS_HA" python3 -c \
        'import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM)' \
        >/dev/null 2>&1; then
        ok "AF_INET socket creation is available and explicitly documented"
    else
        bad "AF_INET socket creation is unexpectedly unavailable"
    fi
}

ping6_ok()
{
    nsrun "$1" ping -6 -c 1 -W 2 -q "$2" >/dev/null 2>&1
}

ping6_fail()
{
    ! ping6_ok "$1" "$2"
}

test_underlay_and_overlay()
{
    if ping6_ok "$NS_A" 2001:db8:10:1::1; then
        ok "IPv6 underlay vtep-a to transit"
    else
        bad "IPv6 underlay vtep-a to transit"
    fi
    if ping6_ok "$NS_B" 2001:db8:10:2::1; then
        ok "IPv6 underlay vtep-b to transit"
    else
        bad "IPv6 underlay vtep-b to transit"
    fi
    if ping6_ok "$NS_A" 2001:db8:100::b; then
        ok "IPv6 VTEP overlay vtep-a to vtep-b"
    else
        bad "IPv6 VTEP overlay vtep-a to vtep-b"
    fi
    if ping6_ok "$NS_B" 2001:db8:100::a; then
        ok "IPv6 VTEP overlay vtep-b to vtep-a"
    else
        bad "IPv6 VTEP overlay vtep-b to vtep-a"
    fi
    if ping6_ok "$NS_HA" 2001:db8:202::b; then
        ok "routed IPv6 host overlay host-a to host-b"
    else
        bad "routed IPv6 host overlay host-a to host-b"
    fi
    if ping6_ok "$NS_HB" 2001:db8:201::a; then
        ok "routed IPv6 host overlay host-b to host-a"
    else
        bad "routed IPv6 host overlay host-b to host-a"
    fi
}

test_ndp()
{
    nsrun "$NS_A" ip -6 neigh flush dev vxlan100
    nsrun "$NS_B" ip -6 neigh flush dev vxlan100
    if ping6_ok "$NS_A" 2001:db8:100::b; then
        ok "NDP baseline after flushing the overlay neighbor cache"
    else
        bad "NDP baseline after flushing the overlay neighbor cache"
    fi
    if nsrun "$NS_A" ip -6 neigh show dev vxlan100 |
        grep -q '2001:db8:100::b'; then
        ok "NDP resolved the overlay peer in vtep-a"
    else
        bad "NDP did not resolve the overlay peer in vtep-a"
    fi

    nsrun "$NS_A" ip -6 neigh flush dev eth0
    if ping6_ok "$NS_A" 2001:db8:10:1::1; then
        ok "underlay NDP baseline after flushing the underlay cache"
    else
        bad "underlay NDP baseline after flushing the underlay cache"
    fi
    if nsrun "$NS_A" ip -6 neigh show dev eth0 |
        grep -q '2001:db8:10:1::1'; then
        ok "underlay NDP resolved the transit"
    else
        bad "underlay NDP did not resolve the transit"
    fi
}

write_python_helpers()
{
    cat >"$WORK/tcp_server.py" <<'EOF'
import socket

sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("2001:db8:202::b", 8080))
sock.listen(1)
sock.settimeout(10)
conn, _ = sock.accept()
conn.sendall(b"ok")
conn.close()
sock.close()
EOF
    cat >"$WORK/tcp_client.py" <<'EOF'
import socket

sock = socket.create_connection(("2001:db8:202::b", 8080), 5)
data = b""
while len(data) < 2:
    part = sock.recv(2 - len(data))
    if not part:
        break
    data += part
assert data == b"ok", data
sock.close()
EOF
    cat >"$WORK/udp_server.py" <<'EOF'
import socket

sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
sock.bind(("2001:db8:202::b", 8081))
sock.settimeout(10)
data, peer = sock.recvfrom(64)
assert data == b"ping", data
sock.sendto(b"pong", peer)
sock.close()
EOF
    cat >"$WORK/udp_client.py" <<'EOF'
import socket

sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
sock.settimeout(5)
sock.sendto(b"ping", ("2001:db8:202::b", 8081))
data, _ = sock.recvfrom(64)
assert data == b"pong", data
sock.close()
EOF
}

test_tcp_udp()
{
    local quiet=${1:-no}
    local server_pid
    write_python_helpers

    ip netns exec "$NS_HB" python3 "$WORK/tcp_server.py" \
        >"$EVIDENCE_DIR/tcp-server.log" 2>&1 &
    server_pid=$!
    PIDS+=("$server_pid")
    sleep 0.5
    if nsrun "$NS_HA" timeout 8 python3 "$WORK/tcp_client.py" \
        >"$EVIDENCE_DIR/tcp-client.log" 2>&1; then
        [ "$quiet" = "yes" ] || ok "IPv6 TCP across the routed VXLAN overlay"
    else
        [ "$quiet" = "yes" ] || bad "IPv6 TCP across the routed VXLAN overlay"
    fi
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    drop_pid "$server_pid"

    ip netns exec "$NS_HB" python3 "$WORK/udp_server.py" \
        >"$EVIDENCE_DIR/udp-server.log" 2>&1 &
    server_pid=$!
    PIDS+=("$server_pid")
    sleep 0.5
    if nsrun "$NS_HA" timeout 8 python3 "$WORK/udp_client.py" \
        >"$EVIDENCE_DIR/udp-client.log" 2>&1; then
        [ "$quiet" = "yes" ] || ok "IPv6 UDP across the routed VXLAN overlay"
    else
        [ "$quiet" = "yes" ] || bad "IPv6 UDP across the routed VXLAN overlay"
    fi
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    drop_pid "$server_pid"
}

write_reconciler_python_helpers()
{
    cat >"$WORK/recon-tcp-server.py" <<'EOF'
import socket

sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("2001:db8:900::b", 8090))
sock.listen(1)
sock.settimeout(10)
conn, _ = sock.accept()
conn.sendall(b"reconciler-ok")
conn.close()
sock.close()
EOF
    cat >"$WORK/recon-tcp-client.py" <<'EOF'
import socket

sock = socket.create_connection(("2001:db8:900::b", 8090), 5)
data = b""
while len(data) < 14:
    part = sock.recv(14 - len(data))
    if not part:
        break
    data += part
assert data == b"reconciler-ok", data
sock.close()
EOF
    cat >"$WORK/recon-udp-server.py" <<'EOF'
import socket

sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
sock.bind(("2001:db8:900::b", 8091))
sock.settimeout(10)
data, peer = sock.recvfrom(64)
assert data == b"recon-ping", data
sock.sendto(b"recon-pong", peer)
sock.close()
EOF
    cat >"$WORK/recon-udp-client.py" <<'EOF'
import socket

sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
sock.settimeout(5)
sock.sendto(b"recon-ping", ("2001:db8:900::b", 8091))
data, _ = sock.recvfrom(64)
assert data == b"recon-pong", data
sock.close()
EOF
}

test_reconciler_tcp_udp()
{
    local server_pid
    write_reconciler_python_helpers

    ip netns exec "$NS_B" python3 "$WORK/recon-tcp-server.py" \
        >"$EVIDENCE_DIR/reconciler-tcp-server.log" 2>&1 &
    server_pid=$!
    PIDS+=("$server_pid")
    sleep 0.5
    if nsrun "$NS_A" timeout 8 python3 "$WORK/recon-tcp-client.py" \
        >"$EVIDENCE_DIR/reconciler-tcp-client.log" 2>&1; then
        ok "actual reconciler-created VXLAN carries IPv6 TCP"
    else
        bad "actual reconciler-created VXLAN did not carry IPv6 TCP"
    fi
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    drop_pid "$server_pid"

    ip netns exec "$NS_B" python3 "$WORK/recon-udp-server.py" \
        >"$EVIDENCE_DIR/reconciler-udp-server.log" 2>&1 &
    server_pid=$!
    PIDS+=("$server_pid")
    sleep 0.5
    if nsrun "$NS_A" timeout 8 python3 "$WORK/recon-udp-client.py" \
        >"$EVIDENCE_DIR/reconciler-udp-client.log" 2>&1; then
        ok "actual reconciler-created VXLAN carries IPv6 UDP"
    else
        bad "actual reconciler-created VXLAN did not carry IPv6 UDP"
    fi
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    drop_pid "$server_pid"
}

drop_pid()
{
    local target=$1 pid
    local keep=()
    if [ "${#PIDS[@]}" -gt 0 ]; then
        for pid in "${PIDS[@]}"; do
            [ "$pid" = "$target" ] || keep+=("$pid")
        done
    fi
    PIDS=("${keep[@]}")
}

counter()
{
    nsrun "$1" cat "/sys/class/net/$2/statistics/$3" 2>/dev/null || echo 0
}

test_encapsulation_counters()
{
    local before_tx before_rx after_tx after_rx
    before_tx=$(counter "$NS_A" vxlan200 tx_packets)
    before_rx=$(counter "$NS_B" vxlan200 rx_packets)
    if ping6_ok "$NS_HA" 2001:db8:202::b; then
        ok "forwarded overlay ping for encapsulation counters"
    else
        bad "forwarded overlay ping for encapsulation counters"
    fi
    after_tx=$(counter "$NS_A" vxlan200 tx_packets)
    after_rx=$(counter "$NS_B" vxlan200 rx_packets)
    if [ "$after_tx" -gt "$before_tx" ] && [ "$after_rx" -gt "$before_rx" ]; then
        ok "VXLAN vxlan200 TX/RX counters increased"
    else
        bad "VXLAN vxlan200 counters did not increase (tx $before_tx->$after_tx, rx $before_rx->$after_rx)"
    fi
    {
        echo "before_tx=$before_tx"
        echo "after_tx=$after_tx"
        echo "before_rx=$before_rx"
        echo "after_rx=$after_rx"
        nsrun "$NS_A" ip -s link show vxlan200
        nsrun "$NS_B" ip -s link show vxlan200
    } >"$EVIDENCE_DIR/counters.txt" 2>&1
}

test_mtu_boundary()
{
    local out
    if ping6_ok "$NS_A" 2001:db8:100::b; then
        ok "overlay MTU baseline at the default size"
    else
        bad "overlay MTU baseline at the default size"
    fi
    if nsrun "$NS_A" ping -6 -M 'do' -c 1 -W 2 -s 1382 -q 2001:db8:100::b \
        >"$EVIDENCE_DIR/mtu-1382.log" 2>&1; then
        ok "overlay MTU boundary: 1382-byte payload fits the 1430-byte VXLAN MTU"
    else
        bad "overlay MTU boundary: 1382-byte payload should fit the 1430-byte VXLAN MTU"
    fi
    if nsrun "$NS_A" ping -6 -M 'do' -c 1 -W 2 -s 1383 -q 2001:db8:100::b \
        >"$EVIDENCE_DIR/mtu-1383.log" 2>&1; then
        bad "overlay MTU boundary: 1383-byte payload must not fit the 1430-byte VXLAN MTU"
    else
        ok "overlay MTU boundary: 1383-byte payload is rejected by the 1430-byte VXLAN MTU"
    fi
    if out=$(nsrun "$NS_A" cat /sys/class/net/vxlan100/mtu 2>/dev/null); then
        if [ "$out" = "1430" ]; then
            ok "vxlan100 MTU is explicitly 1430"
        else
            bad "vxlan100 MTU is '$out', expected 1430"
        fi
    else
        bad "cannot read vxlan100 MTU"
    fi
}

test_recreation()
{
    nsrun "$NS_A" ip link del vxlan100 ||
        bad "cannot delete vxlan100 for the recreation test"
    create_vxlan "$NS_A" vxlan100 100 2001:db8:10:1::a1 2001:db8:10:2::b1
    addr6 "$NS_A" 2001:db8:100::a/64 vxlan100
    if ping6_ok "$NS_A" 2001:db8:100::b; then
        ok "IPv6 overlay survives VXLAN interface deletion and recreation"
    else
        bad "IPv6 overlay did not survive VXLAN interface deletion and recreation"
    fi
}

test_interruption_negative_control()
{
    nsrun "$NS_A" ip link set vxlan100 down ||
        bad "cannot take vxlan100 down for the interruption control"
    if ping6_fail "$NS_A" 2001:db8:100::b; then
        ok "overlay connectivity fails when the IPv6 VXLAN dataplane is interrupted"
    else
        bad "overlay connectivity did not fail when the IPv6 VXLAN dataplane was interrupted"
    fi
    nsrun "$NS_A" ip link set vxlan100 up ||
        bad "cannot restore vxlan100 after the interruption control"
    addr6 "$NS_A" 2001:db8:100::a/64 vxlan100
    sleep 1
    if ping6_ok "$NS_A" 2001:db8:100::b; then
        ok "overlay connectivity recovers after the VXLAN dataplane is restored"
    else
        bad "overlay connectivity did not recover after the VXLAN dataplane was restored"
    fi
}

test_bridge_feasibility()
{
    if ping6_ok "$NS_A" 2001:db8:300::b; then
        ok "generic Linux bridge over IPv6 VXLAN (VNI 300) forwards IPv6"
    else
        bad "generic Linux bridge over IPv6 VXLAN (VNI 300) did not forward IPv6"
    fi
    nsrun "$NS_A" ip -6 neigh flush dev br300
    if ping6_ok "$NS_A" 2001:db8:300::b; then
        ok "bridged overlay NDP baseline after flushing the bridge neighbor cache"
    else
        bad "bridged overlay NDP baseline after flushing the bridge neighbor cache"
    fi
    if nsrun "$NS_A" ip -6 neigh show dev br300 |
        grep -q '2001:db8:300::b'; then
        ok "bridged overlay NDP resolved the peer on br300"
    else
        bad "bridged overlay NDP did not resolve the peer on br300"
    fi
    {
        echo "### bridge link"
        nsrun "$NS_A" bridge link show
        echo "### bridge fdb"
        nsrun "$NS_A" bridge fdb show dev vxlan300
    } >"$EVIDENCE_DIR/bridge.txt" 2>&1
}

reconciler_prepare()
{
    HARNESS=$(mktemp -d "${TMPDIR:-/tmp}/ipv6-reconciler.XXXXXX") ||
        return 1
    mkdir -p "$HARNESS/bin" "$HARNESS/sbin" \
        "$HARNESS/conf-a" "$HARNESS/conf-b" "$HARNESS/log" || return 1

    cat >"$HARNESS/bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-g" ] && [ "$2" = "-n" ]; then
    echo vyattacfg
    exit 0
fi
exec /usr/bin/id "$@"
EOF
    cat >"$HARNESS/bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
    cat >"$HARNESS/bin/modprobe" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat >"$HARNESS/sbin/vyatta-address" <<'EOF'
#!/bin/sh
echo "vyatta-address $*" >>"$HARNESS_LOG"
case "$1" in
    add) ip addr add "$3" dev "$2" ;;
    delete) ip addr del "$3" dev "$2" ;;
    *) exit 2 ;;
esac
EOF
    cat >"$HARNESS/sbin/vyatta-vxlan-bridge" <<'EOF'
#!/bin/sh
echo "vyatta-vxlan-bridge $*" >>"$HARNESS_LOG"
exit 0
EOF
    cat >"$HARNESS/sbin/vyatta-vxlan-firewall" <<'EOF'
#!/bin/sh
echo "vyatta-vxlan-firewall $*" >>"$HARNESS_LOG"
case "$1" in
    --capture) exit 0 ;;
    --apply | --restore) cat >/dev/null; exit 0 ;;
    --verify-all | --remove-all | --validate | --status) exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat >"$HARNESS/sbin/my_cli_shell_api" <<'EOF'
#!/bin/sh
mode=$1
shift
tree=${CONF:-/nonexistent}
[ "$mode" = "existsEffective" ] && tree=${CONF_EFFECTIVE:-$tree}
if [ "${1:-}" = "interfaces" ] && [ "${2:-}" = "vxlan" ]; then
    ifname=$3
    shift 3
    node=""
    for arg in "$@"; do
        node="${node:+$node.}$arg"
    done
    key="$tree/$ifname${node:+.$node}"
    case "$mode" in
        exists | existsEffective)
            if [ -z "$node" ]; then
                for file in "$tree/$ifname".*; do
                    [ -e "$file" ] && exit 0
                done
                exit 1
            fi
            [ -e "$key" ] && exit 0 || exit 1
            ;;
        returnValue | returnValues)
            [ -e "$key" ] && cat "$key"
            exit 0
            ;;
    esac
fi
exit 1
EOF
    cp "$ROOT/src/vyatta-vxlan-addr" "$HARNESS/sbin/vyatta-vxlan-addr" || return 1
    chmod +x "$HARNESS/bin"/* "$HARNESS/sbin"/* || return 1
}

set_reconciler_config()
{
    local dir=$1 local=$2 remote=$3 address=$4 vni=$5 mtu=$6
    mkdir -p "$dir" || return 1
    printf '%s' "$vni" >"$dir/vxlan900.vni"
    printf '%s' "$local" >"$dir/vxlan900.local-ip"
    printf '%s' "$remote" >"$dir/vxlan900.remote-ip"
    printf '%s' '4789' >"$dir/vxlan900.port"
    printf '%s' "$mtu" >"$dir/vxlan900.mtu"
    printf '%s' "$address" >"$dir/vxlan900.address"
    printf '%s' 'ipv6-only reconciler' >"$dir/vxlan900.description"
}

run_reconciler()
{
    local ns=$1 conf=$2 action=$3
    local log="$HARNESS/log/$ns-$action.log"
    nsrun "$ns" env \
        PATH="$HARNESS/bin:$PATH" \
        HARNESS_LOG="$log" \
        CONF="$conf" \
        CONF_EFFECTIVE="$conf" \
        vyatta_sbindir="$HARNESS/sbin" \
        vxlan_bin_modprobe="$HARNESS/bin/modprobe" \
        bash "$ROOT/src/vyatta-vxlan" "$action" vxlan900
}

reconciler_identity_ok()
{
    local ns=$1 vni=$2 mtu=$3 address=$4
    nsrun "$ns" ip -d -o link show vxlan900 2>/dev/null |
        grep -qE "vxlan id $vni([[:space:]]|$)" || return 1
    [ "$(nsrun "$ns" cat /sys/class/net/vxlan900/mtu 2>/dev/null)" = "$mtu" ] || return 1
    nsrun "$ns" ip -6 -o addr show dev vxlan900 2>/dev/null |
        grep -q "$address" || return 1
    return 0
}

test_reconciler_integration()
{
    local mac_before ifindex_before rc fail_before
    if ! command -v perl >/dev/null 2>&1 ||
        ! perl -MJSON::PP -e 1 >/dev/null 2>&1; then
        if [ "$REQUIRE_RECONCILER" = "1" ]; then
            bad "reconciler integration is required but Perl JSON::PP is unavailable"
        else
            skip "reconciler integration: Perl JSON::PP unavailable"
        fi
        RECONCILER_STATUS=skipped
        return
    fi
    if ! reconciler_prepare; then
        bad "reconciler integration: cannot prepare the test harness"
        RECONCILER_STATUS=failed
        return
    fi
    fail_before=$FAIL

    set_reconciler_config "$HARNESS/conf-a" \
        2001:db8:10:1::a1 2001:db8:10:2::b1 2001:db8:900::a/64 900 1430 ||
        { bad "reconciler integration: cannot write vtep-a configuration"; return; }
    set_reconciler_config "$HARNESS/conf-b" \
        2001:db8:10:2::b1 2001:db8:10:1::a1 2001:db8:900::b/64 900 1430 ||
        { bad "reconciler integration: cannot write vtep-b configuration"; return; }

    if run_reconciler "$NS_A" "$HARNESS/conf-a" UPDATE \
        >"$EVIDENCE_DIR/reconciler-vtep-a-create.log" 2>&1; then
        ok "actual reconciler created vxlan900 on vtep-a"
    else
        bad "actual reconciler failed to create vxlan900 on vtep-a"
    fi
    if run_reconciler "$NS_B" "$HARNESS/conf-b" UPDATE \
        >"$EVIDENCE_DIR/reconciler-vtep-b-create.log" 2>&1; then
        ok "actual reconciler created vxlan900 on vtep-b"
    else
        bad "actual reconciler failed to create vxlan900 on vtep-b"
    fi
    sleep 2

    if reconciler_identity_ok "$NS_A" 900 1430 '2001:db8:900::a/64'; then
        ok "reconciler produced the requested IPv6 VXLAN identity on vtep-a"
    else
        bad "reconciler produced an unexpected IPv6 VXLAN identity on vtep-a"
    fi
    if reconciler_identity_ok "$NS_B" 900 1430 '2001:db8:900::b/64'; then
        ok "reconciler produced the requested IPv6 VXLAN identity on vtep-b"
    else
        bad "reconciler produced an unexpected IPv6 VXLAN identity on vtep-b"
    fi
    if ping6_ok "$NS_A" 2001:db8:900::b; then
        ok "reconciler-created IPv6 VXLAN carries overlay traffic"
    else
        bad "reconciler-created IPv6 VXLAN did not carry overlay traffic"
    fi
    test_reconciler_tcp_udp

    # The actual reconciler must reject invalid endpoint families/classes
    # before it mutates the live interface.
    reject_reconciler_endpoint()
    {
        local label=$1 remote=$2
        local log="$EVIDENCE_DIR/reconciler-vtep-a-reject-${label}.log"
        set_reconciler_config "$HARNESS/conf-a" \
            2001:db8:10:1::a1 "$remote" 2001:db8:900::a/64 900 1430
        if run_reconciler "$NS_A" "$HARNESS/conf-a" UPDATE >"$log" 2>&1; then
            bad "actual reconciler accepted invalid endpoint $label"
        else
            ok "actual reconciler rejected invalid endpoint $label"
        fi
        if grep -qE 'ERROR.*(same family|multicast|not a valid)' "$log"; then
            ok "invalid endpoint $label failed with an endpoint-validation error"
        else
            bad "invalid endpoint $label failed for an unexpected reason"
        fi
        if reconciler_identity_ok "$NS_A" 900 1430 '2001:db8:900::a/64'; then
            ok "invalid endpoint $label left the live interface unchanged"
        else
            bad "invalid endpoint $label mutated the live interface"
        fi
    }

    reject_reconciler_endpoint "mixed-family" "192.0.2.1"
    reject_reconciler_endpoint "ipv6-multicast" "ff02::1"
    set_reconciler_config "$HARNESS/conf-a" \
        2001:db8:10:1::a1 2001:db8:10:2::b1 2001:db8:900::a/64 900 1430
    if run_reconciler "$NS_A" "$HARNESS/conf-a" UPDATE \
        >"$EVIDENCE_DIR/reconciler-vtep-a-valid-restore.log" 2>&1; then
        ok "actual reconciler accepted the valid endpoint after rejections"
    else
        bad "actual reconciler rejected the valid endpoint after rejections"
    fi
    if ping6_ok "$NS_A" 2001:db8:900::b; then
        ok "overlay connectivity survives endpoint-validation rejections"
    else
        bad "overlay connectivity was disrupted by endpoint-validation rejections"
    fi

    mac_before=$(nsrun "$NS_A" cat /sys/class/net/vxlan900/address 2>/dev/null || echo missing)
    ifindex_before=$(nsrun "$NS_A" cat /sys/class/net/vxlan900/ifindex 2>/dev/null || echo missing)
    if run_reconciler "$NS_A" "$HARNESS/conf-a" UPDATE \
        >"$EVIDENCE_DIR/reconciler-vtep-a-idempotent.log" 2>&1; then
        ok "actual reconciler accepted an idempotent update"
    else
        bad "actual reconciler rejected an idempotent update"
    fi
    if [ "$(nsrun "$NS_A" cat /sys/class/net/vxlan900/address 2>/dev/null || echo missing)" = "$mac_before" ] &&
        [ "$(nsrun "$NS_A" cat /sys/class/net/vxlan900/ifindex 2>/dev/null || echo missing)" = "$ifindex_before" ]; then
        ok "idempotent reconciler update preserved MAC and ifindex"
    else
        bad "idempotent reconciler update changed MAC or ifindex"
    fi

    # Fault injection: an identity change plus an invalid MTU forces the
    # recreation path, then a failure after deletion, then rollback.
    set_reconciler_config "$HARNESS/conf-a" \
        2001:db8:10:1::a1 2001:db8:10:2::b1 2001:db8:900::a/64 901 60
    run_reconciler "$NS_A" "$HARNESS/conf-a" UPDATE \
        >"$EVIDENCE_DIR/reconciler-vtep-a-rollback.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ok "actual reconciler rejected the invalid recreation"
    else
        bad "actual reconciler accepted the invalid recreation"
    fi
    if grep -qE 'mtu|MTU|Failed to apply requested VXLAN state' \
        "$EVIDENCE_DIR/reconciler-vtep-a-rollback.log"; then
        ok "invalid recreation failed at the MTU/apply step"
    else
        bad "invalid recreation failed for an unexpected reason"
    fi
    sleep 2
    if reconciler_identity_ok "$NS_A" 900 1430 '2001:db8:900::a/64'; then
        ok "actual reconciler rolled back the invalid recreation to the previous identity"
    else
        bad "actual reconciler did not roll back the invalid recreation"
    fi
    if ping6_ok "$NS_A" 2001:db8:900::b; then
        ok "overlay traffic resumes after the actual reconciler rollback"
    else
        bad "overlay traffic does not resume after the actual reconciler rollback"
    fi

    set_reconciler_config "$HARNESS/conf-a" \
        2001:db8:10:1::a1 2001:db8:10:2::b1 2001:db8:900::a/64 900 1430
    if run_reconciler "$NS_A" "$HARNESS/conf-a" UPDATE \
        >"$EVIDENCE_DIR/reconciler-vtep-a-restore.log" 2>&1; then
        ok "actual reconciler restored the desired identity after rollback"
    else
        bad "actual reconciler failed to restore the desired identity after rollback"
    fi
    if ping6_ok "$NS_A" 2001:db8:900::b; then
        ok "overlay traffic passes after reconciler restore"
    else
        bad "overlay traffic fails after reconciler restore"
    fi

    if run_reconciler "$NS_A" "$HARNESS/conf-a" DELETE \
        >"$EVIDENCE_DIR/reconciler-vtep-a-delete.log" 2>&1; then
        ok "actual reconciler deleted vxlan900 on vtep-a"
    else
        bad "actual reconciler failed to delete vxlan900 on vtep-a"
    fi
    if ! nsrun "$NS_A" ip link show dev vxlan900 >/dev/null 2>&1; then
        ok "reconciler deletion removed the vxlan900 netdevice"
    else
        bad "reconciler deletion left the vxlan900 netdevice in place"
    fi
    if run_reconciler "$NS_B" "$HARNESS/conf-b" DELETE \
        >"$EVIDENCE_DIR/reconciler-vtep-b-delete.log" 2>&1; then
        ok "actual reconciler deleted vxlan900 on vtep-b"
    else
        bad "actual reconciler failed to delete vxlan900 on vtep-b"
    fi

    cp "$HARNESS/log"/*.log "$EVIDENCE_DIR/" 2>/dev/null || true
    if [ "$FAIL" -gt "$fail_before" ]; then
        RECONCILER_STATUS=failed
    else
        RECONCILER_STATUS=executed
    fi
}

wait_for_capture_start()
{
    local pid=$1 log=$2 iface=$3 i=0
    while [ "$i" -lt 50 ]; do
        if grep -q "listening on $iface" "$log" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

pcap_count()
{
    local file=$1 filter=$2 out
    if ! out=$(tcpdump -nn -r "$file" "$filter" 2>/dev/null); then
        echo "ERROR: tcpdump could not analyze $file ($filter)" >&2
        return 1
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | wc -l
    else
        echo 0
    fi
}

test_packet_capture()
{
    local underlay="$EVIDENCE_DIR/captures/underlay.pcap"
    local overlay="$EVIDENCE_DIR/captures/overlay.pcap"
    local underlay_log="$EVIDENCE_DIR/captures/underlay.log"
    local overlay_log="$EVIDENCE_DIR/captures/overlay.log"
    local underlay_pid overlay_pid pid
    local fail_before

    if ! command -v tcpdump >/dev/null 2>&1; then
        skip "packet capture: tcpdump unavailable"
        CAPTURE_STATUS=skipped
        [ "$REQUIRE_CAPTURE" = "1" ] &&
            bad "packet capture is required but tcpdump is unavailable"
        return
    fi
    fail_before=$FAIL

    ip netns exec "$NS_T" tcpdump -U -i ta0 -nn -s 0 -w "$underlay" \
        >"$underlay_log" 2>&1 &
    underlay_pid=$!
    PIDS+=("$underlay_pid")
    CAPTURE_PIDS+=("$underlay_pid")
    ip netns exec "$NS_A" tcpdump -U -i vxlan200 -nn -s 0 -w "$overlay" \
        >"$overlay_log" 2>&1 &
    overlay_pid=$!
    PIDS+=("$overlay_pid")
    CAPTURE_PIDS+=("$overlay_pid")

    if ! wait_for_capture_start "$underlay_pid" "$underlay_log" ta0 ||
        ! wait_for_capture_start "$overlay_pid" "$overlay_log" vxlan200; then
        bad "packet capture did not start cleanly"
        echo "--- underlay tcpdump log ---" >&2
        cat "$underlay_log" >&2 2>/dev/null || true
        echo "--- overlay tcpdump log ---" >&2
        cat "$overlay_log" >&2 2>/dev/null || true
        for pid in "${CAPTURE_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            drop_pid "$pid"
        done
        CAPTURE_PIDS=()
        CAPTURE_STATUS=failed
        return
    fi

    nsrun "$NS_A" ip -6 neigh flush dev eth0
    ping6_ok "$NS_A" 2001:db8:10:1::1
    nsrun "$NS_A" ip -6 neigh flush dev vxlan200
    ping6_ok "$NS_A" 2001:db8:200::b
    test_tcp_udp yes
    sleep 2

    for pid in "${CAPTURE_PIDS[@]}"; do
        kill -INT "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        drop_pid "$pid"
    done
    CAPTURE_PIDS=()
    sleep 0.2

    if ! grep -q 'packets captured' "$underlay_log" ||
        ! grep -q 'packets captured' "$overlay_log"; then
        bad "tcpdump did not report capture completion"
        echo "--- underlay tcpdump log ---" >&2
        cat "$underlay_log" >&2 2>/dev/null || true
        echo "--- overlay tcpdump log ---" >&2
        cat "$overlay_log" >&2 2>/dev/null || true
        CAPTURE_STATUS=failed
        return
    fi

    if [ ! -s "$underlay" ] || [ ! -s "$overlay" ]; then
        bad "packet capture produced an empty capture file"
        echo "--- underlay tcpdump log ---" >&2
        cat "$EVIDENCE_DIR/captures/underlay.log" >&2 2>/dev/null || true
        echo "--- overlay tcpdump log ---" >&2
        cat "$EVIDENCE_DIR/captures/overlay.log" >&2 2>/dev/null || true
        CAPTURE_STATUS=failed
        return
    fi

    local underlay_ipv4 underlay_vxlan underlay_nd overlay_ipv4 overlay_ipv6 overlay_tcp overlay_udp overlay_vxlan overlay_nd
    if ! underlay_ipv4=$(pcap_count "$underlay" 'ether proto 0x0800 or ether proto 0x0806') ||
        ! underlay_vxlan=$(pcap_count "$underlay" 'ip6 and udp port 4789') ||
        ! underlay_nd=$(pcap_count "$underlay" 'icmp6 and (ip6[40] == 135 or ip6[40] == 136)') ||
        ! overlay_ipv4=$(pcap_count "$overlay" 'ether proto 0x0800 or ether proto 0x0806') ||
        ! overlay_ipv6=$(pcap_count "$overlay" 'ip6') ||
        ! overlay_tcp=$(pcap_count "$overlay" 'tcp') ||
        ! overlay_udp=$(pcap_count "$overlay" 'udp') ||
        ! overlay_vxlan=$(pcap_count "$overlay" 'udp port 4789') ||
        ! overlay_nd=$(pcap_count "$overlay" 'icmp6 and (ip6[40] == 135 or ip6[40] == 136)'); then
        bad "packet capture analysis failed"
        CAPTURE_STATUS=failed
        return
    fi

    {
        echo "underlay_ipv4_or_arp=$underlay_ipv4"
        echo "underlay_vxlan_udp4789=$underlay_vxlan"
        echo "underlay_nd=$underlay_nd"
        echo "overlay_ipv4_or_arp=$overlay_ipv4"
        echo "overlay_ipv6=$overlay_ipv6"
        echo "overlay_tcp=$overlay_tcp"
        echo "overlay_udp=$overlay_udp"
        echo "overlay_vxlan_udp4789=$overlay_vxlan"
        echo "overlay_nd=$overlay_nd"
    } >"$EVIDENCE_DIR/captures/analysis.txt"

    if [ "$underlay_ipv4" -eq 0 ]; then
        ok "underlay capture contains no IPv4 Ethernet frames or ARP"
    else
        bad "underlay capture contains $underlay_ipv4 IPv4/ARP frame(s)"
    fi
    if [ "$underlay_vxlan" -gt 0 ]; then
        ok "underlay capture contains IPv6 VXLAN UDP/4789 traffic"
    else
        bad "underlay capture contains no IPv6 VXLAN UDP/4789 traffic"
    fi
    if [ "$underlay_nd" -gt 0 ]; then
        ok "underlay capture contains IPv6 Neighbor Discovery"
    else
        bad "underlay capture contains no IPv6 Neighbor Discovery"
    fi
    if [ "$overlay_ipv4" -eq 0 ]; then
        ok "overlay capture contains no IPv4 Ethernet frames or ARP"
    else
        bad "overlay capture contains $overlay_ipv4 IPv4/ARP frame(s)"
    fi
    if [ "$overlay_ipv6" -gt 0 ]; then
        ok "overlay capture contains decapsulated inner IPv6 traffic"
    else
        bad "overlay capture contains no decapsulated inner IPv6 traffic"
    fi
    if [ "$overlay_tcp" -gt 0 ]; then
        ok "overlay capture contains TCP across the VXLAN overlay"
    else
        bad "overlay capture contains no TCP across the VXLAN overlay"
    fi
    if [ "$overlay_udp" -gt 0 ]; then
        ok "overlay capture contains UDP across the VXLAN overlay"
    else
        bad "overlay capture contains no UDP across the VXLAN overlay"
    fi
    if [ "$overlay_vxlan" -eq 0 ]; then
        ok "overlay capture contains no outer UDP/4789 VXLAN headers"
    else
        bad "overlay capture unexpectedly contains outer VXLAN headers"
    fi
    if [ "$overlay_nd" -gt 0 ]; then
        ok "overlay capture contains inner IPv6 Neighbor Discovery"
    else
        bad "overlay capture contains no inner IPv6 Neighbor Discovery"
    fi
    if [ "$FAIL" -gt "$fail_before" ]; then
        CAPTURE_STATUS=failed
    else
        CAPTURE_STATUS=executed
    fi
}

write_summary()
{
    {
        echo "qualification=IPv6-only Level B (Linux network namespace)"
        echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "namespace_suffix=$SUFFIX"
        echo "pass=$PASS"
        echo "fail=$FAIL"
        echo "skip=$SKIP"
        echo "packet_capture=$CAPTURE_STATUS"
        echo "reconciler=$RECONCILER_STATUS"
        echo "require_netns_test=$REQUIRE_NETNS_TEST"
        echo "require_capture=$REQUIRE_CAPTURE"
        echo "require_reconciler=$REQUIRE_RECONCILER"
        echo "evidence_dir=$EVIDENCE_DIR"
    } >"$EVIDENCE_DIR/summary.txt"
}

write_json_summary()
{
    local result=passed
    [ "$FAIL" -eq 0 ] || result=failed
    python3 - "$EVIDENCE_DIR" "$result" "$PASS" "$FAIL" "$SKIP" \
        "$CAPTURE_STATUS" "$RECONCILER_STATUS" "$ROOT" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone

evidence_dir, result, pass_count, fail_count, skip_count, capture, reconciler, root = sys.argv[1:9]
evidence = pathlib.Path(evidence_dir)


def sha256(path):
    try:
        return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    except OSError:
        return ""


def git(*args):
    try:
        return subprocess.check_output(
            ["git", "-c", "safe.directory=*", "-C", root, *args],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return "unknown"


def status_for(value, ok_values, failed_values):
    if value in ok_values:
        return "passed"
    if value in failed_values:
        return "failed"
    return "not-performed"


reconciler_logs = b"".join(
    path.read_bytes()
    for path in sorted(evidence.glob("reconciler-*.log"))
    if path.is_file()
)
reconciler_sha = hashlib.sha256(reconciler_logs).hexdigest() if reconciler_logs else ""

payload = {
    "schemaVersion": "edgeos-vxlan.ipv6-only-qualification/v1",
    "suite": "test/ipv6-only-netns.sh",
    "commit": os.environ.get("GITHUB_SHA") or git("rev-parse", "HEAD"),
    "branch": os.environ.get("GITHUB_REF_NAME") or git("rev-parse", "--abbrev-ref", "HEAD"),
    "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "level": "B",
    "evidenceClasses": ["N6", "N6-R"],
    "result": result,
    "counts": {
        "pass": int(pass_count),
        "fail": int(fail_count),
        "skip": int(skip_count),
    },
    "checks": [
        {
            "id": "ipv6-only-isolation",
            "status": "passed" if result == "passed" else "failed",
            "evidenceSha256": sha256(evidence / "summary.txt"),
        },
        {
            "id": "ipv6-only-dataplane",
            "status": "passed" if result == "passed" else "failed",
            "evidenceSha256": sha256(evidence / "topology-after.txt"),
        },
        {
            "id": "ipv6-only-capture",
            "status": status_for(capture, {"executed"}, {"failed"}),
            "evidenceSha256": sha256(evidence / "captures" / "analysis.txt"),
        },
        {
            "id": "ipv6-only-reconciler",
            "status": status_for(reconciler, {"executed", "passed"}, {"failed"}),
            "evidenceSha256": reconciler_sha,
        },
    ],
    "capture": {
        "status": capture,
        "underlaySha256": sha256(evidence / "captures" / "underlay.pcap"),
        "overlaySha256": sha256(evidence / "captures" / "overlay.pcap"),
        "analysisSha256": sha256(evidence / "captures" / "analysis.txt"),
    },
    "reconciler": {
        "status": reconciler,
        "evidenceSha256": reconciler_sha,
    },
    "hardware": {
        "status": "not-qualified",
        "required": False,
        "evidence": [],
    },
    "limitations": [
        "N6/N6-R are general-Linux namespace evidence, not ER-X hardware evidence.",
        "The EdgeOS configuration API, firewall dispatch, bridge helper and address helper are test doubles in N6-R.",
        "The generic bridge section is not ENG-IPV6-04 hardware qualification.",
        "The host and CI runner are dual-stack; Level D is not achieved.",
        "No PMTUD/ICMPv6 Packet Too Big test across a real routed path is included.",
    ],
}
(evidence / "summary.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

main()
{
    preflight
    record_environment
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/ipv6-only-work.XXXXXX") ||
        die "cannot create work directory"

    HOST_IPV4_FORWARDING_BEFORE=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)
    HOST_IPV6_FORWARDING_BEFORE=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo unknown)
    setup_topology
    record_topology topology-before.txt
    check_isolation preflight
    test_host_escape
    test_ipv4_negative_controls
    test_underlay_and_overlay
    test_ndp
    test_tcp_udp no
    test_encapsulation_counters
    test_mtu_boundary
    test_recreation
    test_interruption_negative_control
    test_bridge_feasibility
    test_reconciler_integration
    test_packet_capture
    check_isolation runtime
    check_host_sysctls
    record_topology topology-after.txt
    write_summary
    write_json_summary

    echo "ipv6-only: pass=$PASS fail=$FAIL skip=$SKIP capture=$CAPTURE_STATUS reconciler=$RECONCILER_STATUS"
    [ "$FAIL" -eq 0 ]
}

main
