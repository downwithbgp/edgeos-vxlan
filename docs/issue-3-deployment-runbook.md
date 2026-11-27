# Issue #3 — Deployment Runbook (release candidate)

Copy-paste-ready procedure for installing a release candidate on the supported router, for recovery,
and for the preflight checks that must precede it. **The v0.2.1 → RC1 installation described here has
been executed** (RC1 is what ran the hardware validation recorded in `issue-3-hardware-evidence.md`).
The current candidate is **RC2**: the minimal RC1 → RC2 upgrade and its post-upgrade validation checks
are in `issue-3-release-candidate-rc2.md`, and its artifacts and hashes are in section A of that
document. Nothing else here has been run.

**Stable release (v0.2.2).** The stable packages, their hashes and the ordered merge → tag → publish
procedure are recorded in `docs/issue-3-v0.2.2-release-gate.md`; the user-facing notes are in
`docs/release-notes-v0.2.2.md`. The candidate records below remain the history of the RC builds.

This is the *sanitised* copy. It contains no live underlay addresses; `<RTR_V6>` is the router's
address on the underlay interface and `<PEER_V6>` is the peer's. The deployment instance's exact
values, and the corresponding ready-to-run variant of this runbook, live in the gitignored `local/`
directory — present in the working tree, never tracked or committed.

Command markers: **[RO]** read-only · **[CFG]** changes the EdgeOS candidate configuration
(reversible, not saved) · **[LIVE]** changes live device state · **[PKG]** changes installed packages.

---

## 0. Artifacts and their hashes

| File | Size | SHA-256 |
|---|---|---|
| `edgeos-vxlan-kmod_0.2.2~rc1+edgeos3.0.1.e50_mipsel.deb` | 28628 | `70e2580cf47e89ca1c11fa9fc5434b3bec7a803a20d6c60d3d2c7ee02ca6faa3` |
| `edgeos-vxlan_0.2.2~rc1+edgeos3.0.1.e50_all.deb` | 19358 | `ed5bb677c932c2eb3c9b6adafd47292f6e2606dd19641c7c8bc173359a5a7f6e` |

Recovery targets — the published v0.2.1 assets, pinned in the repository's `SHA256SUMS`:

| File | SHA-256 |
|---|---|
| `edgeos-vxlan-kmod_0.2.1+edgeos3.0.1.e50_mipsel.deb` | `d3e2893680d5823276ed6d7bee51a4afa9a53fb93162b76c9b8f87d62bb532c2` |
| `edgeos-vxlan_0.2.1+edgeos3.0.1.e50_all.deb` | `066f4e5d746e1ac0ef62f54ed847ec5fffd030fbfb8468eefbada7ae5e0ca231` |

⚠️ **Recovery-media trap.** A file named `edgeos-vxlan_0.2.1+edgeos3.0.1.e50_all.deb` may be present
in a development build directory and is **not** the published v0.2.1 asset: it is a development build
that already contains the IPv6 changes while still claiming version 0.2.1, and its SHA-256 matches
neither value above. Do not use it for recovery.

---

## 1. Preflight — all read-only

Run on the router and record the output. Nothing here changes anything.

| # | Check | Command | Expected |
|---|---|---|---|
| 1.1 | Firmware and kernel | `cat /etc/version; uname -r` | `EdgeRouter.ER-e50.v3.0.1.5862409…`, `4.14.54-UBNT` |
| 1.2 | Installed packages healthy | `dpkg -l edgeos-vxlan edgeos-vxlan-kmod; dpkg --audit; sudo dpkg -V edgeos-vxlan` | both `ii` at `0.2.1+edgeos3.0.1.e50`; audit empty; no modified files |
| 1.3 | Pending candidate configuration | `show system commit`, then `configure` → `compare` → `exit` | `compare` prints nothing. **If it prints anything, stop and read it — do not `discard` it without a decision** |
| 1.4 | No manual test interface | `ip link show dev vxlan900` | "Device … does not exist" |
| 1.5 | No other live VXLAN device | `ip -j link show type vxlan` | empty JSON array `[]` |
| 1.6 | Temporary firewall rule absent | `show firewall ipv6-name VLANv6_LOCAL \| grep -A6 'rule 80'`; `sudo grep -c 'rule 80' /config/config.boot` | nothing from the first; `0` from the second |
| 1.7 | Modules loaded | `lsmod \| grep -E '^(vxlan\|udp_tunnel\|ip6_udp_tunnel)'` | all three; record the exact lines |
| 1.8 | Module files | `sha256sum /lib/modules/4.14.54-UBNT/extra/vxlan.ko /lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko` | `7c346342…`, `6d58ee59…` |
| 1.9 | Free space | `df -h / /tmp` | a few MB free on both (packages total ~48 KB) |
| 1.10 | Independent management path | own SSH session plus a console session; `show service ssh` | management path does not depend on any VXLAN interface; console access confirmed |
| 1.11 | Underlay and services | `ping6 <PEER_V6>`; `show interfaces` | 0% loss; VLANs, DHCP, DNS as usual |

Baseline capture, kept outside the router:

```
[RO] mkdir -p /tmp/rc
[RO] dpkg -l edgeos-vxlan edgeos-vxlan-kmod > /tmp/rc/before-dpkg.txt
[RO] lsmod                                > /tmp/rc/before-lsmod.txt
[RO] ip -j link show type vxlan           > /tmp/rc/before-vxlan.json
[RO] sha256sum /config/config.boot        > /tmp/rc/before-config.sha
```

---

## 2. Backup

```
[RO]  cp /config/config.boot /tmp/rc/config.boot.before-rc1
[CFG] configure; save /config/config.boot.before-rc1
scp <router-user>@<router>:/config/config.boot ~/router-config.boot.before-rc1
sha256sum ~/router-config.boot.before-rc1
```

The off-router copy is the one that matters if the router stops booting.

---

## 3. Recovery media (prepared before touching the router)

```
mkdir -p ~/edgeos-vxlan-recovery && cd ~/edgeos-vxlan-recovery
curl -fLO https://github.com/downwithbgp/edgeos-vxlan/releases/download/v0.2.1/edgeos-vxlan-kmod_0.2.1+edgeos3.0.1.e50_mipsel.deb
curl -fLO https://github.com/downwithbgp/edgeos-vxlan/releases/download/v0.2.1/edgeos-vxlan_0.2.1+edgeos3.0.1.e50_all.deb
sha256sum *.deb
```

Both hashes **must** equal the recovery pins in section 0. If they do not, you do not have recovery
media — stop.

---

## 4. Transfer

Local transfer only; never a network installer pointed at a development branch.

```
scp <candidate>.deb <user>@<peer-host>:/tmp/edgeos-vxlan-rc/
ssh <user>@<peer-host> 'cd /tmp/edgeos-vxlan-rc && sha256sum *.deb'
scp /tmp/edgeos-vxlan-rc/*.deb <router-user>@<router>:/tmp/rc/
ssh <router-user>@<router> 'cd /tmp/rc && sha256sum *.deb && df -h /tmp'
```

Verify on the router immediately before installing, against section 0.

---

## 5. Installation

Both packages in **one** `dpkg` invocation, kernel package first. Do not split the command, do not use
`apt`, and do not use any `--force-*` option.

```
[PKG] sudo dpkg -i /tmp/rc/edgeos-vxlan-kmod_0.2.2~rc1+edgeos3.0.1.e50_mipsel.deb \
                   /tmp/rc/edgeos-vxlan_0.2.2~rc1+edgeos3.0.1.e50_all.deb
```

Expected transcript — it should be boring:

```
Preparing to unpack .../edgeos-vxlan-kmod_0.2.2~rc1+edgeos3.0.1.e50_mipsel.deb ...
Unpacking edgeos-vxlan-kmod (0.2.2~rc1+edgeos3.0.1.e50) over (0.2.1+edgeos3.0.1.e50) ...
Preparing to unpack .../edgeos-vxlan_0.2.2~rc1+edgeos3.0.1.e50_all.deb ...
Unpacking edgeos-vxlan (0.2.2~rc1+edgeos3.0.1.e50) over (0.2.1+edgeos3.0.1.e50) ...
Setting up edgeos-vxlan-kmod (0.2.2~rc1+edgeos3.0.1.e50) ...

NOTICE: udp_tunnel is already loaded.
The patched module has been installed on disk but the currently
loaded module will remain active until it is safely reloaded or
the router is rebooted.

Setting up edgeos-vxlan (0.2.2~rc1+edgeos3.0.1.e50) ...
```

The `over (0.2.1…)` lines are the upgrade path working. The `NOTICE` is expected — the running
`udp_tunnel` module is deliberately left alone. No `Errors were encountered while processing:` line
should appear.

**Stop and go to section 8 on**: `ERROR: Unsupported EdgeOS firmware.`,
`ERROR: Unsupported running kernel.`, `ERROR: Unsupported or locally modified …`,
`ERROR: … is already diverted by another package`, `ERROR: Diverted … is missing`,
`dependency problems - leaving unconfigured`, or any `Errors were encountered while processing:`.
Never retry with `--force`, and never install the second package alone after the first failed.

---

## 6. Post-install checks (read-only)

```
[RO] dpkg -l edgeos-vxlan edgeos-vxlan-kmod | tail -3     # both 'ii' at 0.2.2~rc1+edgeos3.0.1.e50
[RO] dpkg --audit                                         # empty
[RO] sudo dpkg -V edgeos-vxlan edgeos-vxlan-kmod          # silent
[RO] ls -l /opt/vyatta/sbin/vyatta-vxlan-addr             # -rwxr-xr-x
[RO] sha256sum /opt/vyatta/sbin/vyatta-vxlan-addr         # a484717ad975ff429368e66d638f3d1bc05e17a61c37b0cd50ff9ec82866c7d7
[RO] sha256sum /opt/vyatta/sbin/vyatta-vxlan              # e276748ec868a4dcbc53a55bc72509c9c709341b459b2704e17008bc9830f469
[RO] grep -c 'ipv4,ipv6' /opt/vyatta/share/vyatta-cfg/templates/interfaces/vxlan/node.tag/local-ip/node.def   # 1
[RO] sha256sum /lib/modules/4.14.54-UBNT/extra/vxlan.ko \
              /lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko   # 7c346342…, 6d58ee59…
[RO] lsmod | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)' # unchanged from before-lsmod.txt
[RO] ip -j link show type vxlan                           # still []
[RO] sha256sum /config/config.boot                        # identical to before-config.sha
[RO] ping6 <PEER_V6>                                      # still 0% loss
```

Then the first acceptance test, still without touching live state:

```
[CFG] configure
[CFG] set interfaces vxlan vxlan900 vni 900
[CFG] set interfaces vxlan vxlan900 local-ip <RTR_V6>
[CFG] set interfaces vxlan vxlan900 remote-ip <PEER_V6>
[CFG] compare
```

Both `set` commands must be accepted. Then `discard` to return to the saved configuration and
continue with `docs/issue-3-hardware-validation-runbook.md`.

---

## 7. Temporary firewall exception

```
[CFG] set firewall ipv6-name VLANv6_LOCAL rule 80 action accept
[CFG] set firewall ipv6-name VLANv6_LOCAL rule 80 description 'VXLAN underlay test (temporary)'
[CFG] set firewall ipv6-name VLANv6_LOCAL rule 80 protocol udp
[CFG] set firewall ipv6-name VLANv6_LOCAL rule 80 destination port 4789
[CFG] set firewall ipv6-name VLANv6_LOCAL rule 80 source address <PEER_V6>
[CFG] commit
```

Removal:

```
[CFG] delete firewall ipv6-name VLANv6_LOCAL rule 80
[CFG] commit
```

`show firewall ipv6-name VLANv6_LOCAL` confirms it is active; the tunnel tests failing after removal
proves it was doing the work. Do not `save` while it exists.

---

## 8. Recovery

Five independent things can need reverting.

**8.1 Candidate (uncommitted) configuration** — `configure`, `compare`, then `discard` (or targeted
`delete`s). Does not touch packages or live interfaces.

**8.2 Committed configuration** — `configure; rollback 1; compare; commit` for the previous commit
revision, or restore the backup and reboot (8.5). `rollback` replaces the whole configuration.

**8.3 A manually created kernel interface** — `sudo ip link del dev vxlan900`, only if it was created
by hand. Interfaces created by the configuration system must be removed through the configuration.

**8.4 Package installation** — both v0.2.1 packages in one `dpkg -i`, kernel package first. `dpkg`
prints a `downgrading …` warning, which is expected and safe. Verify the files against section 0
first; if they do not match, fetch the published assets again instead.

**8.5 Saved boot configuration** — `load /config/config.boot.before-rc1`, `compare`, `commit`, `save`,
or boot a previous configuration revision from the boot menu. Use the console: network access may be
exactly what is broken.

**8.6 Not recovery.** `commit-confirm` reverts only the candidate configuration and never undoes a
package installation. A reboot is not a rollback: it reloads modules from disk, re-runs the committed
configuration, and can remove the last working management path. `--force-*` flags and
`apt-get install -f` are not recovery either — a reported dependency problem is information, not an
obstacle.
