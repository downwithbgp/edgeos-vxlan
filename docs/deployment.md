# Deployment guide

**Status:** current deployment guidance for `edgeos-vxlan` v0.3.0.
**Platform:** Ubiquiti EdgeRouter X / ER-e50, EdgeOS 3.0.1, Linux `4.14.54-UBNT`.
**Scope:** the six documented deployment scenarios, IPv6 operational considerations, and the
boundary of IPv6-only deployability. The architectural model and standards references are in
[`architecture.md`](architecture.md); the evidence level for each combination
is in [`address-family-support-matrix.md`](address-family-support-matrix.md).

The examples below use documentation address ranges and a single fixed remote VTEP. They are
written for two routers, A and B. Only the `interfaces vxlan` lines are managed by this project;
the underlay-interface lines are shown so the example is complete. If the underlay address already
exists, do not add it again.

## 1. Conventions

| Item | Value |
|---|---|
| Underlay link | `2001:db8:10::/64` (IPv6 scenarios) or `192.0.2.0/24` (IPv4 scenarios) |
| Router A underlay | `2001:db8:10::1` or `192.0.2.1` |
| Router B underlay | `2001:db8:10::2` or `192.0.2.2` |
| Overlay IPv6 prefix | `2001:db8:42::/64` |
| Overlay IPv4 prefix | `198.51.100.0/30` |
| VNI | `42` |
| UDP destination port | `4789` |
| VXLAN interface | `vxlan42` |
| Bridge (scenario 2) | `br42` |
| Family-default MTU | `1430` over IPv6; `1450` over IPv4 |

The underlay addresses in a real deployment must be reachable in both directions before the VXLAN
is configured. If the underlay is routed rather than a shared segment, add the necessary route and
make sure the return path reaches the configured `local-ip` address. A VXLAN cannot repair an
underlay reachability or return-path problem.

`local-ip` and `remote-ip` are outer addresses. The overlay addresses are configured with
`address` on the VXLAN interface or on its bridge. Do not put overlay addresses in
`local-ip`/`remote-ip`.

## 2. Scenario 1: IPv6 underlay with IPv6 overlay

This is the primary deployment model: an IPv6 underlay carrying an IPv6 overlay.

### Router A

```text
configure

set interfaces ethernet eth1 address 2001:db8:10::1/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 address 2001:db8:42::1/64

commit
save
exit
```

### Router B

```text
configure

set interfaces ethernet eth1 address 2001:db8:10::2/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::2
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::1
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 address 2001:db8:42::2/64

commit
save
exit
```

The explicit `mtu 1430` is the family default for a standard untagged 1500-byte IPv6 path. It can
be omitted; set it explicitly when the underlay path differs.

### Verify

On Router A:

```bash
ping6 -c 3 2001:db8:10::2
ip -j -d link show dev vxlan42
ip -6 addr show dev vxlan42
ping6 -c 3 2001:db8:42::2
```

On Router B, use A's addresses in the same checks. The JSON form should report the tunnel with
`local6`, `remote6`, `id`, and `port` matching the configuration. Use `ip -j -d`, not the
human-readable `ip -d` form; the vendor build corrupts numeric fields in the latter.

`show interfaces` is useful for the interface state, but some EdgeOS views emphasize the IPv4
address. Use `ip -6 addr show dev vxlan42` when the IPv6 overlay address matters.

## 3. Scenario 2: IPv6 underlay with bridged Ethernet

A bridged VXLAN carries Ethernet. The VXLAN interface is a bridge port and has no Layer 3 address of
its own. The bridge holds the Layer 3 address.

### Router A

```text
configure

set interfaces ethernet eth1 address 2001:db8:10::1/64

set interfaces bridge br42 address 2001:db8:42::1/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 bridge-group bridge br42
set interfaces vxlan vxlan42 bridge-group cost 200
set interfaces vxlan vxlan42 bridge-group priority 10

commit
save
exit
```

### Router B

```text
configure

set interfaces ethernet eth1 address 2001:db8:10::2/64

set interfaces bridge br42 address 2001:db8:42::2/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::2
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::1
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 bridge-group bridge br42
set interfaces vxlan vxlan42 bridge-group cost 200
set interfaces vxlan vxlan42 bridge-group priority 10

commit
save
exit
```

Bridge membership, path cost, and port priority are mutable and survive interface recreation and
rollback. `cost` accepts `1-65535`; `priority` accepts `0-63`. If omitted, the port is reconciled to
the EdgeOS defaults (`100` and `32` respectively).

A VXLAN interface cannot have both a direct `address` and `bridge-group bridge`. Put Layer 3
addressing on the bridge. Bridged VXLAN interfaces reject `firewall` attachments: this release does
not enable bridge netfilter and does not claim Layer 2 firewall enforcement for bridged traffic.

### Verify

```bash
ip -j -d link show dev vxlan42
bridge link show dev vxlan42
bridge fdb show dev vxlan42
ip -6 addr show dev br42
ip -6 neigh show dev br42
ping6 -c 3 2001:db8:42::2
```

For a dual-stack bridged overlay, add an IPv4 address to `br42` on both routers; the VXLAN endpoint
family remains independent of the bridge's Layer 3 families.

### Legacy IPv4-underlay bridged variant

The bridged model is independent of the underlay family. For a legacy IPv4 underlay, use IPv4 VTEP
endpoints and an IPv4 bridge address; the rest of the bridge configuration is unchanged.

Router A:

```text
configure

set interfaces ethernet eth1 address 192.0.2.1/24
set interfaces bridge br42 address 198.51.100.1/30

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450
set interfaces vxlan vxlan42 bridge-group bridge br42
set interfaces vxlan vxlan42 bridge-group cost 200
set interfaces vxlan vxlan42 bridge-group priority 10

commit
save
exit
```

Router B mirrors this with `192.0.2.2/24` on the underlay, `local-ip 192.0.2.2`,
`remote-ip 192.0.2.1`, and `198.51.100.2/30` on `br42`.

## 4. Scenario 3: IPv6 underlay with a dual-stack overlay

The underlay is IPv6. The overlay carries both IPv6 and IPv4 addresses on the same VXLAN interface.
This is a deployment choice; it is not required by the implementation.

### Router A

```text
configure

set interfaces ethernet eth1 address 2001:db8:10::1/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 address 2001:db8:42::1/64
set interfaces vxlan vxlan42 address 198.51.100.1/30

commit
save
exit
```

### Router B

```text
configure

set interfaces ethernet eth1 address 2001:db8:10::2/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::2
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::1
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 address 2001:db8:42::2/64
set interfaces vxlan vxlan42 address 198.51.100.2/30

commit
save
exit
```

### Verify

```bash
ip -6 addr show dev vxlan42
ip addr show dev vxlan42
ping6 -c 3 2001:db8:42::2
ping -c 3 198.51.100.2
```

The overlay firewall families are independent of the underlay family. Both `firewall in name` and
`firewall in ipv6-name` can be attached at the same time. See the
[native firewall guide](native-firewall.md).

## 5. Scenario 4: IPv4 underlay with IPv6 overlay

This is the interoperability case for an IPv6 overlay transported over an IPv4 underlay. The VTEP
endpoints are IPv4; the inner Layer 3 protocol is IPv6.

### Router A

```text
configure

set interfaces ethernet eth1 address 192.0.2.1/24

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450
set interfaces vxlan vxlan42 address 2001:db8:42::1/64

commit
save
exit
```

### Router B

```text
configure

set interfaces ethernet eth1 address 192.0.2.2/24

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 192.0.2.2
set interfaces vxlan vxlan42 remote-ip 192.0.2.1
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450
set interfaces vxlan vxlan42 address 2001:db8:42::2/64

commit
save
exit
```

### Verify

```bash
ip -j -d link show dev vxlan42
ip -6 addr show dev vxlan42
ping6 -c 3 2001:db8:42::2
```

The outer IP header is IPv4, so the overhead is 50 bytes and the family default is 1450. The inner
IPv6 link still needs at least 1280 bytes; 1450 satisfies that on a 1500-byte IPv4 underlay.

Underlay peer filtering uses an IPv4 `firewall name` ruleset on the underlay interface. An IPv6
overlay policy uses `firewall ipv6-name` on the VXLAN interface. The two policies inspect different
packets: outer UDP/4789 versus decapsulated inner IPv6.

### End-to-end example: routed IPv6 overlay over an IPv4 underlay

This example is deliberately generic. The remote VTEP is managed by the tunnel provider, so only the
router side is shown. Replace the addresses with the provider's transfer subnet, routed allocation
and peer address.

Assume:

* IPv4 Internet underlay on `eth1`, router address `192.0.2.10/24`, gateway `192.0.2.1`;
* provider VTEP `192.0.2.2`, VNI `5002`, UDP port `4789`;
* IPv6 transfer subnet `2001:db8:5002::/64`, provider transfer address `2001:db8:5002::1`;
* routed IPv6 allocation `2001:db8:5002:100::/56`, routed via the transfer address;
* the router provides IPv6-only transit; inner IPv4 is blocked.

Underlay peer filtering for outer UDP/4789 on `eth1`:

```text
set firewall name VXLAN_UNDERLAY4 default-action accept
set firewall name VXLAN_UNDERLAY4 description 'Restrict VXLAN underlay peer'
set firewall name VXLAN_UNDERLAY4 rule 10 action accept
set firewall name VXLAN_UNDERLAY4 rule 10 protocol udp
set firewall name VXLAN_UNDERLAY4 rule 10 source address 192.0.2.2
set firewall name VXLAN_UNDERLAY4 rule 10 destination port 4789
set firewall name VXLAN_UNDERLAY4 rule 20 action drop
set firewall name VXLAN_UNDERLAY4 rule 20 protocol udp
set firewall name VXLAN_UNDERLAY4 rule 20 destination port 4789
set interfaces ethernet eth1 firewall local name VXLAN_UNDERLAY4
```

The routed VXLAN interface and overlay address:

```text
set interfaces vxlan vxlan5002 vni 5002
set interfaces vxlan vxlan5002 local-ip 192.0.2.10
set interfaces vxlan vxlan5002 remote-ip 192.0.2.2
set interfaces vxlan vxlan5002 port 4789
set interfaces vxlan vxlan5002 mtu 1450
set interfaces vxlan vxlan5002 address 2001:db8:5002::2/64
set protocols static route6 2001:db8:5002:100::/56 next-hop 2001:db8:5002::1
```

IPv6 overlay ingress policy. This example permits all ICMPv6 so Neighbor Discovery, Path MTU
Discovery and error signalling work; tighten it with type-specific rules if your policy requires
that. Inner IPv4 is explicitly blocked because this deployment is IPv6-only transit:

```text
set firewall ipv6-name VXLAN6_IN default-action drop
set firewall ipv6-name VXLAN6_IN rule 10 action accept
set firewall ipv6-name VXLAN6_IN rule 10 description 'IPv6 ICMPv6: ND, PMTUD and errors'
set firewall ipv6-name VXLAN6_IN rule 10 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 20 action accept
set firewall ipv6-name VXLAN6_IN rule 20 state established enable
set firewall ipv6-name VXLAN6_IN rule 20 state related enable
# Add the services this router or its downstream networks may receive here.

set firewall name VXLAN4_IN default-action drop
set firewall name VXLAN4_IN description 'Inner IPv4 is not part of this transit service'

set interfaces vxlan vxlan5002 firewall in ipv6-name VXLAN6_IN
set interfaces vxlan vxlan5002 firewall in name VXLAN4_IN
```

If the router itself terminates IPv6 services over the tunnel, add a separate `local` ruleset with
the ICMPv6, established/related and management rules that the router needs; do not rely on the
forwarded-ingress ruleset for router-destined traffic.

The IPv4 underlay adds 50 bytes of overhead, so a 1500-byte underlay path gives a VXLAN MTU of
1450. One outer 802.1Q tag reduces that by 4 bytes. Clamp TCP MSS if the deployment
requires it; the MTU setting alone is not an MSS clamp.

Verification:

```bash
show configuration commands | grep vxlan5002
show interfaces
show firewall ipv6-name VXLAN6_IN
show firewall name VXLAN4_IN
sudo iptables-save -t filter | grep vxlan5002
sudo ip6tables-save -t filter | grep vxlan5002
ip -j -d link show dev vxlan5002
ip -6 neigh show dev vxlan5002
ip -6 route show 2001:db8:5002:100::/56
```

From an external host, verify that the transfer address and an address from the routed /56 are
reachable, that NDP resolves, that a permitted IPv6 service works, that a denied IPv6 port is
blocked, that inner IPv4 is blocked, and that an outer UDP/4789 probe from another source is blocked
by `VXLAN_UNDERLAY4` before decapsulation.

## 6. Scenario 5: IPv6 underlay with IPv4 overlay

This is the interoperability case for an IPv4 overlay transported over an IPv6 underlay. The VTEP
endpoints are IPv6; the inner Layer 3 protocol is IPv4.

### Router A

```text
configure

set interfaces ethernet eth1 address 2001:db8:10::1/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 address 198.51.100.1/30

commit
save
exit
```

### Router B

```text
configure

set interfaces ethernet eth1 address 2001:db8:10::2/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::2
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::1
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 address 198.51.100.2/30

commit
save
exit
```

### Verify

```bash
ip -j -d link show dev vxlan42
ip addr show dev vxlan42
ping -c 3 198.51.100.2
```

The outer IPv6 header adds 70 bytes of overhead. The inner IPv4 payload fits in 1430 bytes on a
1500-byte underlay path. Do not assume that an IPv4 overlay makes IPv6 operational concerns
irrelevant: the outer path still depends on IPv6 reachability, Neighbor Discovery, and ICMPv6
Packet Too Big handling.

## 7. Scenario 6: IPv4 underlay with IPv4 overlay (legacy)

This is the compatibility case for an IPv4 underlay with an IPv4 overlay. It preserves the behaviour
of existing v0.2.x deployments. To carry both overlay families, add the dual-stack addresses from
scenario 3; the support matrix records that variant as row 7, implemented but not separately
hardware-qualified.

### Router A

```text
configure

set interfaces ethernet eth1 address 192.0.2.1/24

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450
set interfaces vxlan vxlan42 address 198.51.100.1/30

commit
save
exit
```

### Router B

```text
configure

set interfaces ethernet eth1 address 192.0.2.2/24

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 192.0.2.2
set interfaces vxlan vxlan42 remote-ip 192.0.2.1
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450
set interfaces vxlan vxlan42 address 198.51.100.2/30

commit
save
exit
```

### Verify

```bash
ip -j -d link show dev vxlan42
ip addr show dev vxlan42
ping -c 3 198.51.100.2
```

Existing IPv4 configurations with canonical literals keep their meaning. Non-canonical IPv4
literals follow the platform's octal interpretation and are never silently rebound as decimal; see
the endpoint rules in [`architecture.md`](architecture.md#5-vtep-endpoint-rules).

## 8. IPv6 operational considerations

### 8.1 Path MTU Discovery and ICMPv6 Packet Too Big

IPv6 routers do not fragment packets in transit. Path MTU Discovery (RFC 8201) depends on ICMPv6
Packet Too Big (type 2, RFC 4443) reaching the sender. If an underlay or overlay firewall drops
Packet Too Big, large packets blackhole while small packets continue to work.

There are two PMTUD scopes, and they must not be conflated:

* **Underlay PMTUD.** The outer IPv6 path between the VTEPs discovers its path MTU. Underlay
  routers send Packet Too Big to the VTEP; the VTEP must be able to receive it, and the VXLAN MTU
  must fit inside the resulting path. The integration does not fragment oversized outer packets.
* **Overlay PMTUD.** Inner IPv6 hosts and routers discover the overlay path MTU end to end. Their
  Packet Too Big messages travel inside the tunnel, so the overlay firewall must permit them. The
  VXLAN MTU bounds the inner IP packet; the inner Ethernet header is additional encapsulation
  overhead, not part of that MTU.

Operational rules:

* Permit ICMPv6 Packet Too Big on the underlay path and through the overlay policy where the
  router or downstream hosts need it.
* Size the VXLAN MTU for the underlay path; do not rely on oversized outer packets being fragmented.
* If the path MTU changes, update the VXLAN `mtu` deliberately. The integration does not track it.
* Clamp TCP MSS where the deployment requires it; setting the interface MTU is not an MSS clamp.

The v0.3.0 implementation does not set an outer `ignore_df` flag or otherwise force outer IPv6
fragmentation. The kernel may fragment inner packets after PMTU feedback, but that is a recovery
mechanism, not a design substitute for correct sizing.

### 8.2 Neighbor Discovery

Neighbor Discovery (RFC 4861) resolves both the underlay peer and overlay peers:

* Underlay: Router A must resolve Router B's underlay address to send outer UDP/4789 packets.
* Overlay: hosts on the emulated Ethernet segment use NS/NA to resolve each other.

Permit Neighbor Solicitation and Neighbor Advertisement (ICMPv6 types 135 and 136) in any firewall
policy that would otherwise drop them. If Router Advertisement and Stateless Address
Autoconfiguration are used, also permit Router Solicitation and Router Advertisement (types 133 and
134) as appropriate. Do not block all ICMPv6 to “harden” an IPv6 interface; that breaks ND, PMTUD,
and often the tunnel itself.

### 8.3 Router Advertisements and SLAAC

The validated deployment model uses static `local-ip` and `remote-ip` addresses. SLAAC or DHCPv6
can supply an underlay address, but this project does not track a delegated-prefix change or
guarantee that a dynamically arriving underlay address is present before the saved configuration is
replayed at boot. Dynamic underlay arrival at boot has not been validated.

If the underlay address is dynamic:

* verify that the address exists before committing the VXLAN configuration;
* expect to update `local-ip`/`remote-ip` manually after a prefix change;
* keep an independent management path;
* do not interpret a successful reboot with a still-present prefix as validation of a prefix-change
  or late-arrival scenario.

Router Advertisement on the overlay is a separate design decision. If the router advertises an
overlay prefix, plan the ND/RA policy and the interaction with the overlay firewall; it is not
required to use VXLAN.

### 8.4 IPv6 minimum MTU

IPv6 requires a link MTU of at least 1280 bytes (RFC 8200). With 70 bytes of VXLAN overhead, an
underlay path must be at least 1350 bytes to leave a 1280-byte IPv6 overlay MTU. On a standard
1500-byte path the default 1430 is comfortably above the minimum. On a smaller path, calculate the
overlay MTU and check that it still meets 1280; do not treat the kernel's VXLAN minimum of 68 as an
IPv6 deployment target.

### 8.5 Source address selection

The outer source address is the configured `local-ip`. If `local-ip` is unspecified (`::` or
`0.0.0.0`), the kernel selects a source according to its address-selection rules (RFC 6724). The
remote VTEP must have a return route to that source address.

For deterministic deployments, configure a specific `local-ip` that is assigned to the router and
reachable from the peer. Avoid asymmetric underlay routing where the return path to the selected
source differs from the forward path in a way the peer cannot route. Check with:

```bash
ip -6 route get 2001:db8:10::2 from 2001:db8:10::1
ip -6 route get 2001:db8:10::1
```

### 8.6 Endpoint scope and validation

The endpoint rules are part of the commit validation, not documentation advice. In summary:

* Accept IPv4/IPv4 and IPv6/IPv6 pairs; reject mixed families.
* Reject prefixes, hostnames, zone identifiers, and bracketed forms for either family.
* For IPv6, reject multicast, loopback, IPv4-mapped, and link-local endpoints; reject an unspecified
  remote; accept an unspecified local.
* IPv4 endpoint acceptance is unchanged from v0.2.x. The IPv6 class checks do not apply to IPv4; do
  not use the validator as an IPv4 scope filter.
* Accept global unicast and ULA IPv6 addresses.
* Compare canonical forms so an equivalent re-spelling does not recreate the interface.

See [`architecture.md`](architecture.md#5-vtep-endpoint-rules) for the full table.

### 8.7 UDP checksum behaviour

IPv6 UDP checksums are enabled by default. The integration passes no `udp6zerocsumtx` or
`udp6zerocsumrx` option and exposes no zero-checksum control. On the validated target, the IPv6
VXLAN was reported with the UDP checksum enabled and both zero-checksum options disabled (see
[`issue-3-hardware-evidence.md`](issue-3-hardware-evidence.md)); that is the target's
default behaviour, not a new configuration. RFC 6935 and RFC 6936 discuss zero-checksum exceptions
for tunnel protocols; this implementation does not rely on them.

Local `tcpdump` captures can show apparently invalid UDP checksums while checksum offload is
enabled. Treat that as a capture artifact unless there is independent evidence of a dataplane
fault. Keep offload enabled and do not disable checksums to make a capture look clean.

### 8.8 Firewall policy and VTEP exposure

Keep the two policy layers separate: the underlay `firewall local` policy filters outer UDP/4789
and is where the VTEP source is restricted; the overlay `firewall in`/`out`/`local` attachments see
decapsulated inner traffic. `remote-ip` is not an ingress allowlist, and VXLAN provides no
authentication or confidentiality.

Bridged VXLAN interfaces reject firewall attachments; bridge netfilter is not enabled and Layer 2
enforcement is not claimed. The EdgeOS 3.0.1 scripted-commit limitation applies to both address
families, so make firewall ruleset changes interactively. Syntax, lifecycle and verification are in
[`native-firewall.md`](native-firewall.md); the support boundary is in
[`v0.3.0-support-boundary.md`](v0.3.0-support-boundary.md).

### 8.9 Fragmentation

Outer IPv6 packets are not fragmented by this path; the integration relies on correct MTU sizing
and PMTUD. Inner IPv4 packets may fragment, and inner IPv6 packets rely on their own PMTUD. Neither
is a substitute for configuring the VXLAN MTU correctly. If you observe large-packet loss with
working small packets, check the underlay path MTU, the VXLAN MTU, and whether ICMPv6 Packet Too
Big is permitted before changing unrelated settings.

### 8.10 Routing and asymmetric reachability

The tunnel is a fixed point-to-point association. The remote VTEP must be reachable from the
configured local address, and the return path must reach that address. A default route that points
the remote VTEP back through the tunnel, a missing return route, or an asymmetric policy-routing
choice can produce a tunnel that looks up but carries no traffic. Check the underlay route and the
source-specific route before changing the VXLAN configuration.

This project does not implement dynamic peer discovery, multiple remote VTEPs, or a routing control
plane. A routing change on the underlay is an operator action.

### 8.11 Overlay multicast and link-local traffic

VXLAN transports Ethernet frames. Overlay broadcast and multicast frames, including IPv6 Neighbor
Discovery and Router Advertisements, are carried as encapsulated Ethernet to the configured remote
VTEP. This project does not configure an underlay multicast group; it uses the fixed-remote unicast
model. Link-local IPv6 addresses inside the overlay are ordinary overlay addresses; link-local
addresses are rejected only as VTEP endpoints.

### 8.12 Management-plane connectivity

The VXLAN dataplane and the router management plane are separate. Do not make management access
depend on the tunnel being up. Keep a physical, VLAN, or console path available, especially while
changing underlay addressing, firewall policy, or MTU.

## 9. IPv6-only deployability

The VXLAN dataplane has been validated with IPv6-only addresses: IPv6 underlay with IPv6 overlay,
and IPv6 underlay with a dual-stack overlay. The isolated Level B namespace environment additionally
removes usable external IPv4 connectivity from the workload and asserts that removal with negative
controls; see [`ipv6-only-qualification.md`](ipv6-only-qualification.md). This still does not mean an
entirely IPv4-free operational environment was validated: the hardware runs did not remove IPv4
from router management, the peer host, the test tooling or CI, and the CI runner remains
dual-stack. "IPv6-only dataplane" therefore means the tunnel dataplane used only IPv6 addresses;
Level B is a property of the isolated workload environment.

The per-area status, evidence classes and gaps are recorded in the
[IPv6-only deployment matrix](address-family-support-matrix.md#4-ipv6-only-deployment-matrix).
In summary: the dataplane is validated; the Level B isolated namespace environment is validated at
the general-Linux evidence class; Level C (installation and management over IPv6 only) and Level D
(an IPv6-only runner and CI control plane) are not validated. Diagnostics are available with the
`ip -j -d` caveat. Complete IPv6-only installation, management and CI infrastructure remain
engineering gaps, not validated features.

## 10. Verification and troubleshooting

### 10.1 Common checks

```bash
show configuration commands | grep -A12 'vxlan vxlan42'
ip -j -d link show dev vxlan42
ip -6 addr show dev vxlan42
ip addr show dev vxlan42
ip -6 route get 2001:db8:42::2
ip route get 198.51.100.2
ping6 -c 3 2001:db8:42::2
ping -c 3 198.51.100.2
ip -s link show dev vxlan42
```

For a bridged deployment, also check:

```bash
bridge link show dev vxlan42
bridge fdb show dev vxlan42
ip -6 neigh show dev br42
```

For firewall attachments, the authoritative state is the live netfilter dispatch:

```bash
show firewall ipv6-name <ruleset>
show firewall name <ruleset>
sudo iptables-save -t filter | grep vxlan42
sudo ip6tables-save -t filter | grep vxlan42
```

### 10.2 Symptom guide

| Symptom | Check |
|---|---|
| Tunnel is up but no overlay traffic | Underlay ping, VNI, UDP port, remote VTEP configuration, underlay return route, firewall counters. |
| Small packets work; large packets fail | Underlay path MTU, VXLAN `mtu`, ICMPv6 Packet Too Big reachability, inner PMTUD, MSS clamp if needed. |
| IPv6 overlay cannot resolve peers | Allow NS/NA (and RS/RA if used), check bridge/FDB and `ip -6 neigh`. |
| Interface is recreated on every commit | Compare canonical endpoint spellings, check that `local-ip` is assigned, and inspect `ip -j -d` for identity fields. |
| `ip -d link show` shows wrong VNI or port | Use `ip -j -d link show`; the human-readable output is defective on this platform. |
| Commit fails after an interface change | Do not `save`; compare `show configuration commands` with the kernel and re-converge. |
| IPv6-only management fails after a change | Use the independent management/console path; the VXLAN is not a management transport. |

### 10.3 What not to infer

A successful ping does not prove firewall policy, IPv6-only installability, dynamic-prefix
behaviour, or hardware offload. The evidence classes and the remaining gaps are recorded in
[`address-family-support-matrix.md`](address-family-support-matrix.md). The historical records
remain the authority for the exact hardware sessions they describe; do not read a later
qualification report back into an earlier candidate record.

## 11. Related documents

* [`../README.md`](../README.md) — installation, feature summary, current limitations.
* [`architecture.md`](architecture.md) — layer model, scope, standards.
* [`address-family-support-matrix.md`](address-family-support-matrix.md) — implementation and
  validation evidence by combination.
* [`native-firewall.md`](native-firewall.md) — firewall and underlay security semantics.
* [`interface-lifecycle.md`](interface-lifecycle.md) — reconciliation, rollback and persistence.
* [`audit/2026-11-documentation-audit.md`](audit/2026-11-documentation-audit.md) — point-in-time
  audit and final-review record.
* [`engineering-backlog.md`](engineering-backlog.md) — repository-local engineering proposals.
* [`v0.3.0-support-boundary.md`](v0.3.0-support-boundary.md) — firewall workflow boundary.
* [`v0.3.0-hardware-qualification-report.md`](v0.3.0-hardware-qualification-report.md) — RC5
  hardware qualification record.
