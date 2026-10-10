# Issue #3 — Hardware Evidence: IPv6 VXLAN Dataplane on the EdgeRouter X

This document records what has actually been demonstrated on real hardware, what it does and does
not establish, and what remains untested. It is deliberately separated from the acceptance criteria,
which continue to track the integration as a whole.

**Method note.** The results in the first half of this document were produced by hand on the router —
a VXLAN interface created with the platform's `ip` command — not through the package's configuration
integration. They establish that the kernel, the module payload and the platform's userspace support
the feature. The native EdgeOS configuration path was exercised later, against the release candidate;
those results are recorded below.

**Environment** (results reported to this repository on 2026-10-10; the owner's delegated prefix is
not published, and `<PREFIX>` stands for it):

| Property | Value |
|---|---|
| Hardware | EdgeRouter X 5-Port / ER-e50 |
| Firmware | EdgeOS v3.0.1, build 5862409 |
| Kernel | `4.14.54-UBNT` |
| `ip` binary | `iproute2-ss171113` |
| Installed integration | `edgeos-vxlan 0.2.1+edgeos3.0.1.e50` |
| Installed module package | `edgeos-vxlan-kmod 0.2.1+edgeos3.0.1.e50` |
| Modules | `vxlan` loads successfully; `udp_tunnel` and `ip6_udp_tunnel` loaded |
| Router underlay | `switch0.65`, `<PREFIX>::1/64` |
| Peer host | peer uplink `<PEER_IF>`, `<PREFIX>:<PEER_IID>/64`, kernel `6.8.0-139-generic` |

The release-candidate runs recorded further down were performed on this same router: RC1 was
installed over v0.2.1, and RC2 over RC1; each section states which build its results belong to.

Underlay connectivity between the two hosts was verified bidirectionally before the tunnel tests.

**Test configuration under test:** `vxlan900`, VNI 900, UDP destination port 4789, MTU 1430,
IPv4 overlay `10.255.254.1/30` ↔ `10.255.254.2/30`, IPv6 overlay `fd42:900::1/64` ↔ `fd42:900::2/64`.

## Results

| Observation | Result |
|---|---|
| IPv6 VXLAN netdevice creation | Successful |
| `ip -j -d link show dev vxlan900` fields | `id: 900`, `local6: <PREFIX>::1`, `remote6: <PREFIX>:<PEER_IID>`, `port: 4789` — all correct |
| VNI and UDP destination port in JSON | Correct |
| IPv4 overlay over the IPv6 tunnel | Router → peer 5/5 replies, 0% loss, avg 1.173 ms; peer → router 5/5, 0% loss, avg 1.009 ms |
| IPv6 overlay over the IPv6 tunnel | Router → peer 5/5 replies, 0% loss, avg 1.800 ms; peer → router 5/5, 0% loss, avg 1.147 ms |
| IPv6 Neighbor Discovery on both VTEPs | Reachable link-layer neighbours confirmed on both ends |
| IPv6 UDP checksum | Enabled |
| IPv6 zero-checksum options | Disabled |
| Sysfs administrative-state format | `0x1003` on an active VLAN interface, `0x1002` on a down VXLAN — hexadecimal, as the reconciler's `read_iface_flags` assumes |

## Two observations worth keeping

**The human-readable `ip -d link show` output is unusable on this platform.** It displays obviously
corrupted numeric fields, including wrong VNI and destination-port values, while the JSON form of
the same query is correct. This project's live-state parsing reads the JSON form
(`ip -j -d link show`) and must continue to; any future diagnostic guidance should tell operators to
do the same rather than trusting the non-JSON output. This is a known quirk of the platform's
`iproute2-ss171113` build, and chasing it further is out of scope for this feature.

**IPv6 endpoints cannot be configured through the installed v0.2.1 templates.** An attempt fails with
`is not a valid value of type "ipv4"`, which is exactly what a 0.2.1 userspace is supposed to do.
That is expected, and it is not evidence about the new implementation either way.

## What this evidence establishes

The Linux 4.14.54 kernel shipped with EdgeOS 3.0.1, the shipped `vxlan.ko`, and the platform's `ip`
binary together support an IPv6 underlay for VXLAN: creation, identity reporting in the JSON form,
and bidirectional forwarding of both IPv4 and IPv6 overlay traffic, with Neighbor Discovery working
over the tunnel. It also confirms the two kernel-side assumptions the implementation depends on: the
hexadecimal sysfs flags format, and the `local6`/`remote6` JSON field names.

## Native-integration and validation results — RC1 (reported 2026-10-10)

The release candidate was subsequently installed on this router and the native EdgeOS configuration
path was exercised. Reported as passed on RC1:

* evaluation of the endpoint templates with IPv6 literals; rejection of a malformed address and of
  an endpoint containing a CIDR prefix;
* rejection of mixed-family `local-ip`/`remote-ip` commits with the expected message, **without
  modifying the live interface** — the invalid configuration left the working interface untouched;
* interface creation through the configuration system, with the correct kernel VNI, UDP port, MTU,
  endpoint identity, MAC and overlay addresses, and dual-stack dataplane over the tunnel;
* IPv6 endpoint canonicalisation — a reformatted but equivalent endpoint does not recreate the
  interface;
* family-aware MTU defaulting with `mtu` unset — 1430 over an IPv6 underlay, 1450 over an IPv4
  underlay — mutable MTU changes without recreation, and removal of an MTU override restoring the
  automatic default;
* recreation on an identity change (VNI), including the IPv4↔IPv6 family transitions;
* unrelated VXLAN interfaces preserved throughout;
* deletion of the interface through the configuration system;
* idempotent (no-op) commits.

Raw command output for these has not been attached to the issue yet, so this section records the
result rather than the captures; the acceptance criteria note this explicitly (Revision 7).

## RC2 installation and upgrade (reported 2026-10-10)

The RC2 pair — `edgeos-vxlan 0.2.2~rc2+edgeos3.0.1.e50` and `edgeos-vxlan-kmod
0.2.2~rc2+edgeos3.0.1.e50` — was installed over RC1 on this router: both packages in one `dpkg`
invocation, kernel package first. Installation passed and `dpkg -V edgeos-vxlan edgeos-vxlan-kmod`
reported no modified files. `dpkg --audit` reports only the pre-existing `squid` and `ssmtp`
checksum-metadata warnings, which predate RC1 and RC2; neither of this project's packages is
affected.

**The live tunnel survived the RC1 → RC2 upgrade without interface recreation**: `vxlan900` kept its
ifindex (20) across the package transaction.

## RC2 minimum-MTU validation (reported 2026-10-10)

The one behavioural change in RC2 — the `mtu` template minimum raised from 64 to 68, the kernel's
own minimum — was checked on the router against the candidate configuration only: `mtu 64` and
`mtu 67` were rejected immediately (the runbook's test 1.8), as was the out-of-range `mtu 8025`.
The candidate configuration was unchanged after every rejection; no commit was attempted and no
live state was touched by these checks.

## RC2 save and reboot restoration (reported 2026-10-10)

The router configuration was saved — including the deployment-specific UDP/4789 firewall exception
noted below — and the router was rebooted. No manual VXLAN recreation and no subsequent
configuration commit was necessary. After the reboot:

| Observation | Result |
|---|---|
| Installed packages | both RC2 packages still installed (`ii`) |
| Underlay | the router's IPv6 underlay address restored |
| Interface | `vxlan900` appeared automatically |
| Interface index | 20 → 16 (expected — the index is not promised across boot or recreation) |
| VNI / UDP port | 900 / 4789, correct |
| JSON identity | correct `local6` and `remote6` endpoints |
| MTU | 1430 |
| MAC | `e6:69:92:17:3e:e9` — unchanged |
| Overlay addresses | `10.255.254.1/30` and `fd42:900::1/64` restored |
| Modules | `vxlan`, `udp_tunnel` and `ip6_udp_tunnel` loaded |

**Firewall note.** The saved configuration carries one deployment-specific exception: an accept
rule for UDP/4789 in the underlay's existing IPv6 local ruleset, restricted to the peer source
address, the router destination and the VXLAN UDP destination port; its description still identifies
it as a temporary test — the saved text reads "Temporary IPv6 VXLAN test" (the runbook prescribed a
differently-worded placeholder). This rule belongs to the deployment, not to the package —
`edgeos-vxlan` does not create or modify firewall policy — and it should be renamed or removed when
the test setup is retired.

## RC2 post-reboot dataplane (reported 2026-10-10)

Run after the reboot above, over the restored tunnel, with the restricted rule in place:

| Direction | Overlay protocol | Packets | Average RTT |
|---|---|---|---|
| EdgeRouter → peer | IPv4 | 5/5 | 1.393 ms |
| peer → EdgeRouter | IPv4 | 5/5 | 1.121 ms |
| EdgeRouter → peer | IPv6 | 5/5 | 1.679 ms |
| peer → EdgeRouter | IPv6 | 5/5 | 1.304 ms |

**Total: 20/20 packets received, zero loss.**

**Scope.** This establishes save/reboot restoration of the native IPv6-underlay VXLAN and dual-stack
overlay connectivity with the *existing* delegated prefix. It does not test a delegated-prefix
change, power-loss recovery, repeated boots, or peer-router reboot persistence; those are separate
scenarios and none of them may be claimed from this run.

**Peer note.** The Ubuntu peer's VXLAN was configured manually. That configuration is outside the
EdgeOS package's responsibility and is not a persistent two-endpoint deployment; it should not be
read as one.

## Phase 5.4 result — kernel rollback PASS, configuration atomicity FAIL (reported 2026-10-10)

The deterministic recreation-failure procedure was executed on the physical ER-X against the
disposable `vxlan901`. Recorded outcome: **kernel rollback PASS, full configuration atomicity FAIL.**

* **Kernel rollback: PASS.** Changing VNI 901 → 902 together with `mtu 64` produced
  `RTNETLINK answers: Invalid argument`; the reconciler reported a successful rollback and the
  interface was restored with VNI 901, UDP port 4791, MTU 1430, the correct IPv6 endpoints and `UP`.
  Its ifindex changed 27 → 29 — expected, since the index is not promised across recreation.
  Unrelated `vxlan900` remained at ifindex 20 throughout.
* **Configuration atomicity: FAIL.** After the failed commit the candidate held the rejected values
  (VNI 902 / MTU 64), the **active EdgeOS configuration held VNI 901 with MTU 64**, and the kernel
  held MTU 1430. A value the kernel never accepted therefore reached the active configuration.
* **Recovery: executed, and successful.** Setting the candidate back to VNI 901 / MTU 1430 and
  committing made the active configuration and the kernel consistent again, with **no interface
  recreation**. Operator note: do not `save` while a failed commit's drift is still in the active
  configuration — that would persist the drifted value into `/config/config.boot`.

The mechanism behind this, and the correction it implies, are analysed in
`issue-3-partial-commit-analysis.md`.

**RC2 status.** The reconciler and the bridge handling in RC2 are byte-identical to RC1 (verified by
extracting both candidate packages and diffing their payloads — the integration package differs only
in the `mtu` template and the changelog), so these RC1 results describe the RC2 code as well. The
RC2-specific failure injection — a 256-character description, the runbook's replacement for the MTU
injection RC2 removed — has **not** been executed on the router; its efficacy premise (the target
kernel refusing a 256-character alias) is currently measured off-device only.

## Phase 6 result — isolated bridge: PASS (reported 2026-10-10)

Executed on the physical ER-X with the disposable `br901` and `vxlan901`, per Phase 6 of the
validation runbook. Reported as passed:

* **Recreation preserved the bridge state.** A VNI recreation kept `br901` membership, path cost 200,
  port priority 10, MTU 1430 and the interface MAC.
* **Failed recreation restored the bridge state.** The run had started from VNI 902; with the
  deterministic failure injection the rollback restored VNI 902, MTU 1430, `br901` membership, cost
  200, priority 10, the MAC and the `UP` state. `vxlan901`'s ifindex changed 31 → 33 — expected,
  since the index is not promised across recreation.
* **The partial-commit limitation reproduced.** As in Phase 5.4, the failed commit left `mtu 64` in
  the active EdgeOS configuration while the kernel had restored 1430. This is the second independent
  reproduction of the behaviour analysed in `issue-3-partial-commit-analysis.md`; it is
  deterministic, not a one-off.
* **Cleanup verified.** `br901` and the disposable `vxlan901` were removed from the kernel. The
  production test tunnel `vxlan900` remained `UP` at ifindex 20 and unchanged throughout. **No router
  configuration was saved.**

Traffic over the bridged tunnel was not part of this run, so the bridged-dataplane acceptance
criterion stays unticked.

**RC2 status.** Same code as RC1 in this area (see the payload-diff note in the Phase 5.4 section);
the RC2 re-run has not been executed.

## What remains untested

Physical hardware, listed with the reason it has not been exercised:

1. **RC2-specific failure injection** — the runbook's 256-character description injection (Phase 5.4
   re-run). The RC1 rollback evidence covers the same reconciler code, but the replacement
   injection's efficacy on the target kernel is measured off-device only.
2. **Bridged-tunnel traffic** — Phase 6 validated membership, cost and priority, not packets over
   the bridge.
3. **Upgrade from v0.2.1 with an existing, configured IPv4 tunnel**, end to end (Phase 8.1–8.3).
   The upgrade transaction has been studied off-device and executed on the router twice
   (v0.2.1 → RC1 → RC2, the second time with a live IPv6 tunnel), but never with a committed IPv4
   VXLAN configuration in `/config/config.boot`.
4. **Non-canonical IPv4 literal behaviour on the target** (Phase 1.7 / matrix row 31) — the
   platform-parity octal interpretation is implemented and unit-tested, but the target's own parser
   has not been asked to bind such a literal.
5. **Delegated-prefix change and underlay readiness timing** — the successful reboot used the prefix
   that was already present. A prefix change on the ISP side, or an underlay address that arrives
   after the configuration replay, is not covered (Phase 7.4).
6. **Snapshot fail-closed path on the target** (Phase 5.5) — covered by off-device
   failure-injection suites; no live-state component can be made unreadable on the router without
   disturbing service.
7. **A failed family transition under injected failure** — covered by the mocked harness; no
   hardware failure-injection on a v4↔v6 transition has been run.
8. **The firewall drop direction for IPv6** — the extended `VLANv6_LOCAL` ruleset (deployment-side)
   was active while the tunnel worked, but an alternate-source IPv6 packet was not produced to
   demonstrate the drop path, and the repository's IPv6 firewall example is not written yet.

No document in this repository should describe the native integration as fully hardware-validated
while any of those are outstanding.
