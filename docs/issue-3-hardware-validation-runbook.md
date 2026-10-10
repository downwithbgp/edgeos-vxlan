# Issue #3 — Hardware Validation Runbook (native EdgeOS integration)

Ordered procedures for validating the IPv6 VXLAN underlay **through the package's native EdgeOS
configuration path** on the supported router. This is the runbook that turns "the kernel can do it"
into "the integration does it". It has not been executed.

The exact underlay addresses are deployment-specific: the sanitised deployment runbook
(`issue-3-deployment-runbook.md`) carries placeholders, and the instance with the live values is held
outside the tracked tree in the gitignored `local/` directory. Here they are written `<RTR_V6>`
(router, `switch0.65`) and `<PEER_V6>` (peer host's uplink). Everything else — interface names, VNI,
port, MTU, overlay addresses — is fixed for this topology:

```
interface      vxlan900        VNI 900        UDP port 4789        MTU 1430
router overlay 10.255.254.1/30 and fd42:900::1/64
peer overlay   10.255.254.2/30 and fd42:900::2/64
```

**Rules of engagement.** Nothing here may be run before the release candidate is installed under the
deployment runbook. Never run failure injection on an interface that carries management
connectivity. Every state-changing step is marked; everything else is read-only. If any stop
condition fires, stop and capture before doing anything else — do not "try the next one".

**Capture convention.** For every test record: the test ID, the date and time, the exact command
run, the raw output, and the observed interface index where relevant. Attach captures to the issue;
this file records only the conclusions.

---

## Phase 0 — prerequisites and baseline (read-only)

| # | Action | Expected | Stop if |
|---|---|---|---|
| 0.1 | `show version` and `cat /etc/version` | ER-e50, EdgeOS v3.0.1 build 5862409; `uname -r` = `4.14.54-UBNT` | Anything else |
| 0.2 | `dpkg -l edgeos-vxlan edgeos-vxlan-kmod` | Both `ii` at `0.2.2~rc1+edgeos3.0.1.e50`; `dpkg --audit` empty | Either package not `ii`, or audit non-empty |
| 0.3 | `lsmod \| grep -E '^(vxlan\|udp_tunnel\|ip6_udp_tunnel)'` | All three present | Any missing |
| 0.4 | `ip -j link show \| grep -c vxlan` | 0 — no live VXLAN interface | Any VXLAN interface present; investigate before proceeding |
| 0.5 | `sha256sum /lib/modules/4.14.54-UBNT/extra/vxlan.ko /lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko` | `7c346342…` and `6d58ee59…` | Any mismatch |
| 0.6 | `ip -6 addr show dev switch0.65` | `<RTR_V6>` present and reachable; `ping6` to the peer 5/5 | No connectivity |
| 0.7 | `ping 10.255.254.2` from the peer's overlay address family context (peer side) | Baseline without the tunnel: expected to fail | If it succeeds, the topology assumption is wrong |

---

## Phase 1 — endpoint validation, before touching live state (state-changing: candidate config only)

Do these in configuration mode with `compare` and no `commit` until stated. A rejected `set` must
leave the candidate configuration unchanged; a rejected `commit` must leave live state unchanged.

| # | Test | Command (configuration mode) | Expected | Stop if |
|---|---|---|---|---|
| 1.1 | IPv6 literals accepted | `set interfaces vxlan vxlan900 vni 900` / `local-ip <RTR_V6>` / `remote-ip <PEER_V6>` | Accepted, no error | Rejection of a valid literal — this is the feature under test |
| 1.2 | Malformed literal rejected | `set interfaces vxlan vxlan900v6bad remote-ip 2001:db8::zz` | Rejected with a clear message | Silently accepted |
| 1.3 | Prefix rejected as endpoint | `set … remote-ip <PEER_V6>/64` | Rejected | Accepted |
| 1.4 | Mixed family rejected | `set … local-ip 192.0.2.1` with an IPv6 `remote-ip` | Rejected: families must match | Accepted |
| 1.5 | Unusable IPv6 remote rejected | `set … remote-ip fe80::1`, then `ff02::1`, `::`, `::1`, `::ffff:192.0.2.2` | Each rejected with its own reason | Any accepted |
| 1.6 | Rejection is inert | `compare`; `ip -j link show dev vxlan900`; `ip -6 addr show dev switch0.65` | Candidate config as expected; no interface created or destroyed; underlay untouched | Any change to live state |
| 1.7 | Non-canonical IPv4 spelling | `set … remote-ip 010.1.2.3` | Accepted and bound exactly as the platform parses it (octal), or rejected with a message — never silently reinterpreted | Any silent reinterpretation |

**Capture for phase 1:** the full text of each rejection message. These are exactly what the
acceptance criteria ask to be recorded, and they are not reproducible off-device.

---

## Phase 2 — native creation

| # | Test | Action | Expected | Stop if |
|---|---|---|---|---|
| 2.1 | Create through the configuration system | Complete the candidate config (VNI 900, both endpoints, both overlay addresses, `mtu 1430`), then `commit` | Commit succeeds; `show interfaces` lists `vxlan900` | Commit fails, or reports an error after creating the interface |
| 2.2 | Interface identity via JSON | `ip -j -d link show dev vxlan900` | `info_kind: vxlan`, `id: 900`, `port: 4789`, `local6: <RTR_V6>`, `remote6: <PEER_V6>` | Any field wrong — and do **not** use the non-JSON form: it is corrupted on this platform |
| 2.3 | Attributes | `ip -j link show dev vxlan900`, `ip -j addr show dev vxlan900` | MTU 1430; MAC locally administered and unicast; `10.255.254.1/30` and `fd42:900::1/64` present; admin state up | Any mismatch |

**Record the interface index now** (`cat /sys/class/net/vxlan900/ifindex`) — every later phase
compares against it. The index is *not* promised to survive recreation; the point is to observe it.

---

## Phase 3 — dataplane

| # | Test | Action | Expected | Stop if |
|---|---|---|---|---|
| 3.1 | IPv4 overlay | `ping 10.255.254.2` from the router; `ping 10.255.254.1` from the peer | 5/5 replies, 0% loss, ~1–2 ms | Loss below 5/5 |
| 3.2 | IPv6 overlay | `ping6 fd42:900::2` from the router; `ping6 fd42:900::1` from the peer | 5/5 replies, 0% loss | Loss below 5/5 |
| 3.3 | Neighbor Discovery | `ip -6 neigh show dev vxlan900` on both ends | Peer's link-layer address present (`REACHABLE` shortly after traffic) | No neighbour entry |
| 3.4 | Firewall path | See the firewall section below | Traffic passes with the restricted rule present, and stops without it | Traffic passes with no rule present (the rule is not doing what you think) |

---

## Phase 4 — idempotency and mutable state

| # | Test | Action | Expected | Stop if |
|---|---|---|---|---|
| 4.1 | Unchanged commit | `commit` with no changes | No interface recreation: the index recorded in phase 2 is unchanged; identity untouched | Index changed, or the interface was deleted and recreated |
| 4.2 | Reformat that must not recreate | Change only the *spelling* of an endpoint (for example a compressed vs expanded IPv6 form with the same value) and `commit` | No recreation — canonical comparison must absorb it | Index changed |
| 4.3 | Mutable parameter change | Change `mtu` to 1400, `commit` | MTU changes in place; index unchanged; no recreation | Recreation, or MTU unchanged |
| 4.4 | Restore | Set `mtu` back to 1430, `commit` | Back to 1430 in place | Any error |
| 4.5 | MTU default, explicit value absent | Delete `mtu`, `commit` | Interface comes up at the family-aware default: **1430** for an IPv6 remote. Then repeat from an IPv4 remote and expect **1450** | Wrong default, or the interface losing its addresses |
| 4.6 | Address change | Change an overlay address, `commit`, then restore | Only the address changes; identity and index unchanged | Recreation |

---

## Phase 5 — identity change and rollback (only after phases 3–4 pass)

| # | Test | Action | Expected | Stop if |
|---|---|---|---|---|
| 5.1 | Controlled identity change | Change `port` to 4790 (a value with no peer behind it), `commit` | Exactly one recreation: new index, correct new identity in JSON, all mutable state (MAC, MTU, addresses, admin state) reapplied | More than one recreation, or state not reapplied |
| 5.2 | Restore identity | Set `port` back to 4789, `commit`; verify traffic again with 3.1/3.2 | Back to the original identity, traffic passes | Any failure |
| 5.3 | Family transition v4→v6 / v6→v4 | Only if an IPv4 underlay is available: switch `local-ip`/`remote-ip` between families, `commit` each way | Each transition is recognised as an identity change, applies the right family and endpoints, and reapplies mutable state | Wrong family or endpoints applied |
| 5.4 | Deterministic recreation failure and rollback | After the basic tests pass and with a second management path confirmed, inject a deterministic failure of the recreation path (for example a blocker that makes the new interface impossible to create), then `commit` | Commit fails, and the *previous* interface is restored: family, endpoints, VNI, port, MAC, MTU, addresses, description, bridge state, admin state | Any component not restored, or the commit leaving no working interface. **Never do this on the management-carrying interface** |
| 5.5 | Snapshot fail-closed | Only if a component can be made unreadable without disturbing service (for example, a bridge-port state that cannot be read) | Commit fails **before** deleting anything | Any deletion before the failure |

---

## Phase 6 — bridging (only if a bridge is available and the interface is not the management path)

| # | Test | Action | Expected | Stop if |
|---|---|---|---|---|
| 6.1 | Join a bridge | `set interfaces vxlan vxlan900 bridge-group bridge brN`, `commit` | The interface joins the bridge; addresses are rejected if combined with bridge membership | Both accepted simultaneously |
| 6.2 | Port options | Set `bridge-group cost` and `priority`, `commit` | `/sys/class/net/vxlan900/brport/path_cost` and `priority` reflect the values | Values not applied |
| 6.3 | Restoration after identity change | Change `vni`, `commit` | The interface returns to the same bridge with the same cost and priority | Membership or options lost |
| 6.4 | Rollback restoration | Repeat 5.4 with the interface bridged | The previous membership, cost and priority are restored | Any lost |

---

## Phase 7 — persistence (requires explicit authorization; a reboot is disruptive)

| # | Test | Action | Expected | Stop if |
|---|---|---|---|---|
| 7.1 | Save | `save` | Configuration written; `show system commit` lists it | Save error |
| 7.2 | Reboot | `reboot` (authorized separately) | Router returns; management reachable | Router unreachable — recover over the console path |
| 7.3 | Post-boot state | Repeat 2.2, 2.3, 3.1, 3.2 | Same identity, MTU, addresses, admin state; traffic passes | Any missing |
| 7.4 | Dynamic underlay address | If the underlay address arrives via SLAAC/DHCPv6: reboot the router *and* the peer's address assignment | Tunnel works once the underlay address exists; record the readiness delay | Tunnel created with a stale address, or never created |
| 7.5 | Cold-boot module state | `lsmod` after boot | `vxlan`, `udp_tunnel`, `ip6_udp_tunnel` all loaded by the boot path, `udp_tunnel.ko` on disk still `6d58ee59…` | Any mismatch |

---

## Phase 8 — upgrade regression

| # | Test | Action | Expected | Stop if |
|---|---|---|---|---|
| 8.1 | Existing IPv4 tunnel survives | With a committed IPv4 VXLAN configuration, upgrade from 0.2.1 to the release candidate per the deployment runbook | Upgrade succeeds; the tunnel is neither recreated nor reconfigured; traffic is uninterrupted | Interface recreated, or traffic interrupted |
| 8.2 | Reinstall is idempotent | Reinstall both packages | Same behaviour; no interface churn | Churn |
| 8.3 | Downgrade path | Reinstall the v0.2.1 pair | Packages return to `ii` at 0.2.1; a committed IPv4 tunnel still works | Any failure |

---

## Firewall exception for the test

The underlay VLAN carries the router's own IPv6 policy (`VLANv6_LOCAL`, default `drop`), so a
deliberately narrow UDP/4789 exception is needed while testing. Extend the existing ruleset; do not
replace it and do not touch WAN policy.

Addition (numbering chosen to sit above the local ruleset's existing rules — adjust to the first free
number on the live system):

```
configure
set firewall ipv6-name VLANv6_LOCAL rule 80 action accept
set firewall ipv6-name VLANv6_LOCAL rule 80 description 'VXLAN underlay test (temporary)'
set firewall ipv6-name VLANv6_LOCAL rule 80 protocol udp
set firewall ipv6-name VLANv6_LOCAL rule 80 destination port 4789
set firewall ipv6-name VLANv6_LOCAL rule 80 source address <PEER_V6>
commit
```

Removal:

```
configure
delete firewall ipv6-name VLANv6_LOCAL rule 80
commit
```

Verification without disturbing service:

* `show firewall ipv6-name VLANv6_LOCAL` — the rule is present with the expected source address and
  destination port.
* From the peer, `sudo nft list ruleset` (or the platform's equivalent) confirms the counter for that
  rule increments as tunnel traffic flows.
* After removal, re-run 3.1/3.2 and confirm they fail — that is the proof the rule was doing the work.

**Do not `save` while the temporary rule exists** unless the owner deliberately wants it kept. If the
router is rebooted with the rule unsaved, the rule disappears — that is the intended fail-safe.

---

## What this runbook deliberately does not do

* It does not install anything: installation is the deployment runbook's job, under separate
  authorization.
* It does not modify the committed configuration structure beyond the nodes under test.
* It does not use `commit-confirm` as an undo for anything except the candidate configuration.
* It does not mark any acceptance criterion as passed. Results are recorded in
  `docs/issue-3-hardware-evidence.md` only after they are actually obtained.
