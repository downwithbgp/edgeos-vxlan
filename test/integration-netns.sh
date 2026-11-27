#!/bin/bash
# shellcheck disable=SC2015
# Generic Linux dataplane integration test for the VXLAN firewall semantics.
#
# This is NOT an EdgeOS test.  It exercises the Linux mechanisms the native
# EdgeOS attachment relies on:
#   - a name-based jump in FORWARD/INPUT applied to the decapsulated VXLAN
#     interface (not the outer UDP transport),
#   - IPv4 and IPv6 overlays over IPv4 and IPv6 underlays,
#   - local, forwarded-ingress and forwarded-egress policy directions,
#   - established/related handling and unsolicited inbound traffic,
#   - IPv6 NDP under an IPv6 local policy,
#   - multiple VXLAN interfaces sharing the same host,
#   - the dispatch surviving netdevice delete/recreate under traffic.
#
# Requires root/CAP_NET_ADMIN and iproute2/iptables/ip6tables/ping.  Exits 0
# with SKIP when the environment cannot support it; set REQUIRE_NETNS_TEST=1
# to turn a skip into a failure (used by CI).
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "SKIP: root/CAP_NET_ADMIN required"
    [ "${REQUIRE_NETNS_TEST:-0}" = "1" ] && exit 1
    exit 0
fi
for cmd in ip iptables ip6tables; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "SKIP: $cmd not available"
        [ "${REQUIRE_NETNS_TEST:-0}" = "1" ] && exit 1
        exit 0
    fi
done
if ! command -v ping >/dev/null 2>&1; then
    echo "SKIP: ping not available"
    [ "${REQUIRE_NETNS_TEST:-0}" = "1" ] && exit 1
    exit 0
fi

PASS=0
FAIL=0
PIDS=()

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $*"
}

A="vxla$$"
B="vxlb$$"
C="vxlc$$"

cleanup() {
    local pid
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    ip netns del "$A" 2>/dev/null || true
    ip netns del "$B" 2>/dev/null || true
    ip netns del "$C" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

run_ns() { # run_ns <namespace> <command...>
    local ns=$1
    shift
    ip netns exec "$ns" "$@"
}

run_shell() { # run_shell <namespace> <shell command>
    local ns=$1
    shift
    ip netns exec "$ns" sh -c "$*"
}

ping4_ok() { run_ns "$1" ping -c 1 -W 2 -q "$2" >/dev/null 2>&1; }
ping4_fail() { ! run_ns "$1" ping -c 1 -W 2 -q "$2" >/dev/null 2>&1; }
ping6_ok() {
    if command -v ping6 >/dev/null 2>&1; then
        run_ns "$1" ping6 -c 1 -W 2 -q "$2" >/dev/null 2>&1
    else
        run_ns "$1" ping -6 -c 1 -W 2 -q "$2" >/dev/null 2>&1
    fi
}
ping6_fail() { ! ping6_ok "$1" "$2"; }

# ------------------------------------------------------------- topology
ip netns add "$A" || exit 1
ip netns add "$B" || exit 1
ip netns add "$C" || exit 1

for ns in "$A" "$B" "$C"; do
    run_shell "$ns" "ip link set lo up"
done

# Underlay: veth pair between A and B, carrying IPv4 and IPv6.
ip link add "va$$" type veth peer name "vb$$" || exit 1
ip link set "va$$" netns "$A"
ip link set "vb$$" netns "$B"
run_shell "$A" "ip addr add 192.0.2.1/24 dev va$$; ip -6 addr add 2001:db8:ff::1/64 nodad dev va$$; ip link set va$$ up"
run_shell "$B" "ip addr add 192.0.2.2/24 dev vb$$; ip -6 addr add 2001:db8:ff::2/64 nodad dev vb$$; ip link set vb$$ up"

# Routed client C: veth pair between A and C.
ip link add "ca$$" type veth peer name "cb$$" || exit 1
ip link set "ca$$" netns "$A"
ip link set "cb$$" netns "$C"
run_shell "$A" "ip addr add 10.0.0.1/24 dev ca$$; ip -6 addr add 2001:db8:cc::1/64 nodad dev ca$$; ip link set ca$$ up"
run_shell "$C" "ip addr add 10.0.0.2/24 dev cb$$; ip -6 addr add 2001:db8:cc::2/64 nodad dev cb$$; ip link set cb$$ up; ip route add 198.51.100.0/24 via 10.0.0.1; ip -6 route add 2001:db8:1::/64 via 2001:db8:cc::1"

# VXLAN over IPv4: two independent overlay networks.
for ns in "$A" "$B"; do
    run_shell "$ns" "ip link add vxlan42 type vxlan id 42 local 192.0.2.$( [ "$ns" = "$A" ] && echo 1 || echo 2 ) remote 192.0.2.$( [ "$ns" = "$A" ] && echo 2 || echo 1 ) dstport 4789"
    run_shell "$ns" "ip link set vxlan42 up"
    run_shell "$ns" "ip link add vxlan43 type vxlan id 43 local 192.0.2.$( [ "$ns" = "$A" ] && echo 1 || echo 2 ) remote 192.0.2.$( [ "$ns" = "$A" ] && echo 2 || echo 1 ) dstport 4789"
    run_shell "$ns" "ip link set vxlan43 up"
done
run_shell "$A" "ip addr add 198.51.100.1/24 dev vxlan42; ip addr add 203.0.113.1/24 dev vxlan43"
run_shell "$B" "ip addr add 198.51.100.2/24 dev vxlan42; ip addr add 203.0.113.2/24 dev vxlan43"

# VXLAN over IPv6, independent overlay.
for ns in "$A" "$B"; do
    run_shell "$ns" "ip link add vxlan6 type vxlan id 46 local 2001:db8:ff::$( [ "$ns" = "$A" ] && echo 1 || echo 2 ) remote 2001:db8:ff::$( [ "$ns" = "$A" ] && echo 2 || echo 1 ) dstport 4789"
    run_shell "$ns" "ip link set vxlan6 up"
done
run_shell "$A" "ip -6 addr add 2001:db8:1::1/64 nodad dev vxlan6"
run_shell "$B" "ip -6 addr add 2001:db8:1::2/64 nodad dev vxlan6"
run_shell "$B" "ip route add 10.0.0.0/24 via 198.51.100.1; ip -6 route add 2001:db8:cc::/64 via 2001:db8:1::1"
run_shell "$A" "echo 1 > /proc/sys/net/ipv4/ip_forward; echo 1 > /proc/sys/net/ipv6/conf/all/forwarding"

sleep 1

# ------------------------------------------------------------- baseline
ping4_ok "$A" 198.51.100.2 && ok || bad "IPv4 overlay A->B"
ping4_ok "$B" 198.51.100.1 && ok || bad "IPv4 overlay B->A"
ping4_ok "$A" 203.0.113.2 && ok || bad "second VXLAN interface A->B"
ping6_ok "$A" 2001:db8:1::2 && ok || bad "IPv6 overlay over IPv6 underlay A->B"
ping6_ok "$B" 2001:db8:1::1 && ok || bad "IPv6 overlay over IPv6 underlay B->A"
ping4_ok "$C" 198.51.100.2 && ok || bad "forwarded A-ingress/B-egress baseline"
run_ns "$A" ping -c 1 -W 2 -q 192.0.2.2 >/dev/null 2>&1 && ok || bad "outer underlay transport baseline"

# ------------------------------------------------------------- chains
run_ns "$A" iptables -N VXLAN_IN
run_ns "$A" iptables -N VXLAN_OUT
run_ns "$A" iptables -N VXLAN_LOCAL
run_ns "$A" iptables -A FORWARD -i vxlan42 -j VXLAN_IN
run_ns "$A" iptables -A FORWARD -o vxlan42 -j VXLAN_OUT
run_ns "$A" iptables -A INPUT -i vxlan42 -j VXLAN_LOCAL
run_ns "$A" iptables -A VXLAN_IN -j ACCEPT
run_ns "$A" iptables -A VXLAN_OUT -j ACCEPT
run_ns "$A" iptables -A VXLAN_LOCAL -j ACCEPT
run_ns "$A" ip6tables -N VXLAN_IN6
run_ns "$A" ip6tables -N VXLAN_OUT6
run_ns "$A" ip6tables -N VXLAN_LOCAL6
run_ns "$A" ip6tables -A FORWARD -i vxlan6 -j VXLAN_IN6
run_ns "$A" ip6tables -A FORWARD -o vxlan6 -j VXLAN_OUT6
run_ns "$A" ip6tables -A INPUT -i vxlan6 -j VXLAN_LOCAL6
run_ns "$A" ip6tables -A VXLAN_IN6 -j ACCEPT
run_ns "$A" ip6tables -A VXLAN_OUT6 -j ACCEPT
run_ns "$A" ip6tables -A VXLAN_LOCAL6 -j ACCEPT

# Local direction: deny unsolicited echo to the router, keep NDP working.
run_ns "$A" iptables -Z VXLAN_LOCAL
run_ns "$A" iptables -I VXLAN_LOCAL 1 -p icmp --icmp-type echo-request -j DROP
ping4_fail "$B" 198.51.100.1 && ok || bad "local policy must drop unsolicited echo"
local_pkts=$(run_ns "$A" iptables -L VXLAN_LOCAL -v -n -x | awk '/DROP/ {print $1; exit}')
[ "${local_pkts:-0}" -gt 0 ] && ok || bad "local policy counter must observe the dropped packet"
run_ns "$A" iptables -D VXLAN_LOCAL -p icmp --icmp-type echo-request -j DROP
ping4_ok "$B" 198.51.100.1 && ok || bad "local policy removal restores traffic"

# Forwarded ingress/egress directions.
run_ns "$A" iptables -I VXLAN_OUT 1 -p icmp -j DROP
ping4_fail "$C" 198.51.100.2 && ok || bad "out policy must drop forwarded egress"
run_ns "$A" iptables -D VXLAN_OUT -p icmp -j DROP
run_ns "$A" iptables -I VXLAN_IN 1 -p icmp -j DROP
ping4_fail "$C" 198.51.100.2 && ok || bad "in policy must drop forwarded ingress"
run_ns "$A" iptables -D VXLAN_IN -p icmp -j DROP
ping4_ok "$C" 198.51.100.2 && ok || bad "in/out policy removal restores forwarded traffic"

# IPv6 forwarded ingress/egress over the IPv6-underlay VXLAN interface.
ping6_ok "$C" 2001:db8:1::2 && ok || bad "forwarded IPv6 baseline"
run_ns "$A" ip6tables -I VXLAN_OUT6 1 -p icmpv6 --icmpv6-type 128 -j DROP
ping6_fail "$C" 2001:db8:1::2 && ok || bad "IPv6 out policy must drop forwarded egress"
run_ns "$A" ip6tables -D VXLAN_OUT6 -p icmpv6 --icmpv6-type 128 -j DROP
run_ns "$A" ip6tables -I VXLAN_IN6 1 -p icmpv6 --icmpv6-type 129 -j DROP
ping6_fail "$C" 2001:db8:1::2 && ok || bad "IPv6 in policy must drop forwarded ingress"
run_ns "$A" ip6tables -D VXLAN_IN6 -p icmpv6 --icmpv6-type 129 -j DROP
ping6_ok "$C" 2001:db8:1::2 && ok || bad "IPv6 in/out policy removal restores traffic"

# Native out semantics: locally originated traffic is not matched by the
# FORWARD -o vxlan42 hook.
run_ns "$A" iptables -I VXLAN_OUT 1 -p icmp -j DROP
ping4_ok "$A" 198.51.100.2 && ok || bad "out policy must not filter locally originated traffic"
run_ns "$A" iptables -D VXLAN_OUT -p icmp -j DROP

# The overlay policy must not filter the outer underlay transport.
run_ns "$A" iptables -I VXLAN_IN 1 -p icmp -j DROP
run_ns "$A" ping -c 1 -W 2 -q 192.0.2.2 >/dev/null 2>&1 && ok || bad "overlay policy must not filter outer transport"
run_ns "$A" iptables -D VXLAN_IN -p icmp -j DROP

# Multiple interfaces: a policy on vxlan42 must not affect vxlan43.
run_ns "$A" iptables -I VXLAN_IN 1 -p icmp -j DROP
ping4_ok "$A" 203.0.113.2 && ok || bad "policy on one VXLAN interface must not affect another"
run_ns "$A" iptables -D VXLAN_IN -p icmp -j DROP

# ------------------------------------------------- established / unsolicited
if command -v python3 >/dev/null 2>&1; then
    server='import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("198.51.100.2", 8080))
s.listen(1)
c, _ = s.accept()
c.sendall(b"ok")
c.close()'
    client='import socket
s = socket.create_connection(("198.51.100.2", 8080), 3)
assert s.recv(2) == b"ok"
s.close()'
    run_ns "$A" iptables -F VXLAN_IN
    run_ns "$A" iptables -A VXLAN_IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    run_ns "$A" iptables -A VXLAN_IN -j DROP

    ip netns exec "$B" python3 -c "$server" &
    PIDS+=($!)
    sleep 0.3
    run_ns "$C" python3 -c "$client" >/dev/null 2>&1 && ok || bad "established forwarded traffic must pass"

    # Unsolicited inbound: B initiates to C; the SYN enters A on vxlan42 as NEW.
    server_c='import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("10.0.0.2", 8081))
s.listen(1)
s.settimeout(3)
try:
    c, _ = s.accept()
    c.sendall(b"ok")
    c.close()
except Exception:
    pass'
    client_b='import socket
s = socket.create_connection(("10.0.0.2", 8081), 2)
assert s.recv(2) == b"ok"
s.close()'
    ip netns exec "$C" python3 -c "$server_c" &
    PIDS+=($!)
    sleep 0.3
    if run_ns "$B" python3 -c "$client_b" >/dev/null 2>&1; then
        bad "unsolicited inbound forwarded traffic must be dropped"
    else
        ok
    fi
else
    echo "NOTE: python3 unavailable; skipping established/unsolicited TCP checks"
fi

# ------------------------------------------------- IPv6 NDP under local policy
run_ns "$A" ip6tables -F VXLAN_LOCAL6
run_ns "$A" ip6tables -A VXLAN_LOCAL6 -p icmpv6 ! --icmpv6-type 128 -j ACCEPT
run_ns "$A" ip6tables -A VXLAN_LOCAL6 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
run_ns "$A" ip6tables -A VXLAN_LOCAL6 -j DROP
run_ns "$A" ip6tables -Z VXLAN_LOCAL6
run_shell "$A" "ip -6 neigh flush dev vxlan6"
run_shell "$B" "ip -6 neigh flush dev vxlan6"
ping6_fail "$B" 2001:db8:1::1 && ok || bad "IPv6 local policy must drop unsolicited echo"
ndp_pkts=$(run_ns "$A" ip6tables -L VXLAN_LOCAL6 -v -n -x | awk '/icmpv6/ && /ACCEPT/ {print $1; exit}')
neigh_v6=$(run_shell "$A" "ip -6 neigh show dev vxlan6")
if [ -n "$neigh_v6" ] || [ "${ndp_pkts:-0}" -gt 0 ]; then ok; else bad "NDP must work under the IPv6 local policy (neigh: $neigh_v6, pkts: ${ndp_pkts:-0})"; fi
ping6_ok "$A" 2001:db8:1::2 && ok || bad "IPv6 established reply must pass the local policy"
neigh_v6=$(run_shell "$A" "ip -6 neigh show dev vxlan6")
if echo "$neigh_v6" | grep -q "2001:db8:1::2"; then ok; else bad "NDP must resolve the overlay peer (neigh: $neigh_v6)"; fi

# ------------------------------------------------- recreation under traffic
run_ns "$C" ping -i 0.2 -c 20 -W 1 198.51.100.2 >"$PWD/netns-ping.$$" 2>&1 &
PIDS+=($!)
sleep 1
run_ns "$A" ip link del vxlan42
run_shell "$A" "ip link add vxlan42 type vxlan id 42 local 192.0.2.1 remote 192.0.2.2 dstport 4789; ip link set vxlan42 up; ip addr add 198.51.100.1/24 dev vxlan42"
wait $! 2>/dev/null || true
run_ns "$A" iptables -C FORWARD -i vxlan42 -j VXLAN_IN >/dev/null 2>&1 && ok || bad "dispatch must survive netdevice recreation"
grep -q "bytes from" "$PWD/netns-ping.$$" && ok || bad "traffic must resume after netdevice recreation"
rm -f "$PWD/netns-ping.$$"

echo "netns: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
