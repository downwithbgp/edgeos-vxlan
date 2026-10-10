# Issue #3 — IPv6 VXLAN Underlay Support: Technical Assessment

**Baseline investigated:** `dc99bce4a1bcfc5d57daed7fc167e98df4441e81` (tag `v0.2.1`, merge of PR #1 `feat/bridge-port-options`)
**Repository:** https://github.com/downwithbgp/edgeos-vxlan — issue #3 "Add IPv6 VXLAN underlay support"
**Target platform:** Ubiquiti EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409, kernel `4.14.54-UBNT`, mipsel
**Status of this document:** investigation and planning only. No production code was modified. No device access, no code pushes, no issue edits.
**Revision 2 (post-review):** incorporates the maintainer review findings of 2026-10-10 — IPv4 literal compatibility, snapshot capture completeness, commit atomicity, deterministic failure injection, revised MTU evidence, defence-in-depth validation, extended tests, firewall deployment guidance, and a citation revalidation against the published `dc99bce` commit. The release-blocking / improvement / optional classification lives in `docs/issue-3-implementation-plan.md` §0.1.

## Evidence legend

Every non-obvious statement below is classified:

- **Verified** — directly established from repository code, shipped binaries, target firmware artifacts, or upstream source at a named revision, or reproduced in an isolated test.
- **Strongly indicated** — supported by primary technical evidence, but not directly exercised on the target hardware.
- **Unverified** — requires access to the device or additional artifacts before it can be relied on.
- **Recommendation** — engineering judgement, not an observed fact.

Evidence sources used:

| Source | Identity |
|---|---|
| Repository | `dc99bce` (v0.2.1), working tree clean |
| Shipped kernel modules | `modules/4.14.54-UBNT/{vxlan.ko,udp_tunnel.ko}` (hashes below) |
| Target firmware | `EdgeRouter.ER-e50.v3.0.1.5862409.250924.1407`; flashing image `ER-e50 v3.0.1` from Ubiquiti's firmware API (`fw-update.ui.com`, product `e50`), tar sha256 `e3d3fe0697bc01d8d9347f3df2b38ce093c2db69f6fa8ea65170270d59a8fb3d`; squashfs md5 verified against the image's own `.md5`; extracted rootfs inspected read-only |
| Upstream kernel | `gregkh/linux` tag `v4.14.54`: `drivers/net/vxlan.c`, `include/net/vxlan.h`, `net/ipv4/udp_tunnel.c`, `net/ipv6/ip6_udp_tunnel.c` |
| Upstream iproute2 | `iproute2/iproute2` tags `v4.9.0`, `v4.13.0`, `v4.14.0`, `v4.15.0`, `v4.20.0`, `v5.10.0`, `v6.1.0`: `ip/iplink_vxlan.c`, `ip/ip.c` |
| Isolated probe | Two-network-namespace VXLAN-over-IPv6 test in a disposable docker container (modern Linux, iproute2 v7.0.0) — **not** EdgeOS validation |
| CVE record | CVE-2022-50405 (MITRE CNA API), upstream fix `3cf7203ca620` |

---

## 1. Executive summary

1. **Feasibility.** IPv6 underlay support is feasible on the existing EdgeRouter X platform and requires **no kernel change**. The shipped `vxlan.ko` already contains the IPv6 code paths and links against the stock `ip6_udp_tunnel` module; the target firmware ships `ip6_udp_tunnel.ko`; the target `ip` binary supports IPv6 VXLAN creation and its JSON output carries `local6`/`remote6` keys (**Verified**: module symbols, stock firmware contents, target `ip` binary strings, upstream 4.14.54 source). The exact JSON text emitted for an IPv6 tunnel is **Strongly indicated** until captured on the device (§5.3, §9).
2. **Kernel module.** No new or rebuilt kernel module is needed. The existing v0.2 `edgeos-vxlan-kmod` payload (including the CVE-2022-50405 backport) remains byte-identical. **Verified.**
3. **Existing IPv4 semantics.** They can be preserved. Nothing in the recommended design changes the meaning of existing IPv4 configuration: the same nodes are extended with an additional accepted address family, and the IPv4 code paths (validation, comparison, MTU default, creation, rollback) keep equivalent behavior. **Recommendation**, with a regression test matrix to prove it.
4. **Most significant risks.** (a) the reconciliation helper presently reads only the IPv4 JSON keys `local`/`remote`, so an IPv6 interface would be misidentified and repeatedly recreated — and the rollback snapshot would lose its endpoints (mandatory fixes); (b) IPv6 textual representations make naive string comparison a false-positive change detector — and EdgeOS additionally accepts non-canonical IPv4 literals whose octal meaning must not be silently reinterpreted (§5.4); (c) the MTU default of 1450 over-sizes IPv6-underlay tunnels, and the outer packets are **not fragmented** by this path: probes show first-packet loss and recovery only through PMTU feedback/inner fragmentation, so 1430 is the default for a standard 1500-byte path (§4.4); (d) live-state capture and rollback contain status-swallowing paths, and leaf handlers may be able to mutate state before the parent reconciler snapshots (target check), so rollback claims are now explicitly scoped (§8).
5. **Readiness.** The repository is ready to begin implementation once the small set of target-capability checks in Phase 1 (Section 8) are executed on the device. Nothing found so far blocks the feature.

**Revision 2 summary (maintainer review).** All nine review findings are reflected in this revision: an IPv4-normalisation policy that never contradicts the platform parser (§5.4, RB-6); snapshot capture that checks every component and propagates failures (RB-2); an explicit atomicity investigation plus a leaf-handler guard or a scoped rollback claim (RB-4); deterministic creation-failure injection for rollback tests (RB-5); a corrected MTU story with measured evidence (RB-3); defence-in-depth validation in the reconciler (RB-7); extended tests (failed snapshot reads, combined changes, partial mutable-state application, interface-index semantics, dynamic-address boot); deployment guidance for underlay interfaces that already carry a local IPv6 policy; and a full citation revalidation against the published commit (one line reference corrected; tree diff empty and line counts exact).

**Confidence:** high on kernel/module capability and on the required userspace changes; medium-high on the exact target JSON output (binary strings + upstream source make it near-certain, but one hardware capture should confirm it before release).

---

## 2. Baseline and method

- HEAD and tag are identical: `dc99bce` = `v0.2.1`. No uncommitted changes existed at investigation time.
- The v0.2.1 tree was audited in full: `src/` (490 + 237 + 472 lines), all 13 configuration templates, Debian packaging, installer, CI workflow, release validators, the CVE patch, and both kernel modules.
- Issue #3 has no body text — it is a one-line feature request. No acceptance criteria were previously defined; `docs/issue-3-acceptance-criteria.md` proposes them.
- The GPL source release named in `README.md` (`GPL.mtk.v3.0.0-rc.9.5753457.tar.bz2`) was **not** downloaded; instead, the final firmware image itself was obtained from Ubiquiti's public firmware API and inspected. This is the stronger artifact: it is the exact firmware the project supports, and every stock-file hash that the repository's packaging scripts claim to expect was checked against it (Section 5.1).
- No functionality was implemented, no module was rebuilt, no router was touched.

---

## 3. Current architecture

### 3.1 Component map

| Path | Responsibility | Family-sensitive? |
|---|---|---|
| `templates/interfaces/vxlan/node.def` | Parent node: name pattern, required-child commit checks, `end:` handler calling the reconciler | No (except endpoint children) |
| `templates/.../node.tag/{vni,port,mtu,address,description,disable,bridge-group*}/node.def` | Leaf templates: validation, defaults, direct (mutable) handlers | `mtu` yes; `address` already dual-family (line 3: `type: ipv4net,ipv6net`); others no |
| `templates/.../node.tag/{local-ip,remote-ip}/node.def` | Underlay endpoints, currently `type: ipv4` (lines 1 and 1 respectively) | **Yes — primary blocker** |
| `src/vyatta-vxlan` (bash, 490 lines) | Reconciliation, identity detection, recreation, snapshot/rollback, MAC derivation, module loading | **Yes** (identity parsing, comparison, MTU default) |
| `src/vyatta-vxlan-bridge` (bash, 237 lines) | Bridge membership, path cost, STP priority, validation | No — uses `brctl` + sysfs only |
| `src/Interface.pm` | Adds `'^vxlan[\d]+$' => { path => 'vxlan' }` to `Vyatta::Interface` (single-line delta to `upstream/libvyatta-cfg1/Interface.pm`) | No |
| `debian/` | Two packages (`edgeos-vxlan`, `edgeos-vxlan-kmod`), diverts, guards, hash pins | No |
| `modules/4.14.54-UBNT/*.ko` | Shipped `vxlan.ko` (sha256 `7c346342…82b6`) and patched `udp_tunnel.ko` (sha256 `6d58ee59…05cc`) | No — already IPv6-capable |
| `patches/4.14.54-UBNT/CVE-2022-50405.patch` | One-line `synchronize_rcu();` in `udp_tunnel_sock_release()` | No — family-agnostic (see 4.5) |
| `install.sh`, `SHA256SUMS`, `scripts/validate-*.sh`, `.github/workflows/` | Release pinning, package validation, CI | No |

### 3.2 Configuration lifecycle

1. **User enters config** — `set interfaces vxlan vxlanN …` (nodes from `templates/interfaces/vxlan/`).
2. **CLI syntax validation** — `type:` checks (stock Vyatta validator, e.g. `ipv4`/`ipv6` regexes in `/opt/vyatta/share/perl5/Vyatta/TypeChecker.pm`), plus `syntax:expression` checks (e.g. `local_ip` warning, `mtu` bounds and `ubnt-hal getMtu` cap).
3. **Commit validation** — `commit:expression` checks: required `vni`/`local-ip`/`remote-ip` (`node.def` lines 10–17), bridge/address mutual exclusions (`address` node line 16, `bridge` node line 11, `cost`/`priority` lines 7–8), bridge port options etc.
4. **Commit handlers run** — leaf `create`/`update`/`delete` handlers may act directly (idempotent by design, `README.md` lines 452–475), then the parent `end:` runs `/opt/vyatta/sbin/vyatta-vxlan "$COMMIT_ACTION" "$VAR(@)"` (`node.def` line 19).
5. **Reconciler reads desired state** — via `/opt/vyatta/sbin/my_cli_shell_api` (`exists`, `returnValue`; `src/vyatta-vxlan` lines 15–25).
6. **Modules loaded** — `modprobe udp_tunnel`, `ip6_udp_tunnel`, `vxlan` (lines 425–427). Note: `ip6_udp_tunnel` is already loaded today.
7. **Interface created** — `sudo ip link add dev NAME type vxlan id VNI local L remote R dstport P` (`create_vxlan`, lines 116–128; no lower-link `dev <link>` argument — the `dev NAME` in the command is the new interface's own name).
8. **Mutable state applied** — MTU, description (`ifalias`), addresses (through the family-aware `/opt/vyatta/sbin/vyatta-address`), bridge membership/cost/priority, admin state (`apply_desired_mutable_state`, lines 224–284).
9. **Config saved** — normal EdgeOS `save` into `/config/config.boot`.
10. **Boot restoration** — standard EdgeOS boot config loader (`/opt/vyatta/sbin/vyatta-boot-config-loader`, `vyatta-load-config.pl` present in firmware) replays the config; parent `end:` recreates the interface (tested for IPv4: `README.md` lines 477–495).
11. **Identity change → controlled recreation** — snapshot (lines 286–337), delete (109–114), create, apply; recreation decision at lines 429–444.
12. **Failure → rollback** — `rollback_live_snapshot` (lines 339–380) recreates the previous live interface including MAC, MTU, description, addresses, bridge state, admin state.
13. **Package removal** — `prerm` guards refuse removal while live interfaces/saved config exist; `postrm` restores diverted files.

```
config CLI ──syntax/commit checks──► config store (cstore)
      │                                    │
      │  commit                            │  boot load
      ▼                                    ▼
 leaf handlers ──┐                 ┌── parent end: handler
 (idempotent)    │                 │      (vyatta-vxlan SET)
                 ▼                 ▼
            /opt/vyatta/sbin/vyatta-vxlan  ── my_cli_shell_api (desired state)
                 │
                 ├── modprobe udp_tunnel, ip6_udp_tunnel, vxlan
                 ├── ip link add  (create/recreate; identity = vni,local,remote,port)
                 ├── ip link set  (mtu, alias, up/down)
                 ├── vyatta-address (v4/v6 addresses)
                 ├── vyatta-vxlan-bridge (bridge port state)
                 └── snapshot / rollback (live identity, MAC, MTU, addresses, bridge)
```

### 3.3 Which parts must be family-aware

**Must be family-aware:** endpoint validation (`local-ip`, `remote-ip`), live-identity extraction, identity comparison, snapshot/rollback endpoints, the MTU default, and the endpoint locality warning.

**Must remain family-independent:** `derive_mac` (name-based), module loading, bridge reconciliation, `Interface.pm`, packaging/diverts, address application (already family-aware), admin state, description.

---

## 4. Kernel capability findings

### 4.1 Linux 4.14.54 supports IPv6 VXLAN underlay — **Verified**

From `gregkh/linux` `v4.14.54`:

- `drivers/net/vxlan.c` `vxlan_config_validate()` (line 2920) accepts `AF_INET6` endpoints, sets `VXLAN_F_IPV6`, and rejects mixed families: *"Local and remote address must be from the same family"* (lines 2953–2957). It also enforces scope rules for link-local local/remote combinations (lines 2979–2997) and rejects a multicast local address (lines 2959–2962).
- Netlink attributes exist for both families: `IFLA_VXLAN_GROUP6` (remote/group, processed at lines 3221–3230) and `IFLA_VXLAN_LOCAL6` (lines 3238–3248).
- Transmit path emits IPv6-encapsulated frames via `udp_tunnel6_xmit_skb()`; receive is handled by `vxlan_rcv()` (line 1331).
- `include/net/vxlan.h` lines 320/322: `VXLAN_HEADROOM = 20+8+8+14 = 50` (IPv4) and `VXLAN6_HEADROOM = 40+8+8+14 = 70` (IPv6).
- `net/ipv6/ip6_udp_tunnel.c` exports `udp_sock_create6` and `udp_tunnel6_xmit_skb`.

### 4.2 The shipped `vxlan.ko` is IPv6-capable — **Verified**

From `modules/4.14.54-UBNT/vxlan.ko` (sha256 `7c346342bf00202820e8581bfdfc28851add052d2b0e5dde1560819f90bf82b6`, matching `scripts/validate-release.sh` lines 60–64):

- `modinfo`: `depends: udp_tunnel,ip6_udp_tunnel`; `vermagic: 4.14.54-UBNT SMP mod_unload MIPS32_R2 32BIT`.
- Undefined symbols include `udp_tunnel6_xmit_skb`, `ip6_dst_hoplimit`, `dst_cache_get_ip6`, `dst_cache_set_ip6`, `__ipv6_addr_type`, `ipv6_stub`.
- String constants include `IPv6 support disabled by administrator` and `Label attribute only applies to IPv6 VXLAN devices` — both are 4.14 IPv6-specific code paths in `vxlan.c`.

The module depends on `ip6_udp_tunnel`; that dependency is satisfiable on the target (4.3).

### 4.3 Target firmware ships the IPv6 tunnel dependency — **Verified**

Extracted from the v3.0.1 firmware:

- `/lib/modules/4.14.54-UBNT/kernel/net/ipv6/ip6_udp_tunnel.ko` — present.
- `/lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko` — present, sha256 `14fbf8c469a7c902ce53d79de581e3e14982a9d52dbc80515d5ab481afb0fa94`, **identical to the hash the repository's `preinst` expects** (`debian/edgeos-vxlan-kmod.preinst` line 7).
- `vxlan.ko` — **absent** (matches `README.md` line 581: the firmware does not ship it).

### 4.4 MTU and outer-packet size — **Verified** (source + isolated probe); target capture pending

- With a lower device known (`dev <link>` passed to the create command, so the kernel can clamp), the kernel derives/clamps `dev->mtu = lowerdev->mtu − headroom`: 1450 for an IPv4 underlay on a 1500-byte path, 1430 for IPv6 (`vxlan_config_apply` lines 3110–3133; `vxlan_change_mtu` lines 2500–2520). The isolated probe reproduced both: with `dev` set the MTU came up at 1430, and raising it to 1450 was rejected (`RTNETLINK answers: Invalid argument`).
- The repository does **not** pass the lower-link `dev <link>` option (`src/vyatta-vxlan` lines 123–127 — the command's `dev "$interface"` argument is the *name of the new interface*, not a lower link). Then `*lower = NULL` (line 3045), no derivation and **no clamp** occurs, and an explicit 1450 is kept as-is.
- **An oversized outer IPv6 packet is not fragmented by this path.** `ip6_fragment()` refuses to fragment locally generated skbs unless `skb->ignore_df` is set (v4.14.54 `net/ipv6/ip6_output.c` lines 626–632 → `fail_toobig` at :880: ICMPv6 Packet-Too-Big + `EMSGSIZE` + `IPSTATS_MIB_FRAGFAILS`), and the VXLAN IPv6 transmit path never sets `ignore_df` (the DF logic in `vxlan.c` lines 2134–2172 is IPv4-only).
- **Probe evidence** (isolated namespaces, modern Linux — **not** EdgeOS): with MTU 1450 on a 1500-byte path, a full-size frame would produce a 1520-byte outer datagram; full-size pings lost packets in every run (2 of 3, then 20 %, then 33 %), `Ip6FragCreates` stayed 0 and `Ip6FragFails` incremented. The capture shows that the 1520-byte datagram never leaves unfragmented: after the first failure, 1512-byte outer frames carry **inner IPv4 fragments** (1428+42 bytes, implying an effective inner MTU of ≈1430 learned from the kernel's own Packet-Too-Big feedback). Recovery therefore comes from inner fragmentation after initial loss, not from outer fragmentation. The 1430 control (outer exactly 1500) was lossless in every run; the IPv4-outer 1450 control was lossless.
- **Recommendation:** default MTU **1430** for an IPv6 underlay on a standard, untagged 1500-byte path (1450 for IPv4); explicit `mtu` is authoritative; 1430 is not universal (VLAN tags subtract 4 bytes each on the outer path, PPPoE 8 bytes, and any non-1500 underlay changes the number — formula and examples in `docs/issue-3-test-plan.md`). Do not rely on outer fragmentation or on PMTU feedback. Phase 7 captures the target's actual behaviour (initial-loss window, recovery, hardware-MAC handling of oversized frames).

### 4.5 CVE-2022-50405 backport and IPv6 — **Verified**

- CVE-2022-50405 is *"net/tunnel: wait until all sk_user_data readers finish before releasing the sock"* — a use-after-free race when a VXLAN device is deleted while packets are being received. The upstream fix is commit `3cf7203ca620`, which adds `synchronize_rcu()` in `udp_tunnel_sock_release()`.
- The repository patch inserts exactly that call at `net/ipv4/udp_tunnel.c:189` (verified against upstream 4.14.54: the insertion point is between `rcu_assign_sk_user_data(sock->sk, NULL)` and `kernel_sock_shutdown()`).
- `udp_tunnel_sock_release()` is family-agnostic, and `vxlan_sock_release()` calls it for both `vn4_sock` and `vn6_sock` (`vxlan.c` lines 1095–1120). **The backport therefore covers the IPv6 teardown path as well.** No further change is required, and the patch must not be modified for this feature.
- `modinfo` on the shipped patched module shows the call materialised as the exported `synchronize_sched` symbol, exactly as `README.md` lines 668–694 describe.

### 4.6 UDP checksum behaviour — **Verified** (source), **Strongly indicated** (target)

- Per-packet TX checksum decision: `udp_sum = !(flags & VXLAN_F_UDP_ZERO_CSUM6_TX)` (`vxlan.c` lines 2096–2099), with the flag unset unless `udp6zerocsumtx`/`udpzero` is configured. Kernel default: **checksum computed**, which is standards-compliant and interoperable.
- RX: `use_udp6_rx_checksums = !(flags & VXLAN_F_UDP_ZERO_CSUM6_RX)` (`vxlan.c` lines 2794–2798) — zero-checksum RX acceptance is opt-in.
- The target `ip` binary advertises `[ [no]udpcsum ] [ [no]udp6zerocsumtx ] [ [no]udp6zerocsumrx ]`; the integration passes none of these, so defaults apply.
- The isolated modern-Linux probe reported `"udp_csum":true, "udp_zero_csum6_tx":false, "udp_zero_csum6_rx":false` for a default IPv6 VXLAN.

**Conclusion (Recommendation):** no kernel change, no new checksum configuration options; do not disable IPv6 UDP checksums anywhere.

---

## 5. Userspace compatibility findings

### 5.1 Target firmware facts — **Verified**

Firmware identity `EdgeRouter.ER-e50.v3.0.1.5862409.250924.1407`.

- **`ip` binary:** `/sbin/ip`, mipsel, from UBNT's own `ubnt-platform` package (`iproute`, version `1:0.1.18+t5862411.er.3.0.1.7989d4f0`, `Provides: iproute2`). It is not a stock Debian package build. Its strings contain the JSON writer (`new_json_obj`, `open_json_object`, `jsonw_*`, `is_json_context`), the `-json` option, and the VXLAN JSON keys **`local6`, `remote6`, `group6`** alongside `local`, `remote`, `group`, `id`, `port`, `info_kind`, `info_data`, `linkinfo`, `dstport`, `port_range`.
- Its `vxlan` usage string includes `local ADDR`, `{ group | remote } IP_ADDRESS`, `dstport PORT`, `[ [no]udpcsum ]`, `[ [no]udp6zerocsumtx ]`, `[ [no]udp6zerocsumrx ]` — i.e. the full modern add-path, and upstream iproute2 ≥ `v4.9.0` already contains the `IFLA_VXLAN_LOCAL6`/`GROUP6` add path (verified in `v4.9.0` and later source).
- `Vyatta::Interface.pm` sha256 `f4985acc53058088bda3ed3b989ed2d76e92a3edd9e2582272ff576dd089f721` — **identical to `debian/edgeos-vxlan.preinst` line 6's expectation.**
- Debian base: `/etc/debian_version` = `9.13`; Perl 5.24.1 with core `Socket.pm` (provides `inet_pton`/`inet_ntop`) and `JSON::PP`; `NetAddr::IP` installed and used by stock scripts (`/opt/vyatta/sbin/check-ipv4-ipv6.pl`, `is_valid_address.pl`).
- Stock templates already use the dual-family literal type in at least 19 nodes, e.g. `system/name-server/node.def:3` (`type: ipv4,ipv6`), `service/ssh/listen-address/node.def:2`, and dual network types in `interfaces/loopback/node.tag/address/node.def:2` (`type: ipv4net,ipv6net`).
- `/opt/vyatta/sbin/vyatta-address` is already family-aware: an argument containing `:` takes the `ip -6 addr add/delete` branch; IPv4 takes `ip addr add … broadcast +`.
- `/opt/vyatta/sbin/local_ip` is an IPv4-only helper (`inet_pton` + `bind` probe; usage string `Usage: %s x.x.x.x`).
- `/opt/vyatta/sbin/my_cli_shell_api` exposes `exists`, `existsActive`, `existsEffective`, `returnValue/Values`, `returnActiveValue(s)`, `returnEffectiveValue(s)`, `listNodes/listActiveNodes/listEffectiveNodes`, `validateTmplPath/ValPath` — and **no** verb for "is this node's value engine-default" was found in its strings.
- Defaults handling in the engine: `Vyatta::Config::isDefault()`/`isDefaultOrig()` (`Config.pm` lines 99–114) and `ConfigOutput.pm` line 132 (`if ($config->isDefault() and !$show_all) { skip }`) show that default-valued nodes can exist in the config store marked as defaults and are hidden unless "show all". `ConfigLoad.pm` lines 393–407 filters deletions of nodes that have template defaults.

### 5.2 IPv6 configuration syntax on the target — **Verified** (templates present)

For the security section, the native IPv6 firewall structures were checked directly in the firmware:

- `firewall ipv6-name <name>` with `default-action` (template default `drop`), `rule <n>` and `rule <n> {action, protocol, source address, destination port, …}`. `source address` is validated by `/opt/vyatta/sbin/vyatta-validate-type.pl ipv6_addr_param` (the stock `TypeChecker` handler).
- Interface attachment: `interfaces <if> firewall local ipv6-name <name>` (node present for ethernet, bonding, etc.).

### 5.3 Live-state JSON keys — **Strongly indicated on target**, **Verified in upstream source**

The repo's parser reads `linkinfo.info_data.{id,local,remote,port|dstport}` (`src/vyatta-vxlan` lines 179–196). For an IPv6 tunnel the printed keys differ: upstream iproute2 (verified in `v4.14.0`, `v4.15.0`, `v4.20.0`, `v5.10.0`, `v6.1.0`) prints:

```c
print_string(PRINT_ANY, "remote6", "remote %s ", …);   /* IPv6 unicast remote */
print_string(PRINT_ANY, "local6",  "local %s ",  …);   /* IPv6 local        */
print_string(PRINT_ANY, "group6",  "group %s ",  …);   /* IPv6 multicast    */
```

JSON output in `ip` exists only from **v4.14.0** onward (`ip.c` has no `json` token through `v4.13.0`; `-json` appears in `v4.14.0`), and the VXLAN JSON keys appear in the same release family. The target binary contains exactly those key strings, so **the current parser will observe `local`/`remote` as empty for an IPv6 tunnel**.

The isolated modern-Linux probe reproduced the resulting JSON (`iproute2-v7.0.0`):

```json
"linkinfo":{"info_kind":"vxlan","info_data":{"id":42,
  "remote6":"2001:db8:1::2","local6":"2001:db8:1::1","port":4789, …}}
```

**Residual (Strongly indicated, to be confirmed):** the exact JSON text emitted by the *target* binary — the key names are verified from the binary; the rendered output is not. This is a one-command hardware check (Phase 1) and must be done before release; the parser design is fail-closed so a surprise cannot silently destroy state.

### 5.4 IPv4 literal compatibility (non-canonical forms) — **Verified** (platform behaviour); policy to be settled in Phase 1

- The stock validator (`Vyatta::TypeChecker.pm:79–84`) requires exactly four decimal octets ≤ 255 and therefore **accepts leading-zero octets** such as `010.1.2.3` (it treats them as digit strings).
- glibc's `inet_pton(AF_INET, "010.1.2.3")` **rejects** them (probe: `reject`), so a naive `inet_pton`-based canonicalizer would refuse syntax the EdgeOS validator accepts.
- The platform tooling does not reject them: iproute2 (glibc `getaddrinfo` path, iproute2 6.15) accepts `local 010.1.2.3 remote 010.1.2.4` and binds them as **octal** `8.1.2.3` / `8.1.2.4` (probe: live `ip -d link show` output). The same config text therefore means different things to different parsers, and v0.2.1's raw string comparison would also loop on recreation for such values.
- **Policy (Recommendation):** never canonicalise to a value different from what the platform would bind. Two acceptable variants: (a) emulate the platform's exact interpretation (octal octets) once the Phase 1 target probe confirms it; or (b) reject non-canonical octets at commit validation with an explicit, documented message. The plan's default is **reject-with-message**, with platform-parity emulation as the reviewed alternative. Either way the behaviour is covered by dedicated tests (`U-V4-NC-*`) and never by silent decimal reinterpretation. Canonical IPv4 literals are unaffected; only non-canonical octet forms are subject to the new policy.

---

## 6. Repository IPv4-specific assumptions (file:line)

| # | Location | Assumption / problem |
|---|---|---|
| 1 | `templates/…/local-ip/node.def:1` | `type: ipv4` — rejects IPv6 literals outright |
| 2 | `templates/…/local-ip/node.def:4–6` | Calls the IPv4-only `/opt/vyatta/sbin/local_ip`; for an IPv6 literal it would emit a spurious "doesn't exist" warning |
| 3 | `templates/…/remote-ip/node.def:1` | `type: ipv4` |
| 4 | `templates/…/node.def:10–17` | No family-consistency check between `local-ip` and `remote-ip` (kernel would reject at creation time, after the interface was deleted) |
| 5 | `src/vyatta-vxlan:187–188` | Live identity reads only `info_data.local` |
| 6 | `src/vyatta-vxlan:190–191` | Live identity reads only `info_data.remote` |
| 7 | `src/vyatta-vxlan:295–300` | Snapshot stores `OLD_LOCAL_IP`/`OLD_REMOTE_IP` from those IPv4 keys |
| 8 | `src/vyatta-vxlan:349–354` | Rollback recreates the interface from the snapshot; with empty endpoints it cannot restore an IPv6 (or any) tunnel faithfully |
| 9 | `src/vyatta-vxlan:436–441` | Identity comparison is raw string comparison — IPv6 alternate spellings cause a false identity change |
| 10 | `src/vyatta-vxlan:397–401` + `templates/…/mtu/node.def:14` | MTU default hard-coded 1450 in two places — IPv4-oriented |
| 11 | `templates/…/mtu/node.def:18` | `delete` handler resets MTU to literal `1450` |
| 12 | `src/vyatta-vxlan:286–337` | Snapshot silently tolerates empty identity fields; nothing prevents a delete of an interface whose identity could not be captured |
| 13 | `README.md:829` | Documents "IPv6 underlay" as not implemented (accurate) |
| 14 | `src/vyatta-vxlan:211–222`, `:327–334` | Address collection uses process substitution; a failing `ip -o addr`/`awk` leaves an empty list with status 0 (demonstrated), so a snapshot can silently miss every address |
| 15 | `templates/…/node.tag/{mtu,address,disable}/node.def` + parent `end:` | Leaf handlers can mutate live properties outside the reconciler's snapshot/create/apply ordering; rollback fidelity under combined changes depends on engine ordering (unverified — RB-4) |
| 16 | `templates/…/local-ip/node.def` (stock validator) | Accepts non-canonical IPv4 literals whose platform meaning is octal (§5.4 — RB-6) |
| 17 | `src/vyatta-vxlan:170–200` consumers | The reconciler re-validates nothing itself; defence-in-depth checks are needed before mutations if the reconciler is ever invoked without the template layer (RB-7) |

Explicitly **not** IPv4-specific (verified by reading): module loading (line 425–427 already loads `ip6_udp_tunnel`), MAC derivation (144–168), bridge reconciliation (`src/vyatta-vxlan-bridge`), address read/apply (202–222, 251–262 use `inet`/`inet6`), `Interface.pm`, packaging.

---

## 7. IPv6 requirements

Functional:

1. `local-ip`/`remote-ip` accept IPv4 **or** IPv6 unicast literals; existing IPv4 configurations keep working unchanged.
2. Mixed-family endpoints are rejected at commit time with a clear message, before any live interface is touched.
3. IPv6 endpoints that cannot work in this fixed-remote model are rejected: link-local (`fe80::/10`, needs a scope/lower device the integration does not set), multicast (`ff00::/8`), unspecified (`::`), loopback (`::1`), IPv4-mapped (`::ffff:0:0/96`). ULA (`fc00::/7`) and global unicast are accepted.
4. Live-state parsing understands both families (`local6`/`remote6` as well as `local`/`remote`).
5. Semantically equal IPv6 addresses compare equal regardless of spelling; different addresses compare unequal; IPv4 comparison behaviour is unchanged.
6. Family transitions (v4→v6 and v6→v4) are recognised as identity changes, recreate exactly once, and restore every mutable property.
7. Idempotent commits (no config change) do not recreate the interface, even when the configured IPv6 spelling differs from the kernel's canonical form.
8. MTU: IPv4 default remains 1450; the IPv6 default is 1430 for a standard, untagged 1500-byte path (not a universal constant — explicit `mtu` otherwise), and explicit `mtu` always wins. No behaviour change for existing IPv4 configs that rely on the 1450 default. Over-sized outer packets must not be relied upon to fragment (§4.4).
9. Rollback must restore the state captured at snapshot time — family, endpoints, VNI, port, MAC, MTU, addresses, description, bridge membership/cost/priority, admin state — and no destructive step may run unless every snapshot component was read successfully (RB-2). The stronger guarantee ("the pre-commit state is restored") holds only in so far as leaf handlers cannot mutate the interface before the snapshot is taken (RB-4: demonstrate on target or implement the guard). The interface index is not preserved by recreation (IM-1).
10. The reconciler validates the desired endpoint family/classes itself before any mutation (defence in depth, RB-7).
11. Non-canonical IPv4 literals are either interpreted exactly as the platform parser interprets them or refused with an explicit message — never silently reinterpreted (RB-6, §5.4).
12. Rollback tests use deterministic, controlled creation failures (RB-5); boot behaviour with dynamic underlay addressing is characterised (IM-2).
13. No new runtime dependencies; no kernel-module change; no packaging-model change.

Non-functional: keep the change surface small (one new helper plus targeted edits), preserve the existing transactional design, keep fixtures/tests runnable off-hardware.

---

## 8. Confirmed blockers and required changes

The review-response classification (release-blocking vs improvements vs optional follow-ups) is in `docs/issue-3-implementation-plan.md` §0.1. The confirmed defects the revision must resolve:

**Release-blocking:**

- **RB-1 — live-state parsing and comparison** (`src/vyatta-vxlan:170–200`, `:436–441`): must read `local6`/`remote6` and compare canonically. Without this, every commit against an IPv6 tunnel mis-detects identity, recreates the device each time, and cannot snapshot/roll back.
- **RB-2 — status-checked, complete snapshots** (`src/vyatta-vxlan:286–337`): every component read must be checked and the address collection must not swallow failures (demonstrated: `while read … done < <(false)` continues with an empty list and status 0). Abort before deleting anything.
- **RB-3 — MTU default** (`src/vyatta-vxlan:397–401`, `templates/…/mtu/node.def:14,18`): must become family-aware. The evidence in §4.4 shows oversized outer packets are dropped rather than fragmented, so 1450 over a 1500-byte IPv6 path is not merely inefficient. Preferred design keeps the template default and probes the engine's explicit-vs-default accessors (implementation plan Phase 4).
- **RB-4 — rollback scope under combined changes**: investigate leaf-handler ordering on target; if leaves can mutate before the snapshot, add the identity-aware guard or scope the claim (implementation plan Phase 5).
- **RB-5 — deterministic failure injection** in the rollback tests (VNI/port collision for identity-changing commits; mocked failures otherwise).
- **RB-6 — IPv4 literal policy** (planned `src/vyatta-vxlan-addr`): never canonicalise differently from the platform parser (§5.4).
- **RB-7 — reconciler-side validation** (`templates/…/{local-ip,remote-ip}/node.def`, parent `node.def`, and the reconciler itself): dual-family acceptance plus class/family checks — the same check runs in the reconciler before any mutation (defence in depth).

**No kernel blocker exists.** The kmod package payload does not need to change.

Phase 1 target-capability checks (on the device, before code is finalised — read-only except reversible test-interface create/delete):

```bash
uname -a; cat /etc/version                        # kernel + firmware identity
ip -Version                                       # UBNT iproute build string
lsmod | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)'
modinfo vxlan | head -20                          # depends: udp_tunnel,ip6_udp_tunnel
ip -j -d link show dev <existing-ipv4-vxlan>      # confirm JSON keys on the target
ip -6 route show; ip -6 addr show                 # underlay addressing

# Revision 2 additions (procedures in implementation plan Phase 1):
#  - IPv4 literal probe: `ip link add … local 010.1.2.3 …` -> octal 8.1.2.3, or rejected?
#  - engine default semantics: existsActive / returnActiveValue / `delete mtu`
#  - handler-ordering observation for combined (identity + mutable) commits
#  - oversized-packet capture at MTU 1450 vs 1430 (Ip6FragFails, dmesg, tcpdump)
```

Then, after a *test* IPv6 tunnel is configured on a spare VNI, the decisive capture:

```bash
ip -j -d link show dev vxlan42 | perl -MJSON::PP -0777 -ne 'print $_'
# expect: "local6": "...", "remote6": "...", "port": 4789, "id": 42
```

---

## 9. Unverified assumptions (and how to close them)

| # | Assumption | Evidence level | How to verify |
|---|---|---|---|
| 1 | Target emits `local6`/`remote6` JSON keys | Strongly indicated (binary strings + upstream source + modern probe) | Phase 1 capture above |
| 2 | Engine default/explicit semantics (`existsActive`/`returnActiveValue`; whether `delete mtu` restores a default) | Unverified — the revised design (IM-6) depends on the Phase 1 probe; the fallback design avoids it | Phase 1 probe: tunnel without `mtu`, read the verbs and `show configuration commands`; then `set mtu 1400` + `delete mtu` and watch the live MTU |
| 3 | Engine ordering: commit validations vs handlers, `end:` vs leaf handlers, and **combined** identity+mutable changes | Documented for simple cases (`README.md:452–475`); combined-change ordering unverified and load-bearing for the rollback claim (RB-4) | Phase 1 step 6 / Phase 7: log handler order for MTU-only, identity-only and combined commits |
| 4 | Boot ordering when the IPv6 underlay address arrives via SLAAC/DHCPv6 | Unverified | Phase 7 reboot test with the underlay in its real configuration |
| 5 | Acceptability of specific edge literals under `type: ipv4,ipv6` (stock `TypeChecker` regex is permissive, e.g. accepts `::ffff:1.2.3.4`) | Verified for acceptance; behaviour is inherited stock behaviour | Unit tests on target-compatible logic + helper class checks |
| 6 | Whether any EdgeOS NSM warning appears for IPv6 vxlan | Unverified | Phase 7 log inspection (IPv4 already produces benign NSM messages per `README.md:838–857`) |
| 7 | How `brctl` path cost/priority behave for a v6-underlay vxlan | Unverified (bridge code is family-agnostic; bridge sees only the Ethernet device) | Phase 7 bridged test |
| 8 | Target `ip` parsing of non-canonical IPv4 literals (`010.1.2.3` → octal, or rejected) | Unverified on target; verified on modern glibc/iproute2 (octal) | Phase 1 step 4 |
| 9 | Target behaviour for oversized outer IPv6 packets (loss window, recovery, hardware-MAC handling) | Strongly indicated (source + isolated probe); target unverified | Phase 1 step 7 / Phase 7 capture |
| 10 | Interface-index change on recreation and its consequences (routes/conntrack referencing the old index) | Deterministic kernel behaviour (new index), consequences not yet documented/measured | Phase 7 matrix row: record `ifindex` before/after recreation and after rollback; document the consequence |
| 11 | SLAAC/DHCPv6 boot timing for the underlay address | Unverified | Phase 7 reboot test with the real underlay configuration (IM-2) |

---

## 10. Security considerations

- **`remote-ip` is not an ingress allowlist.** Verified in kernel source: `vxlan_rcv()` does not compare the received source address with the configured remote; it looks the device up by VNI/port/family (`vxlan_find_vni`, `vxlan_vs_find_vni`). The README's hardware-verified IPv4 statement (lines 528–577) holds identically for IPv6 because it is the same receive code path; the address family only changes the outer header. Re-affirm this explicitly in the IPv6 documentation.
- **Firewall guidance for IPv6 must use the native `ipv6-name` structures** (node paths verified against the target firmware templates): a `firewall ipv6-name` ruleset attached with `interfaces <underlay> firewall local ipv6-name <name>`, keeping `default-action accept` and dropping UDP/4789 from other sources, mirroring the existing IPv4 example (`README.md:534–577`). Verified command set (one `set` per line):

```text
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 default-action accept
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 description 'Restrict VXLAN underlay peers'
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 action accept
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 protocol udp
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 source address 2001:db8:2::2
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 destination port 4789
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 action drop
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 protocol udp
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 destination port 4789
set interfaces ethernet eth1 firewall local ipv6-name VXLAN_UNDERLAY_LOCAL6
```

Behavioural verification remains a hardware item (Phase 7 / matrix row 24). **Deployment note (review finding 8):** if the underlay interface already has a local IPv6 policy attached (`interfaces <if> firewall local ipv6-name <existing>`), do **not** attach a second ruleset — the interface holds one local `ipv6-name`; instead add the two VXLAN rules to the existing ruleset (choose rule numbers that fit its ordering, keep its existing rules and default-action). Replacing the attached ruleset can lock out management traffic: keep an out-of-band path and verify with `show firewall` plus counters before disconnecting. If a dedicated ruleset is preferred, merge the existing rules into it *before* attaching it.
- **UDP checksums.** Default TX checksum is computed and RX accepts zero-checksums only when explicitly configured (4.6). Do not disable.
- **Fragmentation.** Oversized outer IPv6 packets are **not** fragmented by this path — they are dropped with an ICMPv6 Packet-Too-Big/EMSGSIZE and first-packet loss, with recovery only via PMTU feedback/inner fragmentation (§4.4). Size the tunnel MTU correctly (1430 for a standard 1500-byte IPv6 path) rather than relying on fragmentation; this is an MTU/documentation matter, not a kernel defect.
- **Extension headers / PMTUD.** Outer-header handling is the kernel's normal IPv6 path; ICMPv6 Packet Too Big is honoured by the IP stack, but the design must not depend on it (RB-3). Operational validation is a hardware item.
- **CVE-2022-50405 coverage.** The existing backport covers the IPv6 teardown path (4.5). Do not alter the patch or rebuild the module for this feature.
- **No encryption/authentication** is added or implied by VXLAN; unchanged from the IPv4 guidance.

---

## 11. Recommended architecture (summary)

1. **Configuration:** extend the existing nodes — `local-ip` and `remote-ip` become `type: ipv4,ipv6` (the firmware's own dual-family idiom, used by ≥19 stock nodes). Add one commit-level endpoint check enforcing: valid literal (stock type), same family, and permitted IPv6 classes (global unicast or ULA; reject link-local/multicast/unspecified/loopback/v4-mapped). Keep the local-address *warning* behaviour, implemented family-aware. → Option A (extend the existing nodes); Option B (separate `local-ipv6`/`remote-ipv6` nodes) is rejected because it duplicates the tree, requires ambiguity rules, and is not the native idiom. The **local** endpoint may be unspecified (`0.0.0.0`/`::`, matching today's IPv4 behaviour and the kernel's "pick a source" semantics); non-canonical IPv4 literals follow the platform-parity or reject-with-message policy (§5.4).
2. **One small new helper** (installed into `/opt/vyatta/sbin/`), implemented in Perl using only core modules already present (`Socket` for `inet_pton/ntop`, `JSON::PP` for live JSON). Responsibilities: address family/class validation, canonicalization, equality, and parsing `ip -j -d link show` output into a complete, canonical live identity. This keeps the reconciler's logic testable off-hardware with fixtures.
3. **Reconciler:** use the helper for config-value canonicalization and live parsing; compare canonical values (binary-equivalent text) for idempotency; validate the desired endpoints itself before any mutation (defence in depth, RB-7); snapshot/restore canonical endpoint text with every component read status-checked and explicit captures instead of process substitution (RB-2); make snapshots fail-closed; compute the MTU default from the underlay family (1450 v4 / 1430 v6) with explicit `mtu` winning, keeping the template default where the engine allows explicit-vs-default detection. If the target shows leaf handlers can run before the parent reconciler, add the identity-aware leaf guard so combined changes cannot mutate state ahead of the snapshot (RB-4).
4. **Kernel, packaging model, diverts, interface recognition, bridge code:** unchanged. Only the userspace package grows; the kmod payload stays byte-identical.

Rejected alternatives (details in `docs/issue-3-implementation-plan.md`):

- Textual canonicalization as the *source of truth* (re-implementing RFC-5952 formatting to compare strings) instead of comparing packed `inet_pton` bytes — more code, more edge cases, no benefit; the helper still emits canonical text, derived from the bytes.
- Passing `dev` to `ip link add` to let the kernel derive the MTU — would change IPv4 behaviour (clamping/derivation) and couple creation to underlay state; rejected.
- New runtime dependency (e.g. Python or `ipcalc`) — unnecessary; `Socket`/`NetAddr::IP` are already present.
- A `type: txt` + custom regex validator for the endpoints — re-implements the stock validator and diverges from EdgeOS conventions; rejected in favour of `type: ipv4,ipv6` + a class/family check.

---

## 12. Confidence summary

| Area | Confidence | Basis |
|---|---|---|
| Kernel/module can carry VXLAN over IPv6 | High | Shipped-module symbols, stock dependency present, upstream 4.14.54 source |
| Target `ip` can create/inspect IPv6 VXLAN; JSON keys | High (exact output: medium-high) | Binary strings, package metadata, upstream print code; one hardware capture outstanding |
| Required userspace changes are localized and testable | High | Full code audit + probe |
| IPv4 behaviour can be preserved | High | Changes touch only family-sensitive points; regression matrix defined |
| Rollback safety after the changes | Medium-high (design; scoped claims) | Fail-closed, status-checked snapshot + canonical endpoints + leaf-guard option; the pre-commit-state guarantee is explicitly contingent on the Phase 1/7 ordering demonstration (RB-4) |
| MTU / outer-packet behaviour | High (mechanism + isolated probe) | 4.14 source + probe (no outer fragmentation; initial loss; 1430 clean); target capture pending (RB-3) |
| Hardware-level dataplane (EdgeOS, NSM, boot timing) | Medium | Requires Phase 7 |

No blocker prevents starting implementation; Phase 1 (Section 8) should nevertheless be executed on the device before the implementation is merged — its Revision 2 probes settle the IPv4-literal policy, the MTU-default design and the rollback-ordering premise — and Phase 7 before any release. The release-blocking / improvement / optional split is in `docs/issue-3-implementation-plan.md` §0.1.
