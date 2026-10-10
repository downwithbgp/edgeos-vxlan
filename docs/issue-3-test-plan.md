# Issue #3 — IPv6 VXLAN Underlay: Testing and Validation Plan

**Baseline:** `dc99bce4a1bcfc5d57daed7fc167e98df4441e81` (v0.2.1) — feature not yet implemented.
**Golden rule of this plan:** an isolated Linux namespace test proves general Linux behaviour; it does **not** prove EdgeOS 3.0.1 or EdgeRouter X behaviour. Every result below carries its environment.

## 1. Existing test infrastructure inventory

| Area | What exists today | Gaps for issue #3 |
|---|---|---|
| Unit tests | **None** (`test/` does not exist) | Everything: validation, canonicalization, JSON parsing, decision logic |
| Static checks | CI: `sh -n install.sh scripts/*.sh`, `shellcheck install.sh scripts/*.sh`, `git diff --check` (`.github/workflows/release-validation.yml:44–50`) | The new helper is Perl — add `perl -c` (with warnings) syntax checks; shell scripts stay on `sh -n`/shellcheck |
| Build/package checks | CI builds the `.deb`s and runs `scripts/validate-release.sh` (package names, versions, architectures, packaged module hashes `7c346342…`, `6d58ee59…`) | Add package-content check for the new helper; keep module-hash pins |
| Release checks | `scripts/validate-published-release.sh` (installer pins vs published assets) | Update pins at release time only |
| Mocking harness | None | Needed for reconciliation/rollback tests off-hardware |
| Isolated network tests | None in-repo | Container-based probe exists outside the repo (this investigation) |
| Hardware validation | Documented manually in `README.md:773–816` (v0.2.1, IPv4) | Add IPv6 rows; capture evidence; keep status honest |

## 2. Layer A — Static and unit tests (no privileges, runs anywhere with perl/sh)

Proposed location: `test/` with a single runner `test/run.sh` (exit non-zero on failure). Fixtures under `test/fixtures/`. The suites target the new helper (`vyatta-vxlan-addr`) and the reconciler's decision logic; nothing here needs `/sys`, root, or a network.

### A1. Endpoint validation (`U-V4-*`, `U-V6-*`, `U-MIX-*`, `U-CLS-*`, `U-MAL-*`)

| ID | Input | Expected |
|---|---|---|
| U-V4-OK-1..4 | `192.0.2.1`, `0.0.0.0`, `255.255.255.255`, `10.0.0.1` | accepted (IPv4 behaviour unchanged) |
| U-V4-BAD-1..4 | `256.1.1.1`, `1.2.3`, `1.2.3.4.5`, `abc` | rejected |
| U-V6-OK-1..5 | `2001:db8::1`; `2001:db8:0:0:0:0:0:1`; `2001:DB8::1`; ULA `fd00::1`; `2001:0db8:0000:0000:0000:0000:0000:0001` | accepted |
| U-V6-MAL-1..6 | `2001:db8:::1`, `2001:db8::1::2`, `2001:db8:0:0:0:0:0:0:1`, `2001:db8::g`, `2001:db8::1/64`, `host.example` | rejected (system/misc input: prefix must not be accepted where a literal is required) |
| U-CLS-1..6 | IPv6 `fe80::1`, `ff02::1`, `::`, `::1`, `::ffff:192.0.2.1`, `2001:db8::1` | first five rejected for endpoints; last accepted |
| U-MIX-1..4 | (v4,v6), (v6,v4), (v4,v4), (v6,v6) | mixed rejected; same-family accepted |
| U-EMPTY-1 | empty local or remote | rejected (parent `commit:expression` already requires presence; helper must also refuse) |

Every case is table-driven; the suite asserts both the exit code and that the error message names the offending value.

### A2. Canonicalization and equality (`U-CANON-*`)

| ID | Inputs | Expected |
|---|---|---|
| U-CANON-1 | `2001:db8::1` vs `2001:0db8:0000:0000:0000:0000:0000:0001` | equal |
| U-CANON-2 | `2001:DB8:0:0::1` vs `2001:db8::1` | equal |
| U-CANON-3 | `::ffff:192.0.2.1` vs `::ffff:c000:201` | equal |
| U-CANON-4 | `2001:db8::1` vs `2001:db8::2` | unequal |
| U-CANON-5 | `192.0.2.1` vs `192.0.2.1` (and vs `192.0.2.2`) | equal / unequal |
| U-CANON-6 | malformed inputs on either side | unequal, non-fatal |

Design note: equality is decided on packed `inet_pton` bytes; canonical text is derived 1:1 from those bytes and is what the shell compares, so text equality is byte equality. Canonical text is also what rollback recreates from.

### A3. Live-state parsing (`U-PARSE-*`)

Fixtures are synthetic first; the plan requires adding the **real** target capture from Phase 1/7 as a fixture once available (addresses redacted).

| ID | Fixture | Expected identity output |
|---|---|---|
| U-PARSE-1 | IPv4 VXLAN JSON (`local`, `remote`, `id`, `port`) | complete v4 identity with canonical endpoints |
| U-PARSE-2 | IPv6 VXLAN JSON (`local6`, `remote6`, `id`, `port`) | complete v6 identity |
| U-PARSE-3 | `info_kind`/`kind` variants | recognised as vxlan |
| U-PARSE-4 | missing `port` (and `dstport` fallback present) | uses fallback |
| U-PARSE-5 | missing `local`/`local6` | **incomplete → refusal**, not empty string |
| U-PARSE-6 | missing remote | incomplete → refusal |
| U-PARSE-7 | `group6` (multicast) without `remote6` | incomplete → refusal (not treated as remote) |
| U-PARSE-8 | both `local` and `local6` present | inconsistent → refusal |
| U-PARSE-9 | malformed JSON / empty array / non-vxlan kind | non-zero exit, no output |
| U-PARSE-10 | unexpected-but-valid structure (extra keys, numbers as strings) | still parses |

### A4. Decision logic (`U-ID-*`, `U-IDEM-*`, `U-SNAP-*`, `U-RB-*`, `U-MTU-*`, `U-FAILCLOSE-*`, `U-ADDR-*`)

These are unit-level decision tests (Layer A); their end-to-end counterparts run through the Layer-B mocked harness, which is built up with Phases 3–5 and consolidated in Phase 6.

| ID | Scenario | Expected result |
|---|---|---|
| U-ID-1 | v4 → same v4 (canonical equality) | no recreate |
| U-ID-2 | v4 → different v4 public | recreate |
| U-ID-3 | v6 → same v6, different spelling | no recreate |
| U-ID-4 | v6 → different v6 remote/local | recreate |
| U-ID-5..6 | v4 → v6 and v6 → v4 | recreate, family recorded in snapshot |
| U-ID-7..10 | change VNI / UDP port only; no change with absent interface | recreate / create |
| U-IDEM-1..3 | unchanged commit, IPv6 spelling variants, v4 unchanged | mutable-state application only; no delete/create |
| U-SNAP-1..3 | complete v6 snapshot; family-consistent; inconsistent family | stored / stored / refused |
| U-RB-1..3 | rollback values reproduce the original family + endpoints + port + VNI | exact canonical match |
| U-MTU-1..4 | `default-mtu v4/v6`; explicit `mtu` wins; delete restores family default | 1450 / 1430 / explicit / family default |
| U-FAILCLOSE-1..4 | incomplete identity before delete; malformed JSON; non-vxlan device; helper failure | commit aborts, **nothing deleted** |
| U-ADDR-1..3 | IPv6 overlay address: canonical vs alternate spelling; two different addresses; same address with two different prefix lengths (`/64` vs `/65`) | `contains_address` compares equal for the same literal+prefix (no re-add), and unequal for different addresses or a different prefix |

### A5. Template structural checks (`U-TPL-*`)

Grep-level assertions (cheap, catch accidental regressions): `local-ip`/`remote-ip` carry `type: ipv4,ipv6`; the parent node has exactly one `end:` handler and the new `commit:expression`; `mtu` no longer declares a static default; `debian/edgeos-vxlan.install` lists the new helper; module hashes in `scripts/validate-release.sh` unchanged.

## 3. Layer B — Mocked reconciliation tests (no privileges)

Goal: exercise `vyatta-vxlan` end-to-end (create → apply → recreate → rollback) with the kernel/CLI replaced by fakes.

Approach:

1. Small testability change (inventory item C1, required for this layer): make the absolute command paths in **both** reconciler scripts overridable while keeping today's defaults exact — `${brctl:-/usr/sbin/brctl}`, `${modprobe:-/sbin/modprobe}`, `${sysfs_root:-/sys}` — and route all helper invocations through the existing lowercase `vyatta_sbindir` override. Current inconsistencies to fix: in `src/vyatta-vxlan`, `vyatta-vxlan-bridge` is called via `${VYATTA_SBINDIR}` at `:247` but hardcoded at `:267`, `vyatta-address` is hardcoded at `:259` and `:361`, `brctl` is called as `/usr/sbin/brctl` at `:55`/`:58`/`:80`/`:85`/`:95`, sysfs paths are read at `:34`/`:38`/`:43`/`:47`/`:74`/`:92` (bridge state), `:149` (eth0 MAC), `:230`/`:236`/`:271` (MTU/alias/flags), and `:307`–`:319` (snapshot address/MTU/alias/flags), and `modprobe` is called at `:425–427`; in `src/vyatta-vxlan-bridge`, `brctl` is hardcoded at `:69`/`:74`/`:106`/`:116`/`:156`/`:161` and the sysfs paths at `:42`/`:46`/`:51`/`:55`/`:111`/`:149`. No behaviour change when the variables are unset.
2. Harness (`test/mock/`) builds a temp directory and a scripted state file per scenario. Interception is by invocation style, not uniformly by PATH: bare-name commands get PATH fakes (`ip`, `sudo`, `id`, `sha256sum`); absolute-path commands go through the C1 overrides (`brctl`, `modprobe`, the sysfs root); `my_cli_shell_api`, `vyatta-address`, and `vyatta-vxlan-bridge` are reached via the `vyatta_sbindir` override. The `id` fake is required: both reconciler scripts refuse to run unless `id -g -n` prints `vyattacfg` (`src/vyatta-vxlan:4`, `src/vyatta-vxlan-bridge:6`), which never holds off-device.
3. Scenarios:
   - initial IPv6 creation (no live interface) → create with `local 2001:db8::1 remote 2001:db8::2 dstport 4789`, MAC set, MTU 1430;
   - successful identity recreation (v6 remote change) → old state captured (including `local6`/`remote6`), delete, create, mutable state reapplied;
   - failed creation → rollback recreates the original interface with original family/endpoints/MTU/MAC/addresses/bridge state;
   - failed mutable-state application on an unchanged identity → commit fails, interface not deleted;
   - v4 → v6 and v6 → v4 with a forced creation failure → previous family restored;
   - bridge membership/cost/priority preserved across creation and rollback;
   - deterministic MAC stable across recreations;
   - no-op commit (identity equal) → zero `ip link add`/`del` calls (assert on the fake log);
   - malformed live state → refusal with no `ip link del`.
4. The harness asserts on the recorded command log, not on real kernel state.

This layer proves the state machine, the argument construction, and the ordering. It cannot prove kernel semantics — by design.

## 4. Layer C — Isolated Linux networking tests (general Linux only)

### C1. Performed during this investigation (modern Linux; **not EdgeOS**)

Environment: disposable `alpine` docker container, `--cap-add NET_ADMIN --cap-add SYS_ADMIN`, two PID-based network namespaces (`unshare -n` + `nsenter`), veth pair with underlay `2001:db8:1::/64`, `iproute2-v7.0.0`, kernel 6.8. Script preserved at `/tmp/vxlan-v6-ns-test.sh` (outside the repo).

Observed results:

| Check | Result |
|---|---|
| IPv6 underlay reachability | 2/2 ping, 0% loss both directions |
| VXLAN create with `local`/`remote` IPv6 | both sides created successfully |
| Overlay IPv4 ping over the IPv6 tunnel | 3/3, 0% loss both directions |
| Kernel-derived MTU with `dev` set (1500-byte lowerdev) | **1430** |
| `ip -j -d link show` JSON keys | `"local6"`, `"remote6"`, `"id":42`, `"port":4789` |
| UDP checksum defaults in JSON | `"udp_csum":true`, `"udp_zero_csum6_tx":false`, `"udp_zero_csum6_rx":false` |
| Counters increment; teardown | RX/TX bytes > 0; `TEARDOWN_OK` |

### C2. Expanded probe to be added to the repo's test plan (optional, still general Linux)

- IPv6 **overlay** traffic (not just IPv4 over an IPv6 underlay): add `2001:db8:42::/64` addresses on the VXLAN devices and ping across.
- Explicit MTU experiment: set the VXLAN MTU to 1450 without `dev` and confirm outer fragmentation is observable (packet capture or `ip -s`) — demonstrates the operational reason for the 1430 default.
- UDP port variation (e.g. 8472) and counter-based confirmation that the configured port carries traffic.
- Same probe script shaped to run in CI for repositories with a privileged runner (must never be presented as EdgeOS validation).

## 5. Layer D — Hardware validation plan (EdgeRouter X, EdgeOS 3.0.1)

### D0. Prerequisites

- One EdgeRouter X / ER-e50 on EdgeOS 3.0.1 build 5862409 with `edgeos-vxlan` v0.2.1 (or the new build) installed.
- Management access that does **not** depend on the test VNI; keep a console/second path available.
- One Linux host (any current distro) as the remote VTEP; both ends must reach each other over IPv6.
- A dedicated test VNI (e.g. 4242) and dedicated underlay addresses (use ULA or real addresses; `2001:db8::/32` only in examples).
- Packet capture available on both ends.

### D1. Read-only diagnostics (safe, collect before and during tests)

```bash
uname -a; cat /etc/version
lsmod | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)'
modinfo vxlan | head -20
ip -Version
ip -6 addr show; ip -6 route show
ip -j -d link show dev vxlan42          # after a tunnel exists
ip -s link show vxlan42
bridge link show                        # bridged cases
cat /proc/net/vxlan_sock 2>/dev/null    # vxlan statistics if present
sudo tcpdump -ni <underlay-if> -c 20 -vv 'udp port 4789'
dmesg | tail -50
show interfaces vxlan42
```

### D2. State-changing steps (planned, executed only with authorization)

1. Configure an IPv6 tunnel one command per line (`mtu` deliberately unset first, then set it explicitly in a second step), then `commit`, `save`:

   ```text
   set interfaces vxlan vxlan42 vni 4242
   set interfaces vxlan vxlan42 local-ip <v6>
   set interfaces vxlan vxlan42 remote-ip <v6>
   set interfaces vxlan vxlan42 port 4789
   ```
2. Repeat the capture in D1 against the live v6 tunnel (this closes unverified assumption #1).
3. Dataplane: ping IPv4 and IPv6 overlay addresses from both ends; run a sustained transfer; watch counters and `dmesg`.
4. Transition tests: change remote, change family v4→v6 and back, with a deliberate failure injected (e.g. an unreachable `local-ip` or a temporary firewall drop) to exercise rollback.
5. Bridge test: `bridge-group bridge br42` plus cost/priority; verify traffic, STP options and persistence.
6. Reboot test: `save`, reboot, verify the tunnel, MAC, MTU, addresses/bridge state.
7. Security test: confirm an alternate-source VNI-matching packet is accepted (as for IPv4) and that the `ipv6-name` local policy drops it after configuration. Policy example (node paths verified against the stock templates; one command per line):

   ```text
   set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 default-action accept
   set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 action accept
   set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 protocol udp
   set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 source address <remote-v6>
   set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 destination port 4789
   set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 action drop
   set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 protocol udp
   set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 destination port 4789
   set interfaces ethernet eth1 firewall local ipv6-name VXLAN_UNDERLAY_LOCAL6
   ```
8. Upgrade test: install the new integration package over v0.2.1 (kmod payload unchanged) with an existing IPv4 tunnel; verify the tunnel is untouched.
9. Removal test: verify the guards still refuse removal while configuration/live interfaces exist, then remove cleanly and confirm diverts restore stock files.

### D3. Optional: target-binary JSON capture without the router

If hardware is unavailable at review time, the target `/sbin/ip` (MIPS, extracted from the firmware) can be executed under `qemu-mipsel-static` with the firmware's `-L` library path on a machine where a v4/v6 VXLAN exists. This produces the *target's own* JSON formatting without touching a router. It does not replace hardware validation for dataplane/boot behaviour. (Not available in the investigation environment: no qemu, no root.)

### D4. Hardware test ID legend (referenced by the change inventory)

| ID | Matrix rows |
|---|---|
| H-REG-1 | 1 |
| H-VAL-1..2 | 15, 16 |
| H-MTU-1..2 | rows 2–3 (unset MTU on v4/v6 creation) |
| H-MTU-3..4 | 19 (explicit set / delete-restores-default) |
| H-RB-1..2 | 13, 14 |
| H-TRANS-1..2 | 11, 12 |
| H-BOOT-1 | 21 |

## 6. Acceptance matrix (the matrix required by the investigation brief)

Legend — **HW**: requires the EdgeRouter X (or at least the target firmware). **Status**: all IPv6 rows are `not run` until the feature exists; IPv4 rows marked `passed (v0.2.1, README)` are pre-change evidence that must be re-confirmed after the change (regression). No status is claimed here that was not actually executed.

| # | Scenario | Expected result | Procedure (abbrev.) | Evidence | HW | Status |
|---|---|---|---|---|---|---|
| 1 | Existing IPv4 VXLAN configuration | Continues working unchanged | Upgrade, then H-REG-1 | `show interfaces`, JSON identity, ping | yes | passed on v0.2.1; re-run after change |
| 2 | New IPv4 VXLAN | Creates successfully | Configure + commit | `ip -d link`, ping | yes | not run |
| 3 | New IPv6 VXLAN | Creates successfully | Configure + commit | `ip -d link` shows local6/remote6 | yes | not run |
| 4 | IPv6 underlay, IPv4 overlay | Bidirectional traffic | Overlay ping/transfer | counters + capture | yes | not run (general-Linux analogue passed in C1) |
| 5 | IPv6 underlay, IPv6 overlay | Bidirectional traffic | Overlay v6 ping/transfer | counters + capture | yes | not run |
| 6 | IPv6 bridge integration | Traffic + bridge settings persist | bridge-group config, reboot | `bridge link`, counters | yes | not run |
| 7 | IPv6 underlay endpoint reformatted in config | No recreation | Re-enter the same `local-ip`/`remote-ip` in a different spelling, commit | no delete/create in the logs; unit U-CANON/U-IDEM also cover this | yes (unit covers) | not run |
| 8 | Change IPv6 remote | Controlled recreation | `set remote-ip` new value | single delete/create in logs, MAC preserved | yes | not run |
| 9 | Change IPv6 local | Controlled recreation | `set local-ip` new value | as above | yes | not run |
| 10 | Change VNI or UDP port | Controlled recreation | change + commit | as above | yes | not run |
| 11 | v4→v6 transition | Correct family/endpoints; one recreation | set both endpoints v6, commit | JSON shows local6/remote6 | yes | not run |
| 12 | v6→v4 transition | Correct family/endpoints | reverse | JSON shows local/remote | yes | not run |
| 13 | Failed family transition | Previous live state restored | inject creation failure (invalid/unreachable local), commit | rollback recreates v4 (or v6) exactly | yes | not run |
| 14 | Failed IPv6 endpoint change | Previous v6 restored | inject failure | as above | yes | not run |
| 15 | Invalid IPv6 endpoint | Commit rejected safely | `set local-ip fe80::1` / malformed | commit error, interface untouched | yes | not run (unit covers U-CLS/U-MAL) |
| 16 | Mixed v4/v6 endpoints | Commit rejected | set mixed, commit | commit error, no delete | yes | not run (unit covers U-MIX) |
| 17 | Unchanged configuration commit | No destructive change | `commit` twice | no delete/create commands; interface counters continuous | yes | not run (unit U-IDEM) |
| 18 | Admin disable/enable | No state loss | `set disable`/`delete disable` | flags preserved | yes | not run |
| 19 | MTU update | Behaves as designed | set mtu 1400; delete mtu | explicit applied; delete restores family default | yes | not run (unit U-MTU) |
| 20 | Bridge port options | Correct after changes/reboot | cost/priority changes | `bridge link`, sysfs | yes | not run |
| 21 | Save and reboot | IPv6 tunnel restored | save; reboot | post-boot JSON + ping | yes | not run |
| 22 | Package upgrade | IPv4 config remains operational | install new integration pkg | tunnel untouched; kmod hash unchanged | yes | not run |
| 23 | Package removal | Safeguards + restoration work | guards, then removal | diverts restored | yes | not run |
| 24 | Unexpected VXLAN source | Behaviour understood; firewall mitigation works | alternate-source VNI packet + `ipv6-name` policy | captured accept, then drop after policy | yes | not run (IPv4 behaviour: passed per README) |
| 25 | Sustained IPv6 VXLAN traffic | No kernel errors/teardown | throughput run + dmesg | no Oops/stalls; counters grow | yes | not run |

## 7. Capture and reporting convention

For every hardware test record: firmware string (`/etc/version`), kernel, `ip -Version`, exact commands, raw outputs (saved to a file and attached to the issue/PR as appropriate), counters before/after, and `dmesg` excerpts. Use statuses `not run / passed / failed / blocked`; when blocked, state the missing capability (hardware, underlay, capture tool). Never infer a pass from an analogous run on a different environment.

## 8. Safe recovery procedures (for the hardware phase)

1. **A failed commit that rolled back**: the helper prints `Rolling back … completed.` and the commit reports failure; re-verify with `ip -j -d link show dev vxlan42` that the previous identity is live before further work.
2. **A failed commit whose rollback also failed** (exit 2): do not re-commit the same config; inspect the live device, then either delete the VXLAN config or re-create the interface manually (`ip link add … ` using values from `/config/config.boot`) — the error text says which step failed.
3. **Unwanted recreation loop**: stop committing; capture `ip -j -d link show` and the config values, then set a non-canonical spelling aside and file a defect with both strings.
4. **Console path**: EdgeOS keeps the previous committed config in `/config/config.boot`; a bad commit can be discarded with `commit`-level rollback (`discard`) or by removing the VXLAN node and committing again. Reboot always returns to the saved config.
5. **Module/package problems**: do not unload modules by force; the guarded removal paths (`prerm` checks live interfaces) exist so that package removal cannot orphan a live device.
6. **Keep management off the test VNI** so that every recovery action remains reachable.
