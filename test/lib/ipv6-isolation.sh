#!/bin/bash
# IPv6-only isolation assertions for Linux network namespaces.
#
# This file is sourced by test/ipv6-only-netns.sh.  The functions inspect a
# namespace and report violations of the Level B contract: no usable external
# IPv4 connectivity, no translation mechanism, and no unexpected interface
# kinds.  IPv4 loopback and AF_INET kernel support are deliberately allowed;
# they are recorded separately by the caller and are not treated as external
# IPv4 connectivity.
#
# The functions print one violation per line and return non-zero when any
# violation is found.  A state that cannot be read is a violation, not a pass.

ipv6_iso_run()
{
    local ns=$1
    shift
    ip netns exec "$ns" "$@"
}

# Return 0 when the namespace has the expected IPv4 loopback address.
ipv6_iso_loopback_present()
{
    local ns=$1
    ipv6_iso_run "$ns" ip -4 -o addr show dev lo 2>/dev/null |
        grep -q 'inet 127\.0\.0\.1/8'
}

# Print every Level B isolation violation in <namespace>; return 1 if any.
ipv6_iso_violations()
{
    local ns=$1 out line dev addr name rc=0 count

    # 1. IPv4 addresses.  Only 127.0.0.0/8 on the loopback interface is
    #    allowed.  Any other IPv4 address is usable external connectivity.
    if ! out=$(ipv6_iso_run "$ns" ip -4 -o addr show 2>&1); then
        echo "cannot read IPv4 addresses: $out"
        rc=1
    else
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                *" inet "*) ;;
                *) continue ;;
            esac
            dev=$(printf '%s\n' "$line" | awk '{print $2}' | tr -d ':')
            addr=$(printf '%s\n' "$line" | awk '{print $4}')
            case "$addr" in
                127.*)
                    if [ "$dev" != "lo" ]; then
                        echo "IPv4 loopback address $addr on non-loopback interface $dev"
                        rc=1
                    fi
                    ;;
                *)
                    echo "IPv4 address $addr on $dev"
                    rc=1
                    ;;
            esac
        done <<<"$out"
    fi

    # 2. IPv4 routes in every table, including policy-routing tables.  Local
    #    and broadcast routes for 127.0.0.0/8 on lo are kernel bookkeeping;
    #    everything else is an escape path.
    if ! out=$(ipv6_iso_run "$ns" ip -4 route show table all 2>&1); then
        echo "cannot read IPv4 routing tables: $out"
        rc=1
    else
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                default* | *" default "*)
                    echo "IPv4 default route: $line"
                    rc=1
                    ;;
                *" via "*)
                    echo "IPv4 gateway route: $line"
                    rc=1
                    ;;
                *" dev lo "*)
                    ;;
                *)
                    echo "IPv4 non-loopback route: $line"
                    rc=1
                    ;;
            esac
        done <<<"$out"
    fi

    # 3. IPv4 policy rules.  The kernel's default local/main/default rules are
    #    expected; any selector or additional table is a potential escape.
    if ! out=$(ipv6_iso_run "$ns" ip -4 rule show 2>&1); then
        echo "cannot read IPv4 policy rules: $out"
        rc=1
    else
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            if ! printf '%s\n' "$line" |
                grep -Eq '^(0|32766|32767):[[:space:]]+from all lookup (local|main|default)$'; then
                echo "IPv4 policy rule: $line"
                rc=1
            fi
        done <<<"$out"
    fi

    # 4. The main IPv4 table.  /proc/net/route exposes the main table; a
    #    non-header row is a route that must not exist.
    if ! out=$(ipv6_iso_run "$ns" cat /proc/net/route 2>&1); then
        echo "cannot read /proc/net/route: $out"
        rc=1
    else
        count=$(printf '%s\n' "$out" |
            awk 'NR > 1 && NF { n++ } END { print n + 0 }')
        if [ "$count" -ne 0 ]; then
            echo "/proc/net/route contains $count route row(s)"
            rc=1
        fi
    fi

    # 5. IPv4 forwarding.  A forwarding namespace with IPv4 routes would be an
    #    explicit escape path; keep the contract simple and require it off.
    for name in all default; do
        if ! out=$(ipv6_iso_run "$ns" cat "/proc/sys/net/ipv4/conf/$name/forwarding" 2>&1); then
            echo "cannot read IPv4 forwarding ($name): $out"
            rc=1
        elif [ "$out" != "0" ]; then
            echo "IPv4 forwarding is enabled ($name=$out)"
            rc=1
        fi
    done

    # 6. Translation mechanisms: NAT64, DNS64/CLAT helpers, and the well-known
    #    NAT64 prefix must not be present.  DNS64 is a resolver behaviour and
    #    is recorded as a residual risk rather than asserted here.
    if ! out=$(ipv6_iso_run "$ns" ip -6 route show table all 2>&1); then
        echo "cannot read IPv6 routing tables: $out"
        rc=1
    else
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                *"64:ff9b::/96"* | *nat64*)
                    echo "translation route: $line"
                    rc=1
                    ;;
            esac
        done <<<"$out"
    fi

    if ! out=$(ipv6_iso_run "$ns" ip -o link show 2>&1); then
        echo "cannot read interface list: $out"
        rc=1
    else
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                [0-9]*": "*) ;;
                *) continue ;;
            esac
            name=${line#*: }
            name=${name%%:*}
            name=${name%%@*}
            case "$name" in
                nat64 | clat | 464xlat | tayga*)
                    echo "translation interface: $name"
                    rc=1
                    ;;
            esac
        done <<<"$out"
    fi

    # 7. Interface kinds.  Only loopback, veth, vxlan, and bridge devices are
    #    expected in this topology; a physical or tunnel device from another
    #    namespace boundary is not.
    if ! out=$(ipv6_iso_run "$ns" ip -d -o link show 2>&1); then
        echo "cannot read interface details: $out"
        rc=1
    else
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                [0-9]*": "*) ;;
                *) continue ;;
            esac
            name=${line#*: }
            name=${name%%:*}
            name=${name%%@*}
            [ "$name" = "lo" ] && continue
            case "$line" in
                *" veth "* | *" vxlan "* | *" bridge "*)
                    ;;
                *)
                    echo "unexpected interface kind ($name): $line"
                    rc=1
                    ;;
            esac
        done <<<"$out"
    fi

    # 8. AF_INET kernel support is present, but an external IPv4 send must
    #    fail with ENETUNREACH/EHOSTUNREACH.  This is a runtime negative
    #    control, not a substitute for the address/route assertions above.
    if ! out=$(ipv6_iso_run "$ns" python3 -c '
import errno
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    sock.sendto(b"x", ("198.51.100.2", 9))
except OSError as exc:
    if exc.errno not in (errno.ENETUNREACH, errno.EHOSTUNREACH):
        sys.stdout.write("AF_INET external send failed with errno %d\n" % exc.errno)
        sys.exit(1)
except Exception as exc:  # pragma: no cover - defensive
    sys.stdout.write("AF_INET probe failed: %s\n" % exc)
    sys.exit(1)
else:
    sys.stdout.write("AF_INET external send unexpectedly succeeded\n")
    sys.exit(1)
sys.exit(0)
' 2>&1); then
        echo "AF_INET negative control failed: $out"
        rc=1
    fi

    return "$rc"
}

# Run the full assertion set and prefix each violation with a label.
ipv6_iso_assert()
{
    local ns=$1 label=$2 out

    if out=$(ipv6_iso_violations "$ns"); then
        return 0
    fi
    printf '%s\n' "$out" | sed "s/^/  [$label] /"
    return 1
}
