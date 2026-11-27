# Documentation audit — IPv6-first modernization

**Date:** 2026-11-27
**Repository:** `downwithbgp/edgeos-vxlan`
**Baseline:** `origin/main` at `f182a64` (v0.3.0 plus the release-engineering hardening merge)
**Working branch:** `docs/ipv6-first`
**Change class:** documentation and documentation-adjacent text. No runtime, CLI, template, kernel,
package-content, or install-logic change.

## 1. Method and authority

The audit read the current documentation, the implementation, the EdgeOS templates, the packaging
and installer, the off-device tests, and the hardware evidence records. Where documents disagreed,
the implementation and reproducible test evidence were treated as authoritative for product
behaviour; standards were treated as authoritative for protocol semantics. The vendor kernel and
userspace were treated as the platform, not as a generic modern Linux.

The audit did not run live-router tests. The hardware claims below are cited from the repository's
records; the validation performed for this change is listed in section 7.

Historical records were preserved. A record that says “not executed” remains a record of that
candidate or procedure even when a later record reports a completed qualification. Current status is
carried by the README, the architecture and deployment guides, and the support matrix, not by
rewriting the history.

## 2. Documentation inventory and disposition

| Document | Class | Disposition |
|---|---|---|
| `README.md` | Current entry point | Modernized: IPv6-first order, primary IPv6 example, installation/build corrections, IPv6 operational guidance, scope and evidence corrections |
| `docs/ipv6-first-architecture.md` | New current document | Layer model, endpoint rules, MTU table, scope, standards and applicability |
| `docs/ipv6-first-deployment.md` | New current document | Six scenarios in the required order, both endpoints, operations, IPv6-only assessment |
| `docs/address-family-support-matrix.md` | New current document | Capability and validation matrix by underlay/overlay, bridge, firewall, IPv6-only area |
| `docs/README.md` | New current document | Documentation map and historical/current separation |
| `install.sh` | Documentation-adjacent | Printed configuration example made IPv6-first; install logic unchanged |
| `docs/issue-3-*.md` | Historical | Preserved. Records the v0.2.1 → v0.2.2 IPv6-underlay work, test designs, evidence and release gate |
| `docs/release-notes-v0.2.2.md` | Historical | Preserved |
| `docs/v0.3.0-*.md` | Historical/current release records | Preserved. Includes the firewall architecture, support boundary, qualification report, RC artifacts and migration record |
| `docs/release-engineering-hardening.md` | Post-release record | Preserved |
| `src/`, `templates/`, `debian/`, `test/` | Implementation | Not rewritten. No IPv4-only code path found; presentation-level IPv4-first ordering remains noted in section 5 |

## 3. Corrections made

### 3.1 Entry-point ordering and examples

* The README opened with “Native IPv4 and IPv6” and an IPv4-underlay/IPv4-overlay example. It now
  opens with “Native VXLAN for IPv6 and IPv4 underlays”, states IPv6 is the primary deployment
  model, and uses an IPv6-underlay/IPv6-overlay example first.
* The README's IPv6-underlay example previously paired IPv6 VTEP endpoints with an IPv4 overlay
  address. The primary example now uses an IPv6 overlay; IPv4 overlay examples remain in the
  interoperability scenarios.
* The README configuration section was reorganized into the six-scenario order: IPv6/IPv6,
  IPv6/bridged, IPv6/dual-stack, IPv4-underlay/IPv6-overlay, IPv6-underlay/IPv4-overlay, and
  IPv4/IPv4 legacy.
* The installer's printed “Example configuration” block was IPv4-first. It now prints an IPv6
  underlay and IPv6 overlay example. The installer's checks, downloads, hashes and `dpkg`
  transaction are unchanged.

### 3.2 Stale or incorrect statements

| Location | Problem | Correction |
|---|---|---|
| README native-firewall “Hardware validation status” | Said “Hardware acceptance has not been executed” after the RC5 qualification report recorded completed hardware qualification | States that RC5 hardware qualification was completed; independent external OCI probes remain deferred |
| README Known limitations | Said “Hardware acceptance is pending” | Replaced with the actual remaining limitation (deferred external probes and the documented scope boundary) |
| README Installation | Generic v0.3.0 install section used `0.2.2` package filenames | Uses the v0.3.0 filenames |
| README Building | Said the v0.3.0 release was shown but listed `0.3.0~rc1` filenames | Uses `<version>` placeholders and notes the version comes from `debian/changelog` |
| README introduction | “The v0.2 kernel package” implies a historical package only | Refers to the kernel package that carries the CVE-2022-50405 backport |
| README Known limitations | “Upgrade from v0.2.2 with a live IPv4 firewall attachment” is not a meaningful state: v0.2.2 has no native `interfaces vxlan firewall` attachments | Restates the actual gap: the v0.2.1/v0.2.2 upgrade with an existing live IPv4 VXLAN was not hardware-tested; the v0.3.0 upgrade from the qualified RC5 with live native attachments was |
| README “current implementation validated” sentence | Omitted IPv4-over-IPv6 and IPv6-over-IPv4 combinations and implied a broader claim than the evidence | Points to the support matrix, which classifies each combination and its gaps |
| README MTU guidance | Formula was present but the assumptions and the IPv6 minimum-MTU consequence were not | Added the component table, stated assumptions, inner-VLAN and outer-tag effects, and the 1280-byte IPv6 minimum consequence |
| README/bridged section | No IPv6-underlay bridged example | Added a primary bridged IPv6 scenario; retains the IPv4-underlay bridged example as legacy |
| README/underlay trust | IPv4 example preceded the IPv6 example | IPv6 underlay filtering is presented first; IPv4 remains complete |
| README/native firewall | No explicit statement that the overlay policy family is independent of the underlay family | Stated in the firewall section and in the dual-stack scenario |
| Current documentation/no standards references | No RFC citations existed in the current documentation | Added a standards and applicability table to the architecture note, with RFC Editor status verified on 2026-11-27 |
| README/scope | “Dynamic peer discovery” was not listed among the not-implemented items | Added it alongside EVPN, multicast, multiple remote VTEPs and hardware offload |

### 3.3 Technical precision added

* The layer model now distinguishes underlay transport, VTEP endpoint addressing, VXLAN
  encapsulation, overlay Ethernet forwarding, overlay Layer 3 addressing, and management-plane
  connectivity.
* The documentation states that VXLAN transports Ethernet and does not translate protocols.
* The six scenarios are documented in the requested order, each with both endpoints and verification
  commands.
* IPv6 operational guidance now covers PMTUD and ICMPv6 Packet Too Big, Neighbor Discovery,
  Router Advertisements and SLAAC, the IPv6 minimum MTU, source-address selection, endpoint scope,
  UDP checksum behaviour, firewall boundaries, fragmentation, routing/asymmetry, overlay multicast
  and link-local traffic, and management-plane independence.
* The IPv6-only assessment distinguishes the validated dataplane from unvalidated management,
  package acquisition, CI and test-environment claims.
* The support matrix separates implementation, automated off-device, simulated EdgeOS, Linux
  namespace, and physical hardware evidence, and names the gaps.

## 4. Technical inaccuracies corrected

The following are the substantive corrections, as opposed to ordering or presentation changes:

1. **Hardware status.** The README claimed hardware acceptance was pending/not executed while the
   v0.3.0 qualification report records RC5 hardware qualification. The README now separates
   hardware-qualified scope from deferred external probes.
2. **v0.2.2 firewall upgrade.** The README described an upgrade from v0.2.2 “with a live IPv4
   firewall attachment”. v0.2.2 does not have native VXLAN firewall attachments; the native
   attachment subtree is a v0.3.0 feature. The text now describes the actual historical gap.
3. **Installation filenames.** The generic installation section for the current v0.3.0 release used
   v0.2.2 package names.
4. **Build filenames.** The README said the v0.3.0 release was shown but used RC1 package names.
5. **Kernel-package wording.** “The v0.2 kernel package” was stale for the current release line.
6. **Overlay/underlay conflation.** The old IPv6-underlay example used an IPv4 overlay address,
   which could be read as requiring IPv4 on top of an IPv6 underlay. The primary example and the
   deployment guide now separate the two choices.
7. **Validation scope.** The old “validated for…” sentence was narrower than the matrix and did not
   distinguish IPv4-underlay/IPv6-overlay or IPv4-underlay/dual-stack evidence. The matrix now
   states each combination's evidence class and gaps.
8. **MTU assumptions.** The old formula did not state the no-extension-header, no-inner-VLAN,
   no-additional-encapsulation assumptions or the IPv6 1280-byte minimum consequence.
9. **IPv6-only claim.** The documentation did not previously separate dataplane IPv6-only operation
   from management, acquisition and CI. The deployment guide now does.
10. **Standards.** The current documentation had no RFC citations. The architecture note now records
    the status and update relationships of the relevant RFCs and limits their applicability to the
    vendor platform.

Historical records were not edited to remove statements that were true at their date but are no
longer current. The audit report is the reconciliation layer.

## 5. Remaining IPv4-centric assumptions

### 5.1 Implementation and packaging

* **Template help order.** `local-ip`/`remote-ip` declare `type: ipv4,ipv6` and list the IPv4
  `val_help` line first. This is presentation in the CLI, not a functional restriction; the
  templates accept both families and the reconciler enforces the family. Changing the help order
  would change packaged template content and therefore requires a separate packaging change.
* **Kernel module path.** `udp_tunnel.ko` is installed under the vendor's
  `kernel/net/ipv4/udp_tunnel.ko` path. The path name is a kernel/vendor convention; the module and
  the `ip6_udp_tunnel` dependency serve both families. The path must be preserved for module
  dependency resolution.
* **Package and changelog text.** `debian/changelog` and historical release notes describe IPv4
  before IPv6. They are historical records; rewriting them would falsify the release history.
* **IPv4 endpoint class validation is looser than IPv6.** The address helper applies the
  multicast/loopback/unspecified checks only to IPv6; IPv4 endpoints are checked for format and
  family consistency but not for those classes. This is the v0.2.x behaviour, not a regression, and
  the current docs state it explicitly. Harmonising the two families is a follow-up, not a change
  made by this documentation pass.
* **No other functional IPv4-only code path found.** The reconciler, templates, firewall helper,
  bridge helper, `Interface.pm` change, packaging guards and kernel payload are family-aware or
  family-independent. The endpoint parser deliberately implements the platform's non-canonical IPv4
  octal interpretation rather than silently rebinding it.

### 5.2 Tooling and validation

* **CI environment.** The workflow runs on GitHub-hosted Ubuntu and does not provide an IPv6-only
  runner or network. The namespace test configures both address families on the same underlay.
* **Installer acquisition.** `install.sh` uses HTTPS and DNS to reach GitHub. The script contains no
  IPv4 literal, but an IPv6-only acquisition path has not been tested; the same applies to the
  GitHub release endpoints and DNS resolution.
* **Network-namespace coverage.** `test/integration-netns.sh` covers IPv4-underlay/IPv4-overlay,
  IPv6-underlay/IPv6-overlay and firewall semantics. It does not cover IPv4-underlay/IPv6-overlay,
  IPv4-underlay/dual-stack, or an IPv6-only namespace with IPv4 disabled.
* **Diagnostics.** The vendor `ip -d` human output is defective on this platform; documentation now
  consistently directs operators to `ip -j -d`. `show interfaces` also emphasizes IPv4 addressing in
  some views; the guide uses `ip -6 addr` where the IPv6 overlay address matters.
* **Historical documents.** The `docs/issue-3-*` and `docs/v0.3.0-*` records retain their original
  IPv4-first ordering and examples. They are evidence records, not the current entry point.

### 5.3 Scope assumptions that remain intentional

* IPv4 remains supported and is not deprecated. The default MTU for an IPv4 underlay remains 1450.
* The kernel module retains its vendor `udp_tunnel` path and dependency graph.
* The product remains a fixed-remote, point-to-point VXLAN integration. IPv6-first does not add EVPN,
  multicast, dynamic peer discovery, multiple remote VTEPs, or hardware offload.

## 6. IPv6-only deployability findings

| Area | Finding | Status |
|---|---|---|
| VXLAN dataplane | IPv6 underlay with IPv6 overlay, and dual-stack overlay, validated on the ER-X with static endpoints | Supported and validated |
| Router management | EdgeOS management over IPv6 is outside this project's validation; the project does not test an IPv4-free management plane | Not validated |
| Package acquisition | HTTPS/DNS path to GitHub; no IPv6-only acquisition test; offline pre-staged `dpkg` install is possible | Not validated |
| CI/test | No IPv6-only CI job; tests configure both families | Not provided |
| Diagnostics | `ip -6`, `ping6`, `ip6tables`, `tcpdump`, `ss` available; vendor `ip -d` defective | Available with the JSON caveat |

The defensible claim is therefore: **the VXLAN dataplane can be IPv6-only; complete IPv6-only
installation, management and CI are not yet validated.** The README and deployment guide use that
wording.

## 7. Recommended follow-up work, prioritized

### P0 — before broadening the IPv6-only or combination-support claim

1. **Hardware dataplane run for IPv4 underlay + IPv6 overlay.** The implementation supports it; the
   published record does not separately qualify it. Add a two-endpoint run and record it in the
   matrix.
2. **Hardware dataplane run for IPv4 underlay + dual-stack overlay.** Resolve the current partial
   evidence; the emulated-engine record is not a dataplane qualification.
3. **Bridged-traffic run over an IPv6 underlay.** Bridge membership, cost and priority are verified;
   packets over the bridged tunnel are not. Add a bridged dataplane run before claiming the bridged
   model is fully validated.
4. **IPv6-only management and acquisition test, or a narrower supported statement.** Test DNS,
   HTTPS, package staging and SSH management in an IPv4-free environment, or keep the current
   explicit non-claim.
5. **IPv6-only CI or test-environment job.** Add a network namespace with IPv4 disabled and an
   IPv6-only install/acquisition check where the environment supports it.

### P1 — correctness and regression coverage

6. **PMTUD/ICMPv6 Packet Too Big test.** Add an automated or namespace test that blocks PTB and
   demonstrates the failure mode, and a positive test with PTB permitted.
7. **Dynamic underlay boot test.** Exercise SLAAC/DHCPv6 address arrival before and after
   configuration replay; record the timing and the failure mode.
8. **Documentation example validator.** Parse the EdgeOS configuration blocks, check the template
   grammar, canonical IPv6 representation, RFC 3849/9637 and RFC 5737 prefixes, and fail on
   non-documentation addresses.
9. **IPv4 endpoint class validation.** Apply the same multicast/loopback/unspecified checks to
   IPv4, or keep the documented asymmetry and test the IPv4 acceptance boundary explicitly.
10. **Source-address selection and asymmetric return-path test.** Cover an unspecified `local-ip`
    and a return path that differs from the forward path.
11. **Installer IPv6-only test.** Validate DNS and HTTPS acquisition over IPv6, or document and test
    the offline pre-staged path.

### P2 — presentation and release engineering

12. **Template help ordering.** Put the IPv6 `val_help` line first in `local-ip`/`remote-ip` in a
    separate packaging change, after the functional scope is settled.
13. **External OCI probes.** Complete the deferred Internet-facing positive/negative probes for the
    v0.3.0 firewall qualification.
14. **Package removal/downgrade qualification.** The v0.3.0 hardware report records that these were
    not qualified; the v0.2.x removal record remains the relevant evidence.
15. **Validate the example ICMPv6 keywords.** Paste the `icmpv6 type` examples
    (`neighbour-solicitation`, `neighbour-advertisement`, `packet-too-big`,
    `destination-unreachable`, `time-exceeded`, `parameter-problem`) into an EdgeOS 3.0.1 session and
    confirm the CLI accepts the spelling.
16. **Documentation maintenance.** Keep the current/historical split in `docs/README.md`; update the
    matrix when a new hardware or CI result is added.

## 8. Validation performed for this change

| Check | Command / source | Result |
|---|---|---|
| Baseline branch and tree | `git status --short --branch`, `git log` | Branch `docs/ipv6-first` from `origin/main` `f182a64`; clean baseline |
| Off-device suite | `bash test/run.sh` | 349/349 pass: helper 64, firewall 122, templates 93, mock 70 |
| Perl syntax | covered by `test/run.sh` (`perl -c src/vyatta-vxlan-addr`) | Pass |
| Shell syntax | covered by `test/run.sh` (`bash -n` for source/test scripts) | Pass |
| Link/anchor check | local script over the new/edited Markdown | No broken relative links or anchors in the changed documents |
| Documentation-prefix check | local script over the changed documents | IPv6 examples use `2001:db8::/32`; IPv4 examples use RFC 5737 prefixes; no third-party global addresses introduced |
| RFC metadata | RFC Editor JSON and errata pages for the cited RFCs, 2026-11-27 | Status and update relationships recorded in the architecture note |
| ShellCheck | `shellcheck install.sh src/vyatta-vxlan src/vyatta-vxlan-bridge src/vyatta-vxlan-firewall test/*.sh` | Pass |
| Namespace dataplane | `sudo REQUIRE_NETNS_TEST=1 bash test/integration-netns.sh` | Not run: the audit environment has no non-interactive root/sudo; no namespace result is claimed (section 8.1) |
| Diff check | `git diff --check` | Pass (no whitespace errors) |
| Review | Two independent diff reviews | All should-fix findings addressed: IPv4/IPv6 endpoint-class qualification, ICMPv6 Packet Too Big and error coverage in the tunnelbroker example, duplicate heading/scenario reference, evidence labels, legacy IPv4 bridged example, and namespace-test wording |

### 8.1 Validation limitations

* No live EdgeRouter X was used for this change. Hardware statements are cited from the repository's
  records, not re-executed.
* The namespace test was not run in this environment because non-interactive root/CAP_NET_ADMIN was
  unavailable. It remains general-Linux evidence and is not EdgeOS 3.0.1 validation; no result is
  claimed.
* The RFC metadata check confirms status and update relationships, not that the vendor kernel
  implements every requirement.
* The documentation examples were checked structurally and against the test grammar; they were not
  applied to a production router.
* The `icmpv6 type` keywords used in the examples (`neighbour-solicitation`,
  `neighbour-advertisement`, `packet-too-big`, `destination-unreachable`, `time-exceeded`,
  `parameter-problem`) were not pasted into an EdgeOS 3.0.1 CLI in this environment. They follow the
  vendor's keyword family and existing repository usage; validate them on the target before
  production.
* The build/package commands were not rerun for this documentation-only change; the package payload
  is not modified.

## 9. Delivery record

| Item | Value |
|---|---|
| Branch | `docs/ipv6-first` |
| Base | `origin/main` `f182a64` |
| Documented change | Documentation and installer-example text only |
| Runtime/CLI/kernel/package changes | None |
| Merge/tag/publish | None performed |
| Final commit SHA | Reported in the maintainer handoff after the final commit |
| Working tree | Clean at handoff |
| Push | Not performed |

The final handoff also reports the changed-file summary and the exact verification output.
