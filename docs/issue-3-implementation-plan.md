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

**Release gate — Phases 2–5 ship together.** The phase split exists for reviewability (separate commits), not for deployment: an intermediate build that accepts IPv6 endpoints before the parsing, canonical comparison, MTU, and fail-closed changes land would exhibit exactly the hazards described in `docs/issue-3-ipv6-assessment.md` §8 (B1–B4). Keep Phases 2–5 in one pull request and do not install intermediate builds on a router.

Each phase must leave `main` green: `sh -n` + shellcheck + `git diff --check` + the new test suite, all runnable off-hardware. Test layers grow with the phases: Phases 3–5 add the Layer-A unit tests and build up the Layer-B mocked harness (including the C1 overrides); Phase 6 consolidates the runner, completes any remaining mocked scenarios, and wires CI.

---

## Phase 1 — Capability verification (no code; device)

**Why first:** every design decision below rests on two target facts — the shipped module can carry IPv6 VXLAN, and the target `ip` prints `local6`/`remote6` JSON keys. Both are backed by binary/source evidence already; this phase closes the remaining gap cheaply before code is written.

**Steps (in order, on a router that can spare a test VNI):**

1. Read-only inventory: `uname -a`, `cat /etc/version`, `lsmod | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)'`, `modinfo vxlan`, `ip -Version`, `ip -j -d link show dev <existing vxlan>`.
2. One-shot manual creation on a spare VNI *outside* the EdgeOS configuration system (so no config is touched):
   `sudo ip link add dev vxlan900 type vxlan id 900 local <v6> remote <v6> dstport 4789`
   then `ip -j -d link show dev vxlan900`, then `sudo ip link del dev vxlan900` (delete it in all cases, including on failure, and finish by confirming no `type vxlan` devices remain — a left-behind `vxlan900` blocks `edgeos-vxlan-kmod` removal per `debian/edgeos-vxlan-kmod.prerm:6`).
3. Capture and store the raw JSON, plus the interface's `-d` text form.
4. Optional (hardware-free alternative): execute the extracted target `/sbin/ip` under `qemu-mipsel-static -L <rootfs>` to reproduce the target's JSON formatting (see test plan §D3).

**Files:** none. Record results (with raw output) in a document/issue comment; if the capture differs from the assumed shape, adjust the Phase 3 fixtures before coding.

**Completion criteria:** module dependency chain loads; IPv6 VXLAN device is created; JSON contains `local6`/`remote6` (or the deviation is documented and the design is adjusted).

**Failure modes / escalation:** `ip` refuses IPv6 (contradicts upstream evidence) → stop and re-open capability analysis; JSON keys differ → adapt the parser contract and fixtures, then continue.

---

## Phase 2 — Endpoint validation

**Files**

- `src/vyatta-vxlan-addr` — new helper, installed to `/opt/vyatta/sbin/`; Perl; core modules only (`Socket` for `inet_pton`/`inet_ntop`, `JSON::PP` in Phase 3); shebang `#!/usr/bin/perl`; GPL-2.0-only header consistent with the project.
- `templates/interfaces/vxlan/node.tag/local-ip/node.def` — `type: ipv4,ipv6`; replace the `/opt/vyatta/sbin/local_ip` warning call with the helper's family-aware check; help text updated.
- `templates/interfaces/vxlan/node.tag/remote-ip/node.def` — `type: ipv4,ipv6`; help text updated.
- `templates/interfaces/vxlan/node.def` — one additional `commit:expression: exec` calling `check-endpoints` with `$VAR(./local-ip/)` and `$VAR(./remote-ip/)`.
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
vyatta-vxlan-addr equal <a> <b>                  -> exit 0 iff byte-identical
vyatta-vxlan-addr default-mtu v4|v6              -> 1450|1430
vyatta-vxlan-addr parse-live                     -> parse `ip -j -d link show` JSON on stdin
```

**Validation rules**

- IPv4: exactly today's acceptance (`type: ipv4`) plus the existing "warning if not present on the system" behaviour used for `local-ip` (implemented family-aware; a warning, not a rejection, matching v0.2.1).
- IPv6: literal required (no prefix, no hostname, no zone id); permitted classes for endpoints: global unicast and ULA (`fc00::/7`); rejected: link-local (`fe80::/10`), multicast (`ff00::/8`), unspecified (`::`), loopback (`::1`), IPv4-mapped (`::ffff:0:0/96`).
- Family consistency is enforced for both families. The IPv6 class rules above apply to IPv6 endpoints only; IPv4 keeps today's acceptance exactly (any valid `ipv4` literal, warning-only local check). The kernel-derived extra restrictions (local not multicast, remote not unspecified) are likewise applied only where they do not narrow existing IPv4 behaviour — i.e., to IPv6 endpoints.
- Errors must name the offending value and the reason; exit non-zero so the commit aborts with EdgeOS's usual message.

**Failure modes:** engine quoting of `$VAR(...)` inside `commit:expression`/`syntax:expression` (use single-quoted arguments; the values are already validated literals — keep the helper free of shell interpolation); using the wrong output stream — checks invoked from `syntax:expression`/`commit:expression` must print the user-visible reason on **stdout** and exit non-zero (this matches the stock convention, e.g. the `mtu` platform-cap check in this very template emits its message with `echo`), while handler/reconciler diagnostics use **stderr** (as the existing scripts do); `local_ip` semantics changing for IPv4 (must not).

**Tests:** test plan §A1 (`U-V4-*`, `U-V6-*`, `U-MIX-*`, `U-CLS-*`, `U-MAL-*`, `U-EMPTY-1`), `U-TPL-*` structural checks.

**Completion criteria:** helper + templates land; all unit tests pass; the package installs the helper; an IPv4 config validates and commits exactly as before (mocked/unit level); template diff reviewed line by line; the phase is **not** released on its own (see the release gate in §0).

---

## Phase 3 — Live-state parsing and canonical identity

**Files**

- `src/vyatta-vxlan-addr` — `parse-live` (stdin JSON → one tab-separated line).
- `src/vyatta-vxlan` — `get_live_vxlan_identity()` becomes a thin call to the helper; the recreate decision consumes canonical values.
- `test/fixtures/` — IPv4 and IPv6 JSON fixtures (synthetic first; the Phase 1 capture added with addresses redacted).
- `test/` — parsing and canonicalization suites (test plan §A2, §A3).
- `src/vyatta-vxlan` — route the interface-address comparison (`contains_address()`, lines 130–142, called at :252/:258) through the same canonical form (ADJ-1): canonicalize the literal part and compare the prefix length separately, so a non-canonically spelled overlay address no longer re-triggers `vyatta-address add` and a prefix-only change is still detected; add the `U-ADDR-*` tests.

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

- `src/vyatta-vxlan` — MTU resolution (lines 397–401) becomes: explicit `mtu` if the node exists, else `default-mtu <family>`; application point at lines 230–234 unchanged.
- `templates/interfaces/vxlan/node.tag/mtu/node.def` — remove the static `default: 1450`; keep the range/platform checks; the `delete:` handler restores the family-aware default. Preferred: compute it with `vyatta-vxlan-addr default-mtu <family>` and set it directly — this avoids depending on engine handler ordering, which is not source-verified (Q3). Invoking the reconciler with a non-delete action is the fallback.
- Tests: `U-MTU-*`, `U-IDEM-*`, mocked recreation suite (test plan Layer B).

**Deliberate non-changes:** do not add a `dev` argument to `ip link add` (would change IPv4 MTU derivation/clamping and couple creation to underlay state); do not add MTU auto-discovery; do not alter the default for IPv4 (still 1450 when unset).

**Failure modes:** forgetting the `delete` path (interface keeps a stale MTU); the engine making `node_exists mtu` true for unset nodes. The static template default is removed, so this can now only happen if the engine synthesises the value from elsewhere — but note that the MTU resolution at `src/vyatta-vxlan:397–401` still keys off `node_exists mtu`, which is the one remaining dependency on that behaviour; verify in Phase 1/7 (Q2). A user relying on the old visible default — documented.

**Completion criteria:** mocked tests prove: unset MTU + IPv6 family → 1430; unset + IPv4 → 1450; explicit value always wins; deleting an explicit MTU restores the family default; idempotent commits still untouched.

---

## Phase 5 — Rollback hardening

**Files**

- `src/vyatta-vxlan` — `capture_live_snapshot()` completeness/consistency check (before any delete); rollback uses the canonical snapshot values; optional: `create_vxlan()` omits empty `local`/`remote` arguments (only if the rollout needs to represent externally created devices; otherwise fail closed).
- Tests: `U-SNAP-*`, `U-RB-*`, `U-FAILCLOSE-*`, mocked failure scenarios (test plan Layer B).

**Required transitions** (the transition set required by the investigation brief): same-config v4, changed v4, same-config v6, changed v6, v4→v6, v6→v4, and a failed instance of each family transition. For every failure case the test asserts the live interface is restored with: family, endpoints, VNI, port, MAC, MTU, addresses, description, bridge membership, bridge cost/priority, admin state.

**Failure modes:** a snapshot that is complete but *belongs to a different device type* (kind check retained); rollback itself failing (existing exit-2 path retained and messaged); rollback re-adding addresses that the kernel reports in a non-canonical form (addresses are outside this issue's scope but are covered by the existing behaviour and `U-RB` tests where practical).

**Completion criteria:** no code path can delete a live VXLAN unless a complete snapshot exists; all mocked failure scenarios pass.

---

## Phase 6 — Test harness and CI

**Files**

- `test/run.sh` (runner) — consolidates the suites and mocked scenarios that Phases 3–5 build up incrementally, completes any remaining Layer-B scenarios, and is wired into CI here.
- Test-enabling change (inventory C1, required for Layer B): make `${brctl:-/usr/sbin/brctl}`, `${modprobe:-/sbin/modprobe}`, `${sysfs_root:-/sys}` overridable in **both** reconciler scripts and route all helper invocations through the existing lowercase `vyatta_sbindir` override (`src/vyatta-vxlan:12`), matching the `:247` call site (today `vyatta-vxlan-bridge` is hardcoded at `:267` and `vyatta-address` at `:259`/`:361`). Apply the same treatment to `src/vyatta-vxlan-bridge`; the complete call-site list (both scripts) is in the test plan's mocked-harness section. Defaults unchanged.
- `.github/workflows/release-validation.yml` — run the test suite before packaging.
- `scripts/validate-release.sh` — optional: assert the helper is present in the `.deb`.
- `README.md` — short "Running the tests" section.

**Failure modes:** tests depending on the host's iproute2/kernel (must not — the mocked layer and unit layer are distribution-independent); floating fixtures (pin exact expected strings); tests that pass because the harness swallowed a failure (runner must propagate exit codes; `set -e` in the runner).

**Completion criteria:** CI green on a machine with only sh/perl/shellcheck; the namespace probe remains documented as an optional manual layer, never a release gate.

---

## Phase 7 — Hardware integration testing

Execute the test plan §5 (D1–D2) and fill in the acceptance matrix. No implementation work is planned here; failures loop back to Phases 2–5 with a regression test added for whatever escaped. Completion criteria: every matrix row has a status backed by raw evidence; the README's "Tested behavior" list is updated with only what was actually observed.

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
- Do not change IPv4 acceptance, comparison, defaults, or rollback semantics beyond the mechanical canonicalization (canonical dotted-quad round-trips identically; note the stock `ipv4` validator's regex also accepts zero-padded octets such as `010.1.2.3` — `TypeChecker.pm:79–84` — so the canonical comparison must treat such spellings consistently; covered by unit tests).
- Do not extend the feature beyond the fixed-remote, point-to-point scope (no EVPN, FDB management, multicast, multi-VTEP).
- Do not claim hardware validation before Phase 7 produces evidence.
