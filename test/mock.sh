#!/bin/bash
# Deterministic mocked reconciliation tests for src/vyatta-vxlan.
# No root, no real interfaces, no /sys access: the kernel/CLI are faked.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
IF=vxlan42

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
    [ -s "$TMP/log" ] && sed 's/^/    log: /' "$TMP/log" | tail -12
    [ -s "$TMP/err" ] && sed 's/^/    err: /' "$TMP/err" | tail -8
}

# ------------------------------------------------------------- sandbox
BIN="$TMP/bin"
SBIN="$TMP/sbin"
CONF="$TMP/conf"
EFFECTIVE="$TMP/effective"
STATE="$TMP/state"
SYS="$TMP/sys"
mkdir -p "$BIN" "$SBIN" "$CONF" "$EFFECTIVE" "$STATE" "$SYS/class/net"

cat >"$BIN/id" <<'EOF'
#!/bin/sh
case "$*" in
    "-g -n") echo vyattacfg ;;
    "-u") echo 0 ;;
    *) exec /usr/bin/id "$@" ;;
esac
EOF

cat >"$BIN/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF

cat >"$BIN/brctl" <<'EOF'
#!/bin/sh
echo "brctl $*" >>"$IPLOG"
op=$1
bridge=$2
interface=$3
case "$op" in
    addif)
        mkdir -p "$VXLAN_SYSFS_ROOT/class/net/$interface/brport"
        ln -sfn "../../$bridge" "$VXLAN_SYSFS_ROOT/class/net/$interface/brport/bridge"
        printf '%s\n' "100" >"$VXLAN_SYSFS_ROOT/class/net/$interface/brport/path_cost"
        printf '%s\n' "32" >"$VXLAN_SYSFS_ROOT/class/net/$interface/brport/priority"
        ;;
    delif)
        rm -rf "$VXLAN_SYSFS_ROOT/class/net/$interface/brport"
        ;;
    setpathcost)
        printf '%s\n' "$4" >"$VXLAN_SYSFS_ROOT/class/net/$interface/brport/path_cost"
        ;;
    setportprio)
        printf '%s\n' "$4" >"$VXLAN_SYSFS_ROOT/class/net/$interface/brport/priority"
        ;;
esac
exit 0
EOF

cat >"$BIN/modprobe" <<'EOF'
#!/bin/sh
echo "modprobe $*" >>"$IPLOG"
exit 0
EOF

cat >"$BIN/iptables" <<'EOF'
#!/bin/bash
case "$(basename "$0")" in
    ip6tables) S=${IPTSTATE6:?}; C=${CHAINS6:?} ;;
    *) S=${IPTSTATE:?}; C=${CHAINS:?} ;;
esac
echo "iptables $*" >>"$IPLOG"
if [ "$1" = "-t" ] && [ "$2" = "filter" ]; then shift 2; fi
op=$1; shift
case "$op" in
    -S)
        if [ $# -eq 0 ]; then
            # A real EdgeOS router always has the firewall hook jumps in the
            # base chains.  Synthesize them so the reachability check sees the
            # hardware shape; the negative cases use the BASE_* variables.
            [ "${FAIL_IPT_S:-0}" = "1" ] && exit 2
            if [ "${NO_BASE_HOOKS:-0}" != "1" ]; then
                [ "${BASE_SHADOW:-0}" = "1" ] &&
                    printf '%s\n' "-A FORWARD -i $IFNAME -j DROP"
                [ "${BASE_SHADOW_OTHER:-0}" = "1" ] &&
                    printf '%s\n' "-A FORWARD -i eth9 -j DROP"
                printf '%s\n' \
                    "-A INPUT -j VYATTA_FW_LOCAL_HOOK" \
                    "-A FORWARD -j VYATTA_FW_IN_HOOK" \
                    "-A FORWARD -j VYATTA_FW_OUT_HOOK"
            fi
            [ -f "$S" ] && cat "$S"
            exit 0
        fi
        grep -qxF -- "$1" "$C" 2>/dev/null || exit 1
        if [ "${EMPTY_CHAIN:-0}" = "1" ]; then exit 0; fi
        if [ "${NONTERMINAL_CHAIN:-0}" = "1" ]; then
            printf '%s\n' "-A $1 -j LOG"
            exit 0
        fi
        policy=drop
        for fam in name ipv6-name; do
            f="$CONF/firewall/$fam/$1/default-action"
            [ -f "$f" ] && policy=$(cat "$f")
        done
        case "$policy" in
            accept) target=RETURN ;;
            drop) target=DROP ;;
            reject) target=REJECT ;;
            *) target=DROP ;;
        esac
        if [ "${NONUNCONDITIONAL_CHAIN:-0}" = "1" ]; then
            printf '%s\n' "-A $1 -s 10.0.0.0/8 -m comment --comment \"$1-10 default-action $policy\" -j $target"
        elif [ "${MISMATCHED_DEFAULT:-0}" = "1" ]; then
            printf '%s\n' "-A $1 -m comment --comment \"$1-10 default-action drop\" -j DROP"
        elif [ "${TARGET_INCONSISTENT:-0}" = "1" ]; then
            printf '%s\n' "-A $1 -m comment --comment \"$1-10 default-action drop\" -j RETURN"
        else
            printf '%s\n' "-A $1 -m comment --comment \"$1-10 default-action $policy\" -j $target"
        fi
        exit 0
        ;;
    -C)
        hook=$1; flag=$2; iface=$3; j=$4; target=$5
        grep -qxF -- "-A $hook $flag $iface -j $target" "$S" 2>/dev/null
        exit $?
        ;;
    -I)
        hook=$1; shift
        [ "${1:-}" = "1" ] && shift
        flag=$1; iface=$2; j=$3; target=$4
        grep -qxF -- "$target" "$C" 2>/dev/null || echo "$target" >>"$C"
        echo "-A $hook $flag $iface -j $target" >>"$S"
        exit 0
        ;;
    -D)
        hook=$1; flag=$2; iface=$3; j=$4; target=$5
        grep -vxF -- "-A $hook $flag $iface -j $target" "$S" >"$S.tmp" || true
        mv "$S.tmp" "$S"
        exit 0
        ;;
esac
exit 2
EOF
cp "$BIN/iptables" "$BIN/ip6tables"

cat >"$BIN/ubnt-fw" <<'EOF'
#!/bin/bash
case "$1" in
    validate-fw-name) exit 0 ;;
    update-interface)
        echo "ubnt-fw $*" >>"$IPLOG"
        action=$2; iface=$3; dir=$4; chain=$5; family=$6
        case "$family" in
            ipv6-name) S=${IPTSTATE6:?}; C=${CHAINS6:?} ;;
            *) S=${IPTSTATE:?}; C=${CHAINS:?} ;;
        esac
        case "$dir" in
            in) hook=VYATTA_FW_IN_HOOK; flag=-i ;;
            out) hook=VYATTA_FW_OUT_HOOK; flag=-o ;;
            local) hook=VYATTA_FW_LOCAL_HOOK; flag=-i ;;
        esac
        if [ "$action" = "update" ] && [ "${FAIL_FW_UPDATE:-0}" = "1" ]; then
            exit 1
        fi
        if [ "$action" = "delete" ] && [ "${FAIL_FW_DELETE:-0}" = "1" ]; then
            exit 1
        fi
        if [ -n "${API_FAIL_MARKER:-}" ]; then
            : >"$API_FAIL_MARKER"
        fi
        grep -v -- "-A $hook $flag $iface " "$S" >"$S.tmp" 2>/dev/null || true
        mv "$S.tmp" "$S"
        if [ "$action" = "update" ]; then
            grep -qxF -- "$chain" "$C" 2>/dev/null || echo "$chain" >>"$C"
            echo "-A $hook $flag $iface -j $chain" >>"$S"
        fi
        exit 0
        ;;
esac
exit 0
EOF

cat >"$BIN/ip" <<'EOF'
#!/bin/bash
log() { echo "$*" >>"$IPLOG"; }
die() { log "ERROR $*"; exit 2; }

if [ "$1" = "-j" ] && [ "$2" = "-d" ] && [ "$3" = "link" ] && [ "$4" = "show" ] && [ "$5" = "dev" ]; then
    if [ ! -f "$IPSTATE/link" ]; then exit 1; fi
    id=$(cat "$IPSTATE/id")
    port=$(cat "$IPSTATE/port")
    fam=$(cat "$IPSTATE/family")
    lip=$(cat "$IPSTATE/local" 2>/dev/null || true)
    rip=$(cat "$IPSTATE/remote")
    if [ "$fam" = "v6" ]; then keys="\"remote6\":\"$rip\",\"local6\":\"$lip\""; else keys="\"remote\":\"$rip\",\"local\":\"$lip\""; fi
    printf '[{"ifindex":7,"ifname":"%s","linkinfo":{"info_kind":"vxlan","info_data":{"id":%s,%s,"port":%s}}}]\n' \
        "$IFNAME" "$id" "$keys" "$port"
    exit 0
fi

if [ "$1" = "link" ] && [ "$2" = "show" ] && [ "$3" = "dev" ]; then
    [ -f "$IPSTATE/link" ] && exit 0 || exit 1
fi

if [ "$1" = "link" ] && [ "$2" = "add" ]; then
    log "link add $*"
    if [ "${FAIL_ADD:-0}" = "1" ] && [ ! -f "$IPSTATE/failed_add" ]; then
        : >"$IPSTATE/failed_add"
        exit 2
    fi
    shift 2
    ifname=""; id=""; lip=""; rip=""; port=""
    while [ $# -gt 0 ]; do
        case "$1" in
            dev) ifname=$2; shift 2 ;;
            id) id=$2; shift 2 ;;
            local) lip=$2; shift 2 ;;
            remote) rip=$2; shift 2 ;;
            dstport) port=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    mkdir -p "$IPSTATE"
    : >"$IPSTATE/link"
    printf '%s' "$id" >"$IPSTATE/id"
    printf '%s' "$lip" >"$IPSTATE/local"
    printf '%s' "$rip" >"$IPSTATE/remote"
    printf '%s' "$port" >"$IPSTATE/port"
    fam=v4; case "$rip" in *:*) fam=v6 ;; esac
    printf '%s' "$fam" >"$IPSTATE/family"
    mkdir -p "$VXLAN_SYSFS_ROOT/class/net/$ifname"
    printf '%s\n' "00:11:22:33:44:55" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/address"
    printf '%s\n' "1500" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/mtu"
    : >"$VXLAN_SYSFS_ROOT/class/net/$ifname/ifalias"
    printf '%s\n' "0x1002" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/flags"
    exit 0
fi

if [ "$1" = "link" ] && [ "$2" = "del" ]; then
    log "link del $*"
    [ "${FAIL_DEL:-0}" = "1" ] && exit 2
    rm -f "$IPSTATE/link" "$IPSTATE/id" "$IPSTATE/local" "$IPSTATE/remote" "$IPSTATE/port" "$IPSTATE/family"
    rm -rf "${VXLAN_SYSFS_ROOT:?}/class/net/${IFNAME:?}"
    exit 0
fi

if [ "$1" = "link" ] && [ "$2" = "set" ]; then
    log "link set $*"
    ifname=$4
    case "$5" in
        address) printf '%s\n' "$6" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/address" ;;
        mtu)
            if [ "${FAIL_MTU:-0}" = "1" ] && [ ! -f "$IPSTATE/failed_mtu" ]; then
                : >"$IPSTATE/failed_mtu"
                exit 2
            fi
            printf '%s\n' "$6" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/mtu"
            ;;
        alias)
            if [ "${FAIL_ALIAS:-0}" = "1" ] && [ ! -f "$IPSTATE/failed_alias" ]; then
                : >"$IPSTATE/failed_alias"
                exit 2
            fi
            printf '%s\n' "$6" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/ifalias"
            ;;
        up)
            if [ "${FAIL_UP:-0}" = "1" ] && [ ! -f "$IPSTATE/failed_up" ]; then
                : >"$IPSTATE/failed_up"
                exit 2
            fi
            printf '%s\n' "0x1003" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/flags"
            ;;
        down)
            [ "${FAIL_DOWN:-0}" = "1" ] && exit 2
            printf '%s\n' "0x1002" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/flags"
            ;;
    esac
    exit 0
fi

if [ "$1" = "-o" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
    log "addr show $*"
    [ "${FAIL_ADDR:-0}" = "1" ] && exit 3
    n=0
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        n=$((n + 1))
        fam=inet; case "$a" in *:*) fam=inet6 ;; esac
        printf '%s: %s    %s %s scope global %s\n' "$n" "$IFNAME" "$fam" "$a" "$IFNAME"
    done <"$IPSTATE/addrs" 2>/dev/null
    exit 0
fi

log "UNSUPPORTED $*"
exit 2
EOF

cat >"$SBIN/my_cli_shell_api" <<'EOF'
#!/bin/sh
mode=$1
shift
if [ "$mode" = "existsEffective" ] &&
    [ -n "${FAIL_API_EFFECTIVE_PATTERN:-}" ] &&
    printf '%s' "$*" | grep -q -- "$FAIL_API_EFFECTIVE_PATTERN"; then
    echo "configd: session error" >&2
    exit 1
fi
if [ -n "${FAIL_API_PATTERN:-}" ] &&
    printf '%s' "$*" | grep -q -- "$FAIL_API_PATTERN"; then
    echo "configd: session error" >&2
    exit 1
fi
if [ -n "${FAIL_API_AFTER_FW:-}" ] && [ -n "${API_FAIL_MARKER:-}" ] &&
    [ -e "$API_FAIL_MARKER" ] &&
    printf '%s' "$*" | grep -q -- "$FAIL_API_AFTER_FW"; then
    match=1
    if [ -n "${API_FAIL_COUNTER:-}" ]; then
        seen=0
        [ -f "$API_FAIL_COUNTER" ] && seen=$(cat "$API_FAIL_COUNTER")
        match=$((seen + 1))
        printf '%s' "$match" >"$API_FAIL_COUNTER"
    fi
    if [ "$match" -eq "${FAIL_API_AFTER_FW_COUNT:-1}" ]; then
        echo "configd: session error" >&2
        exit 1
    fi
fi
TREE="$CONF"
[ "$mode" = "existsEffective" ] && TREE="$CONF_EFFECTIVE"
key=""
node=""
if [ "${1:-}" = "interfaces" ] && [ "${2:-}" = "vxlan" ]; then
    ifname=$3
    shift 3
    for a in "$@"; do node="${node:+$node.}$a"; done
    key="$TREE/$ifname.$node"
else
    ifname=""
    path=$(printf '%s' "$*" | tr ' ' '/')
    key="$TREE/$path"
fi
case "$mode" in
    exists|existsEffective)
        if [ -n "$ifname" ] && [ -z "$node" ]; then
            # The interface container exists when any of its leaves does.
            for f in "$TREE/$ifname".*; do
                [ -e "$f" ] && exit 0
            done
            exit 1
        fi
        [ -e "$key" ] && exit 0 || exit 1
        ;;
    returnValue) [ -e "$key" ] && cat "$key" || true; exit 0 ;;
    returnValues) [ -e "$key" ] && cat "$key" || true; exit 0 ;;
esac
exit 1
EOF

cat >"$SBIN/vyatta-address" <<'EOF'
#!/bin/sh
echo "vyatta-address $*" >>"$IPLOG"
ifname=$2
addr=$3
case "$1" in
    add)
        if [ "${FAIL_ADDR_ADD:-0}" = "1" ] && [ ! -f "$IPSTATE/failed_addr_add" ]; then
            : >"$IPSTATE/failed_addr_add"
            exit 2
        fi
        printf '%s\n' "$addr" >>"$IPSTATE/addrs"
        ;;
    delete)
        if [ "${FAIL_ADDR_DEL:-0}" = "1" ] && [ ! -f "$IPSTATE/failed_addr_del" ]; then
            : >"$IPSTATE/failed_addr_del"
            exit 2
        fi
        sed -i "\|^$addr\$|d" "$IPSTATE/addrs" 2>/dev/null || true
        ;;
esac
exit 0
EOF

cat >"$SBIN/vyatta-vxlan-bridge" <<'EOF'
#!/bin/sh
echo "vyatta-vxlan-bridge $*" >>"$IPLOG"
if [ "${FAIL_BRIDGE:-0}" = "1" ] && [ ! -f "$IPSTATE/failed_bridge" ]; then
    : >"$IPSTATE/failed_bridge"
    exit 2
fi
exit 0
EOF

cp "$ROOT/src/vyatta-vxlan-addr" "$SBIN/vyatta-vxlan-addr"
cp "$ROOT/src/vyatta-vxlan-firewall" "$SBIN/vyatta-vxlan-firewall"
chmod +x "$BIN"/* "$SBIN"/*

export IFNAME="$IF"
export CONF IPSTATE VXLAN_SYSFS_ROOT="$SYS"
export IPTSTATE="$STATE/fw4" IPTSTATE6="$STATE/fw6"
export CHAINS="$STATE/chains4" CHAINS6="$STATE/chains6"
export IPLOG="$TMP/log"

reset_sandbox() {
    rm -rf "$CONF" "$EFFECTIVE" "$STATE" "$SYS"
    mkdir -p "$CONF" "$EFFECTIVE" "$STATE" "$SYS/class/net/eth0"
    : >"$TMP/log"
    printf '%s\n' "aa:bb:cc:dd:ee:ff" >"$SYS/class/net/eth0/address"
    : >"$STATE/addrs"
    : >"$IPTSTATE"
    : >"$IPTSTATE6"
    : >"$CHAINS"
    : >"$CHAINS6"
    unset FAIL_ADD FAIL_DEL FAIL_ADDR FAIL_FW_UPDATE FAIL_FW_DELETE
    unset FAIL_DOWN FAIL_UP FAIL_API_PATTERN FAIL_IPT_S
    unset FAIL_API_AFTER_FW FAIL_API_AFTER_FW_COUNT API_FAIL_MARKER API_FAIL_COUNTER
    unset FAIL_API_EFFECTIVE_PATTERN
    unset EMPTY_CHAIN NONTERMINAL_CHAIN NONUNCONDITIONAL_CHAIN
    unset MISMATCHED_DEFAULT TARGET_INCONSISTENT
    rm -f "$TMP/api-fail" "$TMP/api-count"
    unset NO_BASE_HOOKS BASE_SHADOW BASE_SHADOW_OTHER NONTERMINAL_CHAIN
}

set_conf() { printf '%s' "$2" >"$CONF/$IF.$1"; }
set_fw_ruleset() { # set_fw_ruleset <name|ipv6-name> <ruleset>
    mkdir -p "$CONF/firewall/$1/$2"
    printf '%s' drop >"$CONF/firewall/$1/$2/default-action"
}

set_fw_default_action() { # set_fw_default_action <name|ipv6-name> <ruleset> <policy>
    printf '%s' "$3" >"$CONF/firewall/$1/$2/default-action"
}
fw_state_has() { grep -qxF -- "$1" "$IPTSTATE"; }
fw_state_lacks() { ! grep -qxF -- "$1" "$IPTSTATE"; }

set_live() { # set_live <family> <local> <remote> <port>
    : >"$STATE/link"
    printf '%s' "42" >"$STATE/id"
    printf '%s' "$3" >"$STATE/remote"
    printf '%s' "$2" >"$STATE/local"
    printf '%s' "$4" >"$STATE/port"
    printf '%s' "$1" >"$STATE/family"
    mkdir -p "$SYS/class/net/$IF"
    printf '%s\n' "00:11:22:33:44:55" >"$SYS/class/net/$IF/address"
    printf '%s\n' "1500" >"$SYS/class/net/$IF/mtu"
    : >"$SYS/class/net/$IF/ifalias"
    printf '%s\n' "0x1003" >"$SYS/class/net/$IF/flags"
}

run_reconciler() { # run_reconciler [SET|DELETE]
    local action=${1:-SET} rc=0
    env PATH="$BIN:/usr/bin:/bin" \
        vyatta_sbindir="$SBIN" \
        vxlan_sysfs_root="$SYS" \
        vxlan_bin_brctl="$BIN/brctl" \
        vxlan_bin_modprobe="$BIN/modprobe" \
        vxlan_bin_ubnt_fw="$BIN/ubnt-fw" \
        vxlan_bin_iptables="$BIN/iptables" \
        vxlan_bin_ip6tables="$BIN/ip6tables" \
        IFNAME="$IF" CONF="$CONF" CONF_EFFECTIVE="$EFFECTIVE" \
        IPSTATE="$STATE" IPLOG="$TMP/log" \
        VXLAN_SYSFS_ROOT="$SYS" IPTSTATE="$IPTSTATE" IPTSTATE6="$IPTSTATE6" \
        CHAINS="$CHAINS" CHAINS6="$CHAINS6" \
        bash "$ROOT/src/vyatta-vxlan" "$action" "$IF" >"$TMP/out" 2>"$TMP/err" ||
        rc=$?
    # A successful commit makes the working configuration effective; a failed
    # commit leaves the previously effective configuration in place.
    if [ "$rc" -eq 0 ]; then
        rm -rf "$EFFECTIVE"
        cp -a "$CONF" "$EFFECTIVE"
    fi
    return "$rc"
}

log_has() { grep -qF -- "$1" "$TMP/log"; }
log_lacks() { ! grep -qF -- "$1" "$TMP/log"; }
count() { grep -cF -- "$1" "$TMP/log" || true; }

# Scenario 1: fresh IPv6 creation applies the family default MTU 1430.
reset_sandbox
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1 &&
    log_has "link add dev $IF type vxlan id 42 local 2001:db8:1::1 remote 2001:db8:1::2 dstport 4789" &&
    log_has "link set dev $IF mtu 1430" &&
    log_has "link set dev $IF up" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then ok; else bad "fresh IPv6 creation"; fi

# Scenario 2: unchanged identity with a reformatted IPv6 spelling -> no recreation.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 42
set_conf remote-ip "2001:0db8:0001:0000:0000:0000:0000:0002"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1 &&
    log_lacks "link del" && log_lacks "link add"; then ok; else bad "reformatted IPv6 no-op"; fi

# Scenario 3: non-canonical IPv4 config matching the platform binding -> no recreation.
reset_sandbox
set_live v4 8.1.2.3 8.1.2.4 4789
set_conf vni 42
set_conf remote-ip "010.1.2.4"
set_conf local-ip "010.1.2.3"
if run_reconciler >/dev/null 2>&1 &&
    log_lacks "link del" && log_lacks "link add"; then ok; else bad "noncanonical IPv4 parity no-op"; fi

# Scenario 4: successful IPv6 -> IPv6 identity change recreates once.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 42
set_conf remote-ip "2001:db8:1::9"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1 &&
    [ "$(count 'link del')" -ge 1 ] &&
    log_has "link add dev $IF type vxlan id 42 local 2001:db8:1::1 remote 2001:db8:1::9 dstport 4789" &&
    log_has "link set dev $IF addr"; then ok; else bad "v6 identity change recreate"; fi

# Scenario 5: failed recreation rolls back the previous v4 identity.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
printf '%s\n' "198.51.100.1/24" >"$STATE/addrs"
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
if FAIL_ADD=1 run_reconciler >/dev/null 2>&1; then
    bad "failed recreation should exit non-zero"
elif log_has "link add dev $IF type vxlan id 42 local 2001:db8:1::1 remote 2001:db8:1::2 dstport 4789" &&
    log_has "link add dev $IF type vxlan id 42 local 192.0.2.1 remote 192.0.2.2 dstport 4789" &&
    log_has "vyatta-address add $IF 198.51.100.1/24"; then
    ok
else
    bad "rollback after failed v4->v6 recreation"
fi

# Scenario 6: failed v6 -> v4 transition rolls back the v6 identity.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
if FAIL_ADD=1 run_reconciler >/dev/null 2>&1; then
    bad "failed v6->v4 should exit non-zero"
elif log_has "link add dev $IF type vxlan id 42 local 2001:db8:1::1 remote 2001:db8:1::2 dstport 4789"; then
    ok
else
    bad "rollback after failed v6->v4 recreation"
fi

# Scenario 7: address-collection failure aborts before anything is deleted.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 42
set_conf remote-ip "2001:db8:1::9"
set_conf local-ip "2001:db8:1::1"
if FAIL_ADDR=1 run_reconciler >/dev/null 2>&1; then
    bad "snapshot address failure should abort"
elif log_lacks "link del" && log_lacks "link add"; then
    ok
else
    bad "snapshot failure must not delete or create"
fi

# Scenario 8: missing sysfs component aborts before anything is deleted.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
rm -f "$SYS/class/net/$IF/mtu"
set_conf vni 42
set_conf remote-ip "2001:db8:1::9"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1; then
    bad "missing sysfs component should abort"
elif log_lacks "link del" && log_lacks "link add"; then
    ok
else
    bad "incomplete snapshot must not delete or create"
fi

# Scenario 9: mixed-family desired config is rejected before any mutation.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "192.0.2.1"
if run_reconciler >/dev/null 2>&1; then
    bad "mixed family should be rejected"
elif [ ! -s "$TMP/log" ]; then
    ok
else
    bad "mixed family rejection must not touch the interface"
fi

# Scenario 10: a failed identity recreation of a bridge port rolls back the
# membership, path cost and port priority captured in the snapshot.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
mkdir -p "$SYS/class/net/br42/bridge" "$SYS/class/net/$IF/brport"
ln -sfn "../../br42" "$SYS/class/net/$IF/brport/bridge"
printf '%s\n' 200 >"$SYS/class/net/$IF/brport/path_cost"
printf '%s\n' 10 >"$SYS/class/net/$IF/brport/priority"
set_conf vni 42
set_conf remote-ip "2001:db8:1::9"
set_conf local-ip "2001:db8:1::1"
printf '%s' "br42" >"$CONF/$IF.bridge-group.bridge"
if FAIL_ADD=1 run_reconciler >/dev/null 2>&1; then
    bad "failed bridge recreation should exit non-zero"
elif grep -q "Rolling back" "$TMP/err" &&
    log_has "link add dev $IF type vxlan id 42 local 2001:db8:1::1 remote 2001:db8:1::2 dstport 4789" &&
    log_has "brctl addif br42 $IF" &&
    log_has "brctl setpathcost br42 $IF 200" &&
    log_has "brctl setportprio br42 $IF 10" &&
    [ -L "$SYS/class/net/$IF/brport/bridge" ] &&
    [ "$(basename "$(readlink "$SYS/class/net/$IF/brport/bridge")")" = "br42" ] &&
    [ "$(cat "$SYS/class/net/$IF/brport/path_cost")" = "200" ] &&
    [ "$(cat "$SYS/class/net/$IF/brport/priority")" = "10" ]; then
    ok
else
    bad "bridge rollback must restore membership, path cost and priority"
fi

# Scenario 11: hexadecimal sysfs flags — an idempotent commit on an up
# interface must not toggle it (UP bit read from 0x1003).
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1 &&
    log_lacks "link set dev $IF up" && log_lacks "link set dev $IF down" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then ok; else bad "hex flags: idempotent up interface"; fi

# Scenario 12: hexadecimal sysfs flags — a down interface without `disable`
# is brought up (DOWN bit read from 0x1002).
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
printf '%s\n' "0x1002" >"$SYS/class/net/$IF/flags"
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1 &&
    log_has "link set dev $IF up" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then ok; else bad "hex flags: down interface is brought up"; fi

# Scenario 13: hexadecimal sysfs flags — `disable` takes an up interface down.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
set_conf disable 1
if run_reconciler >/dev/null 2>&1 &&
    log_has "link set dev $IF down" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ]; then ok; else bad "hex flags: disable takes the interface down"; fi

# Scenario 14: malformed sysfs flags are refused before anything is deleted.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
printf '%s\n' "0x100Z" >"$SYS/class/net/$IF/flags"
set_conf vni 42
set_conf remote-ip "2001:db8:1::9"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1; then
    bad "malformed flags should abort the commit"
elif log_lacks "link del" && log_lacks "link add" &&
    grep -q "unexpected administrative state '0x100Z'" "$TMP/err"; then
    ok
else
    bad "malformed flags must not delete or create"
fi

# Scenario 15: a failed deletion of an up interface fails the commit, leaves
# the old interface in place and restores its administrative state.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
FAIL_DEL=1 run_reconciler >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] &&
    log_has "link del" && log_lacks "link add" &&
    grep -q "failed to delete $IF" "$TMP/err" &&
    grep -q "Restoring $IF to the up state" "$TMP/err" &&
    [ -f "$SYS/class/net/$IF/flags" ] &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "failed deletion must keep the up interface and restore its state (rc=$rc)"
fi

# Scenario 16: a failed deletion of a down interface leaves it down.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
printf '%s\n' "0x1002" >"$SYS/class/net/$IF/flags"
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
FAIL_DEL=1 run_reconciler >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] &&
    log_has "link del" && log_lacks "link add" &&
    ! grep -q "Restoring $IF to the up state" "$TMP/err" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ]; then
    ok
else
    bad "failed deletion of a down interface must leave it down (rc=$rc)"
fi

# Scenario 17: a failure of the administrative-down step aborts the deletion
# without touching the interface.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
FAIL_DOWN=1 run_reconciler >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] &&
    log_lacks "link del" && log_lacks "link add" &&
    grep -q "failed to set $IF down before deletion" "$TMP/err" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "failed administrative-down must abort the deletion (rc=$rc)"
fi

# Scenario 18: a bridge-port directory without a readable bridge link makes
# the snapshot incomplete, so the commit is refused before anything happens.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
mkdir -p "$SYS/class/net/$IF/brport"
set_conf vni 42
set_conf remote-ip "2001:db8:1::9"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1; then
    bad "unreadable bridge state should refuse the commit"
elif log_lacks "link del" && log_lacks "link add" &&
    grep -q "cannot determine bridge membership of $IF" "$TMP/err"; then
    ok
else
    bad "unreadable bridge state must refuse without deleting"
fi

# Scenario 19: a leading-zero VNI spelling must compare numerically, so an
# unchanged identity is not recreated.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 042
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1 &&
    log_lacks "link del" && log_lacks "link add"; then ok; else bad "numeric VNI normalisation"; fi

# Scenario 20: a non-numeric VNI is refused before any mutation.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
set_conf vni 4x2
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1; then
    bad "non-numeric VNI should be refused"
elif log_lacks "link del" && log_lacks "link add" &&
    grep -q "is not a numeric VNI" "$TMP/err"; then
    ok
else
    bad "non-numeric VNI must be refused without mutation"
fi

# Scenario 21: an unparseable live address keeps the offending value in the
# diagnostic (the value used to be lost by the canonicalisation assignment).
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
printf 'not-an-address/24\n' >"$STATE/addrs"
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
if run_reconciler >/dev/null 2>&1; then
    bad "unparseable live address should fail the commit"
elif grep -q "cannot normalise live address 'not-an-address/24'" "$TMP/err" &&
    log_lacks "link del" && log_lacks "link add"; then
    ok
else
    bad "unparseable live address diagnostic must name the value"
fi

# ---------------------------------------------------------------------------
# Per-step failure injection.
#
# Scenarios 22-24 pin the *pre-existing* documented semantics of commits that
# do not change the identity: the commit fails, the interface is not deleted,
# there is no rollback, and mutable state already applied before the failure
# stays applied (IM-3 / acceptance matrix row 32).  These are not IPv6-specific
# regressions and are asserted here so the IPv6 work cannot alter them.
# Scenarios 25-28 pin the recreation contract: a failed apply after recreation
# restores the snapshot.
# ---------------------------------------------------------------------------

# Scenario 22: mutable-only commit, MTU application fails.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_conf mtu 1400
if FAIL_MTU=1 run_reconciler >/dev/null 2>&1; then
    bad "failing MTU application should fail the commit"
elif log_lacks "link del" && log_lacks "link add" &&
    ! grep -q "Rolling back" "$TMP/err" &&
    [ "$(cat "$SYS/class/net/$IF/mtu")" = "1500" ]; then
    ok
else
    bad "mutable-only MTU failure must not delete the interface"
fi

# Scenario 23: mutable-only commit, address add fails after a delete.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
printf '198.51.100.1/24\n' >"$STATE/addrs"
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
printf '203.0.113.9/24\n' >"$CONF/$IF.address"
if FAIL_ADDR_ADD=1 run_reconciler >/dev/null 2>&1; then
    bad "failing address add should fail the commit"
elif log_has "vyatta-address delete $IF 198.51.100.1/24" &&
    log_lacks "link del" && log_lacks "link add" &&
    ! grep -q "Rolling back" "$TMP/err" &&
    ! grep -q "^198.51.100.1/24$" "$STATE/addrs"; then
    ok
else
    bad "mutable-only address failure semantics"
fi

# Scenario 24: mutable-only commit, address delete fails.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
printf '198.51.100.1/24\n' >"$STATE/addrs"
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
if FAIL_ADDR_DEL=1 run_reconciler >/dev/null 2>&1; then
    bad "failing address delete should fail the commit"
elif log_has "vyatta-address delete $IF 198.51.100.1/24" &&
    log_lacks "link del" && log_lacks "link add" &&
    grep -q "^198.51.100.1/24$" "$STATE/addrs"; then
    ok
else
    bad "mutable-only address-delete failure semantics"
fi

# Scenario 25: recreation with a failing MTU step rolls back the snapshot.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
printf '1400\n' >"$SYS/class/net/$IF/mtu"
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
set_conf mtu 1400
if FAIL_MTU=1 run_reconciler >/dev/null 2>&1; then
    bad "failing MTU during recreation should fail the commit"
elif grep -q "Rolling back" "$TMP/err" &&
    log_has "link add dev $IF type vxlan id 42 local 192.0.2.1 remote 192.0.2.2 dstport 4789" &&
    [ "$(cat "$SYS/class/net/$IF/mtu")" = "1400" ]; then
    ok
else
    bad "recreation MTU failure must roll back the snapshot"
fi

# Scenario 26: recreation with a failing description step rolls back.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
printf 'old-desc\n' >"$SYS/class/net/$IF/ifalias"
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
set_conf description "new-desc"
if FAIL_ALIAS=1 run_reconciler >/dev/null 2>&1; then
    bad "failing alias application during recreation should fail the commit"
elif grep -q "Rolling back" "$TMP/err" &&
    [ "$(cat "$SYS/class/net/$IF/ifalias")" = "old-desc" ]; then
    ok
else
    bad "recreation alias failure must roll back the description"
fi

# Scenario 27: recreation with a failing bridge step rolls back the identity.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
mkdir -p "$SYS/class/net/br42/bridge"
set_conf vni 42
set_conf remote-ip "2001:db8:1::9"
set_conf local-ip "2001:db8:1::1"
printf '%s' "br42" >"$CONF/$IF.bridge-group.bridge"
if FAIL_BRIDGE=1 run_reconciler >/dev/null 2>&1; then
    bad "failing bridge reconcile during recreation should fail the commit"
elif grep -q "Rolling back" "$TMP/err" &&
    log_has "link add dev $IF type vxlan id 42 local 2001:db8:1::1 remote 2001:db8:1::2 dstport 4789"; then
    ok
else
    bad "recreation bridge failure must roll back the previous identity"
fi

# Scenario 28: recreation with a failing administrative-up step rolls back.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "2001:db8:1::2"
set_conf local-ip "2001:db8:1::1"
if FAIL_UP=1 run_reconciler >/dev/null 2>&1; then
    bad "failing administrative-up during recreation should fail the commit"
elif grep -q "Rolling back" "$TMP/err" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "recreation admin-state failure must roll back to up"
fi

# ---------------------------------------------------------------------------
# DELETE action and numeric-range coverage.
# ---------------------------------------------------------------------------

# Scenario 29: DELETE removes the interface (down, then delete).
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
if run_reconciler DELETE >/dev/null 2>&1 &&
    log_has "link set dev $IF down" &&
    log_has "link del" &&
    [ ! -e "$SYS/class/net/$IF/flags" ]; then
    ok
else
    bad "DELETE action must remove the interface"
fi

# Scenario 30: a failed DELETE restores the administrative state.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
FAIL_DEL=1 run_reconciler DELETE >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] &&
    [ -f "$SYS/class/net/$IF/flags" ] &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "failed DELETE must restore the up state (rc=$rc)"
fi

# Scenario 31: DELETE on an absent interface is a no-op.
reset_sandbox
if run_reconciler DELETE >/dev/null 2>&1 &&
    log_lacks "link del"; then ok; else bad "DELETE on absent interface"; fi

# Scenario 32: DELETE with unreadable flags refuses without touching the device.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
printf 'garbage\n' >"$SYS/class/net/$IF/flags"
if run_reconciler DELETE >/dev/null 2>&1; then
    bad "DELETE with unreadable flags should refuse"
elif log_lacks "link del" &&
    grep -q "refusing to delete $IF" "$TMP/err" &&
    [ -f "$SYS/class/net/$IF/flags" ]; then
    ok
else
    bad "DELETE refusal on unreadable flags"
fi

# Scenario 33: an out-of-range VNI is refused before any mutation.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 99999999
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
if run_reconciler >/dev/null 2>&1; then
    bad "out-of-range VNI should be refused"
elif log_lacks "link del" && log_lacks "link add" &&
    grep -q "outside 1-16777215" "$TMP/err"; then
    ok
else
    bad "out-of-range VNI must be refused without mutation"
fi

# Scenario 34: an out-of-range port is refused before any mutation.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_conf port 70000
if run_reconciler >/dev/null 2>&1; then
    bad "out-of-range port should be refused"
elif log_lacks "link del" && log_lacks "link add" &&
    grep -q "outside 1-65535" "$TMP/err"; then
    ok
else
    bad "out-of-range port must be refused without mutation"
fi

# Scenario 35: a non-canonical overlay-address spelling is a no-op (the
# reconciler canonicalises the literal part before comparing).
reset_sandbox
set_live v4 8.1.2.3 8.1.2.4 4789
printf '8.1.2.3/24\n' >"$STATE/addrs"
set_conf vni 42
set_conf remote-ip "010.1.2.4"
set_conf local-ip "010.1.2.3"
set_conf address "010.1.2.3/24"
if run_reconciler >/dev/null 2>&1 &&
    log_lacks "link del" && log_lacks "link add" && log_lacks "vyatta-address"; then
    ok
else
    bad "canonical address comparison must not re-add the address"
fi

# Scenario 36: a prefix-only change is still detected through the canonical
# comparison (delete the old prefix, add the new one).
reset_sandbox
set_live v4 8.1.2.3 8.1.2.4 4789
printf '8.1.2.3/24\n' >"$STATE/addrs"
set_conf vni 42
set_conf remote-ip "010.1.2.4"
set_conf local-ip "010.1.2.3"
set_conf address "010.1.2.3/25"
if run_reconciler >/dev/null 2>&1 &&
    log_has "vyatta-address delete $IF 8.1.2.3/24" &&
    log_has "vyatta-address add $IF 8.1.2.3/25"; then
    ok
else
    bad "prefix-only change must be applied"
fi

# ---------------------------------------------------------------------------
# Native firewall attachment lifecycle.
# ---------------------------------------------------------------------------

# Scenario 37: fresh creation with an attachment installs the dispatch before
# the interface is brought up.
reset_sandbox
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
if run_reconciler >/dev/null 2>&1 &&
    log_has "ubnt-fw update-interface update $IF in VXLAN_IN name" &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    log_has "link set dev $IF up"; then ok; else bad "fresh creation with firewall attachment"; fi

# Scenario 38: a failed new attachment on a fresh interface never creates the
# interface and installs no dispatch.
reset_sandbox
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
if FAIL_FW_UPDATE=1 run_reconciler >/dev/null 2>&1; then
    bad "failed fresh attachment should fail the commit"
elif log_lacks "link add dev $IF" &&
    fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    grep -q "Failed to apply firewall attachments" "$TMP/err"; then
    ok
else
    bad "failed fresh attachment must not create an unprotected interface"
fi

# Scenario 39: adding an attachment to an already-up interface fails closed:
# the interface is taken down and no dispatch is installed.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
if FAIL_FW_UPDATE=1 run_reconciler >/dev/null 2>&1; then
    bad "failed attachment on an up interface should fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ] &&
    log_lacks "link del" && log_lacks "link add" &&
    fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    grep -q "left administratively down" "$TMP/err"; then
    ok
else
    bad "failed attachment on an up interface must take it down"
fi

# Scenario 40: an attachment-only commit installs the dispatch without any
# netdevice recreation, and removing it takes only the dispatch away.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
if run_reconciler >/dev/null 2>&1 &&
    log_lacks "link del" && log_lacks "link add" &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "attachment-only commit must not recreate the interface"
fi
rm -f "$CONF/$IF.firewall.in.name"
if run_reconciler >/dev/null 2>&1 &&
    log_lacks "link del" && log_lacks "link add" &&
    fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "attachment removal must leave the interface up without the dispatch"
fi

# Scenario 41: identity recreation keeps the dispatch (iptables matches the
# name, not an index) and does not call ubnt-fw unnecessarily.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
: >"$TMP/log"
set_conf vni 43
if run_reconciler >/dev/null 2>&1 &&
    log_has "link del dev $IF" &&
    log_has "link add dev $IF type vxlan id 43" &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    log_lacks "ubnt-fw update-interface"; then
    ok
else
    bad "identity recreation must preserve and not reinstall the dispatch"
fi

# Scenario 42: a failed recreation restores the previous firewall dispatch.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_ruleset name VXLAN_IN2
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
set_conf vni 43
set_conf firewall.in.name VXLAN_IN2
if FAIL_ADD=1 run_reconciler >/dev/null 2>&1; then
    bad "failed recreation with a new attachment should fail"
elif grep -q "Rolling back" "$TMP/err" &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN2" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "failed recreation must restore the previous firewall dispatch"
fi

# Scenario 43: DELETE removes the dispatch only after the netdevice is gone.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
if run_reconciler DELETE >/dev/null 2>&1 &&
    log_has "link del dev $IF" &&
    log_has "ubnt-fw update-interface delete $IF in VXLAN_IN name" &&
    log_lacks "link add"; then ok; else bad "DELETE must remove the dispatch after the interface"; fi

# Scenario 44: a failed DELETE keeps the interface and its dispatch intact.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
if FAIL_DEL=1 run_reconciler DELETE >/dev/null 2>&1; then
    bad "failed DELETE should fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN"; then
    ok
else
    bad "failed DELETE must leave the interface protected"
fi

# Scenario 45: an interface without attachments does not call ubnt-fw at all.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
if run_reconciler >/dev/null 2>&1 &&
    log_lacks "ubnt-fw" &&
    log_lacks "link del" && log_lacks "link add"; then ok; else bad "no-attachment commit must not touch firewall state"; fi


# Scenario 46: removing `disable` is handled by the parent reconciler after
# the firewall gate; there is no child delete action that could bring the
# interface up early.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_conf disable 1
run_reconciler >/dev/null 2>&1
rm -f "$CONF/$IF.disable"
if run_reconciler >/dev/null 2>&1 &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "removing disable must bring the interface up through the parent reconciler"
fi

# ---------------------------------------------------------------------------
# RC2 review-fix regression scenarios.
# ---------------------------------------------------------------------------

# Scenario 47: an ambiguous live dispatch is a fail-closed condition when an
# attachment is configured: the commit fails and the interface is taken down.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_ruleset name VXLAN_IN2
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN2" >>"$IPTSTATE"
if run_reconciler >/dev/null 2>&1; then
    bad "ambiguous dispatch with an attachment must fail the commit"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ] &&
    grep -q "ambiguous firewall dispatch" "$TMP/err"; then
    ok
else
    bad "ambiguous dispatch with an attachment must take the interface down"
fi

# Scenario 48: the same ambiguous state on an intentionally unfiltered interface
# fails the commit without disrupting the interface.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i $IF -j A" "-A VYATTA_FW_IN_HOOK -i $IF -j B" >"$IPTSTATE"
if run_reconciler >/dev/null 2>&1; then
    bad "ambiguous dispatch without an attachment must fail the commit"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    grep -q "neither the candidate nor the previous configuration" "$TMP/err"; then
    ok
else
    bad "ambiguous dispatch without an attachment must not disrupt the interface"
fi

# Scenario 49: an unreadable filter table is fail-closed when the candidate or
# the previous configuration requires enforcement.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
if FAIL_IPT_S=1 run_reconciler >/dev/null 2>&1; then
    bad "unreadable table with an attachment must fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ]; then
    ok
else
    bad "unreadable table with an attachment must take the interface down"
fi

reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
if FAIL_IPT_S=1 run_reconciler >/dev/null 2>&1; then
    bad "unreadable table without an attachment must fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "unreadable table without an attachment must not disrupt the interface"
fi

# Scenario 49a: a candidate that removes the final attachment does not make
# the interface intentionally unfiltered.  The previous (effective)
# configuration still requires enforcement, so a failed capture is fail-closed.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
rm -f "$CONF/$IF.firewall.in.name"
if FAIL_IPT_S=1 run_reconciler >/dev/null 2>&1; then
    bad "capture failure with a previous attachment must fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    grep -q "previous configuration requires an attachment" "$TMP/err"; then
    ok
else
    bad "capture failure must honour the previous enforcement"
fi

# Scenario 49b: with no candidate or previous attachment, a capture failure
# leaves an intentionally unfiltered interface unchanged.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
run_reconciler >/dev/null 2>&1
if FAIL_IPT_S=1 run_reconciler >/dev/null 2>&1; then
    bad "capture failure without any attachment must fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    grep -q "neither the candidate nor the previous configuration" "$TMP/err"; then
    ok
else
    bad "capture failure without enforcement must leave the interface unchanged"
fi

# Scenario 49c: an unreadable previous configuration is not treated as "no
# enforcement": a capture failure is fail-closed.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
run_reconciler >/dev/null 2>&1
if FAIL_IPT_S=1 \
    FAIL_API_EFFECTIVE_PATTERN='interfaces vxlan vxlan42 firewall' \
    run_reconciler >/dev/null 2>&1; then
    bad "capture failure with an unreadable previous configuration must fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ] &&
    grep -q "previous configuration could not be read" "$TMP/err"; then
    ok
else
    bad "an unreadable previous configuration must be fail-closed"
fi

# Scenario 50: a failure to capture unrelated mutable interface state aborts
# without touching the interface.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
if FAIL_ADDR=1 run_reconciler >/dev/null 2>&1; then
    bad "mutable capture failure must fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    grep -q "live state could not be captured" "$TMP/err"; then
    ok
else
    bad "mutable capture failure must leave the interface untouched"
fi

# Scenario 51: a removal quiesces the interface before the dispatch is removed
# and the reconciler reactivates it only after the commit's gate.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
: >"$TMP/log"
rm -f "$CONF/$IF.firewall.in.name"
if run_reconciler >/dev/null 2>&1 &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN"; then
    down_line=$(grep -n "link set dev $IF down" "$TMP/log" | head -1 | cut -d: -f1)
    del_line=$(grep -n "ubnt-fw update-interface delete $IF in VXLAN_IN name" "$TMP/log" | head -1 | cut -d: -f1)
    up_line=$(grep -n "link set dev $IF up" "$TMP/log" | head -1 | cut -d: -f1)
    if [ -n "$down_line" ] && [ -n "$del_line" ] && [ -n "$up_line" ] &&
        [ "$down_line" -lt "$del_line" ] && [ "$del_line" -lt "$up_line" ]; then
        ok
    else
        bad "removal must quiesce before the delete and activate after it"
    fi
else
    bad "removal with quiesce must leave the interface up without the dispatch"
fi

# Scenario 52: a failed removal restores the previous dispatch and reactivates.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
rm -f "$CONF/$IF.firewall.in.name"
if FAIL_FW_DELETE=1 run_reconciler >/dev/null 2>&1; then
    bad "failed removal must fail the commit"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN"; then
    ok
else
    bad "failed removal must restore the dispatch and reactivate"
fi

# Scenario 53: a recreation whose netdevice deletion fails restores the old
# dispatch and the old administrative state.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_ruleset name VXLAN_IN2
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
set_conf vni 43
set_conf firewall.in.name VXLAN_IN2
if FAIL_DEL=1 run_reconciler >/dev/null 2>&1; then
    bad "failed recreation deletion must fail"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN2" &&
    grep -q "failed to delete" "$TMP/err"; then
    ok
else
    bad "failed recreation deletion must restore the old dispatch and state"
fi

# Scenario 54: a failed administrative-down before recreation also restores the
# old dispatch and leaves the interface up.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
set_conf vni 43
if FAIL_DOWN=1 run_reconciler >/dev/null 2>&1; then
    bad "failed administrative down must fail the recreation"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN"; then
    ok
else
    bad "failed administrative down must leave the old state intact"
fi

# Scenario 55: a configuration API failure is not read as "no attachment": the
# commit fails and the existing dispatch is kept.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
if FAIL_API_PATTERN=firewall run_reconciler >/dev/null 2>&1; then
    bad "configuration API failure must fail the commit"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    grep -q "configuration API failure" "$TMP/err"; then
    ok
else
    bad "configuration API failure must keep the existing dispatch"
fi

# Scenario 56: a configured attachment that is unreachable from the base chain
# fails the gate and the interface is taken down.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
if BASE_SHADOW=1 run_reconciler >/dev/null 2>&1; then
    bad "shadowed hook must fail the commit"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ] &&
    grep -q "shadowed" "$TMP/err"; then
    ok
else
    bad "shadowed hook must take the interface down"
fi

# Scenario 56a: the gate accepts the vendor's unconditional default-action
# rule when its verdict matches the configured action.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_default_action name VXLAN_IN accept
set_conf firewall.in.name VXLAN_IN
if run_reconciler >/dev/null 2>&1 &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN"; then
    ok
else
    bad "matching accept default must pass the gate"
fi

# Scenario 56b: a terminal verdict that does not match the configured action
# fails the gate and leaves the interface down.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_default_action name VXLAN_IN accept
set_conf firewall.in.name VXLAN_IN
if MISMATCHED_DEFAULT=1 run_reconciler >/dev/null 2>&1; then
    bad "default-action mismatch must fail the commit"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ] &&
    grep -q "configured" "$TMP/err"; then
    ok
else
    bad "default-action mismatch must fail closed"
fi

# Scenario 56c: the terminal rule must be unconditional (the comment is its
# only match), not merely carry a terminal verdict.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
if NONUNCONDITIONAL_CHAIN=1 run_reconciler >/dev/null 2>&1; then
    bad "conditional terminal rule must fail the commit"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ] &&
    grep -q "unconditional" "$TMP/err"; then
    ok
else
    bad "conditional terminal rule must fail closed"
fi

# Scenario 56d: the verdict must correspond to the rule's own default-action
# comment.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_conf firewall.in.name VXLAN_IN
if TARGET_INCONSISTENT=1 run_reconciler >/dev/null 2>&1; then
    bad "inconsistent terminal verdict must fail the commit"
elif [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ] &&
    grep -q "does not correspond" "$TMP/err"; then
    ok
else
    bad "inconsistent terminal verdict must fail closed"
fi

# Scenario 57: a multi-attachment change is quiesced around the whole apply; a
# single replacement remains nondisruptive.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_ruleset name VXLAN_IN2
set_fw_ruleset ipv6-name VXLAN6_IN
set_fw_ruleset ipv6-name VXLAN6_IN2
set_conf firewall.in.name VXLAN_IN
set_conf firewall.local.ipv6-name VXLAN6_IN
run_reconciler >/dev/null 2>&1
: >"$TMP/log"
set_conf firewall.in.name VXLAN_IN2
set_conf firewall.local.ipv6-name VXLAN6_IN2
if run_reconciler >/dev/null 2>&1 &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN2" &&
    grep -qxF -- "-A VYATTA_FW_LOCAL_HOOK -i $IF -j VXLAN6_IN2" "$IPTSTATE6"; then
    down_line=$(grep -n "link set dev $IF down" "$TMP/log" | head -1 | cut -d: -f1)
    first_update=$(grep -n "ubnt-fw update-interface update" "$TMP/log" | head -1 | cut -d: -f1)
    up_line=$(grep -n "link set dev $IF up" "$TMP/log" | head -1 | cut -d: -f1)
    if [ -n "$down_line" ] && [ -n "$first_update" ] && [ -n "$up_line" ] &&
        [ "$down_line" -lt "$first_update" ] && [ "$first_update" -lt "$up_line" ]; then
        ok
    else
        bad "multi-attachment change must quiesce around the whole apply"
    fi
else
    bad "multi-attachment change must succeed and end up"
fi

# Scenario 58: a single replacement stays nondisruptive (no link down).
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_ruleset name VXLAN_IN2
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
: >"$TMP/log"
set_conf firewall.in.name VXLAN_IN2
if run_reconciler >/dev/null 2>&1 &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN2" &&
    log_lacks "link set dev $IF down"; then
    ok
else
    bad "single replacement must not quiesce"
fi

# Scenario 59: a configuration-API diagnostic during desired mutable-state
# application is recovered by the reconciler exit trap: the pre-commit dispatch
# is restored and the interface returns to its previous administrative state.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_ruleset name VXLAN_IN2
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
set_conf firewall.in.name VXLAN_IN2
if API_FAIL_MARKER="$TMP/api-fail" \
    FAIL_API_AFTER_FW='interfaces vxlan vxlan42 disable' \
    run_reconciler >/dev/null 2>&1; then
    bad "API diagnostic during mutable state must fail the commit"
elif grep -q "unexpected exit after the firewall change" "$TMP/err" &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN2" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ]; then
    ok
else
    bad "API diagnostic during mutable state must restore the pre-commit state"
fi

# Scenario 60: a configuration-API diagnostic during the final attachment
# verification is a fail-closed gate: the pre-commit dispatch is restored and
# the interface is left down.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_ruleset name VXLAN_IN2
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
set_conf firewall.in.name VXLAN_IN2
if API_FAIL_MARKER="$TMP/api-fail" API_FAIL_COUNTER="$TMP/api-count" \
    FAIL_API_AFTER_FW='firewall name VXLAN_IN2$' FAIL_API_AFTER_FW_COUNT=2 \
    run_reconciler >/dev/null 2>&1; then
    bad "API diagnostic during final verification must fail the commit"
else
    rc=$?
    if [ "$rc" -eq 3 ] &&
        fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
        fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN2" &&
        [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1002" ]; then
        ok
    else
        bad "final verification API diagnostic must fail closed (rc=$rc)"
    fi
fi

# Scenario 61: an API diagnostic during a recreation's mutable state runs the
# rollback path from the exit trap, restoring the previous identity, dispatch
# and administrative state.
reset_sandbox
set_live v4 192.0.2.1 192.0.2.2 4789
set_conf vni 42
set_conf remote-ip "192.0.2.2"
set_conf local-ip "192.0.2.1"
set_fw_ruleset name VXLAN_IN
set_fw_ruleset name VXLAN_IN2
set_conf firewall.in.name VXLAN_IN
run_reconciler >/dev/null 2>&1
set_conf remote-ip "192.0.2.3"
set_conf firewall.in.name VXLAN_IN2
if API_FAIL_MARKER="$TMP/api-fail" \
    FAIL_API_AFTER_FW='interfaces vxlan vxlan42 disable' \
    run_reconciler >/dev/null 2>&1; then
    bad "API diagnostic during recreation must fail the commit"
elif grep -q "Rolling back" "$TMP/err" &&
    fw_state_has "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN" &&
    fw_state_lacks "-A VYATTA_FW_IN_HOOK -i $IF -j VXLAN_IN2" &&
    [ "$(cat "$SYS/class/net/$IF/flags")" = "0x1003" ] &&
    log_has "link add dev $IF type vxlan id 42 local 192.0.2.1 remote 192.0.2.2 dstport 4789"; then
    ok
else
    bad "recreation API diagnostic must restore the previous live state"
fi

echo "mock: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
