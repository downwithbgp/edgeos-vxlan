# Issue #3 — Proposed Acceptance Criteria (GitHub-ready, DO NOT POST WITHOUT REVIEW)

These criteria describe demonstrable behaviour on the supported platform (EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409, kernel `4.14.54-UBNT`). Unchecked items are pending evidence; each criterion carries its status and evidence class. Copy to the issue body only after review.
**Revision 2 (post-review):** updated for the corrected MTU evidence (no fragmentation reliance), scoped rollback claims, snapshot-read failures, deterministic failure injection, the IPv4 literal policy, interface-index semantics, dynamic-address boot, and the existing-policy firewall case.
**Revision 3 (post-hardware, 2026-10-10):** the dataplane criteria marked as demonstrated below were verified on the supported hardware **by hand** (`ip link add`), not through the package's configuration integration — see `issue-3-hardware-evidence.md`.
**Revision 4 (post-RC1, 2026-10-10):** the release candidate was installed and the native EdgeOS integration path exercised: creation, dual-stack dataplane, endpoint canonicalisation, family-aware MTU defaulting and restoration, VNI recreation, IPv4↔IPv6 transitions, deletion, malformed-address and mixed-family rejection, and no-op commits all passed. Those criteria are **deliberately left unticked here** until the raw captures are attached — the result is recorded, the evidence is not yet filed. Rollback, bridging, persistence and packaging criteria remain unverified; the validation runbook now spells out the two hazardous remaining procedures (Phases 5.4 and 6).
**Revision 5 (post-Phase 5.4, 2026-10-10):** the deterministic recreation-failure test was executed: **kernel rollback PASS, full configuration atomicity FAIL.** Restoration of live state passed, and the commit did return an error — but the failed commit still wrote the changed leaf value (`mtu 64`) into the active configuration while the kernel held the pre-commit value. Mechanism, and the recommended correction: `issue-3-partial-commit-analysis.md`. The rollback criteria stay **unticked** until that correction is applied and the test re-run.
**Revision 6 (RC2, 2026-10-10):** the correction is applied — the `mtu` template minimum is now the kernel's own 68, and a regression test pins it (the suite is 132 checks: helper 64, templates 32, mock 36). The rollback criteria stay unticked: the hardware re-run on RC2 has not happened yet. The minimum-MTU behaviour itself is checked by test 1.8 of the validation runbook.
**Revision 7 (final hardware evidence, 2026-10-10):** the RC2 upgrade, the minimum-MTU validation, the save/reboot restoration and the post-reboot dual-stack dataplane (20/20 packets) are recorded in `issue-3-hardware-evidence.md`, and every criterion below now carries a status. Evidence classes: **HW** = demonstrated on the supported hardware; **off-device** = the repository's test suites or packaging simulation; **code/doc review** = read-only analysis. Per the project's rule the statuses do not convert a mock into a pass: where only the mocked layers have evidence, that is stated. `[x]` marks a criterion whose requirement is fully satisfied by the evidence cited; `[ ]` marks partial or absent evidence, with the gap stated. Summary: **15 passed, 15 partially satisfied, 1 untested, none failed.**

---

## Configuration and validation

- [x] `set interfaces vxlan vxlanN local-ip <IPv6>` and `set interfaces vxlan vxlanN remote-ip <IPv6>` are accepted for valid unicast IPv6 literals (global unicast or ULA); canonical IPv4 literals remain accepted exactly as today (non-canonical forms follow the policy criterion below).
  **Status: PASSED (HW).** RC1: IPv6 endpoint templates evaluated and accepted, interface created and committed. RC2: the same configuration restored through the reboot and reported the correct identity.
- [x] A commit with mixed address families for `local-ip`/`remote-ip` is rejected with a clear message, **without deleting or modifying any live interface**.
  **Status: PASSED (HW).** RC1: rejected at commit with the expected message; the rejected configuration left the working interface untouched.
- [ ] A commit with a malformed address, an IPv6 prefix, or a hostname in `local-ip`/`remote-ip` is rejected.
  **Status: PARTIALLY SATISFIED.** Malformed literal and CIDR-prefixed endpoint rejected on hardware (RC1). The hostname form is covered off-device (`U-V6-MAL`) and by the engine's `type: ipv4,ipv6` check, but was not separately exercised on the target.
- [x] IPv6 **remote** endpoints that this fixed-remote model cannot use are rejected with a reason: link-local (`fe80::/10`), multicast (`ff00::/8`), unspecified (`::`), loopback (`::1`), IPv4-mapped (`::ffff:0:0/96`). An unspecified **local** endpoint (`0.0.0.0`/`::`) is accepted exactly as today and treated as "no specific local address".
  **Status: PASSED (HW, RC1).** Covered by the Phase 1 validation record (steps 1.1–1.6; only 1.7 excluded there); the class matrix is not itemised in the summary captures.
- [ ] Non-canonical IPv4 literals (leading-zero octets such as `010.1.2.3`) follow the recorded platform policy: either interpreted exactly as the platform's own parser binds them (octal) or rejected with an explicit message — never silently reinterpreted as decimal.
  **Status: PARTIALLY SATISFIED.** The platform-parity octal interpretation is implemented and unit-tested (`U-V4-NC-1..4`); the target's own parser has not been asked to bind such a literal (Phase 1.7 / matrix row 31 not run). If the platform were to disagree, the failure mode is a refused commit — never a silent rebinding.
- [x] The reconciler itself rejects mixed-family or invalid desired endpoints before any mutation, even when invoked without the template layer (defence in depth).
  **Status: PASSED (off-device).** `U-DEF-1..2` drive the reconciler through the mocked API with invalid endpoints and assert zero commands executed; the check sits in the reconciler's pre-mutation validation (`check-endpoints` before any mutation). Hardware does not exercise this path (it exists for direct invocation).
- [x] Existing IPv4 configurations **with canonical literals** validate and commit unchanged; non-canonical literals follow the recorded policy (platform parity or explicit rejection).
  **Status: PASSED for canonical literals (HW + off-device).** IPv4 endpoints were committed, parsed and reconciled on the router during the family transitions, and the v4 regression suites cover canonical idempotency. The non-canonical half is implemented to the recorded platform-parity policy; its **target confirmation** is tracked under the preceding criterion, and the exact upgrade-from-0.2.1 scenario under "Persistence and packaging".

## Dataplane

- [x] A VXLAN with IPv6 `local-ip`/`remote-ip` is created and passes bidirectional IPv4 overlay traffic to an IPv6-connected peer.
  **Status: PASSED (HW).** First hand-created on v0.2.1, then through the native integration on RC1, and re-confirmed post-reboot on RC2 with 5/5 replies each direction.
- [x] The same tunnel passes bidirectional IPv6 overlay traffic.
  **Status: PASSED (HW).** Same runs as above; RC2 post-reboot: 5/5 each direction.
- [ ] `ip -j -d link show dev vxlanN` on the router reports the tunnel with `local6`, `remote6`, `id`, and `port` matching the configured values (raw output attached as evidence).
  **Status: PARTIALLY SATISFIED.** The values (`local6`, `remote6`, `id: 900`, `port: 4789`) were verified in the JSON form on hardware in every session, including after the RC2 reboot; the raw transcripts are still not attached to the issue (see Evidence requirements). Reminder: the non-JSON form is corrupt on this platform — diagnostics must use the JSON form.
- [ ] With `mtu` unset, an IPv6-underlay tunnel comes up with MTU 1430 on a standard untagged 1500-byte underlay path (and 1450 for IPv4 underlays); an explicit `mtu` value is always honoured; the documentation states the path-MTU formula (VLAN/PPPoE adjustments) and that over-sized outer packets are not relied upon to fragment.
  **Status: PARTIALLY SATISFIED.** Behaviour passed on hardware (RC1): unset `mtu` → 1430 over the IPv6 underlay and 1450 over an IPv4 underlay; explicit values honoured; removal of an override restores the automatic default; mutable MTU changes do not recreate the interface. RC2 adds the minimum-MTU validation and carries MTU 1430 across the reboot. The documented path-MTU formula (README) is outstanding — release task.
- [ ] A bridged VXLAN over an IPv6 underlay passes traffic and keeps its bridge membership, path cost, and port priority.
  **Status: PARTIALLY SATISFIED.** On RC1, the disposable `br901`'s membership, path cost 200 and priority 10 were preserved across an identity recreation and restored (with the membership and options) after a deliberately failed recreation — the bridge-state clauses are HW-verified. Packets over the bridged tunnel were not part of that run, so the traffic clause remains unexercised (readiness report, T5).

## Lifecycle and idempotency

- [x] Committing an unchanged IPv6 configuration does not delete or recreate the interface, including when the configured underlay endpoint spelling differs from the kernel's canonical representation. (Interface addresses with non-canonical spelling are handled by the same canonical comparison; covered by the U-ADDR unit tests.)
  **Status: PASSED (HW).** RC1: canonicalisation preserved identity and no-op commits left the interface in place; RC2: the rebooted tunnel's identity matched without a commit being required.
- [x] Changing `local-ip`, `remote-ip`, `vni`, or `port` recreates the interface exactly once and reapplies MAC, MTU, addresses, description, bridge state, and admin state.
  **Status: PASSED (HW, RC1).** Phase 5.1 (a UDP-port change) and Phase 6.4 (recreation while bridged) each observed exactly one recreation with the mutable state reapplied; the VNI changes and family transitions recreated the interface with the expected identity, and the reapplied mutable state was captured in those runs.
- [x] IPv4→IPv6 and IPv6→IPv4 transitions are recognised as identity changes and apply the correct family and endpoints.
  **Status: PASSED (HW, RC1).**

## Rollback

- [ ] A failed creation during an IPv6 identity change restores the live interface as captured at snapshot time — family, endpoints, VNI, port, MAC, MTU, addresses, description, bridge membership/cost/priority, admin state — and the commit returns an error. The failure is injected deterministically (blocker VNI/port collision or mocked `ip` failure), not by unreachable-VTEP or firewall scenarios.
  **Status: PARTIALLY SATISFIED.** RC1 hardware PASS: the kernel-state rollback restored VNI 901, port 4791, MTU 1430, the correct IPv6 endpoints, MAC, bridge state and administrative state, and the commit returned an error (Phases 5.4 and 6, deterministic injection). The RC2 re-run has not been executed; RC2's reconciler is byte-identical to RC1's (payload diff), and the replacement injection (256-character description) is off-device-measured only. Note the injection used was a kernel-refused value; the VNI/port-blocker method named in this criterion was subsequently **disproved by off-device measurements on a real kernel** (commit `9df85bc`: two VXLAN devices may hold the same VNI/port), so it must not be used.
- [ ] A failed v4→v6 or v6→v4 transition restores the previous family faithfully.
  **Status: PARTIALLY SATISFIED.** Covered by the mocked harness's forced-creation-failure family transitions; no hardware failure-injection on a family transition.
- [ ] If any snapshot component cannot be read successfully (identity fields, MAC, MTU, description, address collection, bridge state, admin state), the commit fails **before** deleting anything.
  **Status: PARTIALLY SATISFIED (off-device).** The designated suites (`U-FAILCLOSE-*`, `U-SNAP-4..7`, and the reconciler's status-checked captures) assert the abort-before-delete behaviour; the target-side scenario (Phase 5.5) remains unexercised because no component can be made unreadable on the router without disturbing service.
- [x] For a combined identity+mutable change, either the handler-order observation shows no pre-snapshot mutation, or the leaf handlers are guarded so the snapshot still reflects the pre-change live state; otherwise the rollback claim is explicitly scoped to snapshot-time state.
  **Status: PASSED (HW + off-device).** The leaf handlers are guarded by `identity-matches`; the guarded no-op was exercised in the RC1 failure run (the changed MTU leaf never reached the kernel before the snapshot, and the rollback restored the pre-change state), and `U-LEAF-*` plus the mock scenarios assert the guard behaviour.
- [x] The interface index is **not** promised across recreation; the behaviour is documented and observed (before/after recreation and rollback).
  **Status: PASSED (HW).** Observed 27 → 29 and 31 → 33 on recreation and 20 → 16 across the RC2 reboot; the semantics are documented in the validation runbook (Phase 2 note, 5.4.5, criterion 5.4-g) and the evidence record — carrying the note into `README.md` is part of the outstanding README update.

## Persistence and packaging

- [ ] `save` + reboot restores the IPv6 tunnel (identity, MTU, MAC, address/bridge state, admin state), including when the underlay IPv6 address arrives dynamically (SLAAC/DHCPv6); the readiness timing is documented.
  **Status: PARTIALLY SATISFIED.** RC2: save + reboot restored the identity, MTU 1430, MAC `e6:69:92:17:3e:e9`, both overlay addresses and the module set (HW), with the delegated prefix already present. Dynamic arrival / readiness timing (Phase 7.4) is not tested and the timing note is not yet written.
- [ ] Upgrading from v0.2.1 with an existing IPv4 VXLAN leaves that tunnel operational (no recreation, no configuration change).
  **Status: NOT TESTED.** The upgrade transaction is analysed and simulated off-device, and two real upgrades have run on the router (v0.2.1 → RC1 → RC2, the second with a live IPv6 tunnel), but no committed IPv4 tunnel has been carried through an upgrade.
- [x] The kernel payload is unchanged: packaged `vxlan.ko` sha256 `7c346342bf00202820e8581bfdfc28851add052d2b0e5dde1560819f90bf82b6`, `udp_tunnel.ko` sha256 `6d58ee597d8ae50898efe90ec61a4803ae4f0549f29fba9c4132ca92260405cc`.
  **Status: PASSED (off-device + HW).** The packaged payloads were extracted and hashed against the pins during this review; `git diff v0.2.1..HEAD -- modules/ patches/` is empty; the on-router `dpkg -V` was clean.
- [ ] Package removal safeguards and `dpkg-divert` restoration still work.
  **Status: PARTIALLY SATISFIED.** The guard refusal with a saved configuration, the downgrade to 0.2.1, diversion survival and the diverted stock `Interface.pm` were exercised in a real-`dpkg` container run and by the on-router RC1→RC2 upgrade; the maintenance scripts are unchanged since v0.2.1, which carries a hardware removal record. A full removal on the RC2/stable build has not been performed.

## Security and documentation

- [ ] The documentation states that `remote-ip` is not an ingress allowlist for IPv6 either, with a tested `firewall ipv6-name` example that drops UDP/4789 from other sources while preserving unrelated traffic — including the case where the underlay interface already has a local IPv6 policy attached (extend the existing ruleset; do not replace it; the management path is preserved).
  **Status: PARTIALLY SATISFIED.** The deployment-side IPv6 ruleset (an extension of the existing `VLANv6_LOCAL` policy, default drop) was active while all post-reboot dataplane tests passed — the "extend, do not replace" case is exercised in practice. The README's IPv6 `firewall ipv6-name` example and the alternate-source drop demonstration are outstanding — release task.
- [x] IPv6 UDP checksum defaults are not weakened (no `udp6zerocsumtx`/`noudpcsum`-style options are introduced or configured by the integration).
  **Status: PASSED (HW + code review).** No such option exists in the integration source; the hardware session confirmed an IPv6 VXLAN with UDP checksum enabled and the zero-checksum options disabled.
- [ ] `README.md` no longer lists IPv6 underlay as a limitation, and the tested-behavior list reflects only tests that were actually executed, with the platform identified.
  **Status: PARTIALLY SATISFIED.** The README is still the v0.2.1 document — accurate for what it claims, but it lists IPv6 underlay under Known limitations and its tested list predates this feature. The update is a release task.

## Evidence requirements

- [ ] Raw command outputs for every hardware row of the acceptance matrix (`ip -Version`, `ip -j -d link show`, `ip -6 addr/route`, counters, `dmesg`, packet captures) are attached to the PR or issue.
  **Status: PARTIALLY SATISFIED.** The results are recorded with exact values in `issue-3-hardware-evidence.md`; the raw transcripts still need attaching to the issue/PR — release task.
- [ ] Automated tests run in CI without hardware: endpoint validation (including the non-canonical IPv4 policy), canonicalization, live-JSON parsing fixtures, recreation/rollback decision tests, snapshot-read failure tests, deterministic failure-injection scenarios, and the interface-index assertions.
  **Status: PARTIALLY SATISFIED.** The suites exist and pass — **132/132** checks reproduced locally during this review (helper 64, templates 32, mock 36) — and the CI workflow runs that same suite plus ShellCheck on `main`/`ci/**` pushes, on tags and on pull requests. No qualifying CI event has yet executed the new suite (feature-branch pushes do not trigger it); opening the release PR produces that run — release task. *(The Revision 4 note said "120/120"; the suite has since grown as Revision 6 recorded.)*
- [ ] The Phase 1 probe results (IPv4 literal parsing, engine default semantics, handler ordering, oversized-packet capture) are recorded before the implementation is merged, and the chosen design variants (MTU default, IPv4 literal policy) are documented.
  **Status: PARTIALLY SATISFIED.** Recorded: the off-device probe evidence (IPv4-literal parsing, MTU/fragmentation behaviour, failure-injection candidates, JSON shape) in `issue-3-test-plan.md` §C0 and the assessment. Not executed on the target: the engine default-semantics probe — the design avoids the dependency (the template `default` was removed and the reconciler computes the family default), the handler-ordering log — the guard design is implemented and was exercised by the RC1 failure runs, the target IPv4-literal probe, and the target oversized-packet capture. The chosen variants are visible in the shipped templates and tests but are not yet written up as a decision record.
- [x] Isolated Linux namespace results are labelled as general-Linux evidence and are not presented as EdgeOS validation.
  **Status: PASSED (code/doc review).** The labelling convention is stated in the test plan (§C, "golden rule") and carried in the evidence document.

---

**Summary at Revision 7:** 15 criteria passed, 15 partially satisfied (each naming its gap above), 1 untested (the v0.2.1 → 0.2.2 upgrade with an existing IPv4 tunnel), none failed. The stable-release assessment that weighs these — including which of the remaining items gate a release and which do not — is `docs/issue-3-stable-release-readiness.md`.
