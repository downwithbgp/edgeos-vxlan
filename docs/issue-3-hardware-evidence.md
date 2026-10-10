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

## Native-integration results (reported 2026-10-10)

The release candidate was subsequently installed on this router and the native EdgeOS configuration
path was exercised. Reported as passed:

* evaluation of the endpoint templates with IPv6 literals, and rejection of malformed addresses;
* rejection of mixed-family `local-ip`/`remote-ip` commits without disturbing live state;
* interface creation through the configuration system, and dual-stack dataplane over the tunnel;
* IPv6 endpoint canonicalisation — a reformatted but equivalent endpoint does not recreate the
  interface;
* family-aware MTU defaulting with `mtu` unset, and restoration of the MTU when the node is removed;
* recreation on an identity change (VNI), including the IPv4↔IPv6 family transitions;
* deletion of the interface through the configuration system;
* idempotent (no-op) commits.

Raw command output for these has not been attached to the issue yet, so this section records the
result rather than the captures, and the corresponding acceptance criteria are left unticked pending
them.

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

## Phase 6 result — isolated bridge: PASS (reported 2026-10-10)

Executed on the physical ER-X with the disposable `br901` and `vxlan901`, per Phase 6 of the
validation runbook. Reported as passed:

* **Recreation preserved the bridge state.** A VNI recreation kept `br901` membership, path cost 200,
  port priority 10, MTU 1430 and the interface MAC.
* **Failed recreation restored the bridge state.** With the deterministic failure injection, the
  rollback restored VNI 902, MTU 1430, bridge membership, cost 200, priority 10, the MAC and the `UP`
  state. `vxlan901`'s ifindex changed 31 → 33 — expected, since the index is not promised across
  recreation.
* **The partial-commit limitation reproduced.** As in Phase 5.4, the failed commit left `mtu 64` in
  the active EdgeOS configuration while the kernel had restored 1430. This is the second independent
  reproduction of the behaviour analysed in `issue-3-partial-commit-analysis.md`; it is
  deterministic, not a one-off.
* **Cleanup verified.** `br901` and the disposable `vxlan901` were removed from the kernel. The
  production test tunnel `vxlan900` remained `UP` at ifindex 20 and unchanged throughout. **No router
  configuration was saved.**

Traffic over the bridged tunnel was not part of this run, so the bridged-dataplane acceptance
criterion stays unticked.

## What remains untested

1. Persistence across `save` and reboot, including a dynamically-arriving underlay address — Phase 7.
2. Package upgrade compatibility on the router itself — Phase 8.
3. Previously accepted non-canonical IPv4 syntax, end to end.
4. Leaf-handler ordering effects beyond what the mocked tests pin, and the snapshot fail-closed path
   when a live-state component cannot be read — Phase 5.5.
5. Re-running Phase 5.4 on RC2, where the minimum-MTU correction moves the rejection into the
   validation phase and the rollback injection is a 256-character description instead (the bridge-removal method is kept
   as an optional drift-observation variant).

No document in this repository should describe the native integration as fully hardware-validated
while any of those are outstanding.
