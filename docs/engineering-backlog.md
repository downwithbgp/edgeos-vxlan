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

---

## ENG-IPV6-01: IPv6-only installation and package acquisition

**Problem.** `install.sh` downloads release assets over HTTPS to GitHub and therefore depends on DNS
and on an IPv6-reachable HTTPS endpoint. No IPv6-only acquisition test exists. The package files
themselves can be installed offline with `dpkg`, but that path is not documented as a tested
IPv6-only procedure.

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

**Problem.** The CI workflow runs on GitHub-hosted Ubuntu and the current tests configure both
address families on the same interfaces. There is no job that disables IPv4 and proves the toolchain,
test suite and package build work in an IPv6-only environment.

**Technical significance.** Without an IPv4-free test environment, an implicit IPv4 dependency can
enter the installer, scripts, test fixtures or package build. The dataplane tests alone do not prove
an IPv6-only environment.

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

**Acceptance criteria.**

* An IPv6-only CI job runs on every relevant change and passes.
* The job builds the packages and runs the 349-check suite plus the namespace test.
* A deliberately introduced IPv4-only dependency fails the job with a clear error.
* The existing dual-stack and IPv4 regression jobs remain in place.
* The CI documentation states which checks run in which environment.

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
