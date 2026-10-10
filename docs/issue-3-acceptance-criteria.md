# Issue #3 — Proposed Acceptance Criteria (GitHub-ready, DO NOT POST WITHOUT REVIEW)

These criteria describe demonstrable behaviour on the supported platform (EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409, kernel `4.14.54-UBNT`). Unchecked items are pending implementation and hardware validation. Copy to the issue body only after review.

---

## Configuration and validation

- [ ] `set interfaces vxlan vxlanN local-ip <IPv6>` and `set interfaces vxlan vxlanN remote-ip <IPv6>` are accepted for valid unicast IPv6 literals (global unicast or ULA); IPv4 remains accepted exactly as today.
- [ ] A commit with mixed address families for `local-ip`/`remote-ip` is rejected with a clear message, **without deleting or modifying any live interface**.
- [ ] A commit with a malformed address, an IPv6 prefix, or a hostname in `local-ip`/`remote-ip` is rejected.
- [ ] IPv6 endpoints that this fixed-remote model cannot use are rejected with a reason: link-local (`fe80::/10`), multicast (`ff00::/8`), unspecified (`::`), loopback (`::1`), IPv4-mapped (`::ffff:0:0/96`).
- [ ] Existing IPv4 configurations validate and commit unchanged.

## Dataplane

- [ ] A VXLAN with IPv6 `local-ip`/`remote-ip` is created and passes bidirectional IPv4 overlay traffic to an IPv6-connected peer.
- [ ] The same tunnel passes bidirectional IPv6 overlay traffic.
- [ ] `ip -j -d link show dev vxlanN` on the router reports the tunnel with `local6`, `remote6`, `id`, and `port` matching the configured values (raw output attached as evidence).
- [ ] With `mtu` unset, an IPv6-underlay tunnel comes up with MTU 1430 on a 1500-byte underlay path (and 1450 for IPv4 underlays); an explicit `mtu` value is always honoured.
- [ ] A bridged VXLAN over an IPv6 underlay passes traffic and keeps its bridge membership, path cost, and port priority.

## Lifecycle and idempotency

- [ ] Committing an unchanged IPv6 configuration does not delete or recreate the interface, including when the configured underlay endpoint spelling differs from the kernel's canonical representation. (Interface addresses with non-canonical spelling are handled by the same canonical comparison; covered by the U-ADDR unit tests.)
- [ ] Changing `local-ip`, `remote-ip`, `vni`, or `port` recreates the interface exactly once and reapplies MAC, MTU, addresses, description, bridge state, and admin state.
- [ ] IPv4→IPv6 and IPv6→IPv4 transitions are recognised as identity changes and apply the correct family and endpoints.

## Rollback

- [ ] A failed creation during an IPv6 identity change restores the previous live interface with its original family, endpoints, VNI, port, MAC, MTU, addresses, description, bridge membership/cost/priority, and admin state; the commit returns an error.
- [ ] A failed v4→v6 or v6→v4 transition restores the previous family faithfully.
- [ ] If the live interface's identity cannot be captured completely (unexpected state), the commit fails **before** deleting anything.

## Persistence and packaging

- [ ] `save` + reboot restores the IPv6 tunnel (identity, MTU, MAC, address/bridge state, admin state).
- [ ] Upgrading from v0.2.1 with an existing IPv4 VXLAN leaves that tunnel operational (no recreation, no configuration change).
- [ ] The kernel payload is unchanged: packaged `vxlan.ko` sha256 `7c346342bf00202820e8581bfdfc28851add052d2b0e5dde1560819f90bf82b6`, `udp_tunnel.ko` sha256 `6d58ee597d8ae50898efe90ec61a4803ae4f0549f29fba9c4132ca92260405cc`.
- [ ] Package removal safeguards and `dpkg-divert` restoration still work.

## Security and documentation

- [ ] The documentation states that `remote-ip` is not an ingress allowlist for IPv6 either, with a tested `firewall ipv6-name` example that drops UDP/4789 from other sources while preserving unrelated traffic.
- [ ] IPv6 UDP checksum defaults are not weakened (no `udp6zerocsumtx`/`noudpcsum`-style options are introduced or configured by the integration).
- [ ] `README.md` no longer lists IPv6 underlay as a limitation, and the tested-behavior list reflects only tests that were actually executed, with the platform identified.

## Evidence requirements

- [ ] Raw command outputs for every hardware row of the acceptance matrix (`ip -Version`, `ip -j -d link show`, `ip -6 addr/route`, counters, `dmesg`, packet captures) are attached to the PR or issue.
- [ ] Automated tests run in CI without hardware: endpoint validation, canonicalization, live-JSON parsing fixtures, and recreation/rollback decision tests.
- [ ] Isolated Linux namespace results are labelled as general-Linux evidence and are not presented as EdgeOS validation.
