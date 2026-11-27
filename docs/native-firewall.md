# Native interface firewall and underlay security


This document is the canonical description of the package's firewall attachment and underlay peer
filtering. It covers the EdgeOS `interfaces vxlan ... firewall` subtree, the lifecycle and
fail-closed behavior, the underlay/overlay policy boundary, and the supported and unsupported
enforcement cases. Deployment scenarios are in [`deployment.md`](deployment.md); interface
reconciliation is in [`interface-lifecycle.md`](interface-lifecycle.md); validation evidence is in
[`address-family-support-matrix.md`](address-family-support-matrix.md).


## Underlay peer filtering and trust


`remote-ip` configures the normal outbound VXLAN destination. It is not an inbound peer allowlist
and does not authenticate a sender.

Hardware testing on the supported EdgeRouter X confirmed that a VNI 42 VXLAN interface configured
with one `remote-ip` still accepted and decapsulated valid VNI 42 packets arriving from a different
underlay source address. The project therefore does not treat `remote-ip` as a security boundary
for either address family.

### Restricting a fixed VXLAN peer (IPv6 underlay)

For a fixed-peer IPv6 deployment, an EdgeOS IPv6 `local` firewall policy on the underlay interface
can restrict UDP/4789 to the intended remote VTEP. If the underlay interface already has a local
IPv6 policy (for example a VLAN ruleset with a default drop), extend that existing ruleset with the
VXLAN rules; do not replace it, and keep the management path in mind.

```text
configure

set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 default-action accept

set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 action accept
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 description 'Allow configured VXLAN peer'
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 protocol udp
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 source address 2001:db8:10::2
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 destination port 4789

set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 action drop
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 description 'Drop other VXLAN senders'
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 protocol udp
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 destination port 4789

set interfaces ethernet eth1 firewall local ipv6-name VXLAN_UNDERLAY_LOCAL6

commit
save
exit
```

The example deliberately uses `default-action accept`; it restricts VXLAN traffic without changing
the treatment of unrelated traffic destined for the router on that interface. If you extend an
existing default-drop policy instead, also permit the ICMPv6 messages the underlay needs: Neighbor
Solicitation/Advertisement (types 135/136) and Packet Too Big (type 2). A policy that drops all
ICMPv6 can break Neighbor Discovery and PMTUD.

On the supported EdgeRouter X, the IPv6 underlay was validated with an extension of the existing
local IPv6 ruleset (default drop) in place; the tunnel, its IPv6 overlay, and its dual-stack overlay
traffic continued to work. The alternate-source IPv6 drop path is not separately produced in the
published record; see the [support matrix](address-family-support-matrix.md).

### Restricting a fixed VXLAN peer (IPv4 underlay, legacy)

For an IPv4 fixed-peer deployment, the same restriction uses an IPv4 `name` ruleset. For example,
if the VXLAN underlay uses `eth1` and the intended remote VTEP is `192.0.2.2`:

```text
configure

set firewall name VXLAN_UNDERLAY_LOCAL default-action accept
set firewall name VXLAN_UNDERLAY_LOCAL description 'Restrict VXLAN underlay peers'

set firewall name VXLAN_UNDERLAY_LOCAL rule 10 action accept
set firewall name VXLAN_UNDERLAY_LOCAL rule 10 description 'Allow configured VXLAN peer'
set firewall name VXLAN_UNDERLAY_LOCAL rule 10 protocol udp
set firewall name VXLAN_UNDERLAY_LOCAL rule 10 source address 192.0.2.2
set firewall name VXLAN_UNDERLAY_LOCAL rule 10 destination port 4789

set firewall name VXLAN_UNDERLAY_LOCAL rule 20 action drop
set firewall name VXLAN_UNDERLAY_LOCAL rule 20 description 'Drop other VXLAN senders'
set firewall name VXLAN_UNDERLAY_LOCAL rule 20 protocol udp
set firewall name VXLAN_UNDERLAY_LOCAL rule 20 destination port 4789

set interfaces ethernet eth1 firewall local name VXLAN_UNDERLAY_LOCAL

commit
save
exit
```

If the VXLAN underlay is carried on a VLAN or another EdgeOS interface type, attach the same
`local` ruleset to that interface instead. This policy also uses `default-action accept` for the
same reason: it restricts VXLAN traffic without changing unrelated traffic handling.

On the supported EdgeRouter X, this IPv4 behaviour was validated with a VXLAN interface configured
for one `remote-ip`:

* packets from the configured peer were accepted and decapsulated;
* otherwise identical VNI-matching packets from another underlay source were accepted before
  filtering;
* after applying the policy above, packets from the configured peer remained accepted;
* packets from the alternate source were dropped before reaching the VXLAN interface.

`edgeos-vxlan` does not automatically create or modify firewall policy. Underlay filtering remains an
explicit deployment responsibility.

This is a source-address allowlist, not cryptographic authentication. On an untrusted or spoofable
underlay, use an authenticated and encrypted transport when peer authenticity or confidentiality is
required.


## Overlay firewall attachments


`interfaces vxlan vxlanN firewall ...` attaches ordinary EdgeOS `firewall name` and
`firewall ipv6-name` rulesets to the traffic carried by the VXLAN interface. The attachment is applied
by the stock EdgeOS `ubnt-fw` engine to the decapsulated inner traffic; it is not a filter on the outer
UDP transport.

This is the native alternative to maintaining independent iptables scripts or startup hooks. The
package attaches operator-owned policies; it never creates permissive or restrictive rulesets, and it
does not infer trust from interface addressing.

### Syntax

```text
set interfaces vxlan vxlan42 firewall in ipv6-name VXLANv6_IN
set interfaces vxlan vxlan42 firewall in name VXLAN_IN

set interfaces vxlan vxlan42 firewall out ipv6-name VXLANv6_OUT
set interfaces vxlan vxlan42 firewall out name VXLAN_OUT

set interfaces vxlan vxlan42 firewall local ipv6-name VXLANv6_LOCAL
set interfaces vxlan vxlan42 firewall local name VXLAN_LOCAL
```

| Direction | Native hook | Matches | Meaning |
|---|---|---|---|
| `in` | `FORWARD`, `VYATTA_FW_IN_HOOK` | `-i vxlanN` | forwarded packets arriving on the VXLAN interface |
| `out` | `FORWARD`, `VYATTA_FW_OUT_HOOK` | `-o vxlanN` | forwarded packets leaving the VXLAN interface |
| `local` | `INPUT`, `VYATTA_FW_LOCAL_HOOK` | `-i vxlanN` | packets destined for the router itself |

`ipv6-name` is an IPv6 ruleset; `name` is an IPv4 ruleset. The overlay policy family is independent
of the underlay family and both overlay families may be active at the same time. A VXLAN interface
can therefore use an IPv6 underlay with IPv4-only inner policy, an IPv4 underlay with IPv6-only inner
policy, or any other combination. The primary IPv6-underlay example is
[deployment scenario 1](deployment.md#2-scenario-1-ipv6-underlay-with-ipv6-overlay);
the dual-stack variant is
[deployment scenario 3](deployment.md#4-scenario-3-ipv6-underlay-with-a-dual-stack-overlay).

`out` follows native EdgeOS semantics: it matches **forwarded** traffic leaving the interface. Traffic
originated by the router itself is handled by `OUTPUT` and is not matched by `firewall out`.

### Policy ownership and validation

* The rulesets must already exist under `firewall name` / `firewall ipv6-name`.
* A missing ruleset, a mixed direction/family, an unsafe ruleset name, or a bridge-port attachment is
  rejected at commit time, before any interface or firewall change.
* Tab completion lists the configured rulesets of the matching family.
* The package does not create, rename, or delete rules. A ruleset still referenced by an attachment
  cannot be deleted by the EdgeOS engine.
* Firewall policy on other interfaces, NAT, routing, conntrack state and hardware offload is not
  modified.

### Lifecycle and failure behavior

The attachment is part of the interface's desired operational state:

1. The reconciler captures the current live firewall dispatch.
2. It applies the complete desired attachment set through `ubnt-fw` and verifies every jump with
   `iptables -C` / `ip6tables -C`.
3. It creates or recreates the netdevice only after the desired dispatch is in place.
4. Immediately before bringing the interface up it verifies the required attachments again.

If a **new** attachment cannot be established on an already-operational interface, the helper restores
the pre-change dispatch and takes the interface administratively down; the commit fails with an
explicit error. If a **replacement** fails, the previous dispatch remains in place and the interface
stays up, still protected by the previous policy.

On a failed recreation, the previous netdevice state **and** the previous firewall dispatch are
restored. If the dispatch cannot be reconstructed, the interface is left down and the commit fails;
the integration does not bring up an interface with an unknown policy.

On interface deletion, the netdevice is removed first and its dispatches are removed afterwards. If
the netdevice deletion fails, the still-live interface and its dispatch remain. If the netdevice is
gone but dispatch removal fails, the interface is already absent and stale jumps may remain; the
helper reports the error, and the stale dispatch may require manual reconciliation.

All of this is bounded by the EdgeOS commit engine: commits are not atomic, and a failed commit can
still write the successful part of the configuration. Follow the existing rule: after a failed
commit, do not `save`; compare the active configuration with the kernel and re-commit the correct
values first.

### Routed and bridged operation

Routed VXLAN interfaces support the full `in`/`out`/`local` attachment set described above.

Bridged VXLAN interfaces **reject** firewall attachments. A frame forwarded by the Linux bridge
between two ports is not seen by the routed `FORWARD` chain with `-i <vxlan-port>`; with bridge
netfilter the logical input is the bridge device, and enabling `br_netfilter` would change the
handling of all bridged traffic on the router. A port attachment would therefore look like
enforcement while leaving L2-forwarded traffic unfiltered. This release does not enable bridge
netfilter or claim bridged L2 firewall enforcement. Existing bridge functionality is unchanged.

### Underlay and overlay boundaries

Keep the four security concerns distinct:

* **Transport reachability** — the route to the remote VTEP. `remote-ip` sets the normal outbound
  destination; it is not an authenticated peer identity or an ingress allowlist.
* **Underlay peer filtering** — a `firewall local` policy on the physical/VLAN interface carrying the
  outer UDP/4789 traffic. This is where you restrict which underlay source may send VXLAN packets.
* **Overlay firewall enforcement** — `firewall in`/`out`/`local` on the VXLAN interface, which sees the
  decapsulated inner traffic.
* **Cryptographic authentication and confidentiality** — not provided by VXLAN. Use IPsec or another
  authenticated transport where required.

An overlay attachment does not filter the outer VXLAN transport, and an underlay policy does not
filter the inner traffic. Both are needed for a complete deployment.


For an end-to-end routed deployment with an IPv4 underlay, an IPv6 overlay and an
underlay peer filter, see the tunnelbroker example in [`deployment.md`](deployment.md#5-scenario-4-ipv4-underlay-with-ipv6-overlay).


### Verification and troubleshooting

The authoritative state is the live netfilter dispatch, not just the configuration text:

```bash
show configuration commands | grep -A6 'vxlan vxlan42'
show firewall name VXLAN_IN
show firewall ipv6-name VXLANv6_IN
sudo iptables-save -t filter | grep vxlan42
sudo ip6tables-save -t filter | grep vxlan42
ip -j -d link show dev vxlan42
```

The expected dispatch is one jump per configured direction/family, for example:

```text
-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN
-A VYATTA_FW_OUT_HOOK -o vxlan42 -j VXLAN_OUT
-A VYATTA_FW_LOCAL_HOOK -i vxlan42 -j VXLAN_LOCAL
```

If the interface is up but a configured jump is missing, the commit-time gate has not been satisfied;
the commit should have failed. If the interface was brought up by an older package or the jump was
removed out-of-band, commit the interface again to reconcile it, or take the interface down until the
policy is restored.

### Workflow limits

Firewall ruleset changes must be made in the interactive EdgeOS CLI on this platform. A scripted
(script-template) commit can misapply `firewall name`/`ipv6-name` changes; the package cannot make a
scripted commit safe. The package manages enforcement during its own configuration lifecycle and is
not a continuous firewall integrity monitor. Boot-time restoration was verified on the qualified
build. See [`v0.3.0-support-boundary.md`](v0.3.0-support-boundary.md) and
[`v0.3.0-edgeos-scripted-commit-limitation.md`](v0.3.0-edgeos-scripted-commit-limitation.md).

### Hardware validation status

The native attachment path has been exercised against the official EdgeOS 3.0.1 configuration engine
under emulation and in Linux network namespaces. The RC5 hardware qualification on the ER-X then
completed the isolated six-combination dataplane matrix, the lifecycle scenarios, interrupted
transactions, the `vxlan41913` migration and saved-configuration reboot; the final v0.3.0 runtime
payload is byte-identical to RC5. Independent external OCI probes remain **deferred**. See
[`v0.3.0-hardware-qualification-report.md`](v0.3.0-hardware-qualification-report.md).

The emulated and namespace results are not a substitute for hardware. The hardware record defines the
qualified scope; do not extend it to the deferred external probes.
