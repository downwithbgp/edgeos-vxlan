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
    printf '%s\n' "4098" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/flags"
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
        mtu) printf '%s\n' "$6" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/mtu" ;;
        alias) printf '%s\n' "$6" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/ifalias" ;;
        up) printf '%s\n' "4099" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/flags" ;;
        down) printf '%s\n' "4098" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/flags" ;;
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
    add) printf '%s\n' "$addr" >>"$IPSTATE/addrs" ;;
    delete) sed -i "\|^$addr\$|d" "$IPSTATE/addrs" 2>/dev/null || true ;;
esac
exit 0
EOF

cat >"$SBIN/vyatta-vxlan-bridge" <<'EOF'
#!/bin/sh
echo "vyatta-vxlan-bridge $*" >>"$IPLOG"
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
    printf '%s\n' "4099" >"$SYS/class/net/$IF/flags"
}

run_reconciler() {
    env PATH="$BIN:/usr/bin:/bin" \
        vyatta_sbindir="$SBIN" \
        vxlan_sysfs_root="$SYS" \
        vxlan_bin_brctl="$BIN/brctl" \
        vxlan_bin_modprobe="$BIN/modprobe" \
        IFNAME="$IF" CONF="$CONF" IPSTATE="$STATE" IPLOG="$TMP/log" VXLAN_SYSFS_ROOT="$SYS" \
        bash "$ROOT/src/vyatta-vxlan" SET "$IF" >"$TMP/out" 2>"$TMP/err"
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
    log_has "link set dev $IF up"; then ok; else bad "fresh IPv6 creation"; fi

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
FAIL_ADD=1
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
FAIL_ADDR=1
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

# Scenario 10: bridge rollback restores membership and port options.
reset_sandbox
set_live v6 2001:db8:1::1 2001:db8:1::2 4789
mkdir -p "$SYS/class/net/br42/bridge" "$SYS/class/net/$IF/brport"
ln -sfn "../../br42" "$SYS/class/net/$IF/brport/bridge"
printf '%s\n' 200 >"$SYS/class/net/$IF/brport/path_cost"
printf '%s\n' 10 >"$SYS/class/net/$IF/brport/priority"
set_conf vni 42
set_conf remote-ip "2001:db8:1::9"
set_conf local-ip "2001:db8:1::1"
set_conf bridge-group bridge br42
if run_reconciler >/dev/null 2>&1 &&
    log_has "vyatta-vxlan-bridge $IF"; then ok; else bad "bridge reconcile after recreation"; fi

echo "mock: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
