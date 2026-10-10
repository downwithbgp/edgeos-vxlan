# Issue #3 — IPv6 VXLAN Underlay: Change-Impact Inventory

**Baseline:** `dc99bce4a1bcfc5d57daed7fc167e98df4441e81` (v0.2.1)
**Read with:** `docs/issue-3-ipv6-assessment.md` (evidence and rationale), `docs/issue-3-implementation-plan.md` (ordering), `docs/issue-3-test-plan.md` (test IDs referenced below).
**Note:** none of these changes have been implemented yet; this is the proposed change set.
**Revision 2 (post-review):** incorporates the maintainer review of 2026-10-10; the classification in §3 is aligned with `docs/issue-3-implementation-plan.md` §0.1.

## 1. Directly affected files

| # | File | Current behavior (refs) | IPv6-specific problem | Proposed change | Regression risk | Required tests |
|---|---|---|---|---|---|---|
| 1 | `templates/interfaces/vxlan/node.tag/local-ip/node.def` | `type: ipv4` (line 1); `syntax:expression` calls IPv4-only `/opt/vyatta/sbin/local_ip` and only warns when the address is missing (lines 4–6) | Rejects every IPv6 literal; would print a bogus "doesn't exist" warning for a valid IPv6 address | `type: ipv4,ipv6` (stock dual-family idiom); replace the helper call with the new family-aware endpoint check (`vyatta-vxlan-addr check-endpoint local …`), keeping the warning semantics for a valid-but-absent address | Low — canonical IPv4 acceptance and the warning behaviour are unchanged; non-canonical literals follow the RB-6 policy | U-V4-* , U-V6-*, U-MIX-*, U-MAL-* (unit); H-REG-1 (hardware) |
| 2 | `templates/interfaces/vxlan/node.tag/remote-ip/node.def` | `type: ipv4` (line 1) | Rejects IPv6 literals | `type: ipv4,ipv6`; help text updated ("Remote VXLAN VTEP address (IPv4 or IPv6)") | Low — canonical IPv4 acceptance unchanged; non-canonical literals follow the RB-6 policy | same as row 1 |
| 3 | `templates/interfaces/vxlan/node.def` (parent) | Requires `vni`/`local-ip`/`remote-ip` (lines 10–17); `end:` handler (line 19); no cross-child family check | A mixed-family config is accepted at commit validation time and only fails later inside `ip link add`, after the old interface may have been deleted | Add one `commit:expression: exec` that calls the helper's `check-endpoints` on the *value* references `$VAR(./local-ip/@)` and `$VAR(./remote-ip/@)` (same family; permitted IPv6 classes); implemented on `remote-ip/node.def` with `$VAR(../local-ip/@)`. **Assumption (Q3):** commit-time validations run before node handlers on this engine, so a bad commit fails without side effects — to be confirmed in Phase 7 | Low — IPv4-only configs satisfy the check trivially | U-MIX-*, U-CLS-*, H-VAL-* |
| 4 | `templates/interfaces/vxlan/node.tag/mtu/node.def` | `default: 1450` (line 14); `update:` sets value directly (line 16); `delete:` resets to literal `1450` (line 18) | A tunnel without an explicit `mtu` gets 1450 over an IPv6 underlay; 1520-byte outer packets on a 1500 path are **not** fragmented (isolated probe + 4.14 source): the first packets are lost and recovery depends on PMTU feedback/inner fragmentation | Preferred (IM-6): keep `default: 1450` and detect explicit-vs-default with the engine's `existsActive`/`returnActiveValue` (Phase 1 probe); apply the family default in the reconciler when the value is not explicit. Fallback: remove the default. The `delete:` handler restores the family-aware default (helper `default-mtu`); `update:` stays the explicit-set path | Medium — visible defaulting behaviour; for IPv4 the computed default stays 1450; the deletion path and the Phase 1 probe must be verified | U-MTU-*; H-MTU-1..4 |
| 5 | `src/vyatta-vxlan` — `get_live_vxlan_identity()` | Reads `info_data.{id,local,remote,port|dstport}` (lines 179–196); emits `kind ⇥ id ⇥ local ⇥ remote ⇥ port` (line 198) | For IPv6 tunnels the target emits `local6`/`remote6`; all endpoint fields come back empty → identity mismatch on every commit | Move/replace parsing with the helper's `parse-live` (stdin JSON → complete canonical identity line). Read `local`/`local6`, `remote`/`remote6`; reject inconsistent/partial combinations | Medium — shared by v4 and v6 paths; must be fixture-verified | U-PARSE-1..10 |
| 6 | `src/vyatta-vxlan` — identity comparison | Raw string comparison of `OLD_{VNI,LOCAL_IP,REMOTE_IP,PORT}` vs config values (lines 436–441) | Even with parsing fixed, alternate IPv6 spellings produce a false identity change → unnecessary recreation on idempotent commits | Canonicalise configured and live endpoints through the helper and compare canonical values (binary-equivalent text) | Medium — comparison logic also gates the v4 path; canonical form of an IPv4 dotted-quad is unchanged | U-CANON-1..6, U-IDEM-* |
| 7 | `src/vyatta-vxlan` — `capture_live_snapshot()` | Stores `OLD_LOCAL_IP`/`OLD_REMOTE_IP` from the (v4-only) identity (lines 295–300); accepts empty fields | Rollback cannot rebuild an IPv6 tunnel; empty values silently degrade the snapshot | Store the canonical endpoints and family from `parse-live`; every component read must be status-checked and the address collection must use explicit captures (RB-2; see rows 11 and 19) | Medium — snapshot feeds rollback only | U-SNAP-*, U-RB-*, U-FAILCLOSE-* |
| 8 | `src/vyatta-vxlan` — `rollback_live_snapshot()` | Recreates from `OLD_*` via `create_vxlan` (lines 349–354) | Same as row 7, from the consuming side | No structural change beyond using the (now complete) snapshot values; optionally make `create_vxlan` omit empty `local`/`remote` arguments for externally created devices | Low | U-RB-*, H-RB-* |
| 9 | `src/vyatta-vxlan` — recreate decision | `RECREATE=1` when any identity component differs, or when the interface is absent (lines 429–444) | With rows 5–6 fixed, behavior is correct for both families; without them, every commit recreates | Keep logic; feed it canonical values; add explicit family to the compared tuple so v4↔v6 transitions are always recognised | Low | U-ID-1..10, H-TRANS-* |
| 10 | `src/vyatta-vxlan` — MTU resolution | `MTU=$(node_value mtu)` else `1450` (lines 397–401); applied at lines 230–234 | IPv4-oriented default | Resolve: explicit `mtu` wins; otherwise helper `default-mtu <family>` → `1450` (v4) / `1430` (v6) | Medium — see row 4 | U-MTU-*; H-MTU-* |
| 11 | `src/vyatta-vxlan` — fail-closed snapshot | `capture_live_snapshot` returns 1 only for "live device is not a VXLAN" (lines 302–305); empty fields pass; the address loops use process substitution whose failures are swallowed (demonstrated: `while read … done < <(false)` continues with status 0) | A partially parsed live interface would be deleted and could not be restored; addresses can be silently missed | Require: `kind == vxlan`, non-empty `id`/`port`, endpoints per the family rules; status-checked reads for MAC/MTU/description/addresses/bridge/admin; any failure aborts **without deleting** (RB-2) | Low (turns a dangerous path into a refusal) | U-FAILCLOSE-1..4, U-SNAP-4..7 |
| 12 | `src/vyatta-vxlan` — module loading | `modprobe udp_tunnel; ip6_udp_tunnel; vxlan` (lines 425–427) | None — already loads the IPv6 dependency | No change | — | H-BOOT-* |
| 13 | `src/vyatta-vxlan-addr` — **new file** (~150 lines, Perl; installed to `/opt/vyatta/sbin/`) | — | — | One helper providing: `family`, `check-endpoint`, `check-endpoints`, `canon`, `canon-v4` (platform-parity or explicit error), `equal`, `present`, `default-mtu`, `parse-live` (JSON in → identity out), `identity-matches` (leaf-guard support); exit-code contract 0/1/2. Uses only core `Socket` + `JSON::PP` (both present on the target) | Low — new, self-contained; used by templates and the reconciler | U-* (all unit suites), U-PARSE-* |
| 14 | `debian/edgeos-vxlan.install` | Installs `src/vyatta-vxlan`, `src/vyatta-vxlan-bridge`, `src/Interface.pm`, templates (4 lines) | A new helper would not be packaged | Add `src/vyatta-vxlan-addr opt/vyatta/sbin/` | Low | CI package-content check |
| 15 | `debian/changelog` | Ends at 0.2.1 | New feature needs a version entry | New entry describing IPv6 underlay support (kept at the repository's versioning style) | Low | `scripts/validate-release.sh` version checks |
| 16 | `README.md` | Documents IPv4-only underlay (examples lines 7–22, 212–255; config tree 307–343; MTU notes 339–343; security 528–577; limitations line 829; tested behavior 773–816) | Docs would be wrong/misleading (MTU, examples, security syntax, limitation) | Update: IPv6 examples; family-aware MTU guidance (1430 = standard 1500-byte path, not universal; no reliance on fragmentation); IPv6 firewall example **including the existing-local-policy case**; `ip -j` IPv6 JSON note; remove "IPv6 underlay" from limitations; document the endpoint restrictions (link-local/multicast/unspecified-remote/loopback/v4-mapped rejected; unspecified local allowed; fixed-remote only) and the IPv4 literal policy; note the fail-closed behaviour change for unparseable live devices (ADJ-3); add new test results; keep the "tested on" statement honest until hardware validation happens | Low | Docs review; H-* evidence recorded |
| 17 | `.github/workflows/release-validation.yml` | `sh -n` + shellcheck + `git diff --check` + build + release validation (lines 44–58) | New unit-test suite would not run in CI | Add a job/step running the new tests (host-side, no device) and the helper's own syntax checks | Low | CI green |
| 18 | `test/` — **new directory** | No tests exist in the repository | Feature must be testable off-hardware | Fixture-based suites + a runner script (see test plan): validation/canonicalization, JSON parsing fixtures, mocked reconciliation scenarios, deterministic failure injection, non-canonical IPv4 policy, snapshot-read failures | Low | itself |
| 19 | `src/vyatta-vxlan` — reconciler-side validation | No self-validation; it trusts the template layer (lines 170–200 consumers) | If the reconciler runs without commit validation (direct invocation, engine quirks), invalid or mixed endpoints reach `ip link add` after a delete | Call `vyatta-vxlan-addr check-endpoints` on the desired values at reconciliation start, before any mutation (RB-7) | Low | U-DEF-1..2 |
| 20 | `templates/.../{mtu,address,disable,bridge-group}/node.def` (leaf handlers) | Leaf handlers mutate live state directly (mtu `update` line 16; address `create`/`delete` lines 12/14; disable lines 3–5; bridge-group `end` line 4) | On a combined identity+mutable commit, leaves may mutate the old interface before the parent snapshot, so rollback would restore the mutated state | Contingent on the Phase 1 ordering probe: identity-aware leaf guard (a helper `identity-matches` check; no-op while an identity change is pending) or scope the rollback claim to snapshot-time state (RB-4) | Medium — engine behaviour unverified | U-LEAF-*, H-ATOM-1 |

## 2. Files explicitly unchanged (with reasons)

| File / area | Reason |
|---|---|
| `src/vyatta-vxlan-bridge`, `templates/.../bridge-group/**` | Bridge logic operates on the Ethernet netdevice (`brctl` + `/sys/class/net/*/brport`); no underlay-family interaction. Verified by code read. Known pre-existing limitation (not addressed in this pass): this script's own `get_live_bridge()` still treats an unreadable `brport/bridge` link as "not bridged"; the snapshot-side copy in `src/vyatta-vxlan` fails closed. |
| `templates/.../address/node.def` | Already `type: ipv4net,ipv6net` and uses family-aware `/opt/vyatta/sbin/vyatta-address`. |
| `templates/.../{description,disable,vni,port}/node.def` | Family-independent. |
| `src/Interface.pm`, `upstream/libvyatta-cfg1/Interface.pm` | Interface-name recognition only; hash-pinned by `preinst`. |
| `modules/4.14.54-UBNT/vxlan.ko`, `.../udp_tunnel.ko`, `patches/4.14.54-UBNT/CVE-2022-50405.patch` | Already IPv6-capable; patch is family-agnostic (covers v6 teardown). Must remain byte-identical. |
| `debian/control` | Dependency set is still correct. Note: because the integration package depends on `edgeos-vxlan-kmod (= ${binary:Version})` (line 17), any release that bumps one package bumps both in lockstep — but the kmod **payload bytes** stay identical. |
| `debian/edgeos-vxlan-kmod.*`, `debian/edgeos-vxlan.{preinst,prerm,postrm}`, `debian/rules`, `upstream/**` | Packaging model, diverts, guards, and hash pins are unaffected by this feature. |
| `scripts/validate-release.sh`, `scripts/validate-published-release.sh` | Module hashes remain the same; no new pinned artifact unless a release decision says otherwise (see implementation plan Phase 8). |
| `install.sh`, `SHA256SUMS` | Updated only at release time, when new package hashes exist; the pinned-installer model is preserved (no branch installs). |

## 3. Findings classification (Revision 2, aligned with the implementation plan §0.1)

**Release-blocking (RB-* — the feature is not done until these are resolved and evidenced)**

| ID | Item | Rows |
|---|---|---|
| RB-1 | Live identity parsing (`local6`/`remote6`) + canonical comparison | 1–3, 5, 6 |
| RB-2 | Status-checked, complete live-state capture (no silent process-substitution failures) | 7, 11 |
| RB-3 | Family-aware MTU default + corrected guidance (no reliance on outer fragmentation) | 4, 10, 16 |
| RB-4 | Rollback fidelity under combined changes (Phase 1 probe → guard or scoped claim) | 20 |
| RB-5 | Deterministic failure injection in the rollback tests | 18 + test plan §B/§D |
| RB-6 | IPv4 literal policy (platform parity or explicit rejection) | 1, 13 |
| RB-7 | Reconciler-side defence-in-depth validation | 19 |

**Implementation improvements (IM-*)**

- IM-1: interface-index semantics documented and asserted (test plan `H-IFIDX-1`).
- IM-2: dynamic-address boot rows (SLAAC/DHCPv6).
- IM-3: per-step mutable-state failure tests (mocked).
- IM-4: firewall guidance for interfaces that already have a local IPv6 policy attached.
- IM-5: interface-address canonical comparison (ADJ-1) folded into Phase 3.
- IM-6: default-materialisation investigation (`existsActive`), keeping the template default as the preferred variant.

**Important adjacent defects (ADJ-*)**

- ADJ-1: `contains_address()` (`src/vyatta-vxlan:130–142`, called at :252 and :258) compares interface addresses as raw strings. For an IPv6 *overlay* address (already supported) written in a non-canonical spelling, the live value from `ip -o addr` is canonical, the comparison fails, and the reconciler re-issues `/opt/vyatta/sbin/vyatta-address add` (:259). The stock `/opt/vyatta/sbin/vyatta-address` then runs `ip -6 addr add` for an address that already exists, which is expected to fail with `EEXIST` and cause a failed commit; on the non-recreate path (:490) there is no rollback. This is a pre-existing defect, not caused by the underlay feature, but its impact was initially understated here. **Fold the canonical comparison into Phase 3 unconditionally (IM-5).** The failure mode does not need hardware to confirm: in the target firmware the stock helper's IPv6 branch is `exec ip -6 addr add "$3" dev "$2"` with no existence pre-check (`/opt/vyatta/sbin/vyatta-address:22–26`), so a live-but-textually-different address reaches `ip -6 addr add` and fails.
- ADJ-2: the `local_ip` warning helper is IPv4-only; it is superseded for both families by the new endpoint check, so it disappears with RB-1/row 1 for this node (no separate issue needed).
- ADJ-3: `create_vxlan()` cannot recreate a live VXLAN created externally without a local endpoint (no `local` argument). The fail-closed snapshot turns this into a refusal instead of an unfaithful rollback; supporting it (conditional arguments) is optional.
- ADJ-4: the `mtu` `syntax:expression` caps at `ubnt-hal getMtu` (platform max) but nothing validates against the *underlay* path MTU; document-only (row 16), no code.

**Optional / enabling (OP-*, C-*)**

- C1 (**enabling — required for the mocked test layer**, not merely optional for Phase 6): make the absolute command paths and the sysfs root overridable in **both** `src/vyatta-vxlan` and `src/vyatta-vxlan-bridge` (call sites listed in the test plan's mocked-harness section and the implementation plan Phase 6) so Layer B can run without touching real `/sys` or `brctl`; no behaviour change when the variables are unset.
- C2: extend `scripts/validate-release.sh` to assert the helper is present in the integration package — cheap CI hardening.
- C3: record handler execution order during Phase 7 and annotate the README's reconciliation section with observed evidence.
- OP-1: platform-parity octal emulation for IPv4 literals — only if the Phase 1 target probe shows a stable, unambiguous parser (otherwise the reject-with-message policy stands).
- OP-2: snapshot journaling (write the captured snapshot to a file) for post-mortem analysis.

## 4. Release-time changes (only when authorization to release is given)

| Artifact | Change |
|---|---|
| `debian/changelog` | New version, e.g. `0.3.0+edgeos3.0.1.e50` |
| `install.sh` | `VERSION`/`PKG_VERSION` and both SHA-256 pins updated to the new packages |
| `SHA256SUMS` | Regenerated from the built packages |
| GitHub release | Built from a tag; `validate-published-release.sh` must pass |
| Compatibility statements | Only extended if Phase 7 hardware validation passed; no new device/firmware claims otherwise |
| `README.md` tested-behavior list | Append the actually performed hardware tests, with honest status |
