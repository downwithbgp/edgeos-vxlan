# Issue #3 — Proposed Acceptance Criteria (GitHub-ready, DO NOT POST WITHOUT REVIEW)

These criteria describe demonstrable behaviour on the supported platform (EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409, kernel `4.14.54-UBNT`). Unchecked items are pending implementation and hardware validation. Copy to the issue body only after review.
**Revision 2 (post-review):** updated for the corrected MTU evidence (no fragmentation reliance), scoped rollback claims, snapshot-read failures, deterministic failure injection, the IPv4 literal policy, interface-index semantics, dynamic-address boot, and the existing-policy firewall case.
**Revision 3 (post-hardware, 2026-10-10):** the dataplane criteria marked as demonstrated below were verified on the supported hardware **by hand** (`ip link add`), not through the package's configuration integration — see `issue-3-hardware-evidence.md`.
**Revision 4 (post-RC1, 2026-10-10):** the release candidate was installed and the native EdgeOS integration path exercised: creation, dual-stack dataplane, endpoint canonicalisation, family-aware MTU defaulting and restoration, VNI recreation, IPv4↔IPv6 transitions, deletion, malformed-address and mixed-family rejection, and no-op commits all passed. Those criteria are **deliberately left unticked here** until the raw captures are attached — the result is recorded, the evidence is not yet filed. Rollback, bridging, persistence and packaging criteria remain unverified; the validation runbook now spells out the two hazardous remaining procedures (Phases 5.4 and 6).
**Revision 5 (post-Phase 5.4, 2026-10-10):** the deterministic recreation-failure test was executed: **kernel rollback PASS, full configuration atomicity FAIL.** Restoration of live state passed, and the commit did return an error — but the failed commit still wrote the changed leaf value (`mtu 64`) into the active configuration while the kernel held the pre-commit value. Mechanism, and the recommended correction: `issue-3-partial-commit-analysis.md`. The rollback criteria stay **unticked** until that correction is applied and the test re-run.
**Revision 6 (RC2, 2026-10-10):** the correction is applied — the `mtu` template minimum is now the kernel's own 68, and a regression test pins it (the suite is 132 checks: helper 64, templates 32, mock 36). The rollback criteria stay unticked: the hardware re-run on RC2 has not happened yet. The minimum-MTU behaviour itself is checked by test 1.8 of the validation runbook.

---

## Configuration and validation

- [ ] `set interfaces vxlan vxlanN local-ip <IPv6>` and `set interfaces vxlan vxlanN remote-ip <IPv6>` are accepted for valid unicast IPv6 literals (global unicast or ULA); canonical IPv4 literals remain accepted exactly as today (non-canonical forms follow the policy criterion below).
- [ ] A commit with mixed address families for `local-ip`/`remote-ip` is rejected with a clear message, **without deleting or modifying any live interface**.
- [ ] A commit with a malformed address, an IPv6 prefix, or a hostname in `local-ip`/`remote-ip` is rejected.
- [ ] IPv6 **remote** endpoints that this fixed-remote model cannot use are rejected with a reason: link-local (`fe80::/10`), multicast (`ff00::/8`), unspecified (`::`), loopback (`::1`), IPv4-mapped (`::ffff:0:0/96`). An unspecified **local** endpoint (`0.0.0.0`/`::`) is accepted exactly as today and treated as "no specific local address".
- [ ] Non-canonical IPv4 literals (leading-zero octets such as `010.1.2.3`) follow the recorded platform policy: either interpreted exactly as the platform's own parser binds them (octal) or rejected with an explicit message — never silently reinterpreted as decimal.
- [ ] The reconciler itself rejects mixed-family or invalid desired endpoints before any mutation, even when invoked without the template layer (defence in depth).
- [ ] Existing IPv4 configurations **with canonical literals** validate and commit unchanged; non-canonical literals follow the recorded policy (platform parity or explicit rejection).

## Dataplane

- [x] A VXLAN with IPv6 `local-ip`/`remote-ip` is created and passes bidirectional IPv4 overlay traffic to an IPv6-connected peer. *(Demonstrated on hardware by hand, not through the integration.)*
- [x] The same tunnel passes bidirectional IPv6 overlay traffic. *(Demonstrated on hardware by hand, not through the integration.)*
- [ ] `ip -j -d link show dev vxlanN` on the router reports the tunnel with `local6`, `remote6`, `id`, and `port` matching the configured values (raw output attached as evidence). *(Only the attachment is outstanding — the values themselves were verified in the hardware session. Note that the non-JSON form of the same query is corrupt on this platform, so diagnostics must use the JSON form; see the evidence document.)*
- [ ] With `mtu` unset, an IPv6-underlay tunnel comes up with MTU 1430 on a standard untagged 1500-byte underlay path (and 1450 for IPv4 underlays); an explicit `mtu` value is always honoured; the documentation states the path-MTU formula (VLAN/PPPoE adjustments) and that over-sized outer packets are not relied upon to fragment.
- [ ] A bridged VXLAN over an IPv6 underlay passes traffic and keeps its bridge membership, path cost, and port priority.

## Lifecycle and idempotency

- [ ] Committing an unchanged IPv6 configuration does not delete or recreate the interface, including when the configured underlay endpoint spelling differs from the kernel's canonical representation. (Interface addresses with non-canonical spelling are handled by the same canonical comparison; covered by the U-ADDR unit tests.)
- [ ] Changing `local-ip`, `remote-ip`, `vni`, or `port` recreates the interface exactly once and reapplies MAC, MTU, addresses, description, bridge state, and admin state.
- [ ] IPv4→IPv6 and IPv6→IPv4 transitions are recognised as identity changes and apply the correct family and endpoints.

## Rollback

- [ ] A failed creation during an IPv6 identity change restores the live interface as captured at snapshot time — family, endpoints, VNI, port, MAC, MTU, addresses, description, bridge membership/cost/priority, admin state — and the commit returns an error. The failure is injected deterministically (blocker VNI/port collision or mocked `ip` failure), not by unreachable-VTEP or firewall scenarios.
- [ ] A failed v4→v6 or v6→v4 transition restores the previous family faithfully.
- [ ] If any snapshot component cannot be read successfully (identity fields, MAC, MTU, description, address collection, bridge state, admin state), the commit fails **before** deleting anything.
- [ ] For a combined identity+mutable change, either the handler-order observation shows no pre-snapshot mutation, or the leaf handlers are guarded so the snapshot still reflects the pre-change live state; otherwise the rollback claim is explicitly scoped to snapshot-time state.
- [ ] The interface index is **not** promised across recreation; the behaviour is documented and observed (before/after recreation and rollback).

## Persistence and packaging

- [ ] `save` + reboot restores the IPv6 tunnel (identity, MTU, MAC, address/bridge state, admin state), including when the underlay IPv6 address arrives dynamically (SLAAC/DHCPv6); the readiness timing is documented.
- [ ] Upgrading from v0.2.1 with an existing IPv4 VXLAN leaves that tunnel operational (no recreation, no configuration change).
- [ ] The kernel payload is unchanged: packaged `vxlan.ko` sha256 `7c346342bf00202820e8581bfdfc28851add052d2b0e5dde1560819f90bf82b6`, `udp_tunnel.ko` sha256 `6d58ee597d8ae50898efe90ec61a4803ae4f0549f29fba9c4132ca92260405cc`.
- [ ] Package removal safeguards and `dpkg-divert` restoration still work.

## Security and documentation

- [ ] The documentation states that `remote-ip` is not an ingress allowlist for IPv6 either, with a tested `firewall ipv6-name` example that drops UDP/4789 from other sources while preserving unrelated traffic — including the case where the underlay interface already has a local IPv6 policy attached (extend the existing ruleset; do not replace it; the management path is preserved).
- [x] IPv6 UDP checksum defaults are not weakened (no `udp6zerocsumtx`/`noudpcsum`-style options are introduced or configured by the integration). *(No such option exists in the integration source, and the hardware session confirmed an IPv6 VXLAN with UDP checksum enabled and the zero-checksum options disabled.)*
- [ ] `README.md` no longer lists IPv6 underlay as a limitation, and the tested-behavior list reflects only tests that were actually executed, with the platform identified.

## Evidence requirements

- [ ] Raw command outputs for every hardware row of the acceptance matrix (`ip -Version`, `ip -j -d link show`, `ip -6 addr/route`, counters, `dmesg`, packet captures) are attached to the PR or issue.
- [x] Automated tests run in CI without hardware: endpoint validation (including the non-canonical IPv4 policy), canonicalization, live-JSON parsing fixtures, recreation/rollback decision tests, snapshot-read failure tests, deterministic failure-injection scenarios, and the interface-index assertions. *(120/120 checks pass locally; the CI workflow runs that same suite plus ShellCheck on pushes to `main` and `ci/**`, on tags, and on pull requests.)*
- [ ] The Phase 1 probe results (IPv4 literal parsing, engine default semantics, handler ordering, oversized-packet capture) are recorded before the implementation is merged, and the chosen design variants (MTU default, IPv4 literal policy) are documented.
- [ ] Isolated Linux namespace results are labelled as general-Linux evidence and are not presented as EdgeOS validation.
