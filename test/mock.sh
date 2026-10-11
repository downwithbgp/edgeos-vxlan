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
STATE="$TMP/state"
SYS="$TMP/sys"
mkdir -p "$BIN" "$SBIN" "$CONF" "$STATE" "$SYS/class/net"

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
ifname=$4
shift 4
node=""
for a in "$@"; do node="${node:+$node.}$a"; done
key="$CONF/$ifname.$node"
case "$mode" in
    exists) [ -e "$key" ] && exit 0 || exit 1 ;;
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
chmod +x "$BIN"/* "$SBIN"/*

export IFNAME="$IF"
export CONF IPSTATE VXLAN_SYSFS_ROOT="$SYS"
export IPLOG="$TMP/log"

reset_sandbox() {
    rm -rf "$CONF" "$STATE" "$SYS"
    mkdir -p "$CONF" "$STATE" "$SYS/class/net/eth0"
    : >"$TMP/log"
    printf '%s\n' "aa:bb:cc:dd:ee:ff" >"$SYS/class/net/eth0/address"
    : >"$STATE/addrs"
    unset FAIL_ADD FAIL_DEL FAIL_ADDR
}

set_conf() { printf '%s' "$2" >"$CONF/$IF.$1"; }

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
    local action=${1:-SET}
    env PATH="$BIN:/usr/bin:/bin" \
        vyatta_sbindir="$SBIN" \
        vxlan_sysfs_root="$SYS" \
        vxlan_bin_brctl="$BIN/brctl" \
        vxlan_bin_modprobe="$BIN/modprobe" \
        IFNAME="$IF" CONF="$CONF" IPSTATE="$STATE" IPLOG="$TMP/log" VXLAN_SYSFS_ROOT="$SYS" \
        bash "$ROOT/src/vyatta-vxlan" "$action" "$IF" >"$TMP/out" 2>"$TMP/err"
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

echo "mock: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
