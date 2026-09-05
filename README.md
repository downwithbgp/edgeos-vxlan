# edgeos-vxlan

Native VXLAN support for the Ubiquiti EdgeRouter X running EdgeOS 3.0.1.

This project adds the missing Linux `vxlan.ko` kernel module and integrates VXLAN interfaces into the native EdgeOS/Vyatta configuration system.

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
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.1.0/install.sh |
  sh -s -- --check
```

Install `edgeos-vxlan`:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.1.0/install.sh |
  sudo sh
```

The installer:

* verifies the EdgeOS firmware and running kernel;
* downloads the matching kernel-module and EdgeOS integration packages;
* verifies both packages against SHA-256 hashes pinned in the tagged installer;
* installs the kernel module first, followed by the EdgeOS integration.

Prefer to inspect the script before running it as root?

```bash
curl -fLO \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.1.0/install.sh

less install.sh
sudo sh install.sh
```

The installer is pinned to release `v0.1.0`; it does not execute the moving `main` branch.

## Supported platform

Version `0.1.0` is deliberately restricted to the platform on which it has been built and tested.

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
* Native `interfaces vxlan vxlanN` EdgeOS configuration
* Persistent configuration through `/config/config.boot`
* Automatic module loading
* VXLAN restoration during boot
* Integration with `show interfaces`
* Integration with `show configuration commands`
* IPv4 and IPv6 interface-address syntax
* Native address validation
* Configurable:

  * VNI
  * local underlay address
  * remote underlay address
  * UDP destination port
  * MTU
  * interface addresses
  * description
  * administrative disable state
* Non-disruptive updates for mutable interface properties
* Controlled interface recreation for VXLAN identity changes
* Rollback to the previous live interface state if recreation fails
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
```

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
* VXLAN recognition in `Vyatta::Interface`

It depends on the exact matching kernel package and the tested EdgeOS configuration packages.

## Installation

Copy both packages to the router.

Install the kernel module first:

```bash
sudo dpkg -i \
  edgeos-vxlan-kmod_0.1.0+edgeos3.0.1.e50_mipsel.deb
```

Then install the EdgeOS integration package:

```bash
sudo dpkg -i \
  edgeos-vxlan_0.1.0+edgeos3.0.1.e50_all.deb
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

## Configuration tree

The current configuration tree is:

```text
interfaces {
    vxlan vxlanN {
        address <address/prefix>
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
4. restores the configured mutable state;
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

After reboot, the VXLAN kernel module, native configuration, deterministic MAC address, MTU, interface address, and operational state are restored.

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

Removing the integration package also restores the original diverted `Vyatta::Interface` file.

## Kernel build provenance

The EdgeRouter X firmware does not ship `vxlan.ko`.

The module included with this project was built from Ubiquiti's published EdgeOS GPL source.

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

## RC9 / EdgeOS 3.0.1 compatibility evidence

The available GPL source release predates the final EdgeOS 3.0.1 firmware build.

Compatibility was validated by comparing an existing kernel module supplied by EdgeOS against a module rebuilt from the GPL source.

The stock final-firmware `udp_tunnel.ko` and the rebuilt module had:

* matching size;
* matching module metadata;
* matching vermagic;
* byte-identical `.text` sections.

The `.text` section SHA-256 was:

```text
699c6b77728c5d6660acd7d341896f729693aa72c7e44367746eb16888b96baa
```

The Vyatta `Interface.pm` from the GPL source was also byte-for-byte identical to the stock EdgeOS 3.0.1 copy used during development.

This provides strong evidence that the relevant kernel and Vyatta interface code did not materially change between the published GPL release and the tested final firmware.

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
edgeos-vxlan_0.1.0+edgeos3.0.1.e50_all.deb

edgeos-vxlan-kmod_0.1.0+edgeos3.0.1.e50_mipsel.deb
```

Packages are compressed using gzip for compatibility with the older `dpkg` version shipped by EdgeOS.

## Repository layout

```text
.
├── debian/
├── modules/
│   └── 4.14.54-UBNT/
│       └── vxlan.ko
├── src/
│   ├── Interface.pm
│   └── vyatta-vxlan
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

Version `0.1.0` has been tested for:

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
* `dpkg-divert` restoration of the stock EdgeOS Perl module.

A point-to-point test between the EdgeRouter X and a Linux host successfully passed bidirectional traffic over the VXLAN interface.

## Known limitations

Version `0.1.0` is intentionally small in scope.

Not yet validated or implemented as first-class configuration features:

* EVPN control plane
* multicast VXLAN
* bridge integration
* VLAN-to-VNI mapping
* flood-and-learn configuration beyond the basic Linux defaults
* IPv6 underlay
* multiple remote VTEPs
* VXLAN-specific FDB configuration
* hardware offload
* other EdgeRouter models
* other EdgeOS releases

The current implementation has primarily been validated as a point-to-point VXLAN tunnel over an IPv4 underlay.

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
