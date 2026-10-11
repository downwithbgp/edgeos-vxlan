# edgeos-vxlan

Native IPv4 and IPv6 VXLAN support for the Ubiquiti EdgeRouter X running EdgeOS 3.0.1.

This project adds the missing Linux `vxlan.ko` kernel module and integrates VXLAN interfaces into the native EdgeOS/Vyatta configuration system, supporting both IPv4 and IPv6 VXLAN underlays. The v0.2 kernel package also carries a narrowly scoped `udp_tunnel.ko` backport for CVE-2022-50405 on the supported EdgeOS 3.0.1 kernel.

Example:

```text
configure

set interfaces vxlan vxlan42 address 198.51.100.1/30
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450

commit
save
exit
```

An IPv6 underlay uses the same tree with IPv6 endpoints:

```text
configure

set interfaces vxlan vxlan42 address 198.51.100.1/30
set interfaces vxlan vxlan42 local-ip 2001:db8::1
set interfaces vxlan vxlan42 remote-ip 2001:db8::2
set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430

commit
save
exit
```

After configuration, the interface behaves like a native EdgeOS interface:

```text
Interface    IP Address        S/L
---------    ----------        ---
vxlan42      198.51.100.1/30      u/u
```

## Quick install

Check whether your router is supported without making any changes:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.2.2/install.sh |
  sh -s -- --check
```

Install `edgeos-vxlan`:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.2.2/install.sh |
  sudo sh
```

The installer:

- verifies the EdgeOS firmware and running kernel;
- downloads the matching kernel-module and EdgeOS integration packages;
- verifies both packages against SHA-256 hashes pinned in the tagged installer;
- installs the kernel module first, followed by the EdgeOS integration.

Prefer to inspect the installer first?

```bash
curl -fLO \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.2.2/install.sh

less install.sh
sudo sh install.sh
```

The installer is pinned to release `v0.2.2`; it does not execute the moving `main` branch.


## Supported platform

Version `0.2.2` is deliberately restricted to the platform on which it has been built and tested.

```text
Device:       Ubiquiti EdgeRouter X / ER-e50
EdgeOS:       3.0.1
Firmware:     EdgeRouter.ER-e50.v3.0.1.5862409.*
Kernel:       4.14.54-UBNT
Architecture: mipsel
```

The Debian packages refuse installation on unsupported EdgeOS firmware.

The kernel-module package also requires the running kernel to be:

```text
4.14.54-UBNT
```

Do not install the package on other EdgeRouter models, EdgeOS releases, or kernel builds without rebuilding and validating it for that target.

## Features

`edgeos-vxlan` currently provides:

* Linux VXLAN kernel support through `vxlan.ko`
* A narrowly scoped `udp_tunnel.ko` security backport for CVE-2022-50405
* Native `interfaces vxlan vxlanN` EdgeOS configuration
* IPv4 and IPv6 VXLAN underlays (`local-ip`/`remote-ip`), with the endpoint family enforced
* Family-aware default MTU — 1450 over an IPv4 underlay, 1430 over an IPv6 underlay
* Canonical endpoint comparison, so an equivalent re-spelling does not recreate the interface
* Endpoint validation that rejects malformed, prefix-carrying, mixed-family and unusable addresses before anything is changed
* Fail-closed live-state capture before any destructive step
* Persistent configuration through `/config/config.boot`
* Automatic module loading
* VXLAN restoration during boot
* Integration with `show interfaces`
* Integration with `show configuration commands`
* IPv4 and IPv6 interface-address syntax
* Native address validation
* Native bridge integration through `bridge-group`, including:
  * bridge membership
  * STP path cost
  * STP port priority
* Validation that prevents a VXLAN interface from being both bridged and directly addressed
* Configurable:

  * VNI
  * local underlay address
  * remote underlay address
  * UDP destination port
  * MTU
  * interface addresses
  * description
  * administrative disable state
* Non-disruptive updates for mutable interface properties, including bridge membership, path cost, and port priority
* Controlled interface recreation for VXLAN identity changes
* Rollback to the previous live interface state, including bridge membership, path cost, and port priority, if recreation fails
* Deterministic locally administered MAC addresses

## Packages

The project builds two Debian packages.

### `edgeos-vxlan-kmod`

Architecture:

```text
mipsel
```

Installs:

```text
/lib/modules/4.14.54-UBNT/extra/vxlan.ko
/lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko
```

The second file is a minimally patched rebuild of the EdgeOS `udp_tunnel.ko` dependency containing the CVE-2022-50405 backport described below. Before replacing the vendor file, the package verifies its expected SHA-256 hash and preserves it with `dpkg-divert` as:

```text
/lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko.edgeos-vxlan-stock
```

Removing the kernel package restores the preserved vendor module. If `udp_tunnel` is already loaded during an upgrade, the package does not forcibly unload it; the newly installed module takes effect after a safe reload or reboot.

The package runs `depmod` and loads:

```text
udp_tunnel
ip6_udp_tunnel
vxlan
```

### `edgeos-vxlan`

Architecture:

```text
all
```

Provides:

* EdgeOS configuration templates
* the `vyatta-vxlan` reconciliation helper
* the `vyatta-vxlan-addr` dual-family address and identity helper
* the `vyatta-vxlan-bridge` bridge-membership helper
* VXLAN recognition in `Vyatta::Interface`

It depends on the exact matching kernel package and the tested EdgeOS configuration packages.

## Installation

Copy both packages to the router.

Install the kernel module first:

```bash
sudo dpkg -i \
  edgeos-vxlan-kmod_0.2.2+edgeos3.0.1.e50_mipsel.deb
```

Then install the EdgeOS integration package:

```bash
sudo dpkg -i \
  edgeos-vxlan_0.2.2+edgeos3.0.1.e50_all.deb
```

Verify that the module is loaded:

```bash
lsmod | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)'
```

Expected output includes:

```text
vxlan
ip6_udp_tunnel
udp_tunnel
```

### Upgrading from v0.2.1

Upgrade both packages in a single `dpkg` invocation, kernel package first (replace the filenames with the downloaded v0.2.2 files):

```bash
sudo dpkg -i \
  edgeos-vxlan-kmod_0.2.2+edgeos3.0.1.e50_mipsel.deb \
  edgeos-vxlan_0.2.2+edgeos3.0.1.e50_all.deb
```

The upgrade replaces files only: it does not modify the saved configuration, recreate interfaces, or unload a loaded module (`depmod`/`modprobe` run, and an already-loaded `udp_tunnel` is left alone until a safe reload or reboot). Verify the result with `dpkg -V edgeos-vxlan edgeos-vxlan-kmod` (silent) and `dpkg --audit`.

The package-upgrade path has been exercised with a live tunnel on the supported platform (release-candidate pair) and in container simulations of the v0.2.1 ↔ release-candidate transactions. The exact v0.2.1 → v0.2.2 upgrade carrying an existing, active **IPv4** VXLAN has not been directly hardware-tested — after upgrading, review the tunnel (`ip -j -d link show dev vxlanN`, `show interfaces`) and re-commit if you want to exercise the configuration path.

A downgrade uses the same single invocation with the v0.2.1 files; `dpkg` prints a `downgrading ...` warning, which is expected.

## Configuration

### Routed VXLAN

A basic point-to-point VXLAN tunnel can be configured as follows:

```text
configure

set interfaces vxlan vxlan42 address 198.51.100.1/30
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450

commit
save
exit
```

Verify:

```bash
show interfaces
```

and:

```bash
ip -j -d link show dev vxlan42
```

The latter should show values similar to:

```json
{
  "info_kind": "vxlan",
  "info_data": {
    "id": 42,
    "remote": "192.0.2.2",
    "local": "192.0.2.1",
    "port": 4789
  }
}
```


### IPv6 underlay

`local-ip` and `remote-ip` also accept IPv6 literals; both must be the same family:

```text
configure

set interfaces vxlan vxlan42 address 198.51.100.1/30
set interfaces vxlan vxlan42 local-ip 2001:db8::1
set interfaces vxlan vxlan42 remote-ip 2001:db8::2
set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 port 4789

commit
save
exit
```

With `mtu` unset, an IPv6-underlay tunnel comes up at the family default of 1430, and `ip -j -d link show dev vxlan42` reports the endpoints as `local6`/`remote6`:

```json
{
  "info_kind": "vxlan",
  "info_data": {
    "id": 42,
    "remote6": "2001:db8::2",
    "local6": "2001:db8::1",
    "port": 4789
  }
}
```

Use the JSON form for diagnostics on this platform: in the firmware's `iproute2` build the human-readable `ip -d link show` output renders some numeric fields incorrectly.

Malformed addresses, addresses carrying a prefix, mixed families, and — for the remote endpoint — link-local, multicast, unspecified, loopback and IPv4-mapped addresses are rejected at commit time before anything is changed. An unspecified **local** address (`0.0.0.0` or `::`) is accepted and means "no specific local address". The remote endpoint is fixed (point-to-point): multiple remote VTEPs and learned peers are not supported.

### Bridged VXLAN

A VXLAN interface can be attached to a native EdgeOS bridge:

```text
configure

set interfaces bridge br42
set interfaces bridge br42 address 198.51.100.1/30

set interfaces vxlan vxlan42 bridge-group bridge br42
set interfaces vxlan vxlan42 bridge-group cost 200
set interfaces vxlan vxlan42 bridge-group priority 10
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450

commit
save
exit
```

A bridged VXLAN interface must not also have an `address` configured directly on the VXLAN interface. If Layer 3 connectivity is required, assign the address to the bridge, as shown above. EdgeOS commit validation rejects simultaneous `bridge-group bridge` and VXLAN interface-address configuration.

Bridge membership and bridge port options are mutable. Moving `vxlan42`
between bridges, adding it to a bridge, removing it from a bridge, or
changing its bridge port cost or priority does not by itself recreate the
VXLAN interface.

`bridge-group cost` accepts values from `1` through `65535`. If omitted,
the bridge port is reconciled to the EdgeOS 3.0.1 default path cost of
`100`.

`bridge-group priority` accepts values from `0` through `63`. If omitted,
the bridge port is reconciled to the EdgeOS 3.0.1 default priority of
`32`.

Bridge port cost and priority require bridge membership. EdgeOS commit
validation rejects either option when `bridge-group bridge` is not
configured.

If a VXLAN identity change requires interface recreation, the configured
bridge membership, cost, and priority are reapplied to the new interface.
If recreation fails, the previous live bridge membership, cost, and
priority are restored during rollback. These settings are also restored
during boot.

## Configuration tree

The current configuration tree is:

```text
interfaces {
    vxlan vxlanN {
        address <address/prefix>
        bridge-group {
            bridge <brN>
            cost <1-65535>
            priority <0-63>
        }
        description <text>
        disable
        local-ip <IPv4 or IPv6 address>
        mtu <68-8024>
        port <1-65535>
        remote-ip <IPv4 or IPv6 address>
        vni <1-16777215>
    }
}
```

`vni`, `local-ip`, and `remote-ip` are required, and `local-ip`/`remote-ip` must be the same address family. The `mtu` minimum is the kernel's own VXLAN minimum (68): a value the kernel cannot apply is rejected at commit time instead of failing later.

The default UDP destination port is:

```text
4789
```

The default MTU is family-aware: `1450` over an IPv4 underlay and `1430` over an IPv6 underlay on a standard untagged 1500-byte path.

### MTU guidance

The VXLAN interface MTU must fit inside the underlay path MTU:

```text
VXLAN MTU = underlay path MTU − (14 Ethernet + IP + 8 UDP + 8 VXLAN)
            IPv4 outer IP header: −20   (total −50)
            IPv6 outer IP header: −40   (total −70)
            per 802.1Q tag on the outer path: −4
```

For the standard untagged 1500-byte path that gives 1450 over IPv4 and 1430 over IPv6 — the defaults above. One 802.1Q tag on the path gives 1426 over IPv6, and a PPPoE path whose MTU is already 1492 gives 1422 (the 8 bytes of PPPoE overhead are already reflected in the path MTU — do not subtract them twice).

The integration does not rely on over-sized outer packets being fragmented: size the tunnel for the path, and set an explicit `mtu` when your underlay differs from the standard case.

## Interface update behavior

The integration distinguishes between mutable properties and VXLAN identity.

The following properties are changed in place without recreating the interface:

* MTU
* interface addresses
* bridge membership
* description
* administrative state

The following properties define the VXLAN tunnel identity and require interface recreation:

* VNI
* local IP
* remote IP
* UDP destination port
* the underlay address family (implied by the endpoints; an IPv4 ↔ IPv6 change is an identity change)

When an identity change is committed, the integration:

1. captures the existing live VXLAN state;
2. removes the old interface;
3. creates the requested VXLAN interface;
4. restores the configured mutable state, including bridge membership;
5. brings the interface to the requested administrative state.

If creation or reconciliation fails, the helper attempts to restore the previous live VXLAN interface, including:

* VNI
* local address
* remote address
* UDP port
* MAC address
* MTU
* description
* configured global addresses
* bridge membership
* administrative state

The failed configuration operation still returns an error so that EdgeOS reports the commit failure.

The kernel interface index (`ifindex`) changes on recreation and is **not** preserved; the properties listed above are reapplied or restored.

### Failed commits and partial configuration

EdgeOS configuration commits are not universally atomic: the engine commits each priority subtree independently and can write the successful part of a commit that failed overall. If a VXLAN commit fails, **do not `save`** — first compare the active configuration with the kernel, for example:

```bash
show configuration commands | grep vxlan42
ip -j -d link show dev vxlan42
```

then set the values so that they agree again and re-commit before saving. The integration validates everything it can before mutating, and restores the captured kernel state when a recreation fails, but it cannot make the configuration engine transactional.

## Deterministic MAC addresses

Linux normally generates a MAC address for a VXLAN interface when the netdevice is created.

Because identity changes require deleting and recreating the interface, that would otherwise result in MAC-address churn.

`edgeos-vxlan` therefore derives a deterministic locally administered unicast MAC from:

```text
EdgeRouter eth0 MAC + VXLAN interface name
```

For example, a specific router's `vxlan42` may consistently receive:

```text
02:00:5e:00:53:42
```

The derived MAC remains stable across:

* VNI changes
* remote-address changes
* UDP-port changes
* interface recreation
* reboot

Rollback restores the exact MAC that existed before the attempted change.

## EdgeOS integration

### `Vyatta::Interface`

Stock EdgeOS 3.0.1 does not recognize interface names matching:

```text
vxlanN
```

This affects tools such as:

```text
show interfaces
vyatta-interfaces.pl
```

The package adds the following interface mapping:

```perl
'^vxlan[\d]+$' => { path => 'vxlan' },
```

to `Vyatta::Interface`.

The stock file is managed using `dpkg-divert`.

Before modifying the system, the package verifies the SHA-256 hash of the known EdgeOS 3.0.1 version:

```text
f4985acc53058088bda3ed3b989ed2d76e92a3edd9e2582272ff576dd089f721
```

If the file is unknown or locally modified, installation is refused.

Removing the package restores the original EdgeOS file.

### Commit reconciliation

The parent VXLAN configuration node uses an `end:` handler.

Mutable child-node actions are intentionally idempotent.

This is necessary because EdgeOS can execute child configuration actions on either side of the parent reconciliation during initial configuration and boot restoration.

For example, during cold creation:

```text
child handler
    |
    | interface may not exist yet
    v
no-op if necessary
    |
parent end: reconciler
    |
    v
create VXLAN + apply complete desired state
```

During an ordinary update to an existing interface, the leaf handler can update the property directly without requiring interface recreation.

## Boot persistence

VXLAN configuration is stored normally in:

```text
/config/config.boot
```

The interface is restored through the standard EdgeOS boot configuration loader.

A tested boot sequence successfully performs:

```text
load finished successfully
commit succeeded
teardown succeeded
```

After reboot, the VXLAN kernel module, patched UDP-tunnel dependency, native configuration, deterministic MAC address, MTU, interface address or bridge membership, and operational state are restored. Save + reboot restoration was re-validated with an IPv6 underlay on the release candidate: the tunnel, its identity, MTU 1430, the deterministic MAC and both overlay addresses came back automatically, and bidirectional IPv4 and IPv6 overlay traffic passed afterwards.

Dynamic underlay addressing (SLAAC/DHCPv6) at boot has not been validated — see Known limitations.

## Removal

Remove all saved VXLAN configuration before uninstalling.

```text
configure
delete interfaces vxlan
commit
save
exit
```

Then remove the integration package:

```bash
sudo dpkg -r edgeos-vxlan
```

and the kernel module package:

```bash
sudo dpkg -r edgeos-vxlan-kmod
```

The packages contain safeguards against:

* removing `edgeos-vxlan` while saved VXLAN configuration exists;
* removing `edgeos-vxlan-kmod` while live VXLAN interfaces remain.

Removing the integration package also restores the original diverted `Vyatta::Interface` file. Removing the kernel package restores the original EdgeOS `udp_tunnel.ko` preserved by its separate `dpkg-divert`.

## Underlay trust and security

`remote-ip` configures the normal outbound VXLAN destination. It is not an inbound peer allowlist and does not authenticate a sender.

Hardware testing on the supported EdgeRouter X confirmed that a VNI 42 VXLAN interface configured with one `remote-ip` still accepted and decapsulated valid VNI 42 packets arriving from a different underlay source address. The project therefore does not treat `remote-ip` as a security boundary.

### Restricting a fixed VXLAN peer

For a fixed-peer deployment, an EdgeOS `local` firewall policy on the underlay interface can restrict UDP/4789 to the intended remote VTEP.

For example, if the VXLAN underlay uses `eth1` and the intended remote VTEP is `192.0.2.2`:

```text
configure

set firewall name VXLAN_UNDERLAY_LOCAL default-action accept
set firewall name VXLAN_UNDERLAY_LOCAL description 'Restrict VXLAN underlay peers'

set firewall name VXLAN_UNDERLAY_LOCAL rule 10 action accept
set firewall name VXLAN_UNDERLAY_LOCAL rule 10 description 'Allow configured VXLAN peer'
set firewall name VXLAN_UNDERLAY_LOCAL rule 10 protocol udp
set firewall name VXLAN_UNDERLAY_LOCAL rule 10 source address 192.0.2.2
set firewall name VXLAN_UNDERLAY_LOCAL rule 10 destination port 4789

set firewall name VXLAN_UNDERLAY_LOCAL rule 20 action drop
set firewall name VXLAN_UNDERLAY_LOCAL rule 20 description 'Drop other VXLAN senders'
set firewall name VXLAN_UNDERLAY_LOCAL rule 20 protocol udp
set firewall name VXLAN_UNDERLAY_LOCAL rule 20 destination port 4789

set interfaces ethernet eth1 firewall local name VXLAN_UNDERLAY_LOCAL

commit
save
exit
```

If the VXLAN underlay is carried on a VLAN or another EdgeOS interface type, attach the same `local` ruleset to that interface instead.

This policy deliberately uses `default-action accept`; it restricts VXLAN traffic without changing the treatment of unrelated traffic destined for the router on that interface.

On the supported EdgeRouter X, this behavior was validated with a VXLAN interface configured for one `remote-ip`:

* packets from the configured peer were accepted and decapsulated;
* otherwise identical VNI-matching packets from another underlay source were accepted before filtering;
* after applying the policy above, packets from the configured peer remained accepted;
* packets from the alternate source were dropped before reaching the VXLAN interface.

`edgeos-vxlan` does not automatically create or modify firewall policy. Underlay filtering remains an explicit deployment responsibility.

### Restricting a fixed VXLAN peer (IPv6 underlay)

`remote-ip` is not an ingress allowlist for IPv6 either. The same restrict-to-the-intended-peer policy can be expressed with an EdgeOS IPv6 local firewall ruleset; if the underlay interface already has a local IPv6 policy attached (for example a VLAN ruleset with a default drop), extend that existing ruleset with the VXLAN rules — do not replace it, and keep the management path in mind:

```text
configure

set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 default-action accept

set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 action accept
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 description 'Allow configured VXLAN peer'
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 protocol udp
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 source address <remote-v6>
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 destination port 4789

set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 action drop
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 description 'Drop other VXLAN senders'
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 protocol udp
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 20 destination port 4789

set interfaces ethernet eth1 firewall local ipv6-name VXLAN_UNDERLAY_LOCAL6

commit
save
exit
```

On the release-candidate deployment, an extension of the underlay's existing local IPv6 ruleset (default drop) was in place while the tunnel was validated; adapt the rule numbers to your own ruleset and validate the drop behaviour on your deployment.

This is a source-address allowlist, not cryptographic authentication. On an untrusted or spoofable underlay, use an authenticated and encrypted transport when peer authenticity or confidentiality is required.

## Kernel build provenance

The EdgeRouter X firmware does not ship `vxlan.ko`.

The `vxlan.ko` module included with this project was built from Ubiquiti's published EdgeOS GPL source. Version 0.2 also rebuilds the vendor `udp_tunnel.ko` dependency from the same corresponding source with one security backport.

GPL source archive:

```text
GPL.mtk.v3.0.0-rc.9.5753457.tar.bz2
```

SHA-256:

```text
4f2ba6fd6b8655582e9090bbc1da96c656cd46841992376811a014970b149fb9
```

Relevant kernel source archive inside the GPL release:

```text
source/kernel_5753457-g001c7c22e530.tgz
```

Kernel:

```text
4.14.54
```

EdgeOS local version:

```text
-UBNT
```

Relevant configuration:

```text
CONFIG_LOCALVERSION="-UBNT"
# CONFIG_LOCALVERSION_AUTO is not set

CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
# CONFIG_MODVERSIONS is not set

CONFIG_NET_UDP_TUNNEL=m
CONFIG_VXLAN=m
```

Toolchain:

```text
mipsel-linux-gnu-gcc 6.3.0 20170516
```

A compatible cross-build environment used during development was:

```bash
docker run --rm -it \
  -v "$PWD:/src" \
  -w /src \
  lochnair/debian-crossenv:mipsel \
  bash
```

The module was built after enabling VXLAN:

```bash
scripts/config --module VXLAN

make \
  ARCH=mips \
  CROSS_COMPILE=mipsel-linux-gnu- \
  olddefconfig

make -j5 \
  ARCH=mips \
  CROSS_COMPILE=mipsel-linux-gnu- \
  vmlinux modules
```

The resulting module reports:

```text
depends: udp_tunnel,ip6_udp_tunnel
vermagic: 4.14.54-UBNT SMP mod_unload MIPS32_R2 32BIT
```

### CVE-2022-50405 UDP-tunnel backport

The corresponding EdgeOS 3.0.1 GPL source clears `sk_user_data` and then immediately shuts down and releases the UDP tunnel socket. It lacks the RCU grace-period wait used by the upstream fix for CVE-2022-50405, a race between VXLAN receive processing and tunnel teardown.

The v0.2 kernel package applies the repository patch:

```text
patches/4.14.54-UBNT/CVE-2022-50405.patch
```

which adds the required `synchronize_rcu()` before socket shutdown. On this kernel configuration that call resolves to the exported `synchronize_sched` symbol.

For the tested firmware, the preserved vendor module SHA-256 is:

```text
14fbf8c469a7c902ce53d79de581e3e14982a9d52dbc80515d5ab481afb0fa94
```

The patched module SHA-256 is:

```text
6d58ee597d8ae50898efe90ec61a4803ae4f0549f29fba9c4132ca92260405cc
```

The package installs the patched module at the canonical EdgeOS module path so existing VXLAN, L2TP, and WireGuard module dependencies continue to resolve normally, while preserving the original vendor file with `dpkg-divert`.

Validation on the supported EdgeRouter X included a cold boot with the patched module and repeated VXLAN identity recreation while valid VXLAN receive traffic was arriving. No kernel Oops, BUG, call trace, panic, use-after-free diagnostic, or RCU stall was observed during that stress test.

## RC9 / EdgeOS 3.0.1 compatibility evidence

The available GPL source release predates the final EdgeOS 3.0.1 firmware build.

Compatibility was validated by comparing an existing kernel module supplied by EdgeOS against a module rebuilt from the GPL source.

Before applying the security backport, the stock final-firmware `udp_tunnel.ko` and an unmodified module rebuilt from the GPL source had:

* matching size;
* matching module metadata;
* matching vermagic;
* byte-identical `.text` sections.

The `.text` section SHA-256 was:

```text
699c6b77728c5d6660acd7d341896f729693aa72c7e44367746eb16888b96baa
```

The Vyatta `Interface.pm` from the GPL source was also byte-for-byte identical to the stock EdgeOS 3.0.1 copy used during development.

This provides strong evidence that the relevant kernel and Vyatta interface code did not materially change between the published GPL release and the tested final firmware. The v0.2 `udp_tunnel.ko` intentionally differs from the vendor binary because it includes the CVE-2022-50405 backport.

It does not imply compatibility with other EdgeOS builds.

## Building the Debian packages

The repository uses Debian source format:

```text
3.0 (native)
```

Build with:

```bash
dpkg-buildpackage -us -uc -b -a mipsel
```

The build produces:

```text
edgeos-vxlan_0.2.2+edgeos3.0.1.e50_all.deb

edgeos-vxlan-kmod_0.2.2+edgeos3.0.1.e50_mipsel.deb
```

Packages are compressed using gzip for compatibility with the older `dpkg` version shipped by EdgeOS.

## Repository layout

```text
.
├── debian/
├── modules/
│   └── 4.14.54-UBNT/
│       ├── udp_tunnel.ko
│       └── vxlan.ko
├── patches/
│   └── 4.14.54-UBNT/
│       └── CVE-2022-50405.patch
├── src/
│   ├── Interface.pm
│   ├── vyatta-vxlan
│   ├── vyatta-vxlan-addr
│   └── vyatta-vxlan-bridge
├── templates/
│   └── interfaces/
│       └── vxlan/
├── test/
│   ├── run.sh
│   ├── unit-helper.sh
│   ├── unit-templates.sh
│   └── mock.sh
└── upstream/
    └── libvyatta-cfg1/
        └── Interface.pm
```

`upstream/libvyatta-cfg1/Interface.pm` is the pristine upstream reference.

`src/Interface.pm` is the package-installed version with the minimal VXLAN interface recognition change.

## Tested behavior

Version `0.2.2` has been tested on the supported platform (EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409, kernel `4.14.54-UBNT`). The release candidates' runtime payloads are byte-identical to the final build; tests were run on the release-candidate and v0.2.1 builds, as noted. Tested for:

* kernel module loading;
* VXLAN interface creation;
* point-to-point IPv4 VXLAN dataplane;
* native EdgeOS configuration;
* save and reboot restoration;
* `show interfaces`;
* `show configuration commands`;
* MTU changes without recreation;
* interface-address add/remove without recreation;
* description changes without recreation;
* administrative disable/enable without recreation;
* VNI recreation;
* UDP-port recreation;
* remote-IP recreation;
* rollback after failed recreation;
* restoration of MAC, MTU, addresses, description, and administrative state during rollback;
* stable deterministic MAC addresses across successful recreations;
* stable deterministic MAC addresses across reboot;
* package removal safeguards;
* `dpkg-divert` restoration of the stock EdgeOS Perl module;
* native bridge attachment and detachment;
* routed-to-bridged and bridged-to-routed transitions;
* bridge-to-bridge moves without VXLAN recreation;
* bridge membership restoration after identity recreation, rollback, and cold boot;
* mutable bridge port cost and priority updates without VXLAN recreation;
* reset of deleted bridge port cost and priority to EdgeOS defaults;
* bridge port cost range validation (`1-65535`);
* bridge port priority range validation (`0-63`);
* rejection of bridge port cost or priority without bridge membership;
* preservation of configured bridge port cost and priority across bridge-to-bridge moves;
* reapplication of configured bridge port cost and priority after VXLAN identity recreation;
* restoration of previous live bridge port cost and priority after failed identity recreation;
* persistence of bridge port cost and priority across save, reboot, and cold boot;
* rejection of simultaneous VXLAN interface addresses and bridge membership;
* literal interface descriptions containing shell metacharacters;
* patched `udp_tunnel.ko` runtime loading and cold boot;
* repeated VXLAN teardown/recreation under active receive traffic;
* alternate-source VXLAN receive behavior demonstrating that `remote-ip` is not an ingress ACL;
* EdgeOS `local` firewall enforcement restricting UDP/4789 to an intended fixed peer;
* IPv6 underlay configuration through the native tree, including template validation and rejection of malformed, prefix-carrying and mixed-family endpoints **without touching live state**;
* rejection of unusable IPv6 remote endpoints (link-local, multicast, unspecified, loopback, IPv4-mapped) and acceptance of an unspecified local endpoint;
* native interface creation and deletion over an IPv6 underlay, with the correct VNI, UDP port, MTU, endpoint identity, MAC and overlay addresses;
* bidirectional IPv4 and IPv6 overlay traffic over an IPv6 VXLAN underlay, including a post-reboot run (20/20 packets, zero loss);
* IPv6 endpoint canonicalisation: an equivalent re-spelling does not recreate the interface, and no-op commits leave it in place;
* family-aware MTU defaulting (1430 over IPv6, 1450 over IPv4), mutable MTU changes without recreation, and restoration of the family default when overrides are removed;
* IPv4 ↔ IPv6 underlay transitions as identity changes with the correct endpoints applied;
* minimum-MTU validation: values the kernel cannot apply (below the VXLAN minimum of 68, or above the platform maximum) are rejected at commit, leaving the candidate configuration unchanged;
* deterministic-failure rollback with bridge state (membership, path cost, port priority) preserved across recreation and restored after a failed one (release-candidate build);
* package upgrade with a live tunnel (release-candidate pair; no interface recreation).

Point-to-point tests between the EdgeRouter X and a Linux host passed bidirectional IPv4 and IPv6 overlay traffic over an IPv6 VXLAN underlay; the earlier (v0.2.1) hardware testing validated bidirectional IPv4 overlay traffic over an IPv4 VXLAN underlay.

## Known limitations

Version `0.2.2` remains intentionally small in scope.

* **VTEP endpoints are statically configured.** The tunnel is a fixed-remote point-to-point link; a delegated-prefix change on the underlay is not tracked automatically — update `local-ip`/`remote-ip` and commit after a prefix change. Dynamic underlay addressing (SLAAC/DHCPv6) at boot has not been validated.
* **EdgeOS commits are not universally atomic.** A failed commit can leave partially applied configuration in some cases; after a failed VXLAN commit, do not `save` — compare the active configuration with the kernel and re-converge first (see the failed-commit guidance above).
* **Upgrade with a live IPv4 tunnel has not been directly hardware-tested.** The exact v0.2.1 → v0.2.2 upgrade carrying an existing, active IPv4 VXLAN has not been exercised on hardware; the package-upgrade mechanism has been validated (including with a live tunnel and in container simulations), and the packages make no configuration or interface changes on upgrade.
* **Firewall configuration is the operator's responsibility.** The package does not create or modify firewall policy, and `remote-ip` is not an ingress allowlist — see the underlay trust and security section for fixed-peer examples.

Not yet validated or implemented as first-class configuration features:

* EVPN control plane
* multicast VXLAN
* VLAN-to-VNI mapping
* flood-and-learn configuration beyond the basic Linux defaults
* multiple remote VTEPs
* VXLAN-specific FDB configuration
* hardware offload
* other EdgeRouter models
* other EdgeOS releases

The current implementation has been validated for routed point-to-point VXLAN — dual-stack overlays over IPv6 underlays and IPv4 overlays over IPv4 underlays — and for native bridge attachment on the supported platform. It remains a fixed-remote, Linux VXLAN dataplane integration rather than a VXLAN control-plane implementation.

### EdgeOS userspace warnings

EdgeOS NSM may emit messages such as:

```text
NSM-6Operation not supported
NSM-6No such device
```

during virtual-interface creation or boot.

No associated VXLAN dataplane failure has been observed.

`systemd-udevd` may also emit:

```text
Could not generate persistent MAC address for vxlanN
```

The package does not rely on udev for the VXLAN MAC and assigns its own deterministic locally administered address.

DHCP services may log:

```text
No subnet declaration for vxlanN
```

for an addressed VXLAN interface that is not configured as a DHCP-serving interface.

## License

This project is distributed under the GNU General Public License version 2 only:

```text
GPL-2.0-only
```

The repository contains code derived from GPL-licensed Linux kernel and Vyatta/EdgeOS sources.

Existing upstream copyright and licensing notices are preserved.

See:

```text
LICENSE
debian/copyright
```

for additional details.

## Disclaimer

This project is not affiliated with or endorsed by Ubiquiti.

It modifies low-level networking behavior and installs a kernel module on EdgeOS. Use it only on hardware and firmware for which it has been explicitly validated, and ensure you have an alternate management/recovery path before experimenting with unsupported configurations.
