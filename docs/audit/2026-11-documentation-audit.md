# Documentation audit — address-family modernization

**Status:** point-in-time audit and final-review record. It is not current operational guidance.
Current guides are indexed in [`../README.md`](../README.md); the engineering backlog is
[`../engineering-backlog.md`](../engineering-backlog.md).

**Date:** 2026-11-27
**Repository:** `downwithbgp/edgeos-vxlan`
**Baseline:** `origin/main` at `f182a64` (v0.3.0 plus the release-engineering hardening merge)
**Working branch:** `docs/ipv6-first`

## 1. Method and authority

The audit read the current documentation, the implementation, the EdgeOS templates, packaging,
installer, off-device tests, and hardware evidence records. Where documents disagreed, the
implementation and reproducible test evidence were treated as authoritative for product behaviour;
standards were treated as authoritative for protocol semantics. The vendor kernel and userspace were
treated as the platform, not as a generic modern Linux.

The audit did not run live-router tests. Hardware statements are cited from repository records. The
namespace test was not run in this environment because non-interactive root/CAP_NET_ADMIN was
unavailable. Historical records were preserved; a record that says “not executed” remains a record
of that candidate or procedure even when a later record reports a completed qualification.

## 2. Final documentation structure

The final review separated enduring guidance from point-in-time records and established one
canonical source per claim:

| Document | Role |
|---|---|
| `README.md` | Entry point: install, package summary, primary configuration, limitations |
| `docs/architecture.md` | Address-family layer model, VTEP rules, MTU terminology, scope, standards |
| `docs/deployment.md` | Six scenarios, both endpoints, IPv6 operations, IPv6-only assessment, troubleshooting |
| `docs/native-firewall.md` | Firewall attachments, underlay peer filtering, lifecycle, bridged/routed semantics, verification |
| `docs/interface-lifecycle.md` | Reconciliation, rollback, MACs, EdgeOS integration, boot, removal, diagnostics |
| `docs/kernel-provenance.md` | Kernel module provenance, CVE backport, compatibility evidence, package build |
| `docs/address-family-support-matrix.md` | Implementation/automated/simulated/namespace/hardware/inferred evidence by combination |
| `docs/engineering-backlog.md` | Repository-local engineering proposals and acceptance criteria |
| `docs/audit/2026-11-documentation-audit.md` | This point-in-time record |

The final README is about 560 lines, down from 1,573 before the review. The reduction comes from removing
duplicated scenario blocks, moving detailed firewall/lifecycle/kernel material to canonical guides,
and replacing the long tested-behavior list with a summary and a matrix link. The detailed guides
retain the technical content; line count was not reduced by deleting coverage.

## 3. Initial corrections and final-review changes

The initial pass corrected the entry-point ordering, added the six-scenario deployment guide, and
recorded the support matrix. It also corrected stale hardware-acceptance claims, the v0.2.2 package
filenames in the v0.3.0 install section, the RC1 build filenames presented as the v0.3.0 release, and
the impossible “v0.2.2 live firewall attachment” upgrade case. The initial audit report captured
those corrections.

The final maintainer review made these additional changes:

1. **Reduced duplication.** Removed the repeated configuration scenarios, MTU table and operational
   bullet list from README; the deployment and architecture guides are now canonical. Moved detailed
   firewall, lifecycle and kernel/build material into dedicated guides.
2. **Neutral naming.** Renamed the architecture and deployment guides from `ipv6-first-*` to neutral
   names; moved this audit under `docs/audit/`. This keeps IPv6 as the ordinary protocol rather than
   a repeated headline label.
3. **Separated records.** The audit is no longer listed as current guidance; it is under
   “Point-in-time audit records” in the documentation map. The current backlog is separate.
4. **Added the engineering backlog.** Seven actionable entries now carry problem, significance,
   validation methodology, dependencies and acceptance criteria. No remote GitHub issue was created.
5. **Clarified MTU terminology.** The architecture note now states that the VXLAN netdev MTU is the
   maximum inner IP packet size, not the inner Ethernet frame or the underlay path MTU.
6. **Separated underlay and overlay PMTUD.** The deployment guide now distinguishes outer-path PMTUD
   from end-to-end overlay PMTUD and explains where ICMPv6 Packet Too Big must be permitted.
7. **Qualified UDP checksum behavior.** The deployment guide now cites the target hardware session
   (checksum enabled, zero-checksum options disabled) and states that the integration passes no
   checksum-disabling options. It does not claim a checksum property that was not observed.
8. **Qualified IPv6-only claims.** The deployment guide now states that the hardware runs used IPv6
   underlay/overlay addresses but did not remove IPv4 from management, the peer, tooling or CI.
9. **Added inferred evidence.** The matrix now distinguishes “inferred from Linux VXLAN” from
   implementation, automated, simulated, namespace and hardware evidence.
10. **Simplified the firewall example.** The tunnelbroker example now permits `protocol icmpv6`
    rather than relying on unvalidated `icmpv6 type` keywords. This uses syntax already exercised by
    the hardware records and avoids presenting an unverified keyword set as supported.
11. **Verified installer scope.** The only `install.sh` change is the printed configuration example.
    The version pins, hashes, `curl` calls, checksum verification and `dpkg` transaction are
    unchanged from the base revision. The published v0.3.0 tag still carries the older printed
    example, so the repository change takes effect only in a future tagged release; this is a
    release-engineering note, not an install-behavior change.
12. **Reconciled the support boundary.** The boot-restoration row in
    `v0.3.0-support-boundary.md` now reflects the RC5 qualification instead of the earlier pending
    state.
13. **Removed the duplicated IPv6-only table** from the deployment guide; the support matrix is the
    single status source, and the deployment guide links to it.
14. **Fixed moved-document references** in the README, deployment guide, release notes and
    documentation map, including the failed-commit link and the backlog anchor.

## 4. Technical verification

### 4.1 IPv6 UDP checksum

The integration passes no `udp6zerocsumtx` or `udp6zerocsumrx` option and exposes no zero-checksum
control. The target hardware session reported the IPv6 VXLAN with UDP checksum enabled and both
zero-checksum options disabled. This is target default behavior, not a new configuration. Local
capture warnings caused by checksum offload are documented as non-authoritative.

### 4.2 Encapsulation overhead and MTU terminology

The component table is 40+8+8+14 = 70 bytes for IPv6 and 20+8+8+14 = 50 bytes for IPv4. The
assumptions (1500-byte path, no outer tag, no IPv4 options, no IPv6 extension headers, no additional
encapsulation, no inner VLAN tag) are stated. The VXLAN netdev MTU is defined as the maximum inner IP
packet; the inner Ethernet header is not part of that MTU. The IPv6 1280-byte link minimum implies a
1350-byte underlay path for an IPv6 overlay at the minimum; a 1280-byte underlay path yields 1210 and
is not a valid IPv6 overlay design without a deliberate alternative.

### 4.3 Underlay PMTUD versus overlay PMTUD

The deployment guide now separates:

* underlay PMTUD — outer IPv6 path, VTEP receives Packet Too Big, VXLAN MTU must fit the path;
* overlay PMTUD — inner IPv6 end-to-end, Packet Too Big travels inside the tunnel, overlay firewall
  must permit it.

The integration does not fragment oversized outer IPv6 packets and does not rely on outer
fragmentation. Inner fragmentation is a recovery mechanism, not the design.

### 4.4 IPv6-only dataplane versus IPv6-only environment

The validated hardware runs used IPv6 underlay and IPv6 overlay addresses. They did not remove IPv4
from router management, the peer host, test tooling or CI. The documentation therefore claims an
IPv6-only **dataplane**, not an IPv6-only operational environment. Management, acquisition and CI are
explicit gaps in the deployment guide, matrix and backlog.

### 4.5 Firewall semantics and bridged enforcement

The docs state that `remote-ip` is not an ingress allowlist, that underlay UDP/4789 filtering is a
separate policy layer, and that overlay `in`/`out`/`local` attachments apply to decapsulated inner
traffic. Bridged VXLAN interfaces reject firewall attachments; bridge netfilter is not enabled and
Layer 2 enforcement is not claimed. The scripted-commit firewall limitation remains in the v0.3.0
support-boundary record.

### 4.6 Demonstrated versus inferred

The matrix now has an explicit **L — Inferred from Linux VXLAN** class. Rows 4 and 7 (IPv4 underlay
with IPv6 or dual-stack overlay) are marked inferred/partial rather than hardware-qualified. The
text states that a Linux VXLAN expectation is not an EdgeOS hardware result.

### 4.7 EdgeOS configuration syntax

The VXLAN examples were checked against the repository templates and helper behavior: interface name
`vxlanN`, required `vni`/`local-ip`/`remote-ip`, same-family endpoints, `port`, `mtu` range, `address`,
`bridge-group` membership/cost/priority, and firewall direction/family leaves. The bridge/ethernet/
firewall/protocol lines are stock EdgeOS syntax; they are not defined by this package's templates.
The firewall example now uses `protocol icmpv6` and `protocol udp`, which are exercised in the
hardware records, rather than type-specific ICMPv6 leaves that were not revalidated on the target.

## 5. Remaining IPv4-centric assumptions

* **Template help order.** `local-ip`/`remote-ip` still list the IPv4 `val_help` line first. This is
  CLI presentation, not a functional restriction; changing it changes packaged template content and
  needs a separate packaging change.
* **`udp_tunnel.ko` path.** The module remains under the vendor's `kernel/net/ipv4/` path. The path
  is a kernel/vendor convention; the module and `ip6_udp_tunnel` dependency serve both families.
* **IPv4 endpoint class validation is looser than IPv6.** The helper applies the multicast/loopback/
  unspecified checks only to IPv6. IPv4 endpoints are checked for format and family consistency but
  not those classes. The docs state this asymmetry; harmonizing the families is backlog item
  ENG-IPV6-06.
* **CI and acquisition.** The workflow and installer do not provide an IPv6-only execution path;
  this is backlog items ENG-IPV6-01 and ENG-IPV6-03.
* **Historical records.** `docs/issue-3-*`, `docs/v0.3.0-*` and the dated release records retain
  their original ordering and examples. They are evidence, not current guidance.

## 6. Documentation merge blockers and engineering priorities

**Documentation merge blockers at this review:** none. The current guides do not claim the gaps as
validated; the matrix and backlog name them.

**Future engineering priorities:** see [`../engineering-backlog.md`](../engineering-backlog.md) for
the seven entries and measurable acceptance criteria. In summary, the priorities are IPv6-only
installation/acquisition, IPv6-only management, IPv6-only CI, bridged IPv6-underlay dataplane,
remaining address-family hardware qualification, consistent IPv4/IPv6 endpoint validation, and
external VTEP qualification over routed networks.

## 7. Validation performed

| Check | Result |
|---|---|
| Origin/main unchanged | `origin/main` remains `f182a64`; branch is based on it |
| Off-device suite | `bash test/run.sh`: 349/349 pass (helper 64, firewall 122, templates 93, mock 70) |
| ShellCheck | Pass |
| `sh -n` / `bash -n` / `git diff --check` | Pass |
| Markdown links/anchors | Pass for current guides and audit record |
| Address-family example check | All VXLAN example blocks checked: node paths and values match the templates; no mixed-family endpoint pairs |
| Documentation address ranges | IPv6 `2001:db8::/32`; IPv4 RFC 5737; intentional unspecified/rejected examples only |
| RFC metadata | Cited RFCs resolve at the RFC Editor; status/update table checked on 2026-11-27 |
| Installer scope | `git diff f182a64 -- install.sh` shows only the printed example lines; version pins, hashes, `curl`, verification and `dpkg` transaction are unchanged |
| Namespace dataplane | Not run: no non-interactive root/CAP_NET_ADMIN |
| Live hardware | Not executed in this review; hardware claims cited from records |

## 8. Delivery record

| Item | Value |
|---|---|
| Branch | `docs/ipv6-first` |
| Base | `origin/main` `f182a64` |
| Divergence | Five commits on top of `origin/main`: three initial documentation commits, the final-review restructure, and a release-note reference fix; final HEAD reported at handoff |
| Runtime/CLI/kernel/package changes | None |
| Installer change | Printed example only; install logic unchanged |
| Merge/tag/publish | None performed |
| Working tree | Clean at handoff |

The final handoff reports the exact HEAD, changed-file summary and validation output.
