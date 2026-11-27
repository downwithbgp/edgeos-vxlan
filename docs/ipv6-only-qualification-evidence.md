# IPv6-only qualification evidence record

**Date:** 2026-11-27 (UTC).
**Branch:** `ci/ipv6-native-qualification`.
**Base commit:** `5958bc469ccf498e54bc0b9f361668e309f66b9d` (`origin/main`, PR #7 merge).
**Record status:** local and hosted validation complete. Hosted CI run
[46044226321](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46044226321) passed at
`7d6762f851c8a40bd649ff7442ff3f9e22d442a0`; the IPv6-only job and the package/reproducibility
jobs are green. The package build, artifact validation, negative tests and reproducibility checks
are included in §5. This record distinguishes implemented functionality from proposed future work.

**Later result.** After the Phase III integration, the branch HEAD `92336a3` re-ran the same suite
inside the canonical `ci.yml` against the same-run candidate package. That result — hosted push run
46060990232, 113 pass / 0 fail / 2 skip, candidate-bound evidence validated — is recorded in
[`ipv6-only-qualification-ci-integration.md`](ipv6-only-qualification-ci-integration.md) §9. The
sections below remain the record of the earlier base and are not rewritten.

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
| `bash test/run.sh` | 0 | **376 checks passed**: 11 build + 64 helper + 122 firewall + 93 templates + 70 mock + 16 qualification-evidence contract |
| `shellcheck install.sh scripts/*.sh test/*.sh test/lib/*.sh debian/*.preinst debian/*.postinst debian/*.prerm debian/*.postrm src/vyatta-vxlan src/vyatta-vxlan-bridge src/vyatta-vxlan-firewall` | 0 | No findings |
| `actionlint .github/workflows/*.yml` | 0 | No findings |
| `zizmor --offline --collect all --format plain .github` | 0 | No findings |

The off-device count is 376, not the historical 349. The 11 `unit-build` checks were added by the
reproducible-build work in PR #6, and the 16 qualification-evidence contract checks are new in this
branch; historical release records retain their original 349 count.

## 4. Isolated IPv6-only suite

### 4.1 Final local run

Command:

```bash
docker run --rm --privileged \
  -v "$PWD:/repo" -v "$TMPDIR:/scratch" -w /repo \
  -e REQUIRE_NETNS_TEST=1 -e REQUIRE_CAPTURE=1 -e REQUIRE_RECONCILER=1 \
  -e EVIDENCE_DIR=/scratch/evidence-final-review \
  ipv6-qual:local bash test/ipv6-only-netns.sh
```

Result: **exit 0**, `pass=113 fail=0 skip=1 capture=executed reconciler=executed`. The hosted run
at the same commit returned **113 pass, 0 fail, 2 skip** (`capture=executed`,
`reconciler=executed`); the second skip is the explicit modern-iproute2 JSON normalization. The
final harness also writes `summary.json`: `result=passed`, `counts={pass:113, fail:0, skip:1}`, and
passed checks for `ipv6-only-isolation`, `ipv6-only-dataplane`, `ipv6-only-capture` and
`ipv6-only-reconciler`. The JSON records the raw underlay/overlay capture hashes, the analysis
hash, the reconciler evidence hash and `hardware.status=not-qualified`.

The single skip is the host-global-IPv6 escape control: the container had no global IPv6 address
to use as a destination. The host-IPv4 escape control ran and passed; the namespace-boundary and
host-side-veth checks also ran. This skip is not a pass and is recorded in `summary.txt`.

### 4.2 Repeated execution and cleanup

Two consecutive runs in the same container:

| Run | Result |
|---|---|
| 1 | exit 0, `pass=113 fail=0 skip=1 capture=executed reconciler=executed` |
| 2 | exit 0, `pass=113 fail=0 skip=1 capture=executed reconciler=executed` |
| Hosted run 46044226321 | exit 0, `pass=113 fail=0 skip=2 capture=executed reconciler=executed` |

After both runs, `ip netns list` was empty and the suite's own "no host-side test veth remains"
check passed. A separate `--cleanup` test against the final script created a namespace
`v6aabc123`, wrote `run.env` with the matching suffix, and removed the exact namespace; it left no
leftover namespace. The cleanup command reconstructs the exact names from `run.env` and does not
delete arbitrary names by prefix.

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
| IPv6 TCP and UDP through the reconciler-created `vxlan900` interface | Passed (N6-R partial) |
| Actual reconciler rejects mixed-family and IPv6-multicast endpoints before mutation | Passed (N6-R partial) |
| Workload veth peers match the intended namespace topology | Passed |
| Host IPv4/IPv6 forwarding sysctls unchanged | Passed |
| Capture startup and completion verified; capture failure fails the suite | Passed |
| Pre-existing same-name namespace refused, not deleted | Passed |
| Hosted-run modern-iproute2 diagnostic/fan-map artifact normalized by the N6-R test shim | Passed, with an explicit reconciler skip on the hosted runner |
| Candidate-packaged userspace (N6-R-P; local) | Passed: integration `.deb` SHA-256 `6afa3f25…`, packaged reconciler `814bf807…`, packaged address helper `a484717a…` |

The reconciler test used the real `src/vyatta-vxlan`, `ip`, sysfs and kernel state. The EdgeOS
configuration API, `vyatta-vxlan-firewall`, `vyatta-vxlan-bridge` and `vyatta-address` were test
doubles.

The candidate-package mode (N6-R-P) was exercised locally against
`edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb` (SHA-256 `6afa3f25…`, built from source commit
`ca90f3683ea15c0859ccd0619fa78536c9e63fc9`). The suite verified the package hash before
extraction, executed the packaged `vyatta-vxlan` (`814bf807…`) and `vyatta-vxlan-addr`
(`a484717a…`), and recorded `candidate.packageExecuted=true` and evidence class `N6-R-P`. The x86
kernel does not qualify the candidate MIPS kernel module. The candidate-bound validator accepted
the resulting summary with the expected source commit, package SHA-256, workflow run/attempt/path/
ref/commit and harness commit, plus the permitted host-global-IPv6 skip. The firewall-dispatch and vendor-engine layers are therefore **not** evidence from this
section; they remain covered by the off-device mock/unit suites and (for hardware) the cited ER-X
records.

### 4.4 Packet capture

The local run had tcpdump available and captured on the transit underlay interface and on
`vxlan200` in `vtep-a`. Analysis of the final run:

| Measurement | Count |
|---|---:|
| Underlay IPv4 Ethernet or ARP frames | 0 |
| Underlay IPv6 UDP/4789 (VXLAN) packets | 30 (local) / 34 (hosted) |
| Underlay ICMPv6 ND (NS/NA) packets | 2 |
| Overlay decapsulated IPv6 packets | 15 |
| Overlay TCP packets | 9 (local) / 9 (hosted) |
| Overlay UDP packets | 2 (local) / 2 (hosted) |
| Overlay outer UDP/4789 packets | 0 |
| Overlay ICMPv6 ND packets | 2 |
| Overlay IPv4 Ethernet or ARP frames | 0 (both) |

This demonstrates the expected protocol split: outer IPv6/VXLAN on the underlay, inner IPv6/TCP/
UDP/ND on the overlay, and no IPv4/ARP frames at either capture point. Packet counts vary slightly
with timing; the assertions require the protocol classes, not exact counts. The authoritative CI job
requires capture and installs tcpdump when absent; a local capture skip is not authoritative
evidence.

### 4.5 Skip and failure semantics

| Command | Exit | Result |
|---|---:|---|
| `bash test/ipv6-only-netns.sh` as a non-root user | 0 | `SKIP: root/CAP_NET_ADMIN required...` |
| `REQUIRE_NETNS_TEST=1 bash test/ipv6-only-netns.sh` as a non-root user | 1 | Missing privilege is a failure when required |
| `EVIDENCE_DIR=... bash test/ipv6-only-netns.sh --cleanup` | 0 | Exact recorded namespace removed; missing evidence/run is a no-op |
| SIGTERM during setup/preflight | 130 | Cleanup removed namespaces and host links; no leftovers |
| Pre-existing namespace with the same suffix | 1 | Refused to reuse it; the pre-existing namespace remained |
| `REQUIRE_CAPTURE=1` with tcpdump hidden | 1 | `FAIL: packet capture is required but tcpdump is unavailable`; capture was not reported as a pass |
| Hosted `ipv6-only` job (run 46044226321) | 0 | 113 pass, 0 fail, 2 skip; capture executed; reconciler executed |

A missing privilege is never converted into a pass. In authoritative mode (`REQUIRE_CAPTURE=1`),
an unavailable tcpdump or a failed capture is a failure; in local mode, the absence of tcpdump is
reported as a skip and is not counted as capture evidence.

### 4.6 Candidate-bound evidence contract

`scripts/validate-ipv6-qualification-evidence.py` validates a summary against expected source,
candidate, package, workflow and harness identities, recomputes every retained evidence hash, and
rejects missing/failed/unperformed checks, unpermitted skips, unreported workarounds and malformed
JSON. `test/unit-ipv6-evidence.sh` runs **16** positive/negative fixtures covering:

* valid candidate-bound evidence with the permitted host-global-IPv6 skip and the documented
  iproute2 normalisation workaround;
* missing summary, failed isolation, missing capture, missing reconciler execution;
* wrong source commit, candidate ID, package digest and harness commit;
* modified evidence, unrelated workflow run, unexpected skip, missing required check;
* missing candidate-package execution, unreported workaround, malformed JSON.

This validator is called by the `ci.yml` IPv6-only job against the same-run package. It is not yet
called by the Phase III candidate builder or publication gate. See [`ipv6-only-qualification-ci-integration.md`](ipv6-only-qualification-ci-integration.md).

## 5. Package and reproducibility validation

Commands run from a clean committed tree (the code/CI commits on this branch):

```bash
./scripts/build-reproducible.sh --output-dir "$TMPDIR/edgeos-vxlan-build"
./scripts/validate-release.sh "$TMPDIR/edgeos-vxlan-build"
bash test/validate-release-negative.sh "$TMPDIR/edgeos-vxlan-build"
./scripts/verify-reproducible-build.sh --source-rev HEAD --work-dir "$TMPDIR/repro"
```

Canonical builds were run from the original base `5958bc4`, the branch HEAD `59d4b9b`, the
intermediate review commits `28368d4`/`36494eb`, the final review code commit `ca90f36`, and in the
controlled container for the base and branch. Every run produced the same canonical package
hashes. Later commits in this record change only the test harness and documentation, so the package
payload is unchanged.

| Command | Exit | Result |
|---|---:|---|
| `scripts/build-reproducible.sh --source-rev 5958bc4 --output-dir "$TMPDIR/pkg-base"` | 0 | Base build: kmod `7ffe10f6…`, integration `6afa3f25…` |
| `scripts/build-reproducible.sh --source-rev 59d4b9b --output-dir "$TMPDIR/pkg-branch"` | 0 | Branch build: identical to base |
| `scripts/build-reproducible-container.sh --source-rev 5958bc4 --no-build --image edgeos-vxlan-reproducible:qualified` | 0 | Controlled container base: identical canonical hashes |
| `scripts/build-reproducible-container.sh --source-rev 59d4b9b --no-build --image edgeos-vxlan-reproducible:qualified` | 0 | Controlled container branch: identical canonical hashes |
| `sha256sum -c SHA256SUMS` in the downloaded v0.3.0 asset directory | 0 | Published assets verify as `c555a99a…`/`73059ba2…` |
| `scripts/build-reproducible.sh --source-rev ca90f36 --output-dir "$TMPDIR/pkg-final-head"` | 0 | Final review build: kmod `7ffe10f611932f6543b96b3ce5683b93b6c678a51ac1b63bcdb3d630e58c7827`, integration `6afa3f25e8145a6ebf31a947ab104b223b351aa615b51aa2a97389364a133e2a` |
| `scripts/validate-release.sh "$TMPDIR/pkg-final-head"` | 0 | Artifact contract PASS; version `0.3.0+edgeos3.0.1.e50` |
| `test/validate-release-negative.sh "$TMPDIR/pkg-final-head"` | 0 | **25 checks passed, 0 failed** |
| `scripts/verify-reproducible-build.sh --source-rev HEAD --work-dir "$TMPDIR/repro-final-head"` | 0 | **SAME** for both packages; same hashes as the canonical build |
| Hosted package job (run 46044226321) | 0 | Canonical build at `7d6762f`; kmod `7ffe10f6…`, integration `6afa3f25…`; `validate-release.sh` PASS; lintian PASS |
| Hosted reproducibility job (run 46044226321) | 0 | **SAME** for both packages; same hashes |
| lintian (container, same suppressions as CI) | 0 | **PASS** (`--fail-on error`, no errors) |

`lintian` was run in a container because the development host does not have it installed; the
hosted CI package job runs the same command.

### 5.1 Package integrity reconciliation

The earlier delivery report incorrectly said that the canonical hashes matched the published
v0.3.0 hashes. They do not. The correct identities are:

| Artifact set | Kernel module | Integration |
|---|---|---|
| **Published v0.3.0** (`SHA256SUMS`, release assets) | `c555a99a8626fc2212e5a7ee35916f66971f83b2661f9281dea24196e7754c5f` | `73059ba2b7f6099efd9d39b6962391e923f86a9eaf120d839723dfff05646eca` |
| **Canonical reproducible build** (base `5958bc4`, branch `59d4b9b`, host and controlled container) | `7ffe10f611932f6543b96b3ce5683b93b6c678a51ac1b63bcdb3d630e58c7827` | `6afa3f25e8145a6ebf31a947ab104b223b351aa615b51aa2a97389364a133e2a` |

**Published artifact integrity.** `gh release download v0.3.0` was followed by
`sha256sum -c SHA256SUMS`; both published assets verified. The published assets were not modified.

**Base versus branch.** `scripts/build-reproducible.sh --source-rev 5958bc4` and
`--source-rev 59d4b9b` were run in the same host environment and in the controlled
`edgeos-vxlan-reproducible:qualified` container (local image ID
`sha256:dd56fabdc1d5038ddc661fe2e97e92ed0fae10a41e33072c6555c0922cd469fe`; the same local image was
used for both revisions). All four builds produced the same canonical hashes. `cmp` reports the
base and branch `.deb` files byte-identical, and host/controlled builds byte-identical; the member
comparison reports no differences. This is package payload equivalence between the original base
and the current branch.

**Branch versus published.** The `.deb` SHA-256 values differ, and the file sizes differ
(kmod 32224 vs 32266 bytes; integration 36078 vs 36244 bytes). A targeted ar/tar comparison of
every member (`debian-binary`, `control.tar.gz`, `data.tar.gz`) found:

* identical member names, order, types, modes, uid/gid, sizes and linknames;
* identical content hashes for every control and payload file, including both kernel modules;
* identical `debian-binary`;
* gzip MTIME zero in both;
* **only tar member mtimes differ** (every member in both `control.tar.gz` and `data.tar.gz`).

The published payload preserved historical working-tree mtimes (for example
`vyatta-vxlan` at `2026-11-26 17:47:12`) and build-window mtimes for generated members
(`01:26:47`–`01:26:51`). The canonical build normalizes every file and directory to the
changelog `SOURCE_DATE_EPOCH` (`01:30:00`, epoch `1795743000`). The differing tar headers compress
to different sizes, which explains the `.deb` size and hash differences. This is the same root
cause already recorded in [`reproducible-builds.md`](reproducible-builds.md#1-root-cause-analysis-of-the-v030-discrepancy).

**Build-input comparison.** The published `.buildinfo` records build date
`2026-11-27 01:26:51`, `SOURCE_DATE_EPOCH=1795743000`, and host dependency versions such as
binutils `2.42-4ubuntu2.10` and libdw `0.190-1.1ubuntu0.1`. The canonical build records a later
build date and newer host dependency versions (binutils `2.42-4ubuntu2.11`, libdw
`0.190-1.1ubuntu0.2`) but the same `SOURCE_DATE_EPOCH`. Those differences do not change the
payload contents because the packages are assembled from committed prebuilt files.

**Conclusion.** There is no unexplained artifact discrepancy and no published-asset integrity
failure. The published bytes are immutable; the canonical rebuilds are repeatable and byte-identical
to each other; the branch does not change the package payload relative to the base; the published
release is not byte-for-byte reproducible because its mtimes were not normalized, exactly as the
reproducible-build record states. Per the PR #6 policy, new releases must use canonical-build
artifacts rather than expect equality with the historical published bytes. This is not an
integration blocker.

### 5.1 Independent review

An independent correctness review and a security review were run on the complete branch diff.
Findings fixed before this record was finalised:

* packet-capture analysis now fails closed on a tcpdump read error instead of reporting zero;
* `addr6` uses `ip -6 addr replace` so a surviving address cannot abort the suite;
* an unreadable transit default route is a failure, not a pass;
* the UDP server PID is removed from the cleanup list;
* SIGINT/SIGTERM run cleanup and exit 130;
* symlinked evidence directories are rejected;
* `--cleanup` reconstructs exact names from the recorded suffix rather than deleting by prefix;
* tcpdump no longer retains root explicitly;
* preflight covers the tools the suite actually invokes;
* duplicate TCP/UDP assertions during capture are suppressed;
* the rollback failure reason is asserted;
* the support-matrix CI row reflects the hosted trusted run;
* the open toolchain-dependency acceptance criterion is restored in the backlog.

The security review found no blocking issue. It noted the existing `push: ci/**` privileged-job
trust model as a pre-existing residual risk; branch protection and review remain the control.

## 6. CI status

Hosted push run
[46044226321](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46044226321) at
`7d6762f851c8a40bd649ff7442ff3f9e22d442a0` completed successfully:

| Job | Result |
|---|---|
| Static analysis (includes `test/lib/*.sh` ShellCheck) | **success** |
| Build and validate packages | **success**; canonical `7ffe10f6…`/`6afa3f25…`; `validate-release.sh` PASS; lintian PASS |
| Reproducibility verification | **success**; both packages SAME |
| Published-release fixtures | **success** |
| Network-namespace dataplane (existing dual-stack) | **success** |
| IPv6-only qualification | **success**; 113 pass, 0 fail, 2 skip; capture and reconciler executed |
| Verify published release | skipped (not a release/manual release-validation event) |

The first hosted push run (46038607030) failed the IPv6-only job with four reconciler failures.
The runner's kernel 7.0 exposed `IFLA_VXLAN_FAN_MAP` to iproute2 6.1.0, which wrote both an
`info: Using default fan map value (33)` diagnostic and a malformed `fan-map ` token inside the
`ip -j -d` JSON. The real reconciler's JSON parser rejected the malformed document. The N6-R
harness now normalizes only those known environment artifacts, records an explicit skip when it
does so, and preserves the real reconciler/kernel/exit behavior. This is a test-environment
compatibility shim, tracked as ENG-IPV6-10; the supported EdgeOS path is unchanged.

The corrected hosted run
[46044226321](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46044226321) passed at
`7d6762f` with `pass=113 fail=0 skip=2 capture=executed reconciler=executed`. The two skips are
the host-global-IPv6 escape control (the runner has no global IPv6) and the explicit iproute2 JSON
normalization. Raw captures, `analysis.txt`, `summary.json` and the per-test logs are retained as
the run artifact.

The new job is guarded by `if: github.event_name != 'pull_request'`. It grants no new permissions,
does not use `pull_request_target`, performs no package acquisition inside the isolated workload,
requires the reconciler path and packet capture, uploads evidence on every outcome, and has an
`always()` cleanup step. A dual-stack GitHub-hosted runner that creates IPv6-only namespaces is
Level B, not Level D. The job lives in `ci.yml`, depends on the `package` job, and fetches the
same-run package by immutable ID/digest. The candidate-manifest/publication-gate contract remains
future work in [`ipv6-only-qualification-ci-integration.md`](ipv6-only-qualification-ci-integration.md).

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
* tcpdump — **required** in authoritative CI; installed from the distribution source in a separate
  preparation step if absent; optional for local developer runs;
* Perl with `JSON::PP` — already required by the existing address helper and the off-device suite;
* `CAP_NET_ADMIN`/root — only in the privileged job and local container.

The CI tooling install script (actionlint/zizmor/ShellCheck) is unchanged and still uses pinned
checksums. The new APT helper is test/CI-only and does not alter the package payload.

## 9. Remaining risks and limitations

1. N6/N6-R/N6-R-P are general-Linux namespace evidence, not ER-X hardware evidence.
2. The reconciler section uses test doubles for the EdgeOS config API, firewall dispatch, bridge
   helper and `vyatta-address`; those layers are not qualified by this record.
3. The generic bridge section is not ENG-IPV6-04 hardware qualification.
4. Packet capture is local evidence in developer runs; authoritative CI requires it and fails if it
   is absent or fails.
5. The host and CI runner are dual-stack; Level D is not achieved.
6. IPv4 loopback and AF_INET support remain in the workload namespaces, by explicit Level B design.
7. No PMTUD/PTB test across a real routed path; the MTU boundary is local to the VXLAN interface.
8. The local host cannot create network namespaces; the privileged-container execution is recorded
   as such and is not hosted CI.
9. Hosted CI has run and passed for this branch (run 46041828240 at the final accepted code commit);
   the candidate-bound port into PR #8's `ci.yml`/release gate is still pending.
10. The `ipv6-only` job is in `ci.yml`; wiring its evidence into the release candidate manifest and
    publication gate is a separate Phase III change, not yet implemented.
11. Candidate-package execution is local integration-ready evidence; it is not yet part of the
    hosted candidate build or release gate.
12. `lintian` passed locally in a container and in the hosted package job.

## 10. Reproduction

See [`ipv6-only-qualification.md`](ipv6-only-qualification.md#7-reproducing-the-evidence) for the
full command set, including the privileged-container form and the cleanup command.
