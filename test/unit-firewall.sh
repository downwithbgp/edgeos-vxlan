#!/bin/bash
# shellcheck disable=SC2015
# Unit tests for src/vyatta-vxlan-firewall (no root, no real iptables).
#
# The helper's only job is the per-interface dispatch in the Vyatta hook
# chains.  These tests pin:
#   - reference/bridge/name validation before any mutation,
#   - idempotent attach/replace/remove,
#   - effective-attachment verification (not just command success),
#   - fail-closed behaviour when a new attachment cannot be established,
#   - rollback of the pre-commit dispatch,
#   - isolation between interfaces and unrelated rules.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
H="$ROOT/src/vyatta-vxlan-firewall"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
    [ -s "$TMP/out" ] && sed 's/^/    out: /' "$TMP/out" | tail -8
    [ -s "$TMP/err" ] && sed 's/^/    err: /' "$TMP/err" | tail -8
}

ck() { # ck <desc> <expected_rc> <cmd...>
    local desc=$1 want=$2
    shift 2
    "$@" >"$TMP/out" 2>"$TMP/err"
    local rc=$?
    if [ "$rc" -eq "$want" ]; then ok; else bad "$desc (rc=$rc want=$want)"; fi
}

# ------------------------------------------------------------- sandbox
BIN="$TMP/bin"
SBIN="$TMP/sbin"
CONF="$TMP/conf"
STATE="$TMP/state"
SYS="$TMP/sys"
mkdir -p "$BIN" "$SBIN" "$CONF" "$STATE" "$SYS/class/net/vxlan42" "$SYS/class/net/vxlan43"

cat >"$BIN/id" <<'EOF'
#!/bin/sh
case "$*" in
    "-g -n") echo vyattacfg ;;
    *) exec /usr/bin/id "$@" ;;
esac
EOF

cat >"$BIN/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF

cat >"$BIN/ip" <<'EOF'
#!/bin/sh
if [ "$1" = "link" ] && [ "$2" = "set" ] && [ "$3" = "dev" ]; then
    ifname=$4
    case "$5" in
        down)
            [ "${FAIL_DOWN:-0}" = "1" ] && exit 2
            printf '%s\n' "0x1002" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/flags"
            ;;
        up)
            [ "${FAIL_UP:-0}" = "1" ] && exit 2
            printf '%s\n' "0x1003" >"$VXLAN_SYSFS_ROOT/class/net/$ifname/flags"
            ;;
    esac
    exit 0
fi
exit 0
EOF

cat >"$BIN/iptables" <<'EOF'
#!/bin/bash
case "$(basename "$0")" in
    ip6tables) S=${IPTSTATE6:?}; C=${CHAINS6:?} ;;
    *) S=${IPTSTATE:?}; C=${CHAINS:?} ;;
esac
if [ "$1" = "-t" ] && [ "$2" = "filter" ]; then shift 2; fi
op=$1; shift
case "$op" in
    -S)
        if [ $# -eq 0 ]; then
            # A real EdgeOS router always has the firewall hook jumps in the
            # base chains.  Synthesize them so the reachability check has the
            # shape it sees on hardware; the negative cases are controlled by
            # the BASE_* variables.
            [ "${FAIL_IPT_S:-0}" = "1" ] && exit 2
            if [ "${NO_BASE_HOOKS:-0}" != "1" ]; then
                [ "${BASE_SHADOW:-0}" = "1" ] &&
                    printf '%s\n' "-A FORWARD -i vxlan42 -j DROP"
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
        printf '%s\n' "-A $1 -m comment --comment synthetic-default -j RETURN"
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

cat >"$SBIN/my_cli_shell_api" <<'EOF'
#!/bin/sh
op=$1
shift
if [ -n "${FAIL_API_PATTERN:-}" ] &&
    printf '%s' "$*" | grep -q -- "$FAIL_API_PATTERN"; then
    echo "configd: session error" >&2
    exit 1
fi
if [ -n "${FAIL_API_AFTER_FW:-}" ] && [ -n "${API_FAIL_MARKER:-}" ] &&
    [ -e "$API_FAIL_MARKER" ] &&
    printf '%s' "$*" | grep -q -- "$FAIL_API_AFTER_FW"; then
    echo "configd: session error" >&2
    exit 1
fi
key=$(printf '%s' "$*" | tr ' ' '/')
path="$CONF/$key"
case "$op" in
    exists)
        [ -e "$path" ] && exit 0 || exit 1
        ;;
    returnValue|returnValues)
        if [ -d "$path" ] && [ -f "$path/node.val" ]; then
            cat "$path/node.val"
        elif [ -f "$path" ]; then
            cat "$path"
        fi
        exit 0
        ;;
esac
exit 1
EOF

chmod +x "$BIN"/* "$SBIN"/*

export PATH="$BIN:$PATH"
export vyatta_sbindir="$SBIN"
export vxlan_bin_ubnt_fw="$BIN/ubnt-fw"
export vxlan_bin_iptables="$BIN/iptables"
export vxlan_bin_ip6tables="$BIN/ip6tables"
export vxlan_sysfs_root="$SYS"
export VXLAN_SYSFS_ROOT="$SYS"
export CONF IPTSTATE="$STATE/fw4" IPTSTATE6="$STATE/fw6"
export CHAINS="$STATE/chains4" CHAINS6="$STATE/chains6"

reset_case() {
    rm -rf "$CONF" "$STATE" "$SYS"
    mkdir -p "$CONF" "$STATE" "$SYS/class/net/vxlan42" "$SYS/class/net/vxlan43"
    : >"$IPTSTATE"
    : >"$IPTSTATE6"
    : >"$CHAINS"
    : >"$CHAINS6"
    printf '%s\n' "0x1003" >"$SYS/class/net/vxlan42/flags"
    printf '%s\n' "0x1003" >"$SYS/class/net/vxlan43/flags"
    unset FAIL_FW_UPDATE FAIL_FW_DELETE FAIL_API_PATTERN FAIL_API_AFTER_FW
    unset API_FAIL_MARKER
    rm -f "$TMP/api-fail"
}

set_conf() { # set_conf <path> <value>
    local path=$1 value=$2 dir
    dir=$(dirname "$CONF/$path")
    mkdir -p "$dir"
    printf '%s' "$value" >"$CONF/$path"
}

set_iface() { # set_iface <iface>
    mkdir -p "$CONF/interfaces/vxlan/$1"
}

set_ruleset() { # set_ruleset <name|ipv6-name> <name>
    mkdir -p "$CONF/firewall/$1/$2"
}

set_attachment() { # set_attachment <iface> <in|out|local> <name|ipv6-name> <ruleset>
    set_conf "interfaces/vxlan/$1/firewall/$2/$3" "$4"
}

run_helper() {
    "$H" "$@" >"$TMP/out" 2>"$TMP/err"
}

run_apply() { # run_apply <old-state> <iface>
    printf '%s\n' "$1" | "$H" --apply "$2" >"$TMP/out" 2>"$TMP/err"
}

run_helper_ck() { # run_helper_ck <desc> <want> <args...>
    local desc=$1 want=$2
    shift 2
    run_helper "$@"
    local rc=$?
    if [ "$rc" -eq "$want" ]; then ok; else bad "$desc (rc=$rc want=$want)"; fi
}

state_eq() { # state_eq <desc> <file> <expected>
    local desc=$1 file=$2 want=$3 got
    got=$(cat "$file")
    if [ "$got" = "$want" ]; then ok; else bad "$desc (got '$got' want '$want')"; fi
}

flags_eq() { # flags_eq <desc> <iface> <expected>
    local desc=$1 iface=$2 want=$3 got
    got=$(cat "$SYS/class/net/$iface/flags")
    if [ "$got" = "$want" ]; then ok; else bad "$desc (got '$got' want '$want')"; fi
}

# ------------------------------------------------------------- validation
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_ruleset ipv6-name VXLAN6_IN

run_helper_ck "validate v4 attachment" 0 --validate vxlan42 in name VXLAN_IN
run_helper_ck "validate v6 attachment" 0 --validate vxlan42 local ipv6-name VXLAN6_IN
run_helper_ck "validate missing ruleset" 1 --validate vxlan42 in name NOPE
grep -q "is not configured" "$TMP/err" && ok || bad "missing ruleset diagnostic"
run_helper_ck "validate invalid direction" 1 --validate vxlan42 sideways name VXLAN_IN
run_helper_ck "validate invalid family" 1 --validate vxlan42 in modify VXLAN_IN
run_helper_ck "validate unsafe name" 1 --validate vxlan42 in name 'VX;IN'
run_helper_ck "validate long name" 1 --validate vxlan42 in name AAAAAAAAAAAAAAAAAAAAAAAAAAAAA
set_conf "interfaces/vxlan/vxlan42/bridge-group/bridge" br0
run_helper_ck "validate rejects bridge member" 1 --validate vxlan42 in name VXLAN_IN
grep -q "not supported on VXLAN bridge port" "$TMP/err" && ok || bad "bridge diagnostic"
set_attachment vxlan42 in name VXLAN_IN
empty_state=$(printf 'v4 in -\nv4 out -\nv4 local -\nv6 in -\nv6 out -\nv6 local -')
if printf '%s\n' "$empty_state" | "$H" --apply vxlan42 >"$TMP/out" 2>"$TMP/err"; then
    bad "apply must reject a bridged attachment even without leaf validation"
else
    grep -q "not supported on VXLAN bridge port" "$TMP/err" && ok || bad "apply bridge diagnostic"
fi

# ------------------------------------------------------------- capture/apply
reset_case
set_iface vxlan42
set_iface vxlan43
set_ruleset name VXLAN_IN
set_ruleset name VXLAN_IN2
set_ruleset ipv6-name VXLAN6_IN

expected_empty=$(printf 'v4 in -\nv4 out -\nv4 local -\nv6 in -\nv6 out -\nv6 local -')
run_helper_ck "capture empty" 0 --capture vxlan42
[ "$(cat "$TMP/out")" = "$expected_empty" ] && ok || bad "capture empty output"

set_attachment vxlan42 in name VXLAN_IN
old=$(cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "apply v4 in"; fi
state_eq "apply v4 in state" "$IPTSTATE" "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN"

# idempotent re-apply: no duplicate rule, no unnecessary engine call
before=$(cat "$IPTSTATE")
if run_apply "$old" vxlan42; then ok; else bad "idempotent apply"; fi
[ "$(cat "$IPTSTATE")" = "$before" ] && ok || bad "idempotent apply duplicated a rule"

# replace the chain atomically (still one interface rule)
set_attachment vxlan42 in name VXLAN_IN2
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "apply replacement"; fi
state_eq "apply replacement state" "$IPTSTATE" "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN2"

# IPv6 local and IPv4 out use the correct hooks/flags
set_attachment vxlan42 local ipv6-name VXLAN6_IN
set_attachment vxlan42 out name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "apply v6 local / v4 out"; fi
grep -qxF -- "-A VYATTA_FW_LOCAL_HOOK -i vxlan42 -j VXLAN6_IN" "$IPTSTATE6" && ok || bad "v6 local hook"
grep -qxF -- "-A VYATTA_FW_OUT_HOOK -o vxlan42 -j VXLAN_IN" "$IPTSTATE" && ok || bad "v4 out hook"

# Effective-state verification must inspect the whole dispatch, not merely
# confirm that one matching jump exists.
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" >"$IPTSTATE"
printf '%s\n' "VXLAN_IN" >"$CHAINS"
run_helper_ck "verify-all exact dispatch" 0 --verify-all vxlan42

EMPTY_CHAIN=1 run_helper_ck "verify-all rejects an empty ruleset chain" 1 --verify-all vxlan42
grep -q "is empty" "$TMP/err" && ok || bad "empty chain diagnostic"

printf '%s\n' \
    "-A VYATTA_FW_IN_HOOK -j DROP" \
    "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" >"$IPTSTATE"
run_helper_ck "verify-all rejects a shadowed dispatch" 1 --verify-all vxlan42
grep -q "shadowed" "$TMP/err" && ok || bad "shadowed dispatch diagnostic"

printf '%s\n' \
    "-A VYATTA_FW_IN_HOOK -i vxlan42 -j OTHER" \
    "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" >"$IPTSTATE"
run_helper_ck "verify-all rejects a stale same-interface rule" 1 --verify-all vxlan42
grep -q "malformed or stale" "$TMP/err" && ok || bad "stale dispatch diagnostic"

printf '%s\n' \
    "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" \
    "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" >"$IPTSTATE"
run_helper_ck "verify-all rejects a duplicate dispatch" 1 --verify-all vxlan42
grep -q "duplicate" "$TMP/err" && ok || bad "duplicate dispatch diagnostic"

printf '%s\n' \
    "-A VYATTA_FW_IN_HOOK -i vxlan43 -j OTHER" \
    "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" >"$IPTSTATE"
run_helper_ck "verify-all accepts another interface's dispatch first" 0 --verify-all vxlan42

# Restore a captured state and assert the resulting table.
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_ruleset name VXLAN_IN2
set_ruleset ipv6-name VXLAN6_IN
printf '%s\n' \
    "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" \
    "-A VYATTA_FW_OUT_HOOK -o vxlan42 -j VXLAN_IN" >"$IPTSTATE"
printf '%s\n' "-A VYATTA_FW_LOCAL_HOOK -i vxlan42 -j VXLAN6_IN" >"$IPTSTATE6"
printf '%s\n' "VXLAN_IN" "VXLAN_IN2" "VXLAN6_IN" >"$CHAINS"
printf '%s\n' "VXLAN6_IN" >"$CHAINS6"
old=$(printf 'v4 in VXLAN_IN2\nv4 out -\nv4 local -\nv6 in -\nv6 out -\nv6 local -')
run_restore() { printf '%s\n' "$1" | "$H" --restore "$2" >"$TMP/out" 2>"$TMP/err"; }
if run_restore "$old" vxlan42; then ok; else bad "restore captured state"; fi
state_eq "restore v4 state" "$IPTSTATE" "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN2"
state_eq "restore v6 state" "$IPTSTATE6" ""

# A truncated or empty snapshot must be refused, never treated as "restore
# nothing and succeed".
if run_restore "" vxlan42; then bad "empty restore must fail"; else grep -q "incomplete firewall state" "$TMP/err" && ok || bad "empty restore diagnostic"; fi
if run_restore "v4 in VXLAN_IN2" vxlan42; then bad "partial restore must fail"; else grep -q "incomplete firewall state" "$TMP/err" && ok || bad "partial restore diagnostic"; fi

# Direct-chain recovery: the old ruleset is gone from the configuration, but
# its iptables chain still exists.  ubnt-fw update fails, so the helper must
# insert the restored jump first, then remove the superseded one.
reset_case
set_iface vxlan42
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i vxlan42 -j NEW" >"$IPTSTATE"
printf '%s\n' "NEW" "OLD" >"$CHAINS"
fallback_state=$(printf 'v4 in OLD\nv4 out -\nv4 local -\nv6 in -\nv6 out -\nv6 local -')
if FAIL_FW_UPDATE=1 run_restore "$fallback_state" vxlan42; then ok; else bad "direct-chain restore fallback"; fi
state_eq "direct-chain restore state" "$IPTSTATE" "-A VYATTA_FW_IN_HOOK -i vxlan42 -j OLD"

# ------------------------------------------------------------- remove / isolation
reset_case
set_iface vxlan42
set_iface vxlan43
set_ruleset name VXLAN_IN
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i eth9 -j OTHER" >"$IPTSTATE"
printf '%s\n' "OTHER" >"$CHAINS"
set_attachment vxlan42 in name VXLAN_IN
set_attachment vxlan43 in name VXLAN_IN
old42=$(run_helper --capture vxlan42; cat "$TMP/out")
old43=$(run_helper --capture vxlan43; cat "$TMP/out")
run_apply "$old42" vxlan42
if run_apply "$old43" vxlan43; then ok; else bad "shared ruleset on two interfaces"; fi
[ "$(grep -c -- "-i vxlan42 -j VXLAN_IN" "$IPTSTATE")" -eq 1 ] && ok || bad "vxlan42 jump count"
[ "$(grep -c -- "-i vxlan43 -j VXLAN_IN" "$IPTSTATE")" -eq 1 ] && ok || bad "vxlan43 jump count"

run_helper_ck "remove-all vxlan42" 0 --remove-all vxlan42
grep -q -- "vxlan42" "$IPTSTATE" && bad "remove-all left the target rule" || ok
grep -qxF -- "-A VYATTA_FW_IN_HOOK -i vxlan43 -j VXLAN_IN" "$IPTSTATE" && ok || bad "remove-all damaged the other interface"
grep -qxF -- "-A VYATTA_FW_IN_HOOK -i eth9 -j OTHER" "$IPTSTATE" && ok || bad "remove-all damaged an unrelated rule"

# ambiguous dispatch is refused
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i vxlan42 -j A" "-A VYATTA_FW_IN_HOOK -i vxlan42 -j B" >"$IPTSTATE"
run_helper_ck "capture ambiguous dispatch" 3 --capture vxlan42
grep -q "ambiguous firewall dispatch" "$TMP/err" && ok || bad "ambiguous dispatch diagnostic"

# ------------------------------------------------------------- fail-closed
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if FAIL_FW_UPDATE=1 run_apply "$old" vxlan42; then bad "failed new attachment must fail"; else ok; fi
flags_eq "failed new attachment leaves interface down" vxlan42 "0x1002"
grep -q "left administratively down" "$TMP/err" && ok || bad "fail-closed diagnostic"
[ -s "$IPTSTATE" ] && bad "failed new attachment left a rule" || ok

# a failed replacement must keep the old dispatch and leave the interface up
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_ruleset name VXLAN_IN2
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
run_apply "$old" vxlan42
set_attachment vxlan42 in name VXLAN_IN2
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if FAIL_FW_UPDATE=1 run_apply "$old" vxlan42; then bad "failed replacement must fail"; else ok; fi
flags_eq "failed replacement keeps interface up" vxlan42 "0x1003"
grep -qxF -- "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" "$IPTSTATE" && ok || bad "failed replacement did not restore old dispatch"

# ------------------------------------------------------------- status
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
run_apply "$old" vxlan42
run_helper_ck "status" 0 --status vxlan42
grep -q "configured name in VXLAN_IN" "$TMP/out" && ok || bad "status configured output"
grep -q "effective  name in VXLAN_IN" "$TMP/out" && ok || bad "status effective output"

# ------------------------------------------------------------- quiesce (removal)
# A replacement/insertion is a single atomic vendor operation; a removal is the
# one transition that reduces enforcement, so the helper quiesces the interface
# and leaves it down for the caller to activate after its own gate.
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "add before removal"; fi
flags_eq "new attachment keeps the interface up" vxlan42 "0x1003"

rm -f "$CONF/interfaces/vxlan/vxlan42/firewall/in/name"
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "quiesced removal"; fi
flags_eq "removal leaves the interface down for activation" vxlan42 "0x1002"
if grep -q -- "vxlan42" "$IPTSTATE"; then bad "removal left a dispatch"; else ok; fi

# failed removal: the old dispatch is restored before reactivation
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
run_apply "$old" vxlan42
rm -f "$CONF/interfaces/vxlan/vxlan42/firewall/in/name"
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if FAIL_FW_DELETE=1 run_apply "$old" vxlan42; then bad "failed removal must fail"; else ok; fi
flags_eq "failed removal reactivates after restore" vxlan42 "0x1003"
state_eq "failed removal restores the dispatch" "$IPTSTATE" "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN"

# a quiesce failure aborts before any mutation
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
run_apply "$old" vxlan42
rm -f "$CONF/interfaces/vxlan/vxlan42/firewall/in/name"
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if FAIL_DOWN=1 run_apply "$old" vxlan42; then bad "quiesce failure must fail"; else ok; fi
flags_eq "quiesce failure leaves the interface untouched" vxlan42 "0x1003"
state_eq "quiesce failure leaves the dispatch" "$IPTSTATE" "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN"
grep -q "cannot quiesce" "$TMP/err" && ok || bad "quiesce failure diagnostic"

# an unknown administrative state is treated as "may be up": a down is
# attempted and confirmed before the dispatch is removed
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
run_apply "$old" vxlan42
rm -f "$CONF/interfaces/vxlan/vxlan42/firewall/in/name"
printf '%s\n' "garbage" >"$SYS/class/net/vxlan42/flags"
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "unknown admin state removal"; fi
flags_eq "unknown state resolved by an attempted down" vxlan42 "0x1002"

# ------------------------------------------------------------- capture / API
reset_case
set_iface vxlan42
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i vxlan42 -j A" "-A VYATTA_FW_IN_HOOK -i vxlan42 -j B" >"$IPTSTATE"
run_helper_ck "capture ambiguous dispatch" 3 --capture vxlan42
grep -q "ambiguous firewall dispatch" "$TMP/err" && ok || bad "ambiguous dispatch diagnostic"
FAIL_IPT_S=1 run_helper_ck "capture unreadable table" 4 --capture vxlan42
grep -q "cannot capture firewall state" "$TMP/err" && ok || bad "unreadable table diagnostic"

# an API failure must not be read as "no attachment configured"
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" >"$IPTSTATE"
printf '%s\n' "VXLAN_IN" >"$CHAINS"
if FAIL_API_PATTERN=firewall run_apply "$old" vxlan42; then bad "API failure must fail the apply"; else ok; fi
grep -qxF -- "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" "$IPTSTATE" && ok || bad "API failure must not remove the dispatch"
grep -q "configuration API failure" "$TMP/err" && ok || bad "API failure diagnostic"

# ------------------------------------------------------------- effective state
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
printf '%s\n' "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" >"$IPTSTATE"
printf '%s\n' "VXLAN_IN" >"$CHAINS"
run_helper_ck "verify-all accepts a reachable hook" 0 --verify-all vxlan42
NO_BASE_HOOKS=1 run_helper_ck "verify-all rejects an unreachable hook" 1 --verify-all vxlan42
grep -q "is not reached" "$TMP/err" && ok || bad "unreachable hook diagnostic"
BASE_SHADOW=1 run_helper_ck "verify-all rejects an interface-scoped shadow" 1 --verify-all vxlan42
grep -q "shadowed" "$TMP/err" && ok || bad "shadowed hook diagnostic"
BASE_SHADOW_OTHER=1 run_helper_ck "verify-all allows another interface's rule" 0 --verify-all vxlan42
NONTERMINAL_CHAIN=1 run_helper_ck "verify-all rejects a non-terminal default" 1 --verify-all vxlan42
grep -q "terminal default" "$TMP/err" && ok || bad "terminal default diagnostic"

# ------------------------------------------------------------- multi-attachment quiesce
# More than one dispatch change is applied sequentially, so it is quiesced: the
# interface must not carry an intermediate combination that neither the
# previous nor the final configuration intended.
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_ruleset name VXLAN_IN2
set_ruleset ipv6-name VXLAN6_IN
set_ruleset ipv6-name VXLAN6_IN2
set_attachment vxlan42 in name VXLAN_IN
set_attachment vxlan42 local ipv6-name VXLAN6_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "multi-attachment add"; fi
flags_eq "multi-attachment add is quiesced" vxlan42 "0x1002"

# two replacements at once are quiesced as well
printf '%s\n' "0x1003" >"$SYS/class/net/vxlan42/flags"
set_attachment vxlan42 in name VXLAN_IN2
set_attachment vxlan42 local ipv6-name VXLAN6_IN2
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "multi-attachment replace"; fi
flags_eq "multi-attachment replace is quiesced" vxlan42 "0x1002"
grep -qxF -- "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN2" "$IPTSTATE" && ok || bad "multi replace v4"
grep -qxF -- "-A VYATTA_FW_LOCAL_HOOK -i vxlan42 -j VXLAN6_IN2" "$IPTSTATE6" && ok || bad "multi replace v6"

# a single replacement is one atomic vendor operation and is not quiesced
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_ruleset name VXLAN_IN2
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
run_apply "$old" vxlan42
set_attachment vxlan42 in name VXLAN_IN2
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if run_apply "$old" vxlan42; then ok; else bad "single replacement"; fi
flags_eq "single replacement stays up" vxlan42 "0x1003"
grep -qxF -- "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN2" "$IPTSTATE" && ok || bad "single replacement target"

# --------------------------------------- exit recovery after mutation
# api_exists() exits directly on a configuration-API diagnostic.  Once the
# dispatch has been mutated, the EXIT trap must restore the pre-change
# dispatch and return the interface to a documented administrative state.
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_ruleset name VXLAN_IN2
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
run_apply "$old" vxlan42
set_attachment vxlan42 in name VXLAN_IN2
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if API_FAIL_MARKER="$TMP/api-fail" \
    FAIL_API_AFTER_FW='interfaces vxlan vxlan42 firewall' \
    run_apply "$old" vxlan42; then
    bad "API diagnostic after mutation must fail the apply"
else
    ok
fi
grep -q "unexpected exit after a firewall change" "$TMP/err" && ok || bad "exit-recovery diagnostic"
grep -qxF -- "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" "$IPTSTATE" && ok || bad "API diagnostic restores the pre-change dispatch"
! grep -qxF -- "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN2" "$IPTSTATE" && ok || bad "API diagnostic removes the new dispatch"
flags_eq "single replacement stays up after exit recovery" vxlan42 "0x1003"

# A quiesced multi-attachment change is restored and the interface resumed.
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_ruleset name VXLAN_IN2
set_ruleset ipv6-name VXLAN6_IN
set_ruleset ipv6-name VXLAN6_IN2
set_attachment vxlan42 in name VXLAN_IN
set_attachment vxlan42 local ipv6-name VXLAN6_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
run_apply "$old" vxlan42
printf '%s\n' "0x1003" >"$SYS/class/net/vxlan42/flags"
set_attachment vxlan42 in name VXLAN_IN2
set_attachment vxlan42 local ipv6-name VXLAN6_IN2
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if API_FAIL_MARKER="$TMP/api-fail" \
    FAIL_API_AFTER_FW='interfaces vxlan vxlan42 firewall' \
    run_apply "$old" vxlan42; then
    bad "API diagnostic after a multi-attachment mutation must fail"
else
    ok
fi
grep -qxF -- "-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN" "$IPTSTATE" && ok || bad "quiesced recovery restores v4"
grep -qxF -- "-A VYATTA_FW_LOCAL_HOOK -i vxlan42 -j VXLAN6_IN" "$IPTSTATE6" && ok || bad "quiesced recovery restores v6"
flags_eq "quiesced recovery resumes the interface" vxlan42 "0x1003"

# A failed new attachment stays down even after the pre-change dispatch (none)
# is restored.
reset_case
set_iface vxlan42
set_ruleset name VXLAN_IN
set_attachment vxlan42 in name VXLAN_IN
old=$(run_helper --capture vxlan42; cat "$TMP/out")
if API_FAIL_MARKER="$TMP/api-fail" \
    FAIL_API_AFTER_FW='interfaces vxlan vxlan42 firewall' \
    run_apply "$old" vxlan42; then
    bad "API diagnostic while adding an attachment must fail"
else
    ok
fi
[ ! -s "$IPTSTATE" ] && ok || bad "failed new attachment leaves no dispatch"
flags_eq "failed new attachment stays down" vxlan42 "0x1002"

echo "unit-firewall: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
