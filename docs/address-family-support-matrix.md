# Address-family capability and validation matrix

**Scope:** `edgeos-vxlan` v0.3.0 on the supported platform (EdgeRouter X / ER-e50, EdgeOS 3.0.1
build 5862409, Linux `4.14.54-UBNT`).
**Purpose:** separate implementation support from automated, simulated, namespace, and physical
hardware evidence. A row is not a claim that every deployment will behave identically; it records
what has actually been exercised.

## 1. Evidence legend

| Code | Evidence class | What it means |
|---|---|---|
| **I** | Implementation | Code, templates, or configuration grammar supports the combination. |
| **A** | Automated off-device | Unit, template, or mocked-reconciler tests in `test/` (349 checks on the current suite). |
| **S** | Simulated EdgeOS | The vendor EdgeOS 3.0.1 configuration engine under qemu, or the documented emulated-engine scenarios. Not hardware. |
| **N** | Linux network namespace | General-Linux dataplane semantics in `test/integration-netns.sh`. Not EdgeOS. |
| **H** | Physical hardware | Demonstrated on the supported ER-X; the evidence document is cited. |
| **—** | Not exercised | No evidence at that class. Do not infer a pass from another row. |

A **partial** mark means the class was exercised for part of the row (for example, bridge state but
not bridged traffic, or firewall attachments but not the underlay family). The note states the
missing part.

## 2. Underlay × overlay matrix

| # | Underlay | Overlay Layer 3 | I | A | S | N | H | Documentation status |
|---:|---|---|---|---|---|---|---|---|
| 1 | IPv6 | IPv6 | yes | yes | partial | yes | **yes** | Primary; scenario 1 |
| 2 | IPv6 | Bridged Ethernet (IPv6 on bridge) | yes | yes | — | — | partial | Primary bridged model; scenario 2 |
| 3 | IPv6 | Dual-stack IPv6 + IPv4 | yes | yes | partial | partial | **yes** | First-class; scenario 3 |
| 4 | IPv4 | IPv6 | yes | partial | partial | — | — | Interoperability; scenario 4; not separately hardware-qualified |
| 5 | IPv6 | IPv4 | yes | yes | — | — | **yes** | Interoperability; scenario 5 |
| 6 | IPv4 | IPv4 | yes | yes | yes | yes | **yes** | Legacy compatibility; scenario 6 |
| 7 | IPv4 | Dual-stack IPv6 + IPv4 | yes | yes | partial | — | partial | Interoperability; not separately hardware-qualified |

Notes:

1. **IPv6/IPv6.** Hardware: RC2 post-reboot IPv6 overlay traffic over an IPv6 underlay, 5/5 each
   direction; see `docs/issue-3-hardware-evidence.md`. Automated: helper, mock, template and
   namespace coverage; the namespace test creates an IPv6 VXLAN over IPv6 and passes overlay IPv6
   traffic.
2. **IPv6/bridged.** Hardware: bridge membership, path cost, and port priority survived recreation
   and rollback on the ER-X; packets over the bridged tunnel were not part of that run. Automated:
   mock bridge scenarios. Firewall attachments on bridge ports are rejected by design.
3. **IPv6/dual-stack.** Hardware: RC2 restored both overlay addresses after reboot and passed
   bidirectional IPv4 and IPv6 overlay traffic (20/20). The emulated-engine record used an IPv4
   underlay with dual-family firewall attachments; it is not evidence for the IPv6-underlay
   dataplane. The namespace test covers IPv6-underlay/IPv6-overlay and IPv4-underlay/IPv4-overlay
   separately, not the combined dual-stack-over-IPv6 case.
4. **IPv4/IPv6.** The implementation is family-independent at the VXLAN layer, and the emulated
   engine exercised an IPv4-underlay VXLAN with IPv6 firewall attachments. No separate hardware
   run in the published record carries an IPv6 overlay over an IPv4 underlay. Treat this as
   implemented and structurally supported, not as a separately hardware-qualified combination.
5. **IPv6/IPv4.** Hardware: RC1 and RC2 carried bidirectional IPv4 overlay traffic over an IPv6
   underlay (5/5 each direction). The outer path's IPv6 ND and MTU behaviour still apply.
6. **IPv4/IPv4.** Hardware: the v0.2.1/v0.2.2 line validated IPv4 VXLAN dataplane, creation,
   persistence, bridge membership, and the interface lifecycle. The v0.3.0 firewall work inherits
   the v0.2.2 interface results. Automated: namespace test and mock coverage.
7. **IPv4/dual-stack.** The emulated engine created dual-family attachments on an IPv4-underlay
   VXLAN. The hardware `vxlan903` matrix exercised dual-family overlay policy, but the sanitized
   record omits the underlay family. Do not claim a separately qualified IPv4-underlay dual-stack
   dataplane.

### Bridged Ethernet independently of overlay Layer 3

| Underlay | Bridge carries | I | A | H | Status |
|---|---|---|---|---|---|
| IPv6 | IPv6 | yes | yes | partial | Membership/cost/priority verified; bridged dataplane not verified |
| IPv6 | Dual-stack | yes | partial | — | No dedicated test |
| IPv6 | Non-IP Ethernet | yes | — | — | VXLAN carries Ethernet; not separately exercised |
| IPv4 | IPv4 | yes | yes | partial | v0.2.x bridge attachment/detachment tested; no separate bridged-traffic record |
| IPv4 | IPv6 or dual-stack | yes | partial | — | No dedicated test |

Bridged VXLAN interfaces cannot carry `firewall` attachments; the implementation rejects them.
This is a scope boundary, not a missing test.

## 3. Firewall attachment matrix

| Direction | IPv4 `name` | IPv6 `ipv6-name` | Independent of underlay | Evidence |
|---|---|---|---|---|
| `in` | yes | yes | yes | Firewall unit suite (122 checks), emulated engine, hardware six-combination matrix |
| `out` | yes | yes | yes | Same |
| `local` | yes | yes | yes | Same |
| bridged port | rejected | rejected | n/a | Validation rejects the attachment |
| `modify` / `ipv6-modify` | not exposed | not exposed | n/a | Out of scope for this release |

The hardware six-combination matrix exercised `in`/`out`/`local` × IPv4/IPv6 with counter evidence
on `vxlan903` (see `docs/v0.3.0-first-hardware-session-record.md`). It proves the native hook and
policy semantics for both overlay families; it does not, by itself, prove every underlay/overlay
combination in section 2.

The firewall policy family is independent of the underlay family. An IPv6 underlay can carry an
IPv4-only overlay policy, an IPv6-only overlay policy, or both. The underlay peer filter is a
separate policy on the physical/VLAN interface and must use the family of the outer transport.

## 4. IPv6-only deployment matrix

| Area | Implementation | Automated / simulated | Hardware | Claim |
|---|---|---|---|---|
| VXLAN dataplane with IPv6 underlay and IPv6 overlay | yes | yes | yes | Validated with static endpoints |
| VXLAN dataplane with IPv6 underlay and IPv4 overlay | yes | partial | yes | Validated on RC1/RC2 |
| Dual-stack overlay over IPv6 underlay | yes | partial | yes | Validated on RC2 (20/20) |
| Router management over IPv6 only | n/a (EdgeOS) | — | — | Not validated by this project |
| Package acquisition over IPv6 only | installer is family-neutral | — | — | Not validated; HTTPS/DNS dependency |
| CI and test environment IPv6-only | tests configure both families | — | — | No IPv6-only CI job |
| Diagnostics over IPv6 only | platform tools exist | — | partial | `ip -j` required; `ip -d` defective |

The supported IPv6-only claim is limited to the VXLAN dataplane with static endpoints. Complete
IPv6-only installation, management, and CI remain engineering gaps.

## 5. Test coverage inventory

| Suite | Checks | Coverage relevant to this matrix |
|---|---:|---|
| `test/unit-helper.sh` | 64 | Address parsing, IPv4/IPv6 equality, endpoint classes, canonical text, JSON live-state parsing, family-aware default MTU |
| `test/unit-firewall.sh` | 122 | IPv4/IPv6 attachment validation, dispatch, verification, restore, fail-closed paths |
| `test/unit-templates.sh` | 93 | Template structure, `type: ipv4,ipv6`, family checks, MTU bounds, firewall leaves |
| `test/mock.sh` | 70 | Reconciler lifecycle, IPv6 creation, identity changes, rollback, bridge state, firewall snapshot/restore |
| `test/integration-netns.sh` | separate | General-Linux IPv4 and IPv6 VXLAN dataplanes, firewall directions, NDP, multiple interfaces, recreation under traffic; root/CAP_NET_ADMIN required |
| CI workflow | — | Runs the 349-check suite, ShellCheck, package build, release validation, and the namespace test |

The 349-check suite is the current off-device baseline. It is not a hardware substitute. The
namespace test is general-Linux evidence and is labelled as such; it is not EdgeOS validation.

## 6. Gaps and unverified behaviour

Ordered by significance for an IPv6-first documentation claim:

1. **IPv4 underlay with IPv6 overlay** is implemented but not separately hardware-qualified in the
   published record. Add a hardware run or label it as an interoperability path with an explicit
   evidence gap.
2. **IPv4 underlay with dual-stack overlay** has emulated-engine evidence and a hardware
   dual-family policy matrix, but not a separately classified hardware dataplane run.
3. **Bridged VXLAN dataplane over an IPv6 underlay** has bridge-state evidence, not packet
   evidence. Add a bridged-traffic run before claiming the bridged model is fully validated.
4. **IPv6-only management, package acquisition, and CI** are not validated. The dataplane result
   must not be generalized to them.
5. **Dynamic underlay addressing (SLAAC/DHCPv6) at boot** is not validated, including prefix-change
   and late-address-arrival timing.
6. **PMTUD/ICMPv6 Packet Too Big interaction** is documented but not covered by a dedicated
   automated or hardware test.
7. **Source-address selection with an unspecified `local-ip`** is kernel behaviour; no separate
   test covers asymmetric return paths.
8. **Documentation example validation** is manual. There is no automated parser for the EdgeOS
   configuration blocks in this guide.
9. **External Internet-facing probes** for the v0.3.0 firewall qualification remain deferred; the
   qualified scope is the isolated dataplane and the operational migration.
10. **Package removal and downgrade** were not qualified in the v0.3.0 hardware report; the v0.2.x
    removal record remains the relevant evidence.

## 7. Reproducing the off-device evidence

```bash
bash test/run.sh
```

Expected current result: `unit-helper` 64, `unit-firewall` 122, `unit-templates` 93, `mock` 70;
all pass. The namespace test requires root/CAP_NET_ADMIN and `ip`, `iptables`, `ip6tables`, and
`ping`:

```bash
sudo REQUIRE_NETNS_TEST=1 bash test/integration-netns.sh
```

The namespace test is not an EdgeOS test. Hardware evidence is in the cited records; do not
reconstruct a hardware result from the namespace or emulated-engine output.

## 8. Related documents

* [`ipv6-first-architecture.md`](ipv6-first-architecture.md) — layer model and scope.
* [`ipv6-first-deployment.md`](ipv6-first-deployment.md) — six deployment scenarios and operations.
* [`documentation-audit-2026-11.md`](documentation-audit-2026-11.md) — audit findings, corrections,
  remaining IPv4 assumptions, and follow-up tasks.
* [`issue-3-hardware-evidence.md`](issue-3-hardware-evidence.md) — IPv6 underlay hardware evidence.
* [`v0.3.0-hardware-qualification-report.md`](v0.3.0-hardware-qualification-report.md) — RC5
  qualification record.
* [`v0.3.0-first-hardware-session-record.md`](v0.3.0-first-hardware-session-record.md) — firewall
  direction/family matrix.
