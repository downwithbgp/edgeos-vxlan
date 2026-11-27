# IPv6-only qualification evidence record

**Date:** 2026-11-27 (UTC).
**Branch:** `ci/ipv6-native-qualification`.
**Base commit:** `5958bc469ccf498e54bc0b9f361668e309f66b9d` (`origin/main`, PR #7 merge).
**Record status:** local validation complete; hosted CI pending because the branch has not been
published. The package build, artifact validation, negative tests and reproducibility checks are
included in §5. This record distinguishes implemented functionality from proposed future work and does
not claim a CI result that did not run.

## 1. Scope

This record covers:

* the isolated IPv6-only Level B suite added by ENG-IPV6-03;
* the actual reconciler path exercised inside that topology (N6-R, partial);
* the existing off-device suite and static checks;
* the existing package build, artifact validation and reproducibility checks;
* the CI workflow definition and its dependency strategy.

It does not cover physical hardware qualification, Level C installation/management, Level D
runner/control-plane operation, or any production router. No production router was accessed.

## 2. Environment

| Item | Value |
|---|---|
| Development host | Ubuntu 24.04.5 LTS, Linux `6.8.0-149-generic`, x86_64 |
| Host privilege | No root/CAP_NET_ADMIN; `ip netns add` is not permitted on the host |
| Namespace validation environment | Privileged Docker container from a local Ubuntu 24.04 image |
| Container network tools | iproute2 6.1.0, iputils 20240117, Python 3.12.3, tcpdump 4.99.4 |
| Container Perl | Perl with `JSON::PP` (required by `src/vyatta-vxlan-addr`) |
| Kernel VXLAN | `vxlan`, `udp_tunnel`, `ip6_udp_tunnel` modules present |
| CI analysis tools | actionlint 1.7.12, zizmor 1.33.1, ShellCheck 0.11.0 (pinned install script) |

The host limitation is why the namespace suite was run in a privileged container. The container
uses the host kernel and creates the same network namespaces; this is real namespace execution,
not a mock. It is **not** hosted-CI evidence and not hardware evidence.

## 3. Off-device and static validation

| Command | Exit | Result |
|---|---:|---|
| `bash test/run.sh` | 0 | **360 checks passed**: 11 build + 64 helper + 122 firewall + 93 templates + 70 mock |
| `shellcheck install.sh scripts/*.sh test/*.sh test/lib/*.sh debian/*.preinst debian/*.postinst debian/*.prerm debian/*.postrm src/vyatta-vxlan src/vyatta-vxlan-bridge src/vyatta-vxlan-firewall` | 0 | No findings |
| `actionlint .github/workflows/release-validation.yml` | 0 | No findings |
| `zizmor --offline --collect all --format plain .github` | 0 | No findings |

The off-device count is 360, not the historical 349. The 11 `unit-build` checks were added by the
reproducible-build work in PR #6; historical release records retain their original 349 count.

## 4. Isolated IPv6-only suite

### 4.1 Final local run

Command:

```bash
docker run --rm --privileged \
  -v "$PWD:/repo" -v "$TMPDIR:/scratch" -w /repo \
  -e REQUIRE_NETNS_TEST=1 -e REQUIRE_CAPTURE=1 -e REQUIRE_RECONCILER=1 \
  -e EVIDENCE_DIR=/scratch/evidence-run6 \
  ipv6-qual:local bash test/ipv6-only-netns.sh
```

Result: **exit 0**, `pass=80 fail=0 skip=1 capture=executed reconciler=executed`.

The single skip is the host-global-IPv6 escape control: the container had no global IPv6 address
to use as a destination. The host-IPv4 escape control ran and passed; the namespace-boundary and
host-side-veth checks also ran. This skip is not a pass and is recorded in `summary.txt`.

### 4.2 Repeated execution and cleanup

Two consecutive runs in the same container:

| Run | Result |
|---|---|
| 1 | exit 0, `pass=80 fail=0 skip=1 capture=executed reconciler=executed` |
| 2 | exit 0, `pass=80 fail=0 skip=1 capture=executed reconciler=executed` |

After both runs, `ip netns list` was empty and the suite's own "no host-side test veth remains"
check passed. A separate `--cleanup` test removed a namespace recorded in
`namespaces.txt` and left no leftover namespace. The cleanup command validates the recorded names
and deletes only names matching the test's prefix.

### 4.3 Functional and negative-control results

| Check | Result |
|---|---|
| Routed IPv6 underlay: VTEP to transit, peer route via transit | Passed |
| VTEP-to-VTEP ICMPv6 over VNI 100, both directions | Passed |
| Routed host-to-host ICMPv6 over VNI 200, both directions | Passed |
| TCP and UDP across the routed host overlay | Passed |
| Underlay and overlay NDP after neighbor-cache flush | Passed |
| VXLAN TX/RX counters increase for VNI 200 | Passed |
| MTU: 1382-byte payload passes; 1383-byte payload rejected with `-M do` at a 1430-byte VXLAN MTU | Passed |
| VXLAN interface deletion and recreation | Passed |
| Overlay connectivity fails when `vxlan100` is down | Passed |
| Overlay connectivity recovers after `vxlan100` is up and its IPv6 address is restored | Passed |
| Generic Linux bridge over VNI 300: IPv6 ping and ND | Passed (generic Linux only) |
| Isolation assertions on five workload namespaces, before and after traffic | Passed |
| Introduced IPv4 address canary detected | Passed |
| Introduced IPv4 route canary detected | Passed |
| Introduced IPv4 policy rule/route canary detected | Passed |
| Validator returns clean after canary removal | Passed |
| IPv4 control pair reaches `198.51.100.2` | Passed |
| Isolated host cannot reach `198.51.100.2` | Passed |
| Isolated host has no IPv4 route to `198.51.100.2` | Passed |
| `AF_INET` socket creation succeeds; external send fails with `ENETUNREACH` | Passed |
| Host IPv4 destination is reachable from the host but not from `vtep-a` | Passed |
| Actual reconciler create, identity, idempotent update, recreation, rollback, restore, delete | Passed (N6-R partial) |

The reconciler test used the real `src/vyatta-vxlan`, `ip`, sysfs and kernel state. The EdgeOS
configuration API, `vyatta-vxlan-firewall`, `vyatta-vxlan-bridge` and `vyatta-address` were test
doubles. The firewall-dispatch and vendor-engine layers are therefore **not** evidence from this
section; they remain covered by the off-device mock/unit suites and (for hardware) the cited ER-X
records.

### 4.4 Packet capture

The local run had tcpdump available and captured on the transit underlay interface and on
`vxlan200` in `vtep-a`. Analysis of the final run:

| Measurement | Count |
|---|---:|
| Underlay IPv4 Ethernet or ARP frames | 0 |
| Underlay IPv6 UDP/4789 (VXLAN) packets | 34 |
| Underlay ICMPv6 ND (NS/NA) packets | 2 |
| Overlay decapsulated IPv6 packets | 15 |
| Overlay TCP packets | 9 |
| Overlay UDP packets | 2 |
| Overlay outer UDP/4789 packets | 0 |
| Overlay ICMPv6 ND packets | 2 |

This demonstrates the expected protocol split: outer IPv6/VXLAN on the underlay, inner IPv6/TCP/
UDP/ND on the overlay, and no IPv4/ARP frames in the capture. Capture is supplementary; the
isolation assertions do not depend on it. CI may record `capture=skipped` if tcpdump is absent.

### 4.5 Skip and failure semantics

| Command | Exit | Result |
|---|---:|---|
| `bash test/ipv6-only-netns.sh` as a non-root user | 0 | `SKIP: root/CAP_NET_ADMIN required...` |
| `REQUIRE_NETNS_TEST=1 bash test/ipv6-only-netns.sh` as a non-root user | 1 | Missing privilege is a failure when required |
| `EVIDENCE_DIR=... bash test/ipv6-only-netns.sh --cleanup` | 0 | Recorded namespace removed |

A missing privilege is never converted into a pass. A capture skip is reported as a skip; it is not
counted as capture evidence.

## 5. Package and reproducibility validation

Commands run from a clean committed tree (the code/CI commits on this branch):

```bash
./scripts/build-reproducible.sh --output-dir "$TMPDIR/edgeos-vxlan-build"
./scripts/validate-release.sh "$TMPDIR/edgeos-vxlan-build"
bash test/validate-release-negative.sh "$TMPDIR/edgeos-vxlan-build"
./scripts/verify-reproducible-build.sh --source-rev HEAD --work-dir "$TMPDIR/repro"
```

The build was run from the committed tree at `28368d4` (the branch HEAD before this evidence
update). The documented package payload hashes are unchanged.

| Command | Exit | Result |
|---|---:|---|
| `scripts/build-reproducible.sh --output-dir "$TMPDIR/edgeos-vxlan-build"` | 0 | Both packages built; kmod `7ffe10f611932f6543b96b3ce5683b93b6c678a51ac1b63bcdb3d630e58c7827`, integration `6afa3f25e8145a6ebf31a947ab104b223b351aa615b51aa2a97389364a133e2a` |
| `scripts/validate-release.sh "$TMPDIR/edgeos-vxlan-build"` | 0 | Artifact contract PASS; version `0.3.0+edgeos3.0.1.e50` |
| `test/validate-release-negative.sh "$TMPDIR/edgeos-vxlan-build"` | 0 | **25 checks passed, 0 failed** |
| `scripts/verify-reproducible-build.sh --source-rev HEAD --work-dir "$TMPDIR/edgeos-vxlan-repro"` | 0 | **SAME** for both packages; same hashes as the canonical build |
| lintian (container, same suppressions as CI) | 0 | **PASS** (`--fail-on error`, no errors) |

The reproducibility hashes match the published v0.3.0 package hashes recorded by the project
(`7ffe10f6…` and `6afa3f25…`), confirming that this branch does not change the package payload.
`lintian` was run in a container because the development host does not have it installed; the
hosted CI package job runs the same command.

## 6. CI status

The workflow definition passes actionlint and zizmor locally. **Hosted CI has not run** because the
branch has not been pushed. The following job results are therefore **pending**, not passed:

* `Static analysis` (includes the new `test/lib/*.sh` ShellCheck input);
* `Build and validate packages`;
* `Reproducibility verification`;
* `Published-release fixtures`;
* `Network-namespace dataplane` (existing dual-stack suite);
* `IPv6-only qualification` (new job);
* `Verify published release` (release events/manual dispatch only).

The new job is guarded by `if: github.event_name != 'pull_request'`. It grants no new permissions,
does not use `pull_request_target`, performs no package acquisition, requires the reconciler path,
uploads evidence on every outcome, and has an `always()` cleanup step. A dual-stack GitHub-hosted
runner that creates IPv6-only namespaces is Level B, not Level D.

## 7. Qualification levels

| Level | Status | Evidence |
|---|---|---|
| **A** — IPv6 dataplane over dual-stack infrastructure | Achieved for the recorded combinations | Existing N and H records; support matrix |
| **B** — isolated IPv6-only workload | Achieved at N6/N6-R | This record; `test/ipv6-only-netns.sh`; local privileged-container run |
| **C** — IPv6-only lifecycle | Not achieved | Installer/management deferred to ENG-IPV6-01/02; GitHub release endpoints returned no AAAA in the audit environment |
| **D** — IPv6-only runner/control plane | Not achieved and not claimed | GitHub-hosted runner and control plane are dual-stack; see the IPv4 inventory |

## 8. New dependencies

The suite adds no runtime dependency to the product. Test-time dependencies:

* `iproute2`, `iputils-ping`, Python 3, coreutils — already present on the GitHub Ubuntu runner;
* tcpdump — optional, used only for capture evidence;
* Perl with `JSON::PP` — already required by the existing address helper and the off-device suite;
* `CAP_NET_ADMIN`/root — only in the privileged job and local container.

The CI tooling install script (actionlint/zizmor/ShellCheck) is unchanged and still uses pinned
checksums. The new APT helper is test/CI-only and does not alter the package payload.

## 9. Remaining risks and limitations

1. N6/N6-R are general-Linux namespace evidence, not ER-X hardware evidence.
2. The reconciler section uses test doubles for the EdgeOS config API, firewall dispatch, bridge
   helper and `vyatta-address`; those layers are not qualified by this record.
3. The generic bridge section is not ENG-IPV6-04 hardware qualification.
4. Packet capture is local evidence; CI may skip it if tcpdump is absent.
5. The host and CI runner are dual-stack; Level D is not achieved.
6. IPv4 loopback and AF_INET support remain in the workload namespaces, by explicit Level B design.
7. No PMTUD/PTB test across a real routed path; the MTU boundary is local to the VXLAN interface.
8. The local host cannot create network namespaces; the privileged-container execution is recorded
   as such and is not hosted CI.
9. Hosted CI is pending.
10. `lintian` was run in a container locally; hosted CI is still the authoritative CI result.

## 10. Reproduction

See [`ipv6-only-qualification.md`](ipv6-only-qualification.md#7-reproducing-the-evidence) for the
full command set, including the privileged-container form and the cleanup command.
