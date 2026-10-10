# Issue #3 — Hardware Validation Runbook (native EdgeOS integration)

Ordered procedures for validating the IPv6 VXLAN underlay **through the package's native EdgeOS
configuration path** on the supported router.

**Status (reported 2026-10-10).** RC1 native-integration validation has been executed on the
supported router and passed: native interface creation, dual-stack dataplane over the tunnel, IPv6
endpoint canonicalisation, family-aware MTU defaulting and explicit-MTU restoration, VNI recreation,
IPv4↔IPv6 family transitions, interface deletion, malformed-address rejection, mixed-family commit
rejection, and idempotent (no-op) commits. Phases 0–4 (except 1.7, the non-canonical IPv4 spelling)
and 5.1–5.3 are therefore covered for `vxlan900`; the raw captures still need attaching to the
issue. What remains are the two procedures
that were previously placeholders precisely because they are the hazardous ones — **5.4
(deterministic recreation failure and rollback)** and **Phase 6 (bridging)**. Both are written out in
full in this revision, and both run only on disposable objects.

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
| 5.4 | Deterministic recreation failure and rollback | See the dedicated procedure below. It uses the **disposable `vxlan901`, never `vxlan900`** | The commit fails, and every captured component of the previous interface is restored | Any component not restored, or a rollback that itself fails. **Never run this on an interface that carries management traffic** |
| 5.5 | Snapshot fail-closed | Only if a component can be made unreadable without disturbing service (for example, a bridge-port state that cannot be read) | Commit fails **before** deleting anything | Any deletion before the failure |

---

## Phase 5.4 — deterministic recreation failure and rollback (disposable `vxlan901`)

The one test that deliberately drives the integration into its failure path. It runs entirely on a
**disposable** interface — `vxlan901`, VNI 901, UDP port 4791, MTU 1430, no addresses, not bridged,
carrying no production traffic — and never touches `vxlan900`. It proves that when recreation of an
interface fails, the reconciler restores the *previous* live state and fails the commit instead of
leaving a half-built interface behind.

### The injection, and why it is deterministic

**Injection: configure `mtu 64` on the disposable interface in the same commit that changes its
identity.** The configuration templates accept `mtu >= 64`, but the kernel refuses to put a VXLAN
device below its minimum MTU, so the commit fails at the MTU step of the recreation — after the old
state has been captured and after the old interface has been deleted.

Why this is deterministic on the supported platform, in four checkable steps:

1. The target kernel sets the VXLAN minimum to `ETH_MIN_MTU`: in the 4.14.54-UBNT source tree,
   `drivers/net/vxlan.c:2651` (`vxlan_setup()`) sets `dev->min_mtu = ETH_MIN_MTU;`. `ETH_MIN_MTU`
   is 68.
2. The network core rejects anything below it: `net/core/dev.c:6939`
   (`if (new_mtu < 0 || new_mtu < dev->min_mtu)`) returns `-EINVAL`.
3. The package's `mtu` template accepts 64
   (`templates/interfaces/vxlan/node.tag/mtu/node.def`, `$VAR(@) >= 64 && $VAR(@) <= 8024`), so the
   configuration layer lets the value through.
4. Measured off-device on a real kernel, VXLAN over IPv6: `ip link set dev <vxlan> mtu 64` →
   `Error: mtu less than device minimum.` (exit 2), while `mtu 68` succeeds; the device reports
   `min_mtu: 68, max_mtu: 65535`.

The same measurements **disprove** three injections that look plausible, so do not use them:

* a duplicate VNI / UDP-port combination does **not** block creation — two VXLAN devices may share a
  socket;
* a `local-ip` that is not present on the router does **not** block creation;
* a duplicate interface name is refused by the kernel, but the reconciler deletes the interface
  first, so the name is always free by the time it creates.

### Why the injection cannot corrupt the snapshot or block the rollback

* The injected value is consumed in exactly one place: `apply_desired_mutable_state()`,
  `src/vyatta-vxlan:317-318` (`ip link set dev "$INTERFACE" mtu "$MTU"`).
* That function is first reached at `src/vyatta-vxlan:635` — **after** `capture_live_snapshot()`
  (called at line 598), after `delete_interface()` (line 616) and after `create_vxlan()` (line 620).
  The snapshot reads live kernel state only — identity, MAC, MTU, description, addresses, bridge
  state, admin state of the interface as it exists — and never reads the desired configuration, so
  the injection cannot influence what is captured.
* The rollback rebuilds the previous interface from the captured values and sets the **captured**
  MTU: `sudo ip link set dev "$INTERFACE" mtu "$OLD_MTU"` (`src/vyatta-vxlan:478`). `$OLD_MTU` is the
  MTU the interface already had (1430 here), which the kernel accepts, so the injected value cannot
  block the rollback.
* Because the identity changes in the same commit, `RECREATE=1` (lines 609/612) and
  `HAVE_OLD_SNAPSHOT=1` (line 602), so the failure takes the rollback branch rather than the
  unprotected mutable-only path at line 659.
* The project's own suite already exercises this exact sequence: mock scenario 25, "recreation with a
  failing MTU step rolls back the snapshot" (`test/mock.sh`), forces the same step to fail, asserts
  the reconciler prints "Rolling back", asserts it recreated the **old** identity, and asserts the
  MTU was restored. It passes in the committed suite (120/120).

### Preconditions

* Phase 0 and phases 1–4 passed; `vxlan900` is healthy and untouched by this procedure.
* You are connected over a management path that does not depend on `vxlan901` (it has no addresses
  and no bridge membership, so it cannot be anyone's path — confirm anyway).
* Console access is available.
* **Do not `save` at any point during this procedure.** The test objects live only in the running
  configuration, so a reboot discards them; saving would make a failed test survive a reboot.

### Procedure

**5.4.1 — create the disposable interface.**

```
configure
set interfaces vxlan vxlan901 vni 901
set interfaces vxlan vxlan901 local-ip <RTR_V6>
set interfaces vxlan vxlan901 remote-ip <PEER_V6>
set interfaces vxlan vxlan901 port 4791
set interfaces vxlan vxlan901 mtu 1430
commit
exit
```

Expected: the interface exists with VNI 901, port 4791, MTU 1430, **no** addresses and **no** bridge
membership.

```
ip -j -d link show dev vxlan901      # id 901, port 4791, mtu 1430
ip -j addr show dev vxlan901         # no addresses
```

**5.4.2 — capture the state the rollback will be held to.**

```
mkdir -p /tmp/rc
ip -o link show dev vxlan901        >  /tmp/rc/pre-5.4-link.txt
ip -j -d link show dev vxlan901     >  /tmp/rc/pre-5.4-identity.json
{
  cat /sys/class/net/vxlan901/address
  cat /sys/class/net/vxlan901/mtu
  cat /sys/class/net/vxlan901/ifalias
  cat /sys/class/net/vxlan901/ifindex
}                                   >> /tmp/rc/pre-5.4-link.txt
ip -j addr show dev vxlan901        >  /tmp/rc/pre-5.4-addrs.json
```

**5.4.3 — prove the injection is effective on *this* device, on a throwaway interface.** Do this
before relying on it.

```
sudo ip link add dev vxlantest type vxlan id 999 local <RTR_V6> remote <PEER_V6> dstport 4799
sudo ip link set dev vxlantest mtu 64      # MUST fail
sudo ip link set dev vxlantest mtu 68      # MUST succeed
sudo ip link del dev vxlantest
```

Expected: the `mtu 64` command exits non-zero (on this platform the text is
`Error: mtu less than device minimum.`; the non-zero exit is what matters), the `mtu 68` command
succeeds, and `vxlantest` is gone afterwards.

**Stop if `mtu 64` is accepted** — the injection is not available on this platform. Use the alternate
injection at the end of this section instead.

**5.4.4 — commit the identity change together with the injection.**

```
configure
set interfaces vxlan vxlan901 vni 902      # identity change -> forces recreation
set interfaces vxlan vxlan901 mtu 64       # the injection
compare
commit
```

Expected: `commit` **fails**, with output of this shape:

```
ERROR: Failed to apply requested VXLAN state for vxlan901.
Rolling back vxlan901 to previous live state...
Rollback of vxlan901 completed.
```

and a non-zero status. Do not `save`. Nothing reaches the saved configuration from a failed commit.

**5.4.5 — verify the rollback.**

```
ip -j -d link show dev vxlan901      # id 901 again, port 4791
cat /sys/class/net/vxlan901/mtu      # 1430
cat /sys/class/net/vxlan901/address  # the MAC captured in 5.4.2
cat /sys/class/net/vxlan901/ifalias  # unchanged
ip -j addr show dev vxlan901         # the same address set as captured
ip -j link show dev vxlan901         # admin state as captured
```

The interface **index** is not promised across recreation: record it and compare it, but a changed
index is expected behaviour, not a failure.

**5.4.6 — clean up.**

```
configure
delete interfaces vxlan vxlan901 mtu
delete interfaces vxlan vxlan901
commit
exit
```

Verify: `ip -j link show type vxlan` no longer lists `vxlan901`, and
`ip link show dev vxlantest` reports "does not exist".

### Acceptance criteria

| # | Criterion |
|---|---|
| 5.4-a | The commit fails and names `vxlan901`; no configuration is saved. |
| 5.4-b | The rollback completes ("Rollback of vxlan901 completed.") and does not itself fail. |
| 5.4-c | Afterwards the interface has the **pre-commit** identity: VNI 901, UDP port 4791, the same local/remote endpoints and address family. |
| 5.4-d | The same MAC, MTU (1430), description/alias and address set as captured in 5.4.2. |
| 5.4-e | The same administrative state as captured (up stays up, disabled stays down). |
| 5.4-f | `vxlan900`'s identity, index, addresses, admin state and traffic are unchanged throughout. |
| 5.4-g | The interface index is recorded before and after; a change is noted, not treated as a failure. |

### Risks, and why the blast radius is contained

* **The rollback itself could fail — that is the property under test.** If it does, the reconciler
  reports "Rollback of vxlan901 also failed." and exits 2, leaving `vxlan901` in an unpredictable
  state. Since `vxlan901` carries no addresses, is not a bridge port and is not any management path,
  the worst case is a stray interface, removable with `sudo ip link del dev vxlan901` followed by
  deleting its configuration nodes. It cannot take the router offline.
* **A failed commit leaves the injection in the candidate configuration.** If 5.4.6 is skipped, the
  next `commit` will fail again. Clean up in the same session.
* **Never run this against `vxlan900`.** It may become a bridge port or carry overlay addressing in
  the other phases, and a failed rollback there would be a real outage.
* **`commit-confirm` is not an undo for this.** It reverts the candidate configuration only; live
  interface state is restored by the reconciler's rollback, or not at all.

### Alternate injection (lab or maintenance window only)

If 5.4.3 shows that MTU 64 is accepted on some other platform, target the same window with a failure
the package enforces rather than the kernel. Attach `vxlan901` to a first disposable bridge (`br901`)
and commit. Then create a second disposable bridge (`br902`), point `bridge-group bridge` at it, and
remove `br902` out-of-band (`sudo ip link del dev br902`) **before** committing an identity change.
The commit must change the identity: that keeps the leaf handlers' identity guards inert, so the
failure lands in the reconciler's apply phase instead of pre-empting it. `reconcile_bridge()`
(`src/vyatta-vxlan:135-148`) refuses a bridge that does not exist, so the mutable step fails.

Two cautions, both real. First, the rollback re-attaches the interface to the bridge that was
captured *before* the change (`src/vyatta-vxlan:485`), so **the captured bridge must still exist** —
if you delete the bridge the interface was already attached to, the rollback fails too and the commit
exits 2 with "Rollback of vxlan901 also failed." That is why this variant needs two disposable
bridges, never one. Second, it **deletes a bridge device**: use it only where no production bridge is
involved. It is not recommended on the home router.

---

## Phase 6 — isolated bridge test (disposable `br901` + `vxlan901`)

Covers bridge membership, port cost/priority, recreation and restoration without altering any
existing bridge or production interface. Everything runs on a **new, empty, disposable bridge**
(`br901`) and the disposable `vxlan901`. `br901` gets **no member other than `vxlan901`**, ever.

**Why a new bridge instead of an existing one:** an established bridge on this router forwards
production VLAN traffic; adding a test port to it, or letting a test failure disturb its membership,
risks an outage for no extra test value. A new empty bridge has no members, forwards nothing, and is
deleted when the test ends.

### Preconditions

* Phases 0–4 passed; `vxlan900` is healthy and is not touched.
* `br901` does not already exist and no production bridge uses that name
  (`ip -j link show dev br901` → does not exist).
* The peer's side is **not** bridged into a production LAN — bridging both ends would extend a
  broadcast domain across the tunnel.
* **Do not `save` during the test** (see 5.4 preconditions).

### Procedure

**6.1 — record the bridges that must not change.**

```
ip -j link show type bridge > /tmp/rc/pre-bridges.json
```

**6.2 — create the empty bridge and the disposable port.**

```
configure
set interfaces bridge br901
set interfaces vxlan vxlan901 vni 901
set interfaces vxlan vxlan901 local-ip <RTR_V6>
set interfaces vxlan vxlan901 remote-ip <PEER_V6>
set interfaces vxlan vxlan901 port 4791
set interfaces vxlan vxlan901 mtu 1430
commit
exit
```

Expected: `br901` exists with **no** members (`ls /sys/class/net/br901/brif/` is empty) and
`vxlan901` exists with **no** addresses.

**6.3 — attach the port with non-default cost and priority.**

```
configure
set interfaces vxlan vxlan901 bridge-group bridge br901
set interfaces vxlan vxlan901 bridge-group cost 200
set interfaces vxlan vxlan901 bridge-group priority 10
commit
exit
```

Deliberately non-default values: EdgeOS 3.0.1 attaches a port with cost 100 and priority 32, so 200/10
proves the configured values were applied rather than assumed.

Expected and to be captured:

```
readlink /sys/class/net/vxlan901/brport/bridge     # ../../br901
cat /sys/class/net/vxlan901/brport/path_cost       # 200
cat /sys/class/net/vxlan901/brport/priority        # 10
ls /sys/class/net/br901/brif/                      # vxlan901, and nothing else
ip -j link show dev vxlan901                       # master == br901's ifindex
```

Also confirm the mutual-exclusion rule: `set interfaces vxlan vxlan901 address 10.255.254.9/30` must
be **rejected** while the interface is a bridge port.

**6.4 — recreation while bridged.** Change the identity and commit; the interface is recreated and
must come back attached with the same port options.

```
configure
set interfaces vxlan vxlan901 vni 903
commit
exit
```

Expected: exactly one recreation (the index changes), `br901` still has exactly one member, and
`path_cost` / `priority` are still 200 / 10. A freshly created interface is **not** a bridge port
until the reconciler re-attaches it, so this step is what actually tests the re-application path.

**6.5 — restoration on failure while bridged.** Repeat the 5.4 injection with the port attached.

```
configure
set interfaces vxlan vxlan901 vni 901      # identity change
set interfaces vxlan vxlan901 mtu 64       # injection (verify it first, per 5.4.3)
commit
```

Expected: the commit fails and rolls back, and afterwards the interface is back on VNI 901, **still a
member of `br901`**, with `path_cost` 200 and `priority` 10, and `br901` still has no other member.

**6.6 — optional dataplane.** Only if the peer has a matching `vxlan901` with an address and is not
bridged into a LAN: `ping` between the two overlay addresses. Membership and port options do not need
traffic to be validated, so skipping this step does not weaken the test.

**6.7 — clean up, in this order.**

```
configure
delete interfaces vxlan vxlan901 bridge-group
delete interfaces vxlan vxlan901
delete interfaces bridge br901
commit
exit
```

Verify: `ip -j link show dev br901` → does not exist; `ip -j link show type vxlan` no longer lists
`vxlan901`; and comparing against 6.1 shows every pre-existing bridge is unchanged.

### Acceptance criteria

| # | Criterion |
|---|---|
| 6-a | `br901` is created with no members and never gains a member other than `vxlan901`. |
| 6-b | `vxlan901` joins `br901`: the `brport/bridge` link resolves to it and the master index matches. |
| 6-c | Configured cost 200 and priority 10 are applied (not the 100/32 defaults the platform attaches a port with). |
| 6-d | Configuring an address on a bridged `vxlan901` is rejected at commit time. |
| 6-e | After an identity recreation, `vxlan901` is re-attached to `br901` with the same cost and priority, and it is still the only member. |
| 6-f | After a failed recreation, the previous identity **and** the previous bridge membership, cost and priority are restored. |
| 6-g | No pre-existing bridge or production interface changes at any point. |

### Risks

* **Creating a bridge is a bigger change than creating a VXLAN.** With no members it is inert, but it
  is still a new network device on a production router — do it in a maintenance window and never add
  a second port to it.
* **Never bridge a production interface into `br901`.** Doing so would move production traffic into
  the test bridge, and if the tunnel is up, into the peer as well.
* **Layer-2 extension:** if the peer's `vxlan901` is itself bridged to a peer LAN, the two LANs merge
  across the tunnel. Keep the peer side unbridged (step 6.6 is optional for this reason).
* **STP:** a bridge with one port cannot form a loop, so STP is not a hazard here — provided rule
  "only `vxlan901`" holds.
* **Cleanup order matters**: remove the port before deleting the bridge, or the configuration system
  may refuse to delete a bridge that still has members.

---

## Safety verdict — execution on the production router

| Procedure | Verdict | Conditions |
|---|---|---|
| 5.4 recreation failure and rollback | **Safe to execute as written**, on the production router | Runs only on disposable `vxlan901`; the injection is proven effective on the device first (5.4.3); an independent management path and console access are available; the test is not `save`d, so a reboot discards it; the route to remove a half-restored interface is known and contained. |
| Phase 6 isolated bridge test | **Safe with conditions**, and the more intrusive of the two | All of 5.4's conditions, plus: a maintenance window, the bridge is new and empty, nothing but `vxlan901` is ever added to it, no production interface is moved, and cleanup happens in the documented order. |

Neither procedure touches `vxlan900`, any production bridge, any VLAN, DHCP, DNS, firewall or
management path. Neither should be run before the objects they use have been confirmed absent (Phase
0.4) and the interface under test has been confirmed disposable.

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
