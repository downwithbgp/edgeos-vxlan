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
| **L** | Inferred from Linux VXLAN | Expected from the Linux VXLAN dataplane where no direct hardware dataplane result exists. It is not a substitute for **H**; use it only with the corresponding note. |
| **A** | Automated off-device | Unit, template, or mocked-reconciler tests in `test/` (376 checks on the current suite: 11 build + 64 helper + 122 firewall + 93 templates + 70 mock + 16 qualification-evidence contract). |
| **S** | Simulated EdgeOS | The vendor EdgeOS 3.0.1 configuration engine under qemu, or the documented emulated-engine scenarios. Not hardware. |
| **N** | Linux network namespace | General-Linux dataplane semantics in `test/integration-netns.sh`. Not EdgeOS. |
| **N6** | Isolated IPv6-only Linux network namespace | The Level B topology in `test/ipv6-only-netns.sh`: no usable external IPv4 connectivity in the workload namespaces. General Linux, not EdgeOS. |
| **N6-R** | Isolated IPv6-only namespace, actual reconciler | The N6 topology with the actual `src/vyatta-vxlan` reconciler. The EdgeOS config API, firewall dispatch and bridge helper are test doubles; kernel/`ip`/sysfs are real. Partial by design. |
| **N6-R-P** | Candidate-packaged userspace | The hash-checked packaged `vyatta-vxlan` and `vyatta-vxlan-addr` extracted from a candidate `.deb` are executed in the same topology. Not MIPS-kernel or hardware evidence. |
| **H** | Physical hardware | Demonstrated on the supported ER-X; the evidence document is cited. |
| **—** | Not exercised | No evidence at that class. Do not infer a pass from another row. |

A **partial** mark means the class was exercised for part of the row (for example, bridge state but
not bridged traffic, or firewall attachments but not the underlay family). The note states the
missing part.

## 2. Underlay × overlay matrix

| # | Underlay | Overlay Layer 3 | I | L | A | S | N | H | Documentation status |
|---:|---|---|---|---|---|---|---|---|---|
| 1 | IPv6 | IPv6 | yes | — | yes | partial | yes | **yes** | Primary; scenario 1 |
| 2 | IPv6 | Bridged Ethernet (IPv6 on bridge) | yes | yes | yes | — | — | partial | Primary bridged model; scenario 2 |
| 3 | IPv6 | Dual-stack IPv6 + IPv4 | yes | — | yes | partial | partial | **yes** | Primary dual-stack; scenario 3 |
| 4 | IPv4 | IPv6 | yes | yes | partial | partial | — | — | Interoperability; scenario 4; inferred, not hardware-qualified |
| 5 | IPv6 | IPv4 | yes | — | yes | — | — | **yes** | Interoperability; scenario 5 |
| 6 | IPv4 | IPv4 | yes | — | yes | yes | yes | **yes** | Compatibility; scenario 6 |
| 7 | IPv4 | Dual-stack IPv6 + IPv4 | yes | yes | yes | partial | — | partial | Interoperability; inferred, not hardware-qualified |

Notes:

1. **IPv6/IPv6.** Hardware: RC2 post-reboot IPv6 overlay traffic over an IPv6 underlay, 5/5 each
   direction; see `docs/issue-3-hardware-evidence.md`. Automated: helper, mock, template and
   namespace coverage; the dual-stack namespace test creates an IPv6 VXLAN over IPv6 and passes
   overlay IPv6 traffic. The N6 suite adds an isolated IPv6-only topology with a routed underlay,
   host-to-host TCP/UDP, NDP, MTU boundaries and negative controls; it is not hardware evidence.
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

### IPv6-only isolated qualification (Level B)

The N6 suite establishes the workload environment without usable external IPv4 connectivity; see
[`ipv6-only-qualification.md`](ipv6-only-qualification.md). The N6-R row is the actual reconciler
path with the EdgeOS configuration API and firewall dispatch replaced by test doubles. The
authoritative CI job requires packet capture; local developer runs may leave it optional. The
future candidate-manifest integration is in
[`ipv6-only-qualification-ci-integration.md`](ipv6-only-qualification-ci-integration.md).

| Area | N6 | N6-R | Claim |
|---|---|---|---|
| IPv6 underlay, IPv6 overlay, VTEP-to-VTEP (VNI 100) | yes | — | Bidirectional ICMPv6 over a routed underlay |
| Routed host-to-host overlay (VNI 200) | yes | — | Bidirectional ICMPv6, TCP and UDP across the tunnel |
| IPv6 Neighbor Discovery (underlay and overlay) | yes | — | Neighbor caches resolve after flush |
| VXLAN encapsulation/decapsulation counters | yes | — | TX/RX counters increase; capture shows outer UDP/4789 and inner IPv6 |
| MTU boundary (1430-byte VXLAN MTU) | yes | — | 1382-byte payload passes; 1383-byte payload is rejected with `-M do` |
| Deletion and recreation | yes | yes | Overlay traffic resumes |
| Reconciler create/update/rollback/delete | — | partial | Real reconciler, kernel and sysfs; config API/firewall/bridge/address are test doubles |
| Generic Linux bridge (VNI 300) | yes | — | Bridge and ND work; **not** ENG-IPV6-04 hardware evidence |
| Isolation assertions and negative controls | yes | — | IPv4 address/route/policy canaries detected; IPv4 control pair reachable; isolated hosts cannot reach it |

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

| Area | Implementation | Automated | Simulated | Hardware | Claim |
|---|---|---|---|---|---|
| VXLAN dataplane with IPv6 underlay and IPv6 overlay | yes | yes | partial | yes | Validated with static endpoints; N6 adds isolated IPv6-only namespace evidence |
| Isolated IPv6-only namespace dataplane (Level B) | yes | yes (N6) | — | — | Level B achieved at N6; not hardware |
| Actual reconciler in the isolated topology (N6-R) | yes | partial (N6-R) | — | — | Reconciler lifecycle, endpoint rejection, and reconciler-created TCP/UDP exercised; config API/firewall/bridge are test doubles |
| Candidate-packaged userspace (N6-R-P) | yes | yes (N6-R-P, release candidate) | — | — | The exact candidate integration `.deb` is hash-checked, extracted and exercised in `release.yml`; the four checks are bound to the candidate manifest under `build.identity` and enforced by the candidate validator and publication gate. Local qualification only until the hosted non-publication run is authorized. See [`release-candidate-ipv6-qualification.md`](release-candidate-ipv6-qualification.md) |
| IPv6-only CI runner and control plane (Level D) | — | — | — | — | Not achieved; GitHub-hosted runner and control plane are dual-stack |
| IPv6-only CI job with isolated namespaces | yes | yes (N6; hosted run 46044226321) | — | — | Hosted trusted run 46044226321 passed with 113/0/2; capture and reconciler executed. CI requires packet capture and installs tcpdump separately if absent. |
| VXLAN dataplane with IPv6 underlay and IPv4 overlay | yes | yes | — | yes | Validated on RC1/RC2 |
| Dual-stack overlay over IPv6 underlay | yes | yes | partial | yes | Validated on RC2 (20/20) |
| Router management over IPv6 only | n/a (EdgeOS) | — | — | — | Not validated by this project |
| Package acquisition over IPv6 only | installer is family-neutral | — | — | — | Not validated; HTTPS/DNS dependency |
| CI and test environment IPv6-only | Level B namespace topology; dual-stack runner | yes (N6; hosted run 46044226321) | — | — | Level B implemented and hosted-run; Level D not achieved |
| Diagnostics over IPv6 only | platform tools exist | — | — | partial | `ip -j` required; `ip -d` defective |

The supported IPv6-only claim is limited to the VXLAN dataplane with static endpoints and the
Level B isolated namespace environment. Complete IPv6-only installation (Level C) and IPv6-only
CI infrastructure (Level D) remain engineering gaps. A dual-stack runner that creates IPv6-only
namespaces is Level B, not Level D.

## 5. Test coverage inventory

| Suite | Checks | Coverage relevant to this matrix |
|---|---:|---|
| `test/unit-helper.sh` | 64 | Address parsing, IPv4/IPv6 equality, endpoint classes, canonical text, JSON live-state parsing, family-aware default MTU |
| `test/unit-firewall.sh` | 122 | IPv4/IPv6 attachment validation, dispatch, verification, restore, fail-closed paths |
| `test/unit-templates.sh` | 93 | Template structure, `type: ipv4,ipv6`, family checks, MTU bounds, firewall leaves |
| `test/mock.sh` | 70 | Reconciler lifecycle, IPv6 creation, identity changes, rollback, bridge state, firewall snapshot/restore |
| `test/unit-build.sh` | 11 | Reproducible-build contract and guard tests |
| `test/unit-ipv6-evidence.sh` | 16 | Candidate-bound qualification-evidence acceptance/rejection, identity/hash binding, permitted skips/workarounds |
| `test/unit-release-ipv6-gate.sh` | 28 | Release-candidate and promotion gates: build identity, retained evidence, workflow provenance, artifact replacement, evidence substitution, permitted exceptions |
| `test/integration-netns.sh` | separate | General-Linux dual-stack IPv4 and IPv6 VXLAN dataplanes, firewall directions, NDP, multiple interfaces, recreation under traffic; root/CAP_NET_ADMIN required |
| `test/ipv6-only-netns.sh` | separate | Level B isolated IPv6-only topology: routed underlay, two VTEPs, host-to-host ICMPv6/TCP/UDP, NDP, MTU, recreation, bridge feasibility, isolation assertions and negative controls; optional candidate-package mode (N6-R-P); root/CAP_NET_ADMIN required |
| CI workflow | — | Runs the 376-check suite, ShellCheck, package build, release validation, the dual-stack namespace test, and the IPv6-only qualification job |

The 376-check suite is the current off-device baseline. It is not a hardware substitute. Both
namespace suites are general-Linux evidence and are labelled as such; neither is EdgeOS
validation. The N6 suite is additionally labelled N6/N6-R, not H.

## 6. Gaps and unverified behaviour

Ordered by significance for the current documentation claims:

1. **IPv4 underlay with IPv6 overlay** is implemented but not separately hardware-qualified in the
   published record. Add a hardware run or label it as an interoperability path with an explicit
   evidence gap.
2. **IPv4 underlay with dual-stack overlay** has emulated-engine evidence and a hardware
   dual-family policy matrix, but not a separately classified hardware dataplane run.
3. **Bridged VXLAN dataplane over an IPv6 underlay** has bridge-state evidence, not packet
   evidence. Add a bridged-traffic run before claiming the bridged model is fully validated.
4. **IPv6-only management and package acquisition (Level C)** are not validated, and **IPv6-only
   CI infrastructure (Level D)** is not achieved. The Level B namespace dataplane result must not
   be generalized to them. See [`ipv6-only-qualification.md`](ipv6-only-qualification.md).
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
11. **Alternate-source IPv6 underlay filtering** was not separately produced in the published
    hardware record. The IPv6 underlay was validated with an extension of the existing local IPv6
    policy in place; the alternate-source drop path for IPv6 is an evidence gap, not a claim.
12. **Family-selective firewall state capture.** The firewall helper reads both `iptables` and
    `ip6tables` tables for every capture. On the supported platform both exist; on an IPv4-less
    platform this would be a hard dependency for an IPv6-only attachment. Tracked as
    [ENG-IPV6-08](engineering-backlog.md#eng-ipv6-08-family-selective-firewall-state-capture).
13. **The N6 bridge section is generic Linux only.** It demonstrates topology feasibility and ND,
    not the physical EdgeOS bridged dataplane required by
    [ENG-IPV6-04](engineering-backlog.md#eng-ipv6-04-ipv6-underlay-bridged-ethernet-dataplane-validation).

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

The IPv6-only Level B suite requires root/CAP_NET_ADMIN, iproute2, iputils-ping, Python 3 and
(optionally) tcpdump. The N6-R reconciler section also requires Perl with `JSON::PP`:

```bash
sudo REQUIRE_NETNS_TEST=1 REQUIRE_CAPTURE=1 REQUIRE_RECONCILER=1 \
  EVIDENCE_DIR=/tmp/ipv6-only-evidence \
  bash test/ipv6-only-netns.sh
```

The namespace tests are not EdgeOS tests. Hardware evidence is in the cited records; do not
reconstruct a hardware result from the namespace or emulated-engine output. The N6 suite is
Level B evidence only; Level C and Level D remain unachieved.

## 8. Related documents

* [`architecture.md`](architecture.md) — layer model and scope.
* [`deployment.md`](deployment.md) — six deployment scenarios and operations.
* [`audit/2026-11-documentation-audit.md`](audit/2026-11-documentation-audit.md) — point-in-time
  audit and final-review record.
* [`engineering-backlog.md`](engineering-backlog.md) — repository-local engineering proposals.
* [`ipv6-only-qualification.md`](ipv6-only-qualification.md) — Level A–D model, isolation contract,
  threat model and CI integration.
* [`ipv4-dependency-inventory.md`](ipv4-dependency-inventory.md) — repository-wide IPv4 dependency
  audit and external service limitations.
* [`ipv6-only-qualification-evidence.md`](ipv6-only-qualification-evidence.md) — validation record.
* [`issue-3-hardware-evidence.md`](issue-3-hardware-evidence.md) — IPv6 underlay hardware evidence.
* [`v0.3.0-hardware-qualification-report.md`](v0.3.0-hardware-qualification-report.md) — RC5
  qualification record.
* [`v0.3.0-first-hardware-session-record.md`](v0.3.0-first-hardware-session-record.md) — firewall
  direction/family matrix.
