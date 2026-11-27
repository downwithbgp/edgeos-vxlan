# Issue #3 — IPv6 VXLAN Underlay: Implementation Roadmap

**Baseline:** `dc99bce4a1bcfc5d57daed7fc167e98df4441e81` (v0.2.1)
**Read with:** `docs/issue-3-ipv6-assessment.md`, `docs/issue-3-change-inventory.md`, `docs/issue-3-test-plan.md`
**Rule:** no production code exists yet. This plan preserves the IPv4 implementation as the compatibility baseline and keeps the kernel package byte-identical.

## 0. Dependency ordering and commit boundaries (overview)

```
Phase 1  Capability verification on target (read-only + manual one-shot test)     [no code]
   │
Phase 2  Endpoint validation (helper + templates + packaging + unit tests)        [commit]
   │
Phase 3  Live-state parsing + canonical identity (helper + reconciler + fixtures) [commit]
   │
Phase 4  Reconciliation + family-aware MTU (reconciler + mtu template + tests)    [commit]
   │
Phase 5  Rollback hardening (fail-closed snapshot + rollback tests)               [commit]
   │
Phase 6  Test harness + CI wiring                                                 [commit]
   │
Phase 7  Hardware integration testing (evidence only; fixes loop back to 2–5)     [no code]
   │
Phase 8  Documentation + release preparation (authorization before release)       [commit(s)]
```

Recommended conventional-commit subjects:

| Phase | Suggested commit |
|---|---|
| 2 | `feat: accept IPv4 or IPv6 VXLAN underlay endpoints` |
| 3 | `feat: parse and compare IPv6 VXLAN endpoints idempotently` |
| 4 | `feat: family-aware VXLAN MTU default for IPv6 underlay` |
| 5 | `fix: fail closed when a live VXLAN identity cannot be snapshotted` |
| 6 | `test: cover endpoint validation, live parsing, and recreation decisions` |
| 8 | `docs: document IPv6 VXLAN underlay support` (release commits added separately) |

**Release gate — Phases 2–5 ship together.** The phase split exists for reviewability (separate commits), not for deployment: an intermediate build that accepts IPv6 endpoints before the parsing, canonical comparison, MTU, and fail-closed changes land would exhibit exactly the hazards described in `docs/issue-3-ipv6-assessment.md` §8 (RB-1..RB-4). Keep Phases 2–5 in one pull request and do not install intermediate builds on a router.

Each phase must leave `main` green: `sh -n` + shellcheck + `git diff --check` + the new test suite, all runnable off-hardware. Test layers grow with the phases: Phases 3–5 add the Layer-A unit tests and build up the Layer-B mocked harness (including the C1 overrides); Phase 6 consolidates the runner, completes any remaining mocked scenarios, and wires CI.

---

## 0.1 Review-response classification (Revision 2)

The maintainer review of 2026-10-10 asked for a clear split between what must be fixed before the feature can ship, what belongs in the implementation for quality, and what can wait. Applied to this plan:

### Release-blocking (the feature is not done until these are resolved and evidenced)

| ID | Item | Where |
|---|---|---|
| RB-1 | Live identity must read both families (`local6`/`remote6`) and compare canonically, or every IPv6 commit recreates the device and rollback loses endpoints | Phase 3 |
| RB-2 | Live-state capture must be status-checked and complete: the `ip -o addr` collection must not fail silently (the current process-substitution pattern swallows failures — demonstrated), and every snapshot component must be validated before any destructive step | Phase 3/5 |
| RB-3 | MTU must become family-aware with the corrected evidence: oversized outer IPv6 packets are **not** fragmented by this path (source + probe), so 1450 over a 1500-byte IPv6 path loses the first packets and depends on PMTU feedback; default 1430 for that case, explicit `mtu` authoritative, target behaviour captured in Phase 7 | Phase 4 |
| RB-4 | Rollback fidelity under **combined** changes: determine on target whether leaf handlers can mutate MTU/addresses/description/bridge state before the parent reconciler snapshots; if so, add the identity-aware leaf guard (or scope the rollback claim to snapshot-time state). Do not claim full rollback before this is demonstrated | Phase 1 + Phase 5 |
| RB-5 | Deterministic failure injection: rollback tests must use controlled creation failures (**corrected 2026-10-10**: a duplicate VNI/UDP-port does *not* block creation — two VXLAN devices share a socket — so the validation runbook's Phase 5.4 uses a below-minimum MTU instead, which the kernel rejects deterministically; mocked `ip` failures per step); unreachable-VTEP and firewall-drop are not creation failures | Phase 6/7 |
| RB-6 | IPv4 literal policy settled: never canonicalise to a value different from the platform's own parser; emulate platform parity exactly (leading-zero octets are octal in iproute2/glibc) or reject with an explicit message; tests for the chosen policy | Phase 2 |
| RB-7 | Defence in depth: the reconciler validates desired endpoint families/classes itself before any mutation, even though the templates also validate | Phase 2/3 |

### Implementation improvements (needed for a complete, maintainable change; not by themselves release gates)

| ID | Item | Where |
|---|---|---|
| IM-1 | Assert and document interface-index semantics: recreation changes `ifindex`; rollback restores properties, not the index; a matrix row captures before/after values | Phase 6/7 |
| IM-2 | Boot rows for dynamic IPv6 underlay addressing (SLAAC/DHCPv6 readiness), plus the note that creation itself does not require the local address to be present | Phase 7 |
| IM-3 | Per-step mutable-state failure tests (mocked) documenting the non-recreate failure path | Phase 6 |
| IM-4 | Firewall deployment guidance for interfaces that already have a local IPv6 policy attached (extend, don't replace; lockout safety) | Phase 8 |
| IM-5 | Interface-address canonical comparison (ADJ-1) folded into Phase 3 | Phase 3 |
| IM-6 | Default-materialisation investigation: prefer keeping the template `default: 1450` and probing the engine's active/effective accessors for an explicit-vs-default distinction (Phase 1; the CLI API has no `isDefault` verb); removing the default becomes the fallback | Phase 1/4 |

### Optional follow-ups (do not block the feature)

- Platform-parity octal emulation for IPv4 literals, only if the Phase 1 target probe shows a stable, unambiguous parser (otherwise the reject-with-message policy stands).
- Snapshot journaling (write the captured snapshot to a file) for post-mortem analysis of failed commits.
- Extend `scripts/validate-release.sh` to assert the helper's presence in the `.deb` (cheap CI hardening).
- Record observed handler ordering in the README after Phase 7.

---

## Phase 1 — Capability verification (no code; device)

**Why first:** every design decision below rests on a handful of target facts: the shipped module can carry IPv6 VXLAN; the target `ip` prints `local6`/`remote6` JSON keys and parses non-canonical IPv4 literals as octal; the engine exposes (or does not expose) the explicit-vs-default distinction the MTU design needs; and leaf-handler ordering is what the rollback claim depends on. Most are backed by binary/source evidence already; this phase closes the remaining gaps cheaply before code is written.

**Steps (in order, on a router that can spare a test VNI):**

1. Read-only inventory: `uname -a`, `cat /etc/version`, `lsmod | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)'`, `modinfo vxlan`, `ip -Version`, `ip -j -d link show dev <existing vxlan>`.
2. One-shot manual creation on a spare VNI *outside* the EdgeOS configuration system (so no config is touched):
   `sudo ip link add dev vxlan900 type vxlan id 900 local <v6> remote <v6> dstport 4789`
   then `ip -j -d link show dev vxlan900`, then `sudo ip link del dev vxlan900` (delete it in all cases, including on failure, and finish by confirming no `type vxlan` devices remain — a left-behind `vxlan900` blocks `edgeos-vxlan-kmod` removal per `debian/edgeos-vxlan-kmod.prerm:6`).
3. Capture and store the raw JSON, plus the interface's `-d` text form.
4. IPv4 literal parser probe (settles RB-6): `sudo ip link add dev vxlan901 type vxlan id 901 local 010.1.2.3 remote 010.1.2.4 dstport 4789`, then read back `ip -d link show dev vxlan901` — does the target bind `8.1.2.x` (octal, as modern iproute2/glibc does) or reject the value? Record the answer with the unit-test policy.
5. Engine default semantics (settles IM-6 and the `mtu delete:` behaviour): with a test tunnel configured *without* `mtu`, read `my_cli_shell_api existsActive|existsEffective|returnActiveValue|returnEffectiveValue interfaces vxlan vxlanN mtu` and check `show configuration commands`; then `set mtu 1400`, commit, `delete mtu`, commit, and read the live MTU again.
6. Handler-ordering observation (settles RB-4's premise): temporarily log entry/exit of the leaf handlers and the parent `end:` (wrapper scripts or timestamps in a temporary copy of the templates), then commit (a) an MTU-only change, (b) an identity-only change, (c) a combined `mtu` + `remote-ip` change; record the observed order.
7. Oversized-packet behaviour on target (closes RB-3's residual): with the test tunnel at MTU 1450 over the IPv6 underlay, send full-size traffic while capturing on the underlay and watching `/proc/net/snmp6` (`Ip6FragFails`/`Ip6FragCreates`) and `dmesg`; repeat at 1430.
8. Optional (hardware-free alternative): execute the extracted target `/sbin/ip` under `qemu-mipsel-static -L <rootfs>` to reproduce the target's JSON formatting (see test plan §D3).

**Files:** none. Record results (with raw output) in a document/issue comment; if the capture differs from the assumed shape, adjust the Phase 3 fixtures before coding.

**Completion criteria:** module dependency chain loads; IPv6 VXLAN device is created; JSON contains `local6`/`remote6`; the IPv4 literal probe, engine default semantics, handler-ordering observation and oversized-packet capture are recorded (or deviations documented and the design adjusted).

**Failure modes / escalation:** `ip` refuses IPv6 (contradicts upstream evidence) → stop and re-open capability analysis; JSON keys differ → adapt the parser contract and fixtures, then continue.

---

## Phase 2 — Endpoint validation

**Files**

- `src/vyatta-vxlan-addr` — new helper, installed to `/opt/vyatta/sbin/`; Perl; core modules only (`Socket` for `inet_pton`/`inet_ntop`, `JSON::PP` in Phase 3); shebang `#!/usr/bin/perl`; GPL-2.0-only header consistent with the project.
- `templates/interfaces/vxlan/node.tag/local-ip/node.def` — `type: ipv4,ipv6`; replace the `/opt/vyatta/sbin/local_ip` warning call with the helper's family-aware check; help text updated.
- `templates/interfaces/vxlan/node.tag/remote-ip/node.def` — `type: ipv4,ipv6`; help text updated.
- `templates/interfaces/vxlan/node.tag/remote-ip/node.def` — one additional `commit:expression: exec` calling `check-endpoints` with the *value* references `$VAR(../local-ip/@)` and `$VAR(@)`. (A bare `$VAR(<path>)` is a presence test whose value is the node name, not the configured address.)
- `debian/edgeos-vxlan.install` — add the helper.
- `test/` — new suite for the helper (validation cases of test plan §A1).

**Helper contract (proposed)**

```
vyatta-vxlan-addr family <addr>                  -> v4|v6; exit 1 if not a literal
vyatta-vxlan-addr check-endpoint local|remote <addr>
                                                 -> exit 0 or message + exit 1
vyatta-vxlan-addr check-endpoints <local> <remote>
                                                 -> same family; both permitted classes
vyatta-vxlan-addr canon <addr>                   -> RFC-5952-style canonical text
vyatta-vxlan-addr canon-v4 <addr>                -> platform-parity canonical form, or explicit error (RB-6)
vyatta-vxlan-addr equal <a> <b>                  -> exit 0 iff byte-identical
vyatta-vxlan-addr present <addr>                 -> exit 0 iff configured on the system (family-aware replacement for the IPv4-only local_ip probe)
vyatta-vxlan-addr default-mtu v4|v6              -> 1450|1430
vyatta-vxlan-addr parse-live                     -> parse `ip -j -d link show` JSON on stdin
vyatta-vxlan-addr identity-matches <ifname>      -> exit 0 iff the desired and live identity match (leaf-guard support)
```

**Validation rules**

- IPv4: exactly today's acceptance (`type: ipv4`) plus the existing "warning if not present on the system" behaviour used for `local-ip` (implemented family-aware; a warning, not a rejection, matching v0.2.1).
- IPv4 non-canonical literals (RB-6): the stock validator accepts leading-zero octets (`TypeChecker.pm:79–84`) and the platform's own parser binds them as **octal** (glibc/iproute2 probe: `010.1.2.3` → `8.1.2.3`); `inet_pton` alone rejects them. The helper must therefore never canonicalise to a different value than the platform would bind: emulate the platform's interpretation exactly (platform-parity mode, enabled only if the Phase 1 target probe confirms it) or reject such literals with an explicit message. No silent decimal reinterpretation; dedicated `U-V4-NC-*` tests either way.
- IPv6: literal required (no prefix, no hostname, no zone id); permitted classes for endpoints: global unicast and ULA (`fc00::/7`); rejected: link-local (`fe80::/10`), multicast (`ff00::/8`), unspecified (`::`), loopback (`::1`), IPv4-mapped (`::ffff:0:0/96`). For the **local** endpoint an unspecified value (`::`, like IPv4 `0.0.0.0`) is treated as "no specific local address" rather than rejected, matching the IPv4 baseline; the live parser must treat a missing `local`/`local6` key the same way (iproute2 prints nothing for an unspecified local).
- Family consistency is enforced for both families. The IPv6 class rules above apply to IPv6 endpoints only; IPv4 keeps today's acceptance exactly (any valid `ipv4` literal, warning-only local check). The kernel-derived extra restrictions (local not multicast, remote not unspecified) are likewise applied only where they do not narrow existing IPv4 behaviour — i.e., to IPv6 endpoints.
- Errors must name the offending value and the reason; exit non-zero so the commit aborts with EdgeOS's usual message. Exit codes are part of the contract: `0` success, `1` invalid/refused, `2` operational failure (e.g. cannot read state) — callers must distinguish them.
- The same `check-endpoints` entry point is used by the reconciler before any mutation (RB-7), so validation does not depend on the template layer having run.

**Failure modes:** engine quoting of `$VAR(...)` inside `commit:expression`/`syntax:expression` (use single-quoted arguments; the values are already validated literals — keep the helper free of shell interpolation); using the wrong output stream — checks invoked from `syntax:expression`/`commit:expression` must print the user-visible reason on **stdout** and exit non-zero (this matches the stock convention, e.g. the `mtu` platform-cap check in this very template emits its message with `echo`), while handler/reconciler diagnostics use **stderr** (as the existing scripts do); `local_ip` semantics changing for IPv4 (must not).

**Tests:** test plan §A1 (`U-V4-*`, `U-V6-*`, `U-MIX-*`, `U-CLS-*`, `U-MAL-*`, `U-EMPTY-1`), `U-TPL-*` structural checks.

**Completion criteria:** helper + templates land; all unit tests pass; the package installs the helper; a canonical IPv4 config validates and commits exactly as before (mocked/unit level) and non-canonical literals follow the RB-6 policy; the `U-V4-NC-*` policy tests pass and the Phase 1 target probe outcome is recorded; template diff reviewed line by line; the phase is **not** released on its own (see the release gate in §0).

---

## Phase 3 — Live-state parsing and canonical identity

**Files**

- `src/vyatta-vxlan-addr` — `parse-live` (stdin JSON → one tab-separated line).
- `src/vyatta-vxlan` — `get_live_vxlan_identity()` becomes a thin call to the helper; the recreate decision consumes canonical values.
- `test/fixtures/` — IPv4 and IPv6 JSON fixtures (synthetic first; the Phase 1 capture added with addresses redacted).
- `test/` — parsing and canonicalization suites (test plan §A2, §A3).
- `src/vyatta-vxlan` — route the interface-address comparison (`contains_address()`, lines 130–142, called at :252/:258) through the same canonical form (ADJ-1): canonicalize the literal part and compare the prefix length separately, so a non-canonically spelled overlay address no longer re-triggers `vyatta-address add` and a prefix-only change is still detected; add the `U-ADDR-*` tests.
- `src/vyatta-vxlan` — replace both process-substitution collections (`read_live_addresses` lines 211–222, `capture_live_snapshot` lines 327–334) with explicit `out=$(... ) || fail` captures; the current form swallows failures (demonstrated: `while read … done < <(false)` continues with an empty list and status 0). Every snapshot component read (identity fields, MAC, MTU, description, addresses, bridge, cost/priority, admin flags) must be checked and a failure must abort before any delete (RB-2).
- `src/vyatta-vxlan` — add the defence-in-depth `check-endpoints` call on the desired values at reconciliation start, before any mutation (RB-7); abort with a clear message on failure.

**Identity contract (proposed)**

```
kind <TAB> id <TAB> port <TAB> family <TAB> local <TAB> remote
```

- `kind` must be `vxlan` (accepting `info_kind` or `kind`).
- Endpoints: `local`/`local6`, `remote`/`remote6`; exactly one family must be present and complete; mixed or partial → exit non-zero.
- `port` from `port`, falling back to `dstport`; `id` required.
- All endpoint text emitted canonicalised (via `inet_ntop`) so shell comparison is byte-equivalent; the configured endpoints are canonicalised through `canon` before comparison.
- `group6` is never treated as a remote.

**Reconciler behaviour:** the comparison at `src/vyatta-vxlan:436–441` becomes a comparison of `(vni, port, family, local_canon, remote_canon)` against the canonical configured tuple. Record the family in the decision so v4↔v6 is always a change even if some field were accidentally equal.

**Failure modes:** unexpected JSON shape (extra nesting, arrays, null); locale/encoding of `inet_ntop`; a live device created without a local address; `ip -j` unavailable (today's code would exit non-zero under `set -e` and abort the commit — retain that fail-closed behaviour).

**Tests:** §A2, §A3, `U-ID-1..10`, `U-IDEM-*`.

**Completion criteria:** unit tests pass; a `commit` with an unchanged IPv6 configuration is proven (mock level) to make no `ip link add`/`ip link del` calls; IPv4 identity strings compare identically to today for canonical input.

---

## Phase 4 — Reconciliation and family-aware MTU

**Files**

- `src/vyatta-vxlan` — MTU resolution (lines 397–401) becomes: an **explicitly set** `mtu` wins; otherwise `default-mtu <family>` (1450 v4 / 1430 v6). Explicitness is probed with the engine's active/effective accessors (`existsActive`/`existsEffective`/`returnActiveValue`/`returnEffectiveValue` — the CLI API exposes no `isDefault` verb; Phase 1, IM-6); if they do not distinguish explicit values from defaults, fall back to removing the template `default:` and keying off `node_exists` (the previous design).
- `templates/interfaces/vxlan/node.tag/mtu/node.def` — keep the range/platform checks. **Preferred (IM-6): keep `default: 1450`** so `show` and delete semantics stay as in v0.2.1, and let the reconciler apply the family default when the node is not explicitly set. Note the visible consequence of the keep-default variant: `show configuration` displays the template default 1450 while a live IPv6 tunnel runs at 1430 — if that mismatch is unacceptable, choose the removal variant. Fallback: remove the default (documented behaviour change). In both variants the `delete:` handler restores the family-aware default by computing it with `vyatta-vxlan-addr default-mtu <family>` and setting it directly — no dependence on engine ordering (Q3); Phase 1 records whether the engine itself also restores a default on delete.
- Tests: `U-MTU-*`, `U-IDEM-*`, mocked recreation suite (test plan Layer B).

**MTU guidance (part of the deliverable):** 1430 is the default for the *standard* case — a plain, untagged Ethernet path with a 1500-byte MTU and no further encapsulation. It is not a universal constant: subtract 4 bytes per VLAN tag on the outer path and 8 for PPPoE, and use the real underlay MTU for anything else; explicit `mtu` is recommended whenever the path is not the standard case. Formula and examples are in `docs/issue-3-test-plan.md`. Evidence basis: with 1450 on a 1500-byte IPv6 path, oversized outer packets are **not** fragmented (isolated probe + 4.14 source), the first packets are lost, and traffic recovers only through PMTU feedback/inner fragmentation — see `docs/issue-3-ipv6-assessment.md` §4.4.

**Deliberate non-changes:** do not add a lower-link `dev <link>` argument to `ip link add` (would change IPv4 MTU derivation/clamping and couple creation to underlay state); do not add MTU auto-discovery; do not alter the default for IPv4 (still 1450 when unset).

**Failure modes:** forgetting the `delete` path (interface keeps a stale MTU); the engine reporting an explicitly-set `mtu` when the user never set one (Phase 1 probe; the fallback design removes the exposure); relying on PMTU feedback instead of sizing the tunnel correctly (explicitly out of scope — the default and the documentation must avoid it).

**Completion criteria:** mocked tests prove: unset MTU + IPv6 family → 1430; unset + IPv4 → 1450; explicit value always wins; deleting an explicit MTU restores the family default; idempotent commits still untouched; the Phase 1 default-semantics probe is recorded and the chosen variant (keep vs remove the template default) is documented.

---

## Phase 5 — Rollback hardening

**Files**

- `src/vyatta-vxlan` — `capture_live_snapshot()` completeness/consistency check (before any delete): identity (both families), MAC, MTU, description, address collection (status-checked), bridge membership/cost/priority, admin state. Rollback uses the canonical snapshot values; optional: `create_vxlan()` omits empty `local`/`remote` arguments (only if the rollout needs to represent externally created devices; otherwise fail closed).
- Identity-aware leaf guard (RB-4, contingent on the Phase 1 ordering observation): when a commit both changes identity and touches mutable leaves, no leaf handler may mutate the live interface before the parent reconciler snapshots. Implementation: each mutable handler (mtu `update`/`delete`, address `create`/`delete`, `disable` `update`, bridge-group `end`) first asks the helper whether the desired identity matches the live identity; if it does not, the handler no-ops and the reconciler recreates in order and applies everything. If Phase 1/7 shows leaves never run before the parent on combined changes, the guard is optional and the rollback claim is explicitly scoped to **snapshot-time state** instead.
- Tests: `U-SNAP-*`, `U-RB-*`, `U-FAILCLOSE-*`, `U-LEAF-*`, mocked failure scenarios (test plan Layer B).

**Required transitions** (the transition set required by the investigation brief): same-config v4, changed v4, same-config v6, changed v6, v4→v6, v6→v4, and a failed instance of each family transition — plus one **combined** change per family (identity + MTU/address/bridge in a single commit). For every failure case the test asserts the live interface is restored with: family, endpoints, VNI, port, MAC, MTU, addresses, description, bridge membership, bridge cost/priority, admin state. **Scope of the claim:** the snapshot restores what was captured at snapshot time; the pre-commit-state guarantee holds only in so far as the leaf-handler guard (or the Phase 1 ordering observation) excludes pre-snapshot mutations. The interface **index** is not preserved by recreation (IM-1) — tests assert that explicitly rather than assuming it.

**Failure modes:** a snapshot that is complete but *belongs to a different device type* (kind check retained); rollback itself failing (existing exit-2 path retained and messaged); rollback re-adding addresses that the kernel reports in a non-canonical form; leaf handlers mutating state between the snapshot and the recreation (RB-4).

**Completion criteria:** no code path can delete a live VXLAN unless a complete, status-checked snapshot exists; the RB-4 question is answered (guard implemented, or ordering demonstrated and the claim scoped); all mocked failure scenarios pass.

---

## Phase 6 — Test harness and CI

**Files**

- `test/run.sh` (runner) — consolidates the suites and mocked scenarios that Phases 3–5 build up incrementally, completes any remaining Layer-B scenarios, and is wired into CI here.
- Additional coverage required by the review: `U-V4-NC-*` (non-canonical IPv4), the extended `U-SNAP-*` (failed component reads), `U-LEAF-*` (identity-guard behaviour), `U-DEF-*` (reconciler-side validation), `U-IFIDX-*` (index-semantics assertions), and the deterministic failure-injection scenarios (`H-FAILINJ-*`).
- Test-enabling change (inventory C1, required for Layer B): make `${brctl:-/usr/sbin/brctl}`, `${modprobe:-/sbin/modprobe}`, `${sysfs_root:-/sys}` overridable in **both** reconciler scripts and route all helper invocations through the existing lowercase `vyatta_sbindir` override (`src/vyatta-vxlan:12`), matching the `:247` call site (today `vyatta-vxlan-bridge` is hardcoded at `:267` and `vyatta-address` at `:259`/`:361`). Apply the same treatment to `src/vyatta-vxlan-bridge`; the complete call-site list (both scripts) is in the test plan's mocked-harness section. Defaults unchanged.
- `.github/workflows/release-validation.yml` — run the test suite before packaging.
- `scripts/validate-release.sh` — optional: assert the helper is present in the `.deb`.
- `README.md` — short "Running the tests" section.

**Failure modes:** tests depending on the host's iproute2/kernel (must not — the mocked layer and unit layer are distribution-independent); floating fixtures (pin exact expected strings); tests that pass because the harness swallowed a failure (runner must propagate exit codes; `set -e` in the runner).

**Completion criteria:** CI green on a machine with only sh/perl/shellcheck; the namespace probe remains documented as an optional manual layer, never a release gate.

---

## Phase 7 — Hardware integration testing

Execute the test plan §5 (D1–D2) and fill in the acceptance matrix — including the Revision 2 rows: combined property+identity change, failed snapshot reads (mocked), partial mutable-state application, interface-index observation, dynamic IPv6 boot, firewall-on-existing-policy, and the deterministic VNI-collision rollback injection. The Phase 1 probes (IPv4 literal parsing, default semantics, handler ordering, oversized-packet capture) are repeated here as release evidence. No implementation work is planned here; failures loop back to Phases 2–5 with a regression test added for whatever escaped. Completion criteria: every matrix row has a status backed by raw evidence; the README's "Tested behavior" list is updated with only what was actually observed.

---

## Phase 8 — Documentation and release preparation

**Files:** `README.md` (examples, config tree, MTU guidance, security example with `firewall ipv6-name`, `ip -j` note, limitations list, tested behavior); `debian/changelog`; release artifacts (`install.sh` pins, `SHA256SUMS`) only when authorized; optionally `docs/` updates with the Phase 1/7 captures.

**Release mechanics (recommendation):** bump both packages to the new version so the existing `edgeos-vxlan-kmod (= ${binary:Version})` dependency stays valid; assert that the packaged module hashes still match `scripts/validate-release.sh` (`vxlan.ko 7c346342…`, `udp_tunnel.ko 6d58ee59…`) so the kernel payload is provably unchanged. Update installer pins only at release time; do not point the installer at a branch. Upgrade from v0.2.1 must preserve existing IPv4 configurations; removal safeguards must remain intact (test plan rows 22–23).

**Authorization gates:** Phase 7 requires device access; releasing requires the maintainer's explicit go-ahead. Neither is implied by this plan.

---

## What must not be done (guard rails)

- Do not rebuild, replace, or "clean up" the kernel modules or the CVE-2022-50405 patch.
- Do not change the `dpkg-divert` model, hash pins, or compatibility checks.
- Do not add a `dev` argument or auto-MTU logic to `ip link add`.
- Do not introduce new runtime dependencies (Python, `ipcalc`, CPAN modules are unnecessary; `Socket`/`JSON::PP`/`NetAddr::IP` already exist on the target).
- Do not change IPv4 acceptance, comparison, defaults, or rollback semantics beyond the mechanical canonicalization (canonical dotted-quad round-trips identically). For non-canonical IPv4 literals, never canonicalise to a different value than the platform's own parser would bind (leading-zero octets are octal in glibc/iproute2): emulate platform parity exactly or reject with an explicit message (RB-6); no silent decimal reinterpretation.
- Do not claim rollback fidelity beyond its demonstrated scope: restore-what-was-snapshotted (RB-2) and, until the leaf-guard/ordering question is settled, no claim of pre-commit-state restoration under combined changes (RB-4).
- Do not rely on outer IPv6 fragmentation or on PMTU feedback to make an over-sized tunnel work — size the MTU correctly (RB-3).
- Do not extend the feature beyond the fixed-remote, point-to-point scope (no EVPN, FDB management, multicast, multi-VTEP).
- Do not claim hardware validation before Phase 7 produces evidence.
