# IPv6-only qualification: model, isolation contract and CI integration

**Status:** current engineering note, 2026-11-27. It records the Level B capability added by
ENG-IPV6-03. It does not promote any namespace result to hardware evidence and does not claim
Level C or Level D.
**Scope:** the isolated Linux network-namespace topology in `test/ipv6-only-netns.sh`, its
assertions and negative controls, and its GitHub Actions job.
**Related:** [`address-family-support-matrix.md`](address-family-support-matrix.md),
[`engineering-backlog.md`](engineering-backlog.md),
[`ipv4-dependency-inventory.md`](ipv4-dependency-inventory.md), and the validation record
[`ipv6-only-qualification-evidence.md`](ipv6-only-qualification-evidence.md).

## 1. Qualification levels

"IPv6-only" is not one property. This project distinguishes four levels because they have different
threat models, evidence classes and residual dependencies.

| Level | Environment | Evidence class | Status on 2026-11-27 |
|---|---|---|---|
| **A** | IPv6 dataplane over dual-stack infrastructure: IPv6 VTEP endpoints and IPv6 overlay; IPv4 may remain elsewhere. | Existing `test/integration-netns.sh` (N) and hardware records (H). | **Achieved** for the combinations recorded in the support matrix. This is not independence from IPv4. |
| **B** | Isolated IPv6-only execution environment: IPv6-only underlay and overlay, no usable IPv4 interfaces or routes for external communication, no IPv4 management/dataplane dependency, no hidden IPv4 reachability through the host, no NAT64/DNS64/CLAT. | `test/ipv6-only-netns.sh` (N6), plus the reconciler path in the same topology (N6-R, partial). | **Achieved at the Linux network-namespace evidence class.** Not hardware-qualified. |
| **C** | IPv6-only lifecycle: installation, configuration, management, diagnostics, upgrade and removal without IPv4 connectivity. | None. | **Not achieved.** Deferred to ENG-IPV6-01 and ENG-IPV6-02; external acquisition is a known blocker. |
| **D** | End-to-end IPv6-only CI infrastructure: runner, source/dependency acquisition, artifact distribution and CI control plane without IPv4. | None. | **Not achieved and not claimed.** GitHub-hosted runners and GitHub service endpoints remain external dependencies; see §9. |

A dual-stack GitHub-hosted runner that creates IPv6-only namespaces is **Level B**, not Level D.
The runner's own management and the workflow's control plane still use the host stack.

### 1.1 Evidence classes used here

| Code | Meaning |
|---|---|
| **N6** | Isolated IPv6-only Linux network-namespace topology. General-Linux dataplane semantics; not EdgeOS, not hardware. |
| **N6-R** | The same topology, but the VXLAN lifecycle is driven by the actual `src/vyatta-vxlan` reconciler. The EdgeOS configuration API and firewall dispatch are test doubles; the kernel, `ip`, sysfs, MTU, addresses, recreation and rollback are real. |
| **H** | Physical ER-X hardware; only the records cited in the support matrix. |

The N6 topology does not replace the existing N (dual-stack namespace) test. It is an additional
qualification layer. Hardware evidence remains a separate class.

## 2. Level B topology

The topology is deterministic, uses documentation addressing (RFC 3849 / RFC 5737), and has no
physical interface or external route.

```text
       host-a                         transit                         host-b
  2001:db8:201::a/64         2001:db8:10:1::/64 2001:db8:10:2::/64   2001:db8:202::b/64
        |                              |               |                    |
      eth1                           ta0             tb0                  eth1
        |                              |               |                    |
     +--------+                    +-------+       +-------+            +--------+
     | vtep-a |---- eth0 --------- |transit| ----- | vtep-b | -----------| vtep-b |
     +--------+  2001:db8:10:1::a1 +-------+       +-------+  eth0        +--------+
        |                              ^               |      2001:db8:10:2::b1
        | vxlan100 / vxlan200 / vxlan300                 |
        +---------------- IPv6 VXLAN over UDP/4789 ------+
             VNI 100: 2001:db8:100::/64 (VTEP-to-VTEP)
             VNI 200: 2001:db8:200::/64 (routed host overlay)
             VNI 300: 2001:db8:300::/64 (generic Linux bridge feasibility)
```

| Component | Address / parameter | Notes |
|---|---|---|
| Underlay A | `2001:db8:10:1::/64` | Transit `::1`, VTEP A `::a1`; MTU 1500 |
| Underlay B | `2001:db8:10:2::/64` | Transit `::1`, VTEP B `::b1`; MTU 1500 |
| VTEP underlay routes | default via the transit | The transit has only connected routes and no default |
| VNI 100 overlay | `2001:db8:100::/64` | VTEP A `::a`, VTEP B `::b`; `vxlan100` MTU 1430 |
| VNI 200 overlay | `2001:db8:200::/64` | VTEP A `::a`, VTEP B `::b`; `vxlan200` MTU 1430 |
| Host A segment | `2001:db8:201::/64` | Host A `::a`, VTEP A `::1`; default via `::1` |
| Host B segment | `2001:db8:202::/64` | Host B `::b`, VTEP B `::1`; default via `::1` |
| Routed host path | A: `202::/64 via 200::b`; B: `201::/64 via 200::a` | Traffic crosses VNI 200; hosts are on different /64s |
| VNI 300 bridge | `2001:db8:300::/64` | `vxlan300` enslaved to `br300` on each VTEP; generic Linux bridge only |
| IPv4 control pair | `198.51.100.1/24` and `.2/24` | Separate namespaces; used only to prove the negative-control destination is reachable in an IPv4-capable environment |

Design properties:

* **Routed underlay.** The VTEPs do not share an Ethernet segment. The transit namespace forwards
  IPv6 between two /64 links, and the assertions verify that the route to the peer VTEP is via the
  transit.
* **Two independently isolated VTEPs.** `vtep-a` and `vtep-b` are separate network namespaces with
  separate interfaces and routing tables; they are connected only through the transit.
* **Separate overlays.** VNI 100 carries VTEP-originated traffic; VNI 200 carries routed
  host-to-host traffic; VNI 300 is the bridge feasibility case. VXLAN encap/decap and counters are
  checked for VNI 200.
* **Explicit MTU.** Underlay links are 1500 bytes; VXLAN interfaces and the bridge are 1430 bytes.
  The boundary is checked with `ping -M do`: a 1382-byte ICMPv6 payload fits
  (40 + 8 + 1382 = 1430), and 1383 bytes is rejected instead of being source-fragmented.
* **No external connectivity during dataplane execution.** The transit has no default route; the
  VTEPs' default routes point only at the transit; there is no NAT, proxy or translation function.

## 3. Isolation contract

The Level B contract is more than a successful IPv6 ping. The test asserts all of the following in
`vtep-a`, `vtep-b`, the transit, and both hosts.

### 3.1 Preflight and runtime assertions

| Check | Required state |
|---|---|
| IPv4 addresses | No IPv4 address except `127.0.0.1/8` on `lo`. A loopback-mapped address on any other interface is also a violation. |
| IPv4 routes | `ip -4 route show table all` contains only local/broadcast bookkeeping on `lo`; no default, gateway or non-loopback route. |
| IPv4 policy rules | No rule except the kernel's default `local`, `main` and `default` rules; any selector or additional table is a violation. |
| IPv4 main table | `/proc/net/route` has no route row after the header. |
| IPv4 forwarding | `net.ipv4.conf.{all,default}.forwarding` is `0`. |
| Translation | No `64:ff9b::/96` or `nat64` route and no `nat64`, `clat`, `464xlat` or `tayga*` interface. |
| Interface kinds | Only loopback, veth, VXLAN and bridge devices are present. |
| veth peers | Every workload veth peer is the intended namespace: VTEPs to the transit, hosts to their VTEP, and the IPv4 control pair to each other. A veth peer outside that set is a violation. |
| Namespace boundaries | The five workload namespaces have distinct network-namespace inodes and none equals the host's namespace. |
| Host escape | No host-side test veth remains after setup; the VTEP cannot reach a host IPv4 or global IPv6 address. A host-global-IPv6 control is skipped when no suitable address exists, and the skip is recorded. |
| Host sysctls | The host's IPv4 `ip_forward` and IPv6 `all/forwarding` values are unchanged after the run. Namespace sysctls are written only through `ip netns exec`. |
| Collision safety | The suite refuses to reuse pre-existing namespaces or host links; cleanup removes only objects recorded as created by this run. |
| AF_INET negative control | An `AF_INET` socket can be created, but a UDP send to `198.51.100.2` fails with `ENETUNREACH` or `EHOSTUNREACH`. |

IPv4 loopback and AF_INET kernel support deliberately remain. They are platform facilities, not
usable external IPv4 connectivity. The test records that loopback is present and that socket
creation succeeds, and separately requires the external send to fail. The presence of AF_INET is
never interpreted as a pass for external IPv4 connectivity.

### 3.2 Negative controls

| Control | Expected result |
|---|---|
| Add `192.0.2.99/32` to a VTEP link | The isolation validator reports the introduced address and fails. |
| Add an IPv4 route `203.0.113.0/24 dev <underlay>` | The validator reports the route and fails. |
| Add an IPv4 policy rule and a route in table 100 | The validator inspects all policy tables and fails. |
| Remove the canaries | The validator returns to a clean state. |
| IPv4 control pair pings `198.51.100.2` | The destination is reachable in the IPv4-capable control environment. |
| Isolated host pings the same destination | The ping fails; there is no route. |
| Bring `vxlan100` down | Overlay connectivity fails. |
| Bring `vxlan100` up and re-add its IPv6 address | Overlay connectivity recovers. (Linux flushes IPv6 addresses on link-down; the test restores the address deliberately.) |

These controls make the assertions falsifiable. A validator that reports success regardless of the
introduced state would fail the control.

### 3.3 Threat model

| Asset | Boundary | Threat | Control | Residual risk |
|---|---|---|---|---|
| The "IPv6-only" claim | Workload network namespaces | A missed IPv4 address/route or policy table | Address/route/rule/`/proc` assertions in every workload namespace | Kernel AF_INET and loopback remain; documented, not external connectivity |
| Host network | Host namespace vs workload namespaces | A veth or route escapes into the host | Both veth ends are moved into workload namespaces; host-side leftovers and host addresses are checked | A kernel or tool defect could violate the boundary |
| Dataplane | VXLAN interfaces | A test pings a local address instead of crossing VXLAN | Routed underlay, host-to-host traffic, VXLAN counters, capture of UDP/4789 and inner TCP/UDP/ND | Namespace semantics are not vendor-kernel semantics |
| Hidden translation | Namespaces | NAT64, DNS64, CLAT or a proxy conceals IPv4 reachability | No translation route/interface; external IPv4 send must fail | DNS64 is a resolver behaviour; no resolver is used in the dataplane test, so it is recorded as out of scope |
| CI execution | Trusted refs only | Untrusted PR code gains `CAP_NET_ADMIN` | `if: github.event_name != 'pull_request'`; no `pull_request_target`; no extra permissions | A compromised trusted branch can misuse runner privileges, as with any CI job |
| Production router | Project boundary | Test activity touches the maintainer's ER-X | No hardware access in this work; namespace topology only | Hardware qualification remains separate |
| Inherited sockets | Process boundary | A pre-opened socket or Unix-domain socket bypasses the network namespace | The harness passes no extra file descriptors, uses no proxy environment, and runs only trusted project code | The harness is **not** a security sandbox for arbitrary adversarial code |
| Alternative translation prefixes | Namespaces | A NAT64 implementation using a prefix other than `64:ff9b::/96` conceals IPv4 reachability | No IPv4 address or route exists in the workload; the transit has no default route; no translation interface is present; the IPv4 external-send control fails | A userspace proxy over a host Unix socket is outside the network-namespace model and is explicitly out of scope |
| Proxy environment | Process environment | A host HTTP/HTTPS/ALL_PROXY variable could route traffic through an IPv4-capable proxy | The test does not use HTTP; proxy variables are not consulted by the dataplane tools; inherited environment is not treated as qualification evidence | Application-level proxy behavior is out of scope for the network dataplane |

The absence of a `64:ff9b::/96` route is not, by itself, proof that every possible NAT64 deployment
is absent. The stronger property here is the closed topology: the workload has no IPv4 address or
route, the transit has no default IPv6 route, and no translation interface or external IPv6 path
exists. A translation function would need one of those paths to reach an IPv4 destination; the
assertions remove them. The harness qualifies trusted project code under controlled conditions; it
is not a security sandbox for arbitrary adversarial code.

The topology is intentionally conservative: it does not attempt to prove the absence of every
possible IPv4 application dependency. It proves the specific Level B properties above, and the
IPv4 dependency inventory records the rest.

## 4. Functional coverage

| Area | Coverage | Evidence |
|---|---|---|
| IPv6 VTEP endpoint configuration | `ip link add ... local <IPv6> remote <IPv6> dstport 4789`; identity inspected | N6 |
| VXLAN interface creation | VNI 100, 200 and 300 on both VTEPs | N6 |
| IPv6 overlay addressing | `/64` overlay addresses on `vxlan100`, `vxlan200`, `br300` | N6 |
| Neighbor Discovery | Underlay and overlay neighbor caches are flushed, traffic resumes, and the peer appears in `ip -6 neigh` | N6 |
| Bidirectional overlay connectivity | ICMPv6 in both directions for VTEP and host overlays | N6 |
| TCP and UDP | Python IPv6 TCP and UDP client/server across the routed host overlay | N6 |
| Routed underlay | Transit namespace; route to the peer VTEP is via the transit | N6 |
| Encapsulation/decapsulation | VXLAN TX/RX counters increase; capture shows UDP/4789 on the underlay and decapsulated inner IPv6 on the overlay | N6 |
| Deletion and recreation | `vxlan100` is deleted and recreated; overlay traffic resumes | N6 |
| MTU boundary | 1430-byte VXLAN MTU; 1382-byte payload passes, 1383 is rejected with `-M do` | N6 |
| Generic Linux bridge | `vxlan300` enslaved to `br300`; IPv6 ping and ND work | N6 (generic Linux only) |
| Actual reconciler lifecycle | Real `src/vyatta-vxlan` creates, updates idempotently, recreates, rolls back on an invalid MTU, restores and deletes | N6-R (partial) |
| Reconciler-created TCP/UDP | IPv6 TCP and UDP through the `vxlan900` interface created by the actual reconciler | N6-R (partial) |
| Reconciler endpoint validation | Mixed-family and IPv6-multicast endpoints are rejected before mutation; the live interface is unchanged | N6-R (partial) |
| Repeated execution and cleanup | Two consecutive runs leave no namespaces or host-side links; SIGTERM exits 130 and cleans up | N6 |

### 4.1 What the reconciler path actually executes

The N6-R section runs the repository's `src/vyatta-vxlan` inside the VTEP namespaces. The
following components are real:

* the VXLAN identity parsing through `src/vyatta-vxlan-addr` and `ip -j -d link show`;
* endpoint validation, canonicalisation and family checks;
* `ip link add`, MAC assignment, MTU application, address reconciliation and link state;
* live-state capture, idempotent comparison, recreation, rollback and deletion;
* IPv6 TCP and UDP through the reconciler-created `vxlan900` interface;
* rejection of mixed-family and IPv6-multicast endpoints before any mutation;
* the real `ip` binary, sysfs device state and kernel VXLAN/NDP behaviour.

The following are test doubles and are **not** evidence for those product layers:

* `my_cli_shell_api` (a file-backed configuration tree, not the EdgeOS config engine);
* `vyatta-vxlan-firewall` (the capture/apply/restore/verify/remove interface is stubbed);
* `vyatta-vxlan-bridge` (a no-op for routed interfaces);
* `vyatta-address` (a thin `ip addr add/del` wrapper);
* `id`, `sudo` and `modprobe` wrappers;
* a test-only `ip` shim that drops the known `info: Using default fan map value` diagnostic from
  `ip -j -d` output on modern iproute2. All other `ip` calls and the real exit status are
  preserved. This is an environment compatibility layer, **not** a product fix; the supported
  EdgeOS behavior is unchanged. See ENG-IPV6-10.

Consequently the N6-R result is classified **partial**: it exercises the VXLAN reconciler, not
EdgeOS firewall dispatch, the vendor configuration engine, or bridge-port reconciliation. Those
remain covered by the off-device unit/mock suite and by hardware qualification, respectively.
The bridge section is generic Linux bridge feasibility; it is **not** ENG-IPV6-04 physical
EdgeOS bridged-dataplane qualification.

## 5. CI integration

The new job is `ipv6-only` in `.github/workflows/release-validation.yml`, named
**IPv6-only qualification**.

| Property | Value |
|---|---|
| Events | `push` to `main` and `ci/**`, tags `v*`, `release: published`, `workflow_dispatch` |
| Pull requests | **Not executed.** The job is guarded by `if: github.event_name != 'pull_request'`, like the existing privileged namespace job. |
| Runner | `ubuntu-24.04`, GitHub-hosted |
| Permissions | Workflow-level `contents: read`; no additional permissions are granted |
| Privileges | `sudo` for network namespaces and `modprobe`; no repository secrets |
| Dependency preparation | Tool-presence check; `iproute2`, `iputils-ping`, Python 3 and coreutils come from the runner image. If tcpdump is absent, a separate step refreshes only the distribution APT source and installs tcpdump; no package is installed inside the isolated workload. |
| Authoritative capture | `REQUIRE_CAPTURE=1`; tcpdump availability, startup, completion and analysis are required. An absent or failed capture fails the job. Raw captures and `analysis.txt` are uploaded. |
| VXLAN modules | Explicit `modprobe vxlan udp_tunnel ip6_udp_tunnel`; a failure fails the job. |
| Isolation assertions | Inside `test/ipv6-only-netns.sh` before and after functional traffic. |
| Dataplane | Same script; IPv6 ICMP/TCP/UDP, NDP, MTU, recreation, capture when available. |
| Evidence | `$RUNNER_TEMP/ipv6-only-evidence` uploaded as `ipv6-only-qualification-evidence` on every outcome. |
| Cleanup | The script's `EXIT`/`INT`/`TERM` trap, plus an `always()` cleanup step that reconstructs the exact namespace/link names from the recorded suffix. |
| Required reconciler | `REQUIRE_RECONCILER=1`; a missing Perl `JSON::PP` or harness failure fails the job instead of silently skipping the integration path. |
| Packet capture | Authoritative CI requires capture (`REQUIRE_CAPTURE=1`). The script verifies tcpdump startup, capture completion, non-empty captures and the expected VXLAN/IPv6/TCP/UDP/ND counts, and rejects IPv4/ARP at both capture points. Local developer runs may leave capture optional. |

No `pull_request_target` is used. No workflow permission is added. The job does not execute
downloaded packages. On a release event the privileged job runs the tagged source; tags require
write access, so this is the existing trusted-tag boundary, not untrusted pull-request code.

### 5.1 Failure semantics

| Result | Meaning | Job effect |
|---|---|---|
| **Passed** | The assertion ran and its expected condition held. | Contributes to the exit status 0. |
| **Failed** | The assertion ran and its expected condition did not hold, or a required dependency was missing under a `REQUIRE_*` flag. | Non-zero exit; the job fails. |
| **Skipped** | A genuinely optional check could not run (for example, the host has no global IPv6 address for the escape control). The reason is printed and recorded in `summary.txt`. In authoritative CI, capture is not optional: an absent tcpdump fails dependency verification; a capture that starts but fails is **failed**. | Does not fail the job unless the corresponding `REQUIRE_*` flag is set. Never reported as a pass. |
| **Unsupported** | The kernel or runner lacks a required facility (network namespaces, VXLAN module, root). With `REQUIRE_NETNS_TEST=1`, this is a failure; without it, the script exits 0 with an explicit `SKIP` line. | In CI, `REQUIRE_NETNS_TEST=1` makes this a failure. |
| **Blocked** | Hosted CI has not run because the branch has not been published. | Not evidence of success; must be reported as pending. |

The script prints `PASS:`, `FAIL:`, `SKIP:` and a final `ipv6-only: pass=... fail=... skip=...`
line. The uploaded `summary.txt`, `summary.json`, `environment.txt`, `topology-*.txt`,
`captures/*.pcap`, `captures/analysis.txt` and the per-test logs are the diagnostic record.
`summary.json` (schema `edgeos-vxlan.ipv6-only-qualification/v1`) is the proposed machine-readable
hand-off to a candidate/qualification manifest; see
[`ipv6-only-qualification-ci-integration.md`](ipv6-only-qualification-ci-integration.md).

### 5.2 CI dependency reliability

The transient failure after PR #7 was an `apt-get update` failure on an unrelated
`packages.microsoft.com` repository. The namespace jobs do not need that repository.

* The `ipv6-only` job performs no package acquisition for the dataplane itself. It checks the
  runner image's tools and, when tcpdump is absent, installs only tcpdump from the distribution
  source in a separate dependency-preparation step. The isolated workload starts afterwards.
* The existing `dataplane` job checks for its tools first and acquires packages only when a tool is
  missing. If acquisition is needed, `scripts/apt-update-ubuntu-only.sh` refreshes only the
  distribution's own APT source file and disables the source-parts directory for that invocation.
* The package and reproducibility jobs use the same helper. The shared runner configuration is not
  modified, signature verification is not disabled, and TLS behaviour is unchanged.
* A failure of the distribution source itself is not retried or hidden; it fails the job as an
  infrastructure error. The distinction between infrastructure failure and product regression is
  recorded in the job output.

## 6. Level D feasibility

Level D requires the runner, source acquisition, dependency acquisition, artifact distribution and
CI control plane to operate without IPv4. The current setup does not satisfy it:

* GitHub-hosted runners are dual-stack infrastructure. The job creates isolated IPv6-only
  namespaces, but the runner's management, `actions/checkout`, artifact upload and the GitHub
  control plane use the host stack.
* At the time of this audit, the resolver returned AAAA records for `raw.githubusercontent.com`
  and `archive.ubuntu.com`, but **no AAAA records** for `github.com`, `codeload.github.com`,
  `api.github.com` or `objects.githubusercontent.com`; see
  [`ipv4-dependency-inventory.md`](ipv4-dependency-inventory.md). The release assets that
  `install.sh` downloads are served through those GitHub endpoints. This is an external service
  limitation, not a defect in the installer's address-family logic.
* No self-hosted IPv6-only runner or IPv6-only CI control-plane path is available in this project.
  Adding one would require infrastructure outside this repository and is not claimed.

Level D is therefore **not achieved and not claimed**. A future Level D attempt needs an IPv6-only
runner with an IPv6-reachable CI control plane, plus an IPv6-reachable source/dependency/artifact
path. That is an infrastructure project, not a test-script change.

## 7. Reproducing the evidence

Local privileged container (used for the validation record because the development host does not
grant network-namespace privileges):

```bash
docker run --rm --privileged \
  -v "$PWD:/repo" -w /repo \
  -e REQUIRE_NETNS_TEST=1 \
  -e REQUIRE_CAPTURE=1 \
  -e REQUIRE_RECONCILER=1 \
  -e EVIDENCE_DIR=/tmp/ipv6-only-evidence \
  ipv6-qual:local \
  bash test/ipv6-only-netns.sh
```

On a host or CI runner with root/CAP_NET_ADMIN:

```bash
sudo REQUIRE_NETNS_TEST=1 REQUIRE_CAPTURE=1 REQUIRE_RECONCILER=1 \
  EVIDENCE_DIR=/tmp/ipv6-only-evidence \
  bash test/ipv6-only-netns.sh
```

Cleanup after an interrupted run:

```bash
sudo EVIDENCE_DIR=/tmp/ipv6-only-evidence bash test/ipv6-only-netns.sh --cleanup
```

The cleanup command reconstructs the exact names from `run.env` (the recorded suffix); it does not
delete arbitrary names by prefix. It does not flush host firewall rules, routes or sysctls.

## 8. Limitations and residual risks

1. **Namespace evidence is not hardware evidence.** N6/N6-R exercise general Linux semantics. The
   supported ER-X kernel and userspace are older; hardware evidence remains authoritative for
   platform claims.
2. **No EdgeOS configuration engine.** The reconciler harness uses a file-backed API double. The
   vendor commit, template validation and firewall dispatch are not exercised in the namespace.
3. **Firewall dispatch is stubbed.** `src/vyatta-vxlan-firewall` is replaced by a test double in
   N6-R. The unit, mock and hardware suites remain the evidence for firewall behavior.
4. **Bridge evidence is generic Linux only.** The VNI 300 section shows the topology can carry a
   bridged VXLAN and that ND works. It is not the physical EdgeOS bridged dataplane required by
   ENG-IPV6-04.
5. **Packet capture is mandatory in authoritative CI.** The local developer default remains
   optional, but the trusted `ipv6-only` job installs tcpdump when needed and sets
   `REQUIRE_CAPTURE=1`; a capture failure fails the job. A local capture skip is not authoritative
   evidence.
6. **IPv4 loopback and AF_INET remain.** The test proves they do not provide external IPv4
   connectivity in the workload namespaces; it does not disable them. This is explicitly part of
   the Level B definition, not a hidden exception.
7. **The host and CI runner are dual-stack.** Level B is a property of the isolated workload
   environment. Level D is not achieved.
8. **No PMTUD/PTB test across a real routed path.** The MTU boundary is tested locally at the
   VXLAN interface. Underlay PMTUD and ICMPv6 Packet Too Big remain covered by documentation and
   hardware qualification records, not by this namespace test.
9. **No production router access.** The maintainer's ER-X was not accessed, modified or used as a
   fixture for this work.
10. **Modern iproute2 diagnostic.** The hosted runner's `ip -j -d` emits a non-JSON `info:` line
    that the real reconciler parser rejects. The N6-R harness filters only that line and records a
    skip; the supported EdgeOS path is unchanged. Tracked as
    [ENG-IPV6-10](engineering-backlog.md#eng-ipv6-10-modern-iproute2-json-diagnostic-tolerance).

## 9. Related documents

* [`address-family-support-matrix.md`](address-family-support-matrix.md) — evidence by combination,
  including the new N6 rows.
* [`ipv4-dependency-inventory.md`](ipv4-dependency-inventory.md) — repository-wide classification
  of IPv4 assumptions and external service limitations.
* [`engineering-backlog.md`](engineering-backlog.md) — ENG-IPV6-03 status and remaining work.
* [`ipv6-only-qualification-evidence.md`](ipv6-only-qualification-evidence.md) — exact commands,
  environment, counts and limitations from the validation run.
* [`ipv6-only-qualification-ci-integration.md`](ipv6-only-qualification-ci-integration.md) — proposed
  integration contract with the trusted release lifecycle (PR #8).
* [`architecture.md`](architecture.md) — layer model and endpoint rules.
* [`deployment.md`](deployment.md) — deployment scenarios and operational guidance.
