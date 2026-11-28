# IPv6 engineering backlog

**Status:** repository-local engineering proposals. No remote GitHub issue has been created.
**Scope:** work needed to broaden the validated IPv6 surface of `edgeos-vxlan` beyond the current
documented scope. These are not documentation merge blockers unless a future document turns one of
them into a supported claim.

The current support statement is in [`address-family-support-matrix.md`](address-family-support-matrix.md).
The point-in-time audit that identified these gaps is
[`audit/2026-11-documentation-audit.md`](audit/2026-11-documentation-audit.md).

## Classification

| Class | Meaning |
|---|---|
| **Documentation merge blocker** | A claim in the current docs is wrong or unsupported and must be fixed before merge. |
| **Engineering priority** | A real capability or validation gap; the docs may merge while the gap is stated honestly. |
| **Future opportunity** | Useful work that does not gate the current documentation. |

At this review, **no open documentation merge blocker remains**. The entries below are engineering
priorities or future opportunities. The documentation explicitly does not claim their acceptance
criteria as met.

## IPv4 dependency audit (2026-11-27)

The repository-wide inventory is in [`ipv4-dependency-inventory.md`](ipv4-dependency-inventory.md).
Its findings map to ENG-IPV6-01 (installer/acquisition), ENG-IPV6-02 (management), ENG-IPV6-03
(CI/test execution), ENG-IPV6-06 (endpoint validation) and ENG-IPV6-08 (firewall state capture).
The audit also fixed the incidental CI dependency on unrelated third-party APT repositories; it did
not change product runtime semantics, installer behavior or release assets.

## Priority summary

| ID | Item | Priority | Gates a current claim? |
|---|---|---|---|
| ENG-IPV6-01 | IPv6-only installation and package acquisition | P0 | No, provided the limitation remains stated |
| ENG-IPV6-02 | IPv6-only router management | P0 | No, provided the limitation remains stated |
| ENG-IPV6-03 | Native IPv6-only CI and test execution | P0 | No, but it gates regression confidence |
| ENG-IPV6-04 | IPv6-underlay bridged Ethernet dataplane validation | P0 | No, provided bridged dataplane is not claimed |
| ENG-IPV6-05 | Remaining address-family hardware qualification | P0 | No, provided the matrix gaps remain explicit |
| ENG-IPV6-06 | Consistent IPv4 and IPv6 endpoint validation | P1 | No, the asymmetry is documented |
| ENG-IPV6-07 | External VTEP qualification over real routed networks | P1 | No, external acceptance is not claimed |
| ENG-IPV6-08 | Family-selective firewall state capture | P1 | No, provided the current limitation remains stated |
| ENG-IPV6-09 | Routed-underlay PMTUD and ICMPv6 Packet Too Big qualification | P1 | No, provided the local-MTU limitation remains stated |
| ENG-IPV6-10 | Modern iproute2 JSON diagnostic tolerance | P2 | No, provided the supported-platform boundary remains stated |
| ENG-IPV6-11 | Trusted release-candidate IPv6 qualification integration | P0 | **Yes — must be complete before production release publication is enabled** |

---

## ENG-IPV6-01: IPv6-only installation and package acquisition

**Problem.** `install.sh` downloads release assets over HTTPS to GitHub and therefore depends on DNS
and on an IPv6-reachable HTTPS endpoint. No IPv6-only acquisition test exists. The package files
themselves can be installed offline with `dpkg`, but that path is not documented as a tested
IPv6-only procedure. The 2026-11-27 audit observed no AAAA records for the GitHub release endpoints
in one environment; this is a point-in-time external-service observation, not a permanent or
universal claim. Re-check the endpoints at release time and provide a mirror or offline procedure
rather than assuming the result.

**Technical significance.** A deployment that has no IPv4 connectivity cannot use the network
installer unless DNS, HTTPS, and every redirect are reachable over IPv6. This is separate from the
VXLAN dataplane, which has been validated with IPv6 only.

**Proposed validation methodology.**

1. Build an IPv4-free test network with an IPv6-only DNS resolver and an HTTPS mirror that serves the
   release assets.
2. Run `install.sh --check` and the install path from the router with no IPv4 address and no IPv4
   default route.
3. Record DNS resolution, TLS connection, redirect handling, checksum verification, and `dpkg`
   transaction.
4. Separately test the offline path: copy both `.deb` files and `SHA256SUMS` over an IPv6-only
   transfer, verify hashes, and install with `dpkg`.
5. Test the failure mode when only an IPv4 route exists, so the error is explicit.

**Dependencies.** IPv6-only test network; DNS with AAAA records; HTTPS mirror or upstream endpoint
with IPv6 reachability; release artifacts; no change to package payload unless the installer needs a
fallback or an offline mode.

**Acceptance criteria.**

* A supported router with no IPv4 address or route completes `install.sh --check` and the package
  installation over IPv6 only.
* Both package hashes verify against the pinned values.
* The offline pre-staged `dpkg` path is documented and passes the same verification.
* A deliberate IPv4-only environment produces an explicit, documented failure rather than a partial
  install.
* The README states the tested acquisition modes and their prerequisites.

---

## ENG-IPV6-02: IPv6-only router management

**Problem.** The project validates the VXLAN dataplane, not the router's management plane. No
hardware run has removed IPv4 management addresses and verified SSH, DNS, NTP, logging, monitoring
and recovery over IPv6 only.

**Technical significance.** Operators need an independent management path that does not depend on
the tunnel. An IPv6-only dataplane is not an IPv6-only operational deployment if management still
requires IPv4.

**Proposed validation methodology.**

1. On a lab router, configure an IPv6-only management VLAN or physical interface, SSH, DNS, NTP and
   a monitoring endpoint over IPv6.
2. Remove IPv4 addresses and IPv4 default routes from the management path, retaining a console.
3. Verify SSH, configuration commit, monitoring, logging, and a reboot.
4. Test recovery from a failed commit and from a lost management address using the console.
5. Record which EdgeOS services still require IPv4 or a dual-stack dependency.

**Dependencies.** Lab router with console; IPv6-only management network; external IPv6 DNS/NTP/
monitoring endpoints; documented recovery procedure.

**Acceptance criteria.**

* SSH and configuration commits work over IPv6 only.
* DNS, NTP, logging and monitoring work over IPv6 only, or each residual IPv4 dependency is listed.
* A reboot restores the IPv6 management path without manual intervention.
* The console recovery procedure is documented and exercised.
* The README/deployment guide clearly states the validated management scope.

---

## ENG-IPV6-03: Native IPv6-only CI and test execution

**Problem.** The CI workflow runs on GitHub-hosted Ubuntu and the original tests configure both
address families on the same interfaces. There was no job that establishes an isolated IPv6-only
workload and proves the dataplane, helpers and qualification assertions work without usable IPv4
connectivity.

**Technical significance.** Without an IPv4-free execution environment, an implicit IPv4 dependency
can enter the test fixtures or CI wiring. The dataplane tests alone do not prove an IPv6-only
environment, and a successful IPv6 ping is not sufficient evidence.

**Proposed validation methodology.**

1. Provide a self-hosted runner or a container/network-namespace job with IPv4 disabled.
2. Pre-bake or mirror build dependencies so `apt` and the package build do not need IPv4.
3. Run `bash test/run.sh`, the namespace dataplane test, and the installer acquisition test with only
   IPv6 connectivity.
4. Add a negative check that fails if a test or script introduces an IPv4-only dependency.
5. Keep the existing dual-stack coverage; do not replace IPv4 regression tests with the IPv6-only
   job.

**Dependencies.** IPv6-only runner or network namespace; IPv6 package mirror or pre-baked image;
GitHub Actions policy/approval; CI secrets must not be committed.

### Current state (2026-11-27)

**Level B implemented at the Linux network-namespace evidence class.**

* `test/ipv6-only-netns.sh` builds a deterministic topology with two independent VTEPs, a routed
  IPv6 underlay through a transit namespace, separate VNIs, host endpoints, explicit MTUs and
  negative controls. See [`ipv6-only-qualification.md`](ipv6-only-qualification.md).
* `test/lib/ipv6-isolation.sh` implements the Level B assertions: no global IPv4 addresses, no
  IPv4 routes (including policy tables), default IPv4 rules only, empty `/proc/net/route`, IPv4
  forwarding off, no NAT64/CLAT interfaces or routes, expected interface kinds, distinct namespace
  boundaries, no host-side veth, and an `AF_INET` external-send negative control.
* The suite includes an N6-R section that runs the actual `src/vyatta-vxlan` reconciler inside the
  VTEP namespaces. The EdgeOS configuration API, firewall dispatch, bridge helper and
  `vyatta-address` wrapper are test doubles; the kernel, `ip`, sysfs, MTU, address, recreation and
  rollback paths are real. This is explicitly partial, not hardware or EdgeOS-engine evidence.
* `.github/workflows/ci.yml` has an `ipv6-only` job on trusted events only. It depends on the
  `package` job, fetches the same-run package artifact by immutable ID/digest, runs N6-R-P against
  the exact integration `.deb`, validates the candidate-bound summary, uploads evidence on every
  outcome, and has an `always()` cleanup step. The job grants only `contents: read` and
  `actions: read`; no `pull_request_target` or publication path is used.
* `scripts/apt-update-ubuntu-only.sh` scopes CI dependency refresh to the distribution's own source
  file. The dataplane job checks for tools before acquiring them; the IPv6-only job uses the runner
  image and installs only tcpdump when capture tooling is absent.
* The existing off-device suite remains green at 376 checks (11 build + 64 helper + 122 firewall +
  93 templates + 70 mock + 16 qualification-evidence contract). The new namespace suite is separate
  and reports its own pass/fail/skip counts.

**Level C and Level D are not achieved.** Installer/management over IPv6 only is deferred to
ENG-IPV6-01/02. The CI runner and control plane remain dual-stack; GitHub Release endpoints returned
no AAAA records in the audit environment. A GitHub-hosted dual-stack runner with IPv6-only
namespaces is Level B, not Level D.

**Acceptance criteria.**

* [x] An isolated IPv6-only workload job runs on trusted push, tag, release and manual-dispatch
  events; pull requests are excluded because the job needs `CAP_NET_ADMIN`.
* [x] The isolated environment is established reproducibly and the absence of usable external IPv4
  connectivity is asserted.
* [x] Negative controls demonstrate that the assertions detect an introduced IPv4 address, route
  and policy route, and that overlay connectivity fails when the VXLAN dataplane is interrupted.
* [x] IPv6 VXLAN dataplane functionality is demonstrated (ICMPv6, NDP, TCP, UDP, routed underlay,
  encapsulation counters, MTU boundary, recreation).
* [x] The degree to which project integration code is exercised is documented (N6-R partial).
* [x] Existing dual-stack and IPv4 regression jobs remain in place.
* [x] CI dependency acquisition is scoped and does not depend on unrelated third-party repositories
  for the namespace jobs.
* [ ] A deliberately introduced IPv4-only toolchain or test-harness dependency fails the job with
  a clear error. The current negative controls validate the isolation validator and dataplane
  interruption; they do not prove that an arbitrary toolchain dependency is rejected. This
  criterion remains open.
* [x] The authoritative hosted job requires packet capture; tcpdump is installed from the
  distribution source in a separate dependency-preparation step if absent. Capture startup,
  completion, non-empty output, VXLAN/IPv6/TCP/UDP/ND observations and absence of IPv4/ARP are
  checked; a failed capture fails the job.
* [x] The authoritative hosted run passed: run 46044226321 at `7d6762f`, 113 pass / 0 fail / 2 skip, capture
  executed, reconciler executed, package/reproducibility jobs green.
* [x] The actual reconciler path is exercised for creation, IPv6 endpoint validation, address/MTU
  application, idempotent reapplication, recreation, rollback, deletion and reconciler-created
  IPv6 TCP/UDP.
* [x] Base-versus-branch package equality and published-versus-canonical package differences are
  resolved and recorded: published v0.3.0 (`c555a99a…`/`73059ba2…`) is not byte-identical to the
  canonical rebuild (`7ffe10f6…`/`6afa3f25…`) because historical mtimes were not normalized; every
  payload/control member is content-identical. See
  [`ipv6-only-qualification-evidence.md`](ipv6-only-qualification-evidence.md#51-package-integrity-reconciliation).
* [x] Candidate-package mode (N6-R-P) verifies and extracts the exact integration `.deb`, executes
  the packaged reconciler/address helper, and records candidate/package identity and exercised-file
  hashes.
* [x] `scripts/validate-ipv6-qualification-evidence.py` and 16 positive/negative fixtures validate
  candidate-bound identity, evidence hashes, required checks, permitted skips/workarounds and
  malformed or substituted evidence.
* [x] The job is ported into the trusted-release-lifecycle `ci.yml` and binds its evidence to the
  same-run package artifact, source commit, workflow identity and packaged reconciler hashes.
* [x] The evidence is wired into the release candidate manifest and publication gate (ENG-IPV6-11,
  implemented and hosted-demonstrated on the development branch; the main-branch production
  candidate remains blocked by version eligibility, not by the IPv6 gate). See
  [`release-candidate-ipv6-qualification.md`](release-candidate-ipv6-qualification.md) §12.
* [x] The candidate builder supplies the validated IPv6 evidence before candidate ID/attestation;
  `validate-candidate.sh`/`check-release-gates.sh` reject missing/failed/unpermitted IPv6 checks.
  Candidate-gate fixtures are in `test/unit-release-ipv6-gate.sh`.
* [x] The hosted run itself exposed a modern-iproute2 JSON diagnostic (`info: Using default fan map
  value`) on stdout. The N6-R harness filters only that non-JSON line and records a skip; the real
  reconciler, kernel and exit statuses are unchanged. This is a test-environment compatibility shim,
  not a product fix; the supported EdgeOS behavior is unchanged. Tracked as ENG-IPV6-10.
* [ ] Level C: installer, package acquisition and management over IPv6 only. Deferred to
  ENG-IPV6-01/02.
* [ ] Level D: IPv6-only runner/control plane/source and artifact acquisition. Not achievable with
  the current GitHub-hosted infrastructure.
* [ ] Hardware qualification of the new isolation model. Not part of Level B; no production router
  was accessed.

**Evidence record:** [`ipv6-only-qualification-evidence.md`](ipv6-only-qualification-evidence.md).

---

## ENG-IPV6-04: IPv6-underlay bridged Ethernet dataplane validation

**Problem.** Bridge membership, path cost and port priority have been validated on the ER-X, but
packets over a bridged VXLAN tunnel with an IPv6 underlay were not part of the published hardware
run. The current docs state this gap.

**Technical significance.** A bridged VXLAN is a supported configuration shape. Bridge-state
reconciliation without bridged traffic evidence does not prove the dataplane, FDB learning, NDP
behavior, or MTU handling.

**Proposed validation methodology.**

1. Build a two-endpoint bridged topology with an IPv6 underlay, a bridge on each endpoint, and IPv6
   overlay addresses on the bridges.
2. Verify bidirectional ICMPv6, NDP resolution, TCP, and FDB learning.
3. Exercise bridge membership, cost and priority changes; recreate the VXLAN identity; reboot.
4. Confirm firewall attachments on the bridge port are rejected.
5. Capture counters and packet captures; record MTU behavior.

**Dependencies.** Two routers or a router plus a Linux VTEP peer; lab network; console/management
path; test plan and evidence capture.

**Acceptance criteria.**

* Bidirectional IPv6 overlay traffic passes over the bridged IPv6-underlay tunnel.
* NDP resolves and the FDB learns the peer MAC.
* Bridge membership, cost and priority survive recreation and reboot.
* Firewall attachment on the bridged VXLAN is rejected.
* The matrix row moves from partial to hardware-validated.

---

## ENG-IPV6-05: Remaining address-family hardware qualification

**Problem.** The matrix marks two combinations as implemented but not separately hardware-qualified:
IPv4 underlay with IPv6 overlay, and IPv4 underlay with dual-stack overlay. The published hardware
records also do not separately classify a full IPv4-underlay dual-stack dataplane run.

**Technical significance.** The implementation is family-independent at the VXLAN layer, but
"implemented" is not the same as "demonstrated on the supported platform." The docs must not blur
that distinction.

**Proposed validation methodology.**

1. Use the existing two-endpoint test plan and the documentation address ranges.
2. For each missing combination, verify creation, identity, MTU, bidirectional overlay traffic,
   firewall attachments in both families where applicable, recreation, rollback and save/reboot.
3. Capture `ip -j -d`, counters, `dmesg`, firewall state and packet captures.
4. Update the matrix with the exact evidence class and any limitations.

**Dependencies.** Hardware or approved lab equivalent; peer; test plan; maintenance window.

**Acceptance criteria.**

* IPv4-underlay/IPv6-overlay passes bidirectional dataplane, firewall, recreation and reboot tests.
* IPv4-underlay/dual-stack passes the same matrix.
* The matrix and README are updated with the new evidence.
* Any remaining unqualified combination is explicitly listed, not inferred from a neighboring row.

---

## ENG-IPV6-06: Consistent IPv4 and IPv6 endpoint validation

**Problem.** `vyatta-vxlan-addr` applies the multicast, loopback and unspecified checks to IPv6
only; IPv4 endpoints are checked for format and family consistency but not for those classes. The
documentation now states this asymmetry, but the validation behavior is inconsistent.

**Technical significance.** The validation boundary should be predictable across address families.
An IPv4 multicast, loopback or unspecified remote endpoint can be accepted even though the
equivalent IPv6 endpoint is rejected. This is a validation and operational-safety issue, not a
dataplane failure.

**Proposed validation methodology.**

1. Decide the policy: apply the IPv6 class rules to IPv4, or retain the asymmetry with explicit
   documentation and tests.
2. If changing behavior, implement it in `vyatta-vxlan-addr` and adjust the templates/tests.
3. Add table-driven tests for IPv4 multicast, loopback, unspecified local/remote and broadcast.
4. Re-run the helper, template, mock and namespace suites.
5. Review backward compatibility for existing accepted IPv4 configurations; this is a runtime change
   and requires separate approval.

**Dependencies.** Implementation change approval; packaging/release process; regression matrix.

**Acceptance criteria.**

* The chosen policy is documented once and tested for both families.
* Existing canonical IPv4 configurations that remain valid are not broken.
* The helper rejects or accepts the same classes consistently, with explicit messages.
* The matrix and endpoint table reflect the tested behavior.

---

## ENG-IPV6-07: External VTEP qualification over real routed networks

**Problem.** The v0.3.0 qualification deferred independent external OCI positive/negative probes.
Local VTEP results and router-originated connectivity do not prove a real routed Internet path,
external firewall behavior, PMTUD across multiple hops, or an external VTEP's configuration.

**Technical significance.** The project should not claim Internet-facing acceptance from a local
test fixture. External qualification is needed before describing the firewall and PMTUD behavior as
operationally proven over a routed path.

**Proposed validation methodology.**

1. Provision an external host on a routed network and a VTEP peer controlled by the test.
2. Run positive and negative probes for IPv4 and IPv6 overlays, underlay UDP/4789, and the native
   firewall directions.
3. Exercise PMTUD with a path MTU below 1500 and verify ICMPv6 Packet Too Big behavior.
4. Test asymmetric routing and return-path behavior.
5. Record packet captures and counters without publishing operational addresses or secrets.

**Dependencies.** External host and VTEP; routed network; test credentials kept outside the repo;
coordination with the infrastructure owner.

**Acceptance criteria.**

* The defined external probe matrix passes.
* PMTUD/PTB and firewall deny paths are demonstrated across a routed path.
* Failure modes and limitations are documented.
* No operational addresses, credentials or third-party identifiers are committed.
* The docs distinguish external evidence from local VTEP and router-originated evidence.

---

## ENG-IPV6-08: Family-selective firewall state capture

**Problem.** `src/vyatta-vxlan-firewall` `capture_state()` reads the IPv4 `iptables -S` table and
the IPv6 `ip6tables -S` table for every capture, even when only an IPv6 attachment is configured.
The supported EdgeOS platform supplies both tools, so this is not a current deployment failure. On
a kernel or userland without IPv4 firewall tooling it would be a hard dependency for an IPv6-only
attachment, and therefore for a fully IPv4-free lifecycle.

**Technical significance.** The project claims IPv6-only dataplane operation, not IPv6-only
firewall-tool availability. The distinction matters for Level C/D and for any future IPv4-less
platform. The behavior is also a performance and failure-domain consideration: an unrelated missing
IPv4 table can prevent an IPv6-only commit from capturing its pre-change state.

**Proposed validation methodology.**

1. Confirm whether the vendor engine requires both tables even for a single-family attachment.
2. Capture only the families that have configured or live attachments, while preserving the
   fail-closed semantics for an unreadable table that is actually required.
3. Add unit and mock cases for IPv6-only, IPv4-only and dual-family configurations, including a
   missing/unreadable table on the non-configured family.
4. Re-run the helper, firewall, template, mock and namespace suites.
5. Treat a behavior change as a product runtime change requiring separate approval and a release
   note.

**Dependencies.** Firewall helper ownership, vendor-engine confirmation, regression matrix.

**Acceptance criteria.**

* An IPv6-only attachment captures and restores state without requiring IPv4 firewall tooling, or
  the residual requirement is documented and justified.
* A missing table for an actually required family still fails closed.
* Dual-family behavior is unchanged.
* Tests cover the three family configurations and the failure modes.

---

## ENG-IPV6-09: Routed-underlay PMTUD and ICMPv6 Packet Too Big qualification

**Problem.** The Level B suite verifies that the VXLAN interface enforces its configured 1430-byte
MTU and that a 1383-byte payload is rejected with `-M do`. That is **local interface MTU
enforcement**, not path-MTU discovery across a routed underlay with an intermediate bottleneck. The
project documents PMTUD/PTB behavior but has no test for a path whose MTU is below 1500.

**Technical significance.** An IPv6 underlay path that cannot deliver a full-size outer packet must
generate and deliver ICMPv6 Packet Too Big so that the overlay sender can reduce its packet size.
A test that only checks the local VXLAN MTU can pass while a real routed path blackholes large
packets. The two properties must not be conflated.

**Proposed validation methodology.**

1. Extend the routed IPv6 topology with a transit bottleneck whose MTU is below the VXLAN
   underlay's nominal MTU (for example 1280 or 1400).
2. Verify the outer path drops oversized packets and returns ICMPv6 Packet Too Big with the correct
   MTU; verify the VTEP does not fragment the outer IPv6 packet.
3. Verify overlay TCP and UDP behave correctly: PMTUD-driven size reduction, no blackhole, and a
   documented failure mode when PTB is filtered.
4. Capture outer ICMPv6 PTB and inner traffic; record the exact MTU values and counters.
5. Distinguish this from the existing local `vxlan` interface MTU boundary test in the evidence
   record.

**Dependencies.** Namespace topology extension; ICMPv6-aware path; packet capture; existing level B
suite. No hardware is required for the namespace-level test; hardware PMTUD remains separate.

**Acceptance criteria.**

* A routed underlay bottleneck below 1500 bytes is demonstrated.
* ICMPv6 PTB is observed with the correct next-hop MTU, or the exact reason it is not observable is
  documented.
* Overlay TCP/UDP recovers via PMTUD or fails with an explicit, documented blackhole mode.
* The local VXLAN-MTU test remains distinct from the routed-PMTUD test in the evidence record.
* The new test is part of the authoritative CI qualification or explicitly listed as pending.

---

## ENG-IPV6-10: Modern iproute2 JSON diagnostic tolerance

**Problem.** On the GitHub-hosted Ubuntu runner, `ip -j -d link show` emits a non-JSON diagnostic
line (`info: Using default fan map value (33)`) and, with the newer kernel exposing
`IFLA_VXLAN_FAN_MAP` to iproute2 6.1.0, a malformed `fan-map ` token inside the JSON
(`"remote6":"..."fan-map ,"local6":...`). The real `src/vyatta-vxlan` reconciler pipes that output
to `vyatta-vxlan-addr parse-live`; the parser correctly rejects it, so an otherwise valid
interface cannot be re-read. The supported EdgeOS 3.0.1 iproute2 path does not exhibit this in the
available evidence. This is a portability issue for the N6-R test environment and potentially for
a future unsupported userland.

**Technical significance.** The product's supported platform is EdgeOS 3.0.1, not Ubuntu 24.04.
The N6-R harness filters only the known diagnostic so it can exercise the real reconciler on the
hosted runner. That shim must not be mistaken for product robustness; a real deployment on a
modern iproute2 userland has not been qualified.

**Proposed validation methodology.**

1. Reproduce the diagnostic with the affected iproute2 version and record the exact versions.
2. Decide whether the product call site should tolerate a leading diagnostic before JSON parsing,
   or whether the supported-platform/version boundary should be stated explicitly.
3. If changing product behavior, add a unit test with contaminated `ip -j` output and re-run the
   helper, mock, firewall and namespace suites.
4. Remove the test-harness shim once the product boundary is resolved, or keep it as an explicitly
   named environment compatibility layer.

**Dependencies.** Product runtime change approval; supported-platform decision; iproute2 version
matrix.

**Acceptance criteria.**

* The supported EdgeOS behavior is demonstrated or explicitly stated.
* The modern-iproute2 behavior is either tolerated by the product or documented as unsupported.
* The N6-R shim is documented as a test-environment compatibility layer, not a product fix.
* The test suite distinguishes a normalized environment artifact from a real reconciler failure and
  records an explicit skip when normalization occurs.

---

## ENG-IPV6-11: Trusted release-candidate IPv6 qualification integration

**Priority: P0. This work must be complete before production release publication is enabled.**

**Status (2026-11-28): implemented, merged to `main` as `fffdedd` (PR #10), and hosted-qualified on
the development branch
([run 46096392548](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548),
non-release and non-promotable). Post-merge CI and build-environment qualification on `fffdedd`
passed, but a production candidate cannot be constructed at the published `0.3.0` version:
[run 46103291407](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46103291407) failed at the
version-eligibility gate (`production version 0.3.0 is not newer than published 0.3.0`), and this
assignment did not authorize a version increment or a new `main`-branch trigger. Main-branch
candidate qualification, attestation and production-policy promotion validation therefore remain
**not demonstrated**; see
[`release-candidate-ipv6-qualification.md`](release-candidate-ipv6-qualification.md) §12. Release
publication remains disabled.**

The implementation is described in
[`release-candidate-ipv6-qualification.md`](release-candidate-ipv6-qualification.md). The `ci.yml`
`ipv6-only` job still qualifies a non-release CI package built in the same workflow run; the new
`release.yml` path qualifies the exact release candidate, attaches the four checks to the candidate
manifest under an immutable `build.identity`, and is enforced by `validate-candidate.sh` and
`check-release-gates.sh --candidate-dir`. Local qualification (build identity, packaged N6-R-P,
candidate finalize, validator, promotion dry-run) is recorded in that document §10, and the
hosted non-publication run on the development branch is recorded in §11. The hosted run establishes
the real workflow identity; production release-candidate qualification from `main` and publication
still require the merge and remain behind the disabled publication controls.

**Problem.** `scripts/build-release-candidate.sh` computes the candidate ID and attests
`release-candidate.json` with `qualification.checks` from `artifact-contract`, `build-metadata`,
`sbom` and `reproducibility`. `validate-candidate.sh` requires every listed check to pass but does
not require IPv6 check IDs, and `check-release-gates.sh`/`promote-release.sh` do not consume IPv6
evidence. A candidate can therefore be qualified and promoted with no isolated IPv6-only
qualification of its own artifacts.

**Technical significance.** Qualification must bind to the exact immutable artifacts that will be
published. Evidence produced against a separately rebuilt package, an earlier commit, or a
non-release CI build is not proof that a later release candidate passed. The candidate identity, the
qualified build and the published artifact must form a non-circular chain: the manifest identity is
computed after the qualification checks are attached, and the evidence references that candidate
identity without being used to derive it. A post-hoc manifest edit would invalidate the candidate
ID/attestation and is not acceptable.

**Proposed implementation.**

1. **Exact immutable candidate artifacts.** Run the N6-R-P suite against the integration `.deb`
   built by `build-release-candidate.sh` for that candidate, after build A and before candidate
   ID/attestation. Do not rebuild after qualification.
2. **Non-circular identity.** Pass the resulting `summary.json` and its SHA-256 into the candidate
   builder; append the IPv6 checks to `release/candidate-schema.json` `qualification.checks[]`
   **before** the candidate ID is computed and the manifest attested. The candidate ID must not be
   an input to the qualification run in a way that makes the evidence and the identity mutually
   dependent.
3. **Trusted workflow provenance.** Record and verify workflow run ID/attempt, workflow path, ref
   and commit, source commit and harness commit. Production candidates require `refs/heads/main`
   with the workflow commit equal to the source commit. Evidence from a non-release CI run or a
   feature branch must not be accepted for a production candidate.
4. **Mandatory check identifiers.** Require `ipv6-only-isolation`, `ipv6-only-dataplane`,
   `ipv6-only-capture` and `ipv6-only-reconciler` as named checks. A missing, failed or
   `not-performed` required check rejects the candidate.
5. **Candidate manifest integration.** Validate the evidence with
   `scripts/validate-ipv6-qualification-evidence.py` using the candidate source commit, the
   candidate package SHA-256, the trusted workflow identity and the harness commit, then attach the
   four checks with their `evidenceSha256` values to the manifest before attestation.
6. **Evidence integrity verification.** Recompute each `evidenceSha256` from the retained candidate
   evidence bytes, not from a mutable working directory and not from a self-reported field.
7. **Fail-closed release gates.** `validate-candidate.sh` requires the four check IDs and the
   recomputed hashes; `check-release-gates.sh`/`promote-release.sh` reject a candidate with a
   missing/failed/not-performed check, a mandatory-capture failure, absent reconciler execution, an
   identity mismatch, an evidence-hash mismatch or an unpermitted skip.
8. **Permitted-skip and workaround semantics.** Exactly two exceptions are permitted and must be
   declared in the manifest: the `host-global-ipv6-escape-unavailable` skip and the
   `iproute2-json-normalization` skip/workaround. Any other skip rejects the candidate. Mandatory
   capture and reconciler execution are never skippable.
9. **Positive and negative release-gate fixtures.** Extend the existing 16 evidence-binding
   fixtures with release-gate cases covering candidate ID, package digest and workflow identity
   mismatches, missing/failed/unpermitted checks, evidence tampering, a non-trusted workflow, and
   publication ordering.
10. **Non-publication hosted qualification of the combined path.** Exercise the full candidate plus
    IPv6-qualification path on a hosted run that does **not** publish, and retain the run URL,
    evidence bundle, `summary.json` hash and candidate manifest hash.

**Relationship to the accepted integration.** The recommended contract was recorded in
[`ipv6-only-qualification-ci-integration.md`](ipv6-only-qualification-ci-integration.md) §4. It is
now implemented as described above. The implementation changed `release.yml`,
`release/candidate-schema.json`, `scripts/build-release-candidate.sh`,
`scripts/validate-candidate.sh`, `scripts/check-release-gates.sh`,
`scripts/promote-release.sh`, `scripts/verify-release.sh`,
`scripts/validate-ipv6-qualification-evidence.py`, `test/ipv6-only-netns.sh` and the test suites;
it did **not** change the publication policy, the `release-publication` environment controls or
`RELEASE_PUBLICATION_ENABLED` (still unset).

**Dependencies.** Maintainer approval of the candidate-manifest and release-gate change; the
Phase III trusted release lifecycle as merged; a non-publication hosted qualification run.

**Acceptance criteria.**

* [x] The N6-R-P suite runs against the exact candidate integration `.deb` before candidate
  ID/attestation, with no rebuild between qualification and publication. (Local, §10 of the
  contract document.)
* [x] The four mandatory check IDs are present, passed and hash-verified in the candidate manifest.
* [x] The manifest identity chain is non-circular: the build identity is established before
  qualification, and the candidate ID is computed only after the checks are attached.
* [x] Workflow provenance is verified, and non-trusted or non-main evidence is rejected for a
  production candidate. (The finalize stage independently supplies expected run/attempt/path/ref/
  commit and rejects unbound evidence; fixture coverage includes unrelated run/attempt and an
  unauthorized workflow path.)
* [x] `validate-candidate.sh`, `check-release-gates.sh` and `promote-release.sh` fail closed on a
  missing/failed/not-performed check, a capture or reconciler failure, an identity or hash mismatch,
  and an unpermitted skip.
* [x] Positive and negative release-gate fixtures pass, including the candidate ID, package digest
  and workflow identity cases (`test/unit-release-ipv6-gate.sh`, 28 fixtures).
* [x] A non-publication **hosted** run exercises the combined candidate-plus-qualification path
  and its evidence is validated independently:
  [run 46096392548](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548) on
  `ci/ipv6-release-qualification` (build, qualification, finalize/attest, dry-run all passed;
  publication jobs skipped; candidate/evidence/attestation verified independently). This is
  development-branch evidence, not a production publication authorization.
* [x] Release publication remains disabled: `RELEASE_PUBLICATION_ENABLED` is unset and no release or
  image was published.
