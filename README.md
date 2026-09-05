# edgeos-vxlan

Native VXLAN support for the Ubiquiti EdgeRouter X running EdgeOS 3.0.1.

This project adds the missing Linux `vxlan.ko` kernel module and integrates VXLAN interfaces into the native EdgeOS/Vyatta configuration system. The v0.2 kernel package also carries a narrowly scoped `udp_tunnel.ko` backport for CVE-2022-50405 on the supported EdgeOS 3.0.1 kernel.

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
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.2.0/install.sh |
  sh -s -- --check
```

Install `edgeos-vxlan`:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.2.0/install.sh |
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
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.2.0/install.sh

less install.sh
sudo sh install.sh
```

The installer is pinned to release `v0.2.0`; it does not execute the moving `main` branch.


## Supported platform

Version `0.2.0` is deliberately restricted to the platform on which it has been built and tested.

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
* Persistent configuration through `/config/config.boot`
* Automatic module loading
* VXLAN restoration during boot
* Integration with `show interfaces`
* Integration with `show configuration commands`
* IPv4 and IPv6 interface-address syntax
* Native address validation
* Native bridge membership through `bridge-group bridge brN`
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
* Non-disruptive updates for mutable interface properties, including bridge membership
* Controlled interface recreation for VXLAN identity changes
* Rollback to the previous live interface state, including bridge membership, if recreation fails
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
* the `vyatta-vxlan-bridge` bridge-membership helper
* VXLAN recognition in `Vyatta::Interface`

It depends on the exact matching kernel package and the tested EdgeOS configuration packages.

## Installation

Copy both packages to the router.

Install the kernel module first:

```bash
sudo dpkg -i \
  edgeos-vxlan-kmod_0.2.0+edgeos3.0.1.e50_mipsel.deb
```

Then install the EdgeOS integration package:

```bash
sudo dpkg -i \
  edgeos-vxlan_0.2.0+edgeos3.0.1.e50_all.deb
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


### Bridged VXLAN

A VXLAN interface can be attached to a native EdgeOS bridge:

```text
configure

set interfaces bridge br42
set interfaces bridge br42 address 198.51.100.1/30

set interfaces vxlan vxlan42 bridge-group bridge br42
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

Bridge membership is mutable. Moving `vxlan42` between bridges, adding it to a bridge, or removing it from a bridge does not by itself recreate the VXLAN interface. If a VXLAN identity change does require recreation, the configured bridge membership is restored afterward and is also included in rollback and boot restoration.

## Configuration tree

The current configuration tree is:

```text
interfaces {
    vxlan vxlanN {
        address <address/prefix>
        bridge-group {
            bridge <brN>
        }
        description <text>
        disable
        local-ip <IPv4 address>
        mtu <64-8024>
        port <1-65535>
        remote-ip <IPv4 address>
        vni <0-16777215>
    }
}
```

`vni`, `local-ip`, and `remote-ip` are required.

The default UDP destination port is:

```text
4789
```

The default MTU is:

```text
1450
```

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

After reboot, the VXLAN kernel module, patched UDP-tunnel dependency, native configuration, deterministic MAC address, MTU, interface address or bridge membership, and operational state are restored.

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
edgeos-vxlan_0.2.0+edgeos3.0.1.e50_all.deb

edgeos-vxlan-kmod_0.2.0+edgeos3.0.1.e50_mipsel.deb
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
│   └── vyatta-vxlan-bridge
├── templates/
│   └── interfaces/
│       └── vxlan/
└── upstream/
    └── libvyatta-cfg1/
        └── Interface.pm
```

`upstream/libvyatta-cfg1/Interface.pm` is the pristine upstream reference.

`src/Interface.pm` is the package-installed version with the minimal VXLAN interface recognition change.

## Tested behavior

Version `0.2.0` has been tested for:

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
* rejection of simultaneous VXLAN interface addresses and bridge membership;
* literal interface descriptions containing shell metacharacters;
* patched `udp_tunnel.ko` runtime loading and cold boot;
* repeated VXLAN teardown/recreation under active receive traffic;
* alternate-source VXLAN receive behavior demonstrating that `remote-ip` is not an ingress ACL.
* EdgeOS `local` firewall enforcement restricting UDP/4789 to an intended fixed peer;

A point-to-point test between the EdgeRouter X and a Linux host successfully passed bidirectional traffic over the VXLAN interface.

## Known limitations

Version `0.2.0` remains intentionally small in scope.

Not yet validated or implemented as first-class configuration features:

* EVPN control plane
* multicast VXLAN
* bridge-group cost/priority controls
* VLAN-to-VNI mapping
* flood-and-learn configuration beyond the basic Linux defaults
* IPv6 underlay
* multiple remote VTEPs
* VXLAN-specific FDB configuration
* hardware offload
* other EdgeRouter models
* other EdgeOS releases

The current implementation has been validated for routed point-to-point VXLAN and native bridge attachment over an IPv4 underlay. It remains a fixed-remote, Linux VXLAN dataplane integration rather than a VXLAN control-plane implementation.

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
