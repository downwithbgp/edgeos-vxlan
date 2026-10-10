#!/bin/bash
# Unit tests for src/vyatta-vxlan-addr (no root, no network, no /sys access).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
H="$ROOT/src/vyatta-vxlan-addr"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ck() { # ck <desc> <expected_rc> <cmd...>
    local desc=$1 want=$2
    shift 2
    "$@" >"$TMP/out" 2>"$TMP/err"
    local rc=$?
    if [ "$rc" = "$want" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (rc=$rc want=$want)"
        sed 's/^/    /' "$TMP/err" | head -3
    fi
}

eq() { # eq <desc> <expected_stdout> <cmd...>
    local desc=$1 want=$2
    shift 2
    local got
    got=$("$@" 2>"$TMP/err")
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (got '$got' want '$want')"
    fi
}

eq_stdin() { # eq_stdin <desc> <expected_stdout> <file> <cmd...>
    local desc=$1 want=$2 file=$3
    shift 3
    local got
    got=$("$@" <"$file" 2>"$TMP/err")
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (got '$got' want '$want')"
    fi
}

# ------------------------------------------------------------ family/canon
eq "family v4" "v4" "$H" family 192.0.2.1
eq "family v6" "v6" "$H" family 2001:db8::1
ck "family invalid" 1 "$H" family 1.2.3
ck "family prefix" 1 "$H" family 2001:db8::1/64
ck "family hostname" 1 "$H" family example.com

eq "canon v6 compressed" "2001:db8::1" "$H" canon 2001:0db8:0000:0000:0000:0000:0000:0001
eq "canon v6 case" "2001:db8::1" "$H" canon 2001:DB8::1
eq "canon v4" "192.0.2.1" "$H" canon 192.0.2.1
eq "canon v4 platform parity (octal)" "8.1.2.3" "$H" canon 010.1.2.3
eq "canon v4 parity 2" "8.8.8.8" "$H" canon 010.010.010.010
eq "canon v4 zero" "0.0.0.0" "$H" canon 0.0.0.0
eq "canon v4 255" "255.255.255.255" "$H" canon 255.255.255.255
ck "canon v4 invalid octal" 1 "$H" canon 08.1.2.3
ck "canon v4 out of range" 1 "$H" canon 256.1.1.1
ck "canon v4 short" 1 "$H" canon 1.2.3
eq "canon-v4 rejects v6" "" "$H" canon-v4 2001:db8::1
ck "canon-v4 rejects v6 rc" 1 "$H" canon-v4 2001:db8::1

ck "equal v6 variants" 0 "$H" equal 2001:db8::1 2001:0db8:0:0:0:0:0:1
ck "equal v4 parity" 0 "$H" equal 010.1.2.3 8.1.2.3
ck "equal different" 1 "$H" equal 2001:db8::1 2001:db8::2
ck "equal malformed" 1 "$H" equal 2001:db8::1 not-an-address

# ------------------------------------------------------------ endpoints
ck "local v6 unicast" 0 "$H" check-endpoint local 2001:db8::1
ck "local v6 ULA" 0 "$H" check-endpoint local fd00::1
ck "local v6 unspecified allowed" 0 "$H" check-endpoint local ::
ck "local v6 link-local rejected" 1 "$H" check-endpoint local fe80::1
ck "local v6 multicast rejected" 1 "$H" check-endpoint local ff02::1
ck "local v6 loopback rejected" 1 "$H" check-endpoint local ::1
ck "local v6 mapped rejected" 1 "$H" check-endpoint local ::ffff:192.0.2.1
ck "local v4 unspecified allowed" 0 "$H" check-endpoint local 0.0.0.0
ck "local v4 unchanged" 0 "$H" check-endpoint local 192.0.2.1
ck "remote v6 unicast" 0 "$H" check-endpoint remote 2001:db8::2
ck "remote v6 unspecified rejected" 1 "$H" check-endpoint remote ::
ck "remote v6 link-local rejected" 1 "$H" check-endpoint remote fe80::2
ck "remote v4 unchanged" 0 "$H" check-endpoint remote 192.0.2.2

ck "endpoints v4/v4" 0 "$H" check-endpoints 192.0.2.1 192.0.2.2
ck "endpoints v6/v6" 0 "$H" check-endpoints 2001:db8::1 2001:db8::2
ck "endpoints 0.0.0.0/v4" 0 "$H" check-endpoints 0.0.0.0 192.0.2.2
ck "endpoints ::/v6" 0 "$H" check-endpoints :: 2001:db8::2
ck "endpoints mixed" 1 "$H" check-endpoints 192.0.2.1 2001:db8::2
ck "endpoints mixed 2" 1 "$H" check-endpoints :: 192.0.2.2
ck "endpoints malformed" 1 "$H" check-endpoints 192.0.2.1 nope

eq "default-mtu v4" "1450" "$H" default-mtu v4
eq "default-mtu v6" "1430" "$H" default-mtu v6

# --------------------------------------------------------------- present
cat >"$TMP/ipstub" <<'EOF'
#!/bin/sh
printf '%s\n' "2: eth0    inet 192.0.2.1/24 brd 192.0.2.255 scope global eth0"
printf '%s\n' "2: eth0    inet6 2001:db8::1/64 scope global"
EOF
chmod +x "$TMP/ipstub"
VXLAN_BIN_IP="$TMP/ipstub" ck "present v4" 0 "$H" present 192.0.2.1
VXLAN_BIN_IP="$TMP/ipstub" ck "present v6" 0 "$H" present 2001:db8::1
VXLAN_BIN_IP="$TMP/ipstub" ck "present absent" 1 "$H" present 198.51.100.9
VXLAN_BIN_IP=/nonexistent-ip ck "present operational error" 2 "$H" present 192.0.2.1

# ------------------------------------------------------------- parse-live
cat >"$TMP/v4.json" <<'EOF'
[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":42,"remote":"192.0.2.2","local":"192.0.2.1","port":4789}}}]
EOF
cat >"$TMP/v6.json" <<'EOF'
[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":42,"remote6":"2001:db8:1::2","local6":"2001:db8:1::1","port":4789}}}]
EOF
cat >"$TMP/v6_nolocal.json" <<'EOF'
[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":42,"remote6":"2001:db8:1::2","port":4789}}}]
EOF
cat >"$TMP/v6_dstport.json" <<'EOF'
[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":7,"remote6":"2001:db8:1::2","local6":"2001:db8:1::1","dstport":8472}}}]
EOF
cat >"$TMP/mixed.json" <<'EOF'
[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":42,"remote":"192.0.2.2","local6":"2001:db8:1::1","port":4789}}}]
EOF
cat >"$TMP/noremote.json" <<'EOF'
[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":42,"local6":"2001:db8:1::1","port":4789}}}]
EOF
cat >"$TMP/group.json" <<'EOF'
[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":42,"group6":"ff02::1","port":4789}}}]
EOF
cat >"$TMP/nonvxlan.json" <<'EOF'
[{"ifindex":2,"ifname":"br0","linkinfo":{"info_kind":"bridge","info_data":{}}}]
EOF
printf 'not json' >"$TMP/bad.json"

eq_stdin "parse-live v4" "$(printf 'vxlan\t42\t4789\tv4\t192.0.2.1\t192.0.2.2')" "$TMP/v4.json" "$H" parse-live
eq_stdin "parse-live v6" "$(printf 'vxlan\t42\t4789\tv6\t2001:db8:1::1\t2001:db8:1::2')" "$TMP/v6.json" "$H" parse-live
eq_stdin "parse-live v6 no local" "$(printf 'vxlan\t42\t4789\tv6\t-\t2001:db8:1::2')" "$TMP/v6_nolocal.json" "$H" parse-live
eq_stdin "parse-live dstport fallback" "$(printf 'vxlan\t7\t8472\tv6\t2001:db8:1::1\t2001:db8:1::2')" "$TMP/v6_dstport.json" "$H" parse-live
ck "parse-live mixed keys" 1 "$H" parse-live <"$TMP/mixed.json"
ck "parse-live missing remote" 1 "$H" parse-live <"$TMP/noremote.json"
ck "parse-live multicast group" 1 "$H" parse-live <"$TMP/group.json"
ck "parse-live non-vxlan" 1 "$H" parse-live <"$TMP/nonvxlan.json"
ck "parse-live malformed" 1 "$H" parse-live <"$TMP/bad.json"

# --------------------------------------------------------- identity guard
mkdir -p "$TMP/bin" "$TMP/api"
cat >"$TMP/bin/my_cli_shell_api" <<'EOF'
#!/bin/sh
mode=$1
ifname=$4
node=$5
case "$mode" in
    exists) [ -f "$API_DIR/$ifname.$node" ] && exit 0 || exit 1 ;;
    returnValue) cat "$API_DIR/$ifname.$node" 2>/dev/null; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/my_cli_shell_api"
cat >"$TMP/ipjson" <<'EOF'
#!/bin/sh
printf '%s\n' '[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":42,"remote6":"2001:db8:1::2","local6":"2001:db8:1::1","port":4789}}}]'
exit 0
EOF
chmod +x "$TMP/ipjson"
cat >"$TMP/ipgone" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TMP/ipgone"
printf '42' >"$TMP/api/vxlan42.vni"
printf '2001:0db8:1::1' >"$TMP/api/vxlan42.local-ip"
printf '2001:db8:1::2' >"$TMP/api/vxlan42.remote-ip"

API_DIR="$TMP/api" VXLAN_BIN_IP="$TMP/ipjson" vyatta_sbindir="$TMP/bin" ck "guard matches (v6 reformatted config)" 0 "$H" identity-matches vxlan42
printf '2001:db8:9::2' >"$TMP/api/vxlan42.remote-ip"
API_DIR="$TMP/api" VXLAN_BIN_IP="$TMP/ipjson" vyatta_sbindir="$TMP/bin" ck "guard mismatch on remote" 1 "$H" identity-matches vxlan42
printf '2001:db8:1::2' >"$TMP/api/vxlan42.remote-ip"
API_DIR="$TMP/api" VXLAN_BIN_IP="$TMP/ipgone" vyatta_sbindir="$TMP/bin" ck "guard mismatch when interface absent" 1 "$H" identity-matches vxlan42
printf '42' >"$TMP/api/vxlan42.vni"
printf '010.1.2.3' >"$TMP/api/vxlan42.local-ip"
printf '8.1.2.4' >"$TMP/api/vxlan42.remote-ip"
cat >"$TMP/ipjson4" <<'EOF'
#!/bin/sh
printf '%s\n' '[{"ifindex":2,"ifname":"vxlan42","linkinfo":{"info_kind":"vxlan","info_data":{"id":42,"remote":"8.1.2.4","local":"8.1.2.3","port":4789}}}]'
exit 0
EOF
chmod +x "$TMP/ipjson4"
API_DIR="$TMP/api" VXLAN_BIN_IP="$TMP/ipjson4" vyatta_sbindir="$TMP/bin" ck "guard matches noncanonical v4" 0 "$H" identity-matches vxlan42

echo "unit-helper: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
