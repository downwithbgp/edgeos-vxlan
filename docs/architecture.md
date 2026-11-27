# Architecture and address-family model

**Status:** current architecture note for `edgeos-vxlan` v0.3.0.
**Platform:** Ubiquiti EdgeRouter X / ER-e50, EdgeOS 3.0.1, Linux `4.14.54-UBNT`.
**Scope:** this document defines the address-family model the documentation uses. It does not add
features or change the supported scope. Implementation and reproducible test evidence are
authoritative for product behaviour; this note explains how to read them.

## 1. Architectural position

IPv6 is the primary deployment model for new deployments. IPv4 remains supported for
interoperability and for existing deployments. Dual-stack operation is a deployment choice, not a
prerequisite for using this project. IPv6-only operation is supported where the implementation and
validation evidence allow it; the boundaries of that claim are recorded in
[`address-family-support-matrix.md`](address-family-support-matrix.md).

The implementation is a Linux VXLAN dataplane integration for EdgeOS. It is not a VXLAN control
plane, an EVPN implementation, or a dynamic tunnel manager.

## 2. Six distinct things

Discussions of “IPv4 VXLAN” or “IPv6 VXLAN” are ambiguous unless they name the layer. The following
layers are independent:

| Layer | What it is | Where it is configured | What determines its address family |
|---|---|---|---|
| Underlay transport | The routed path between the two VTEPs | The router's normal interface and routing configuration | The VTEP endpoint addresses |
| VTEP endpoint addressing | The local and remote outer addresses | `interfaces vxlan vxlanN local-ip` / `remote-ip` | IPv4 or IPv6; both endpoints must match |
| VXLAN encapsulation | Outer IP + UDP + VXLAN header around an inner Ethernet frame | The kernel VXLAN device | Follows the VTEP endpoints |
| Overlay Ethernet forwarding | The emulated Layer 2 segment (FDB, flooding, bridge membership) | Linux VXLAN/bridge dataplane | Family-independent; it forwards Ethernet |
| Overlay Layer 3 addressing | IPv4 and/or IPv6 addresses on the VXLAN interface or its bridge | `interfaces vxlan ... address` or `interfaces bridge ... address` | IPv4, IPv6, or both; independent of the underlay |
| Management-plane connectivity | SSH, NETCONF, DNS, package transfer, monitoring | The router's management interfaces | Independent of the VXLAN dataplane |

The distinction matters in both directions:

* An IPv6 underlay does not imply an IPv6 overlay. The overlay can carry IPv4, IPv6, both, or
  non-IP Ethertypes.
* An IPv6 overlay does not require an IPv6 underlay. IPv6 can be carried over an IPv4 VXLAN
  underlay.
* VXLAN does not translate protocols. It encapsulates an Ethernet frame; the inner Ethertype and
  the inner Layer 3 protocol are preserved.

## 3. What VXLAN transports

A VXLAN device takes an Ethernet frame from the overlay, adds a VXLAN header, encapsulates the
result in UDP and then in the outer IP header selected by the VTEP endpoint family, and sends it to
the remote VTEP's UDP port. The reverse path decapsulates and delivers the original Ethernet frame.

Consequences for this project:

* The outer IP version is selected by `local-ip`/`remote-ip`. The integration enforces that both
  endpoints are the same family.
* The inner frame can contain IPv4, IPv6, ARP, Neighbor Discovery, or any other Ethernet payload.
* The overlay MAC layer and the overlay Layer 3 addressing are separate. A bridged VXLAN can carry
  Ethernet without any IP address on the VXLAN interface itself.
* The VNI and UDP destination port are family-independent. VNI 42 over IPv6 and VNI 42 over IPv4
  are different tunnel instances because their outer endpoints differ.

## 4. Documented scenarios and order

The documentation uses the following order. The first example a new reader encounters is an
entirely IPv6-based deployment.

| Order | Underlay | Overlay | Purpose | Guide |
|---:|---|---|---|---|
| 1 | IPv6 | IPv6 | Primary deployment model | [Scenario 1](deployment.md#2-scenario-1-ipv6-underlay-with-ipv6-overlay) |
| 2 | IPv6 | Bridged Ethernet | Primary bridged model; Layer 3 addressing is on the bridge | [Scenario 2](deployment.md#3-scenario-2-ipv6-underlay-with-bridged-ethernet) |
| 3 | IPv6 | Dual-stack IPv6 + IPv4 | First-class dual-stack overlay over an IPv6 underlay | [Scenario 3](deployment.md#4-scenario-3-ipv6-underlay-with-a-dual-stack-overlay) |
| 4 | IPv4 | IPv6 | Interoperability: IPv6 overlay over an IPv4 underlay | [Scenario 4](deployment.md#5-scenario-4-ipv4-underlay-with-ipv6-overlay) |
| 5 | IPv6 | IPv4 | Interoperability: IPv4 overlay over an IPv6 underlay | [Scenario 5](deployment.md#6-scenario-5-ipv6-underlay-with-ipv4-overlay) |
| 6 | IPv4 | IPv4 | Legacy compatibility | [Scenario 6](deployment.md#7-scenario-6-ipv4-underlay-with-ipv4-overlay-legacy) |

The order is a documentation and design preference, not a restriction. Every combination above is
implemented by the same fixed-remote VXLAN dataplane; the evidence level differs by combination and
is recorded in the support matrix.

An IPv4 underlay with a dual-stack overlay is implemented as the scenario 6 underlay with the
dual-stack addressing from scenario 3. It is matrix row 7 and is not a separate scenario; it is not
separately hardware-qualified.

## 5. VTEP endpoint rules

`local-ip` and `remote-ip` are outer addresses, not overlay addresses. The implementation applies
these rules before any live state is changed:

| Rule | Behaviour |
|---|---|
| Same family | IPv4/IPv4 and IPv6/IPv6 are accepted; mixed families are rejected at commit time. |
| Literal only | Prefixes, hostnames, zone identifiers, and bracketed forms are rejected. |
| IPv6 scope | For IPv6, multicast, loopback, IPv4-mapped, and link-local addresses are rejected as VTEP endpoints. |
| Remote scope | For IPv6, an unspecified remote address is rejected. IPv4 endpoint acceptance is unchanged from v0.2.x; the IPv6 class checks do not apply to IPv4. |
| Local scope | An unspecified local address (`0.0.0.0` or `::`) is accepted and means “no specific local address”; the kernel selects the source. |
| Fixed remote | The remote endpoint is a single configured peer. Multiple remote VTEPs and learned peers are not supported. |
| Canonical comparison | Semantically equal spellings compare equal; an equivalent re-spelling does not recreate the interface. |

A link-local IPv6 address is not accepted as a VTEP endpoint because this integration configures a
fixed-remote VXLAN device without a lower-link `dev` argument or a scope identifier. Link-local
addresses inside the overlay are a different matter: they are ordinary overlay addresses and are
not restricted by the VTEP endpoint validation.

The class checks are implemented for IPv6 only. IPv4 endpoints are still checked for format and
family consistency, but IPv4 multicast, loopback, and unspecified addresses are not rejected by the
helper. Do not use the validator as an IPv4 scope filter. This asymmetry is tracked as
[ENG-IPV6-06](engineering-backlog.md#eng-ipv6-06-consistent-ipv4-and-ipv6-endpoint-validation).

Non-canonical IPv4 literals with leading-zero octets are parsed with the platform's octal semantics,
matching what the target `ip` binary binds; they are never silently rebound as decimal.

## 6. Encapsulation overhead and MTU

The VXLAN netdev MTU is the maximum **inner IP packet** size. It does not include the inner
Ethernet header; that header is part of the encapsulation overhead below. The underlay path MTU is a
separate value and is usually larger.

The outer packet size for a full-size inner Ethernet frame is:

| Component | IPv6 underlay | IPv4 underlay |
|---|---:|---:|
| Outer IP header | 40 bytes | 20 bytes |
| UDP header | 8 bytes | 8 bytes |
| VXLAN header | 8 bytes | 8 bytes |
| Inner Ethernet header | 14 bytes | 14 bytes |
| **Total overhead** | **70 bytes** | **50 bytes** |
| **Overlay IP MTU over a 1500-byte underlay** | **1430** | **1450** |

The calculation assumes:

* a 1500-byte underlay path MTU;
* one untagged outer Ethernet header;
* no IPv4 options and no IPv6 extension headers;
* no additional encapsulation (for example, no IPsec, PPPoE, or MPLS label stack);
* no inner VLAN tag.

An inner 802.1Q tag adds 4 bytes to the inner frame and reduces the overlay IP MTU by 4. An outer
802.1Q tag reduces the usable underlay path MTU by 4. A PPPoE path whose MTU is already 1492 has
already accounted for its 8-byte PPPoE overhead; do not subtract it twice. The table is a
calculation for the stated assumptions, not a universal constant.

The integration's defaults are 1430 for an IPv6 underlay and 1450 for an IPv4 underlay on such a
path. An explicit `mtu` is authoritative. The kernel VXLAN minimum of 68 is not an IPv6 deployment
target: an IPv6 link must support at least 1280 bytes (RFC 8200), so an underlay path used for an
IPv6 overlay must be large enough to leave at least 1280 bytes after the 70-byte overhead. On a
1500-byte path the default 1430 satisfies that requirement. On a 1280-byte underlay path the
calculated overlay MTU is 1210, which is below the IPv6 minimum; do not use such a path for an IPv6
overlay without a deliberate, documented design that addresses the constraint.

Path MTU Discovery is an end-to-end responsibility, and underlay PMTUD is distinct from overlay
PMTUD. This integration does not fragment oversized outer IPv6 packets and does not rely on outer
fragmentation for correctness. Size the VXLAN MTU for the underlay path and permit ICMPv6 Packet Too
Big messages; see [`deployment.md`](deployment.md#8-ipv6-operational-considerations).

## 7. Scope

### Implemented

* Fixed-remote, point-to-point Linux VXLAN over an IPv4 or IPv6 underlay.
* One local VTEP address and one remote VTEP address, both in the same family.
* Routed VXLAN interfaces with IPv4, IPv6, or dual-stack overlay addresses.
* Bridged VXLAN interfaces, with Layer 3 addressing on the bridge.
* Native EdgeOS `firewall in`, `firewall out`, and `firewall local` attachments for routed VXLAN
  interfaces, in the IPv4 `name` and IPv6 `ipv6-name` families.
* Deterministic locally administered MAC addresses, recreation with rollback, boot restoration, and
  the documented interface update semantics.

### Not implemented or not claimed

* EVPN or any other VXLAN control plane.
* Multicast VXLAN underlay groups or dynamic peer discovery.
* Multiple remote VTEPs or a learned remote-peer table.
* VLAN-to-VNI mapping, VXLAN-specific FDB configuration, or flood-and-learn configuration beyond
  the Linux defaults used by the fixed-remote device.
* Hardware VXLAN offload.
* Bridged Layer 2 firewall enforcement; bridged VXLAN interfaces reject firewall attachments.
* Authenticated or encrypted VXLAN. Use IPsec or another authenticated transport where required.
* IPv6-only router management or package acquisition as validated project capabilities. The
  dataplane can be IPv6-only, and the isolated Level B namespace environment is qualified; those
  do not make installation, management or an IPv6-only CI runner/control plane (Level D)
  validated capabilities. The distinction is defined in
  [`ipv6-only-qualification.md`](ipv6-only-qualification.md).
* Dynamic underlay addressing (SLAAC/DHCPv6) at boot. Static endpoints are the validated model.

## 8. Platform constraints

The supported platform is deliberately narrow: EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409,
Linux `4.14.54-UBNT`, MIPS little-endian. The vendor kernel and userspace predate many current
IPv6 recommendations. RFC status is not evidence that the vendor kernel implements every update;
the implementation is validated against the actual platform, not against a generic Linux
assumption.

Two platform quirks are operationally relevant:

* The vendor `iproute2-ss171113` build renders corrupt numeric fields in human-readable
  `ip -d link show` output. Use `ip -j -d link show` for diagnostics.
* The vendor configuration engine is not universally atomic. After a failed commit, do not `save`;
  compare the active configuration with the kernel and re-converge first.

## 9. Standards and applicability

The table records the RFC Editor status and update relationships checked on 2026-11-27. It also
states how each document is used here. The list is not a claim that the vendor kernel implements
every requirement or every update.

| RFC | Status | Updates / obsoletes | Use and applicability |
|---|---|---|---|
| [RFC 7348](https://www.rfc-editor.org/rfc/rfc7348.html) | Informational | — | VXLAN dataplane. This project implements fixed-remote unicast VXLAN, not the control-plane or EVPN options discussed elsewhere. |
| [RFC 8200](https://www.rfc-editor.org/rfc/rfc8200.html) | Internet Standard | Obsoletes RFC 2460; updated by RFC 9673 | IPv6 base specification. The vendor kernel is 4.14.54; later updates are not assumed. |
| [RFC 8201](https://www.rfc-editor.org/rfc/rfc8201.html) | Internet Standard | Obsoletes RFC 1981 | IPv6 Path MTU Discovery. Outer IPv6 relies on PMTUD and ICMPv6 Packet Too Big; the integration does not rely on outer fragmentation. |
| [RFC 4443](https://www.rfc-editor.org/rfc/rfc4443.html) | Internet Standard | Updates RFC 2780; updated by RFC 4884 | ICMPv6, including Packet Too Big and the error messages used by Neighbor Discovery. Firewall policy must not blackhole these messages. |
| [RFC 4861](https://www.rfc-editor.org/rfc/rfc4861.html) | Draft Standard | Obsoletes RFC 2461; multiple updates, latest RFC 9926 | Neighbor Discovery for IPv6. Used on the underlay and inside the overlay; the vendor kernel may not implement every update. |
| [RFC 4862](https://www.rfc-editor.org/rfc/rfc4862.html) | Draft Standard | Obsoletes RFC 2462; updated by RFC 7527 and RFC 9762 | Stateless Address Autoconfiguration. Relevant to underlay addressing; dynamic underlay arrival at boot is not validated by this project. |
| [RFC 4291](https://www.rfc-editor.org/rfc/rfc4291.html) | Draft Standard | Obsoletes RFC 3513; updated by RFC 5952, 6052, 7136, 7346, 7371, 8064 | IPv6 addressing architecture. Defines the address classes the endpoint validation rejects or accepts. |
| [RFC 5952](https://www.rfc-editor.org/rfc/rfc5952.html) | Proposed Standard | Updates RFC 4291 | Canonical IPv6 text representation. Documentation examples use canonical lowercase/compressed forms; the helper canonicalises before comparison. |
| [RFC 3849](https://www.rfc-editor.org/rfc/rfc3849.html) | Informational | Updated by RFC 9637 | IPv6 documentation prefix `2001:db8::/32`, used throughout this repository. |
| [RFC 9637](https://www.rfc-editor.org/rfc/rfc9637.html) | Informational | Updates RFC 3849 | Expands the IPv6 documentation space with `3fff::/20`. The repository continues to use `2001:db8::/32`; both are documentation space. |
| [RFC 6164](https://www.rfc-editor.org/rfc/rfc6164.html) | Proposed Standard | Updated by RFC 6547 | 127-bit IPv6 prefixes on inter-router links. Optional; the deployment examples use /64 segments, and any /127 use must be deliberate. |
| [RFC 9099](https://www.rfc-editor.org/rfc/rfc9099.html) | Informational | — | Operational security considerations for IPv6 networks. Used for the underlay-filtering and management-plane guidance; it is not a protocol requirement. |
| [RFC 6935](https://www.rfc-editor.org/rfc/rfc6935.html) | Proposed Standard | Updates RFC 2460 | IPv6 UDP checksum considerations. The integration leaves the kernel's default checksum behaviour unchanged. |
| [RFC 6936](https://www.rfc-editor.org/rfc/rfc6936.html) | Proposed Standard | — | UDP zero-checksum applicability. The integration does not expose or enable zero-checksum options. |
| [RFC 8504](https://www.rfc-editor.org/rfc/rfc8504.html) | Best Current Practice (BCP 220) | Obsoletes RFC 6434 | IPv6 node requirements. Useful as a checklist; the vendor platform is older than the current recommendation set. |
| [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737.html) | Informational | Updates RFC 1166 | IPv4 documentation prefixes (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`), used where IPv4 examples remain necessary. |
| [RFC 6724](https://www.rfc-editor.org/rfc/rfc6724.html) | Proposed Standard | Obsoletes RFC 3484 | Default source-address selection. Relevant when `local-ip` is unspecified and the kernel must choose the outer source. |

No errata were used to override a base specification in this document. Where an erratum exists
against a cited RFC, the operational statement here is limited to the behaviour the implementation
and tests actually demonstrate.

## 10. Terminology used in this repository

* **Underlay** — the routed IP network carrying the outer VXLAN packets.
* **Overlay** — the Ethernet segment emulated by VXLAN.
* **VTEP** — VXLAN tunnel endpoint; the local and remote outer addresses configured by
  `local-ip`/`remote-ip`.
* **Legacy IPv4** — IPv4 used for interoperability or existing deployments, not as the default
  design assumption.
* **Dual-stack** — an overlay carrying both IPv4 and IPv6 addressing; it does not describe the
  underlay.
* **IPv6-only** — a deployment with no IPv4 transport or overlay dependency. The dataplane and the
  isolated Level B namespace environment have been validated in this mode; installation,
  management and an IPv6-only CI runner/control plane are assessed separately. See
  [`ipv6-only-qualification.md`](ipv6-only-qualification.md) for the Level A–D model.
