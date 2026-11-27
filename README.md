# edgeos-vxlan

Native VXLAN for IPv6 and IPv4 underlays on the Ubiquiti EdgeRouter X running EdgeOS 3.0.1.

This project adds the missing Linux `vxlan.ko` kernel module and integrates VXLAN interfaces into
the native EdgeOS/Vyatta configuration system. IPv6 is the primary deployment model: the project
supports IPv6 and IPv4 VXLAN underlays, with the overlay Layer 3 family chosen independently. IPv4
remains supported for interoperability and existing deployments. The kernel package also carries a
narrowly scoped `udp_tunnel.ko` backport for CVE-2022-50405 on the supported EdgeOS 3.0.1 kernel.

> **Documentation orientation.** Configuration examples begin with IPv6. The
> [architecture note](docs/architecture.md) explains the underlay/overlay distinction;
> the [deployment guide](docs/deployment.md) provides both endpoints for all six
> documented scenarios; the [support matrix](docs/address-family-support-matrix.md) records what
> has been validated and what remains unverified. Historical release records are preserved in
> `docs/`; the full map is [`docs/README.md`](docs/README.md). Engineering proposals are in the
> [backlog](docs/engineering-backlog.md).

Primary example — IPv6 underlay, IPv6 overlay:

```text
configure

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 address 2001:db8:42::1/64
set interfaces vxlan vxlan42 mtu 1430

commit
save
exit
```

The underlay interface must already carry the local address and have a route to the peer; only the
`interfaces vxlan` lines are managed by this project. The matching Router B configuration and the
other address-family combinations are in the [deployment guide](docs/deployment.md).

Verify the interface and the IPv6 overlay address:

```bash
show interfaces
ip -j -d link show dev vxlan42
ip -6 addr show dev vxlan42
```

Use the JSON form for tunnel identity on this platform; the vendor `ip -d` human output corrupts
numeric fields. A successful IPv6 overlay check includes:

```text
$ ip -6 addr show dev vxlan42
    inet6 2001:db8:42::1/64 scope global
```

`show interfaces` reports the interface state; it does not replace the address-family-specific
checks.

## Quick install

The currently published release is **v0.3.0**. It adds native EdgeOS firewall attachments for
VXLAN interfaces while keeping the v0.2.x interface feature set; see
[`docs/v0.3.0-release-notes.md`](docs/v0.3.0-release-notes.md) for features, supported workflows and
limitations. Existing v0.2.2 installations upgrade in place.

> **Supported workflows and important limitations.** Firewall ruleset changes must be made in the
> interactive EdgeOS CLI; scripted (script-template) commits can misapply them on EdgeOS 3.0.1. The
> extension manages enforcement during its own configuration lifecycle — it is **not** a continuous
> firewall integrity monitor. Bridged firewall attachments are not supported. See
> [`docs/v0.3.0-support-boundary.md`](docs/v0.3.0-support-boundary.md) and
> [`docs/v0.3.0-edgeos-scripted-commit-limitation.md`](docs/v0.3.0-edgeos-scripted-commit-limitation.md).

Check whether your router is supported without making any changes:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.3.0/install.sh |
  sh -s -- --check
```

Install `edgeos-vxlan`:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.3.0/install.sh |
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
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.3.0/install.sh

less install.sh
sudo sh install.sh
```

The installer is pinned to release `v0.3.0`; it does not execute the moving `main` branch.


## Supported platform

The project is deliberately restricted to the platform on which it has been built and tested.

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
* IPv6 and IPv4 VXLAN underlays (`local-ip`/`remote-ip`), with the endpoint family enforced
* Family-aware default MTU — 1430 over an IPv6 underlay, 1450 over an IPv4 underlay
* Canonical endpoint comparison, so an equivalent re-spelling does not recreate the interface
* Endpoint validation that rejects malformed, prefix-carrying, mixed-family and unusable addresses before anything is changed
* Fail-closed live-state capture before any destructive step
* Persistent configuration through `/config/config.boot`
* Automatic module loading
* VXLAN restoration during boot
* Integration with `show interfaces`
* Integration with `show configuration commands`
* IPv6 and IPv4 overlay interface-address syntax
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
* Native EdgeOS firewall attachment for routed VXLAN interfaces:
  * `firewall in`, `firewall out` and `firewall local`
  * IPv6 `ipv6-name` and IPv4 `name` rulesets, independently of the underlay family
  * commit-time reference validation and completion from the configured rulesets
  * fail-closed verification that the interface dispatch is effective before the interface is activated
  * dispatch snapshot/restore across recreation failures
  * rejection of firewall attachments on VXLAN bridge ports
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
* the `vyatta-vxlan-firewall` attachment lifecycle helper
* VXLAN recognition in `Vyatta::Interface`

The integration package depends on the stock `vyatta-cfg-firewall` package (the `firewall name` /
`firewall ipv6-name` configuration tree) and `iptables`. It does not pull in a new firewall engine or a
new userspace dependency beyond what the supported firmware already provides.

It depends on the exact matching kernel package and the tested EdgeOS configuration packages.

## Installation

Copy both packages to the router.

Install the kernel module first:

```bash
sudo dpkg -i \
  edgeos-vxlan-kmod_0.3.0+edgeos3.0.1.e50_mipsel.deb
```

Then install the EdgeOS integration package:

```bash
sudo dpkg -i \
  edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb
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

### Upgrading from v0.2.2 to v0.3.0

v0.3.0 upgrades from v0.2.2 without changing existing VXLAN configuration. Configurations without
`firewall` attachments keep their established unfiltered behavior; the attachment subtree is
optional. Install both packages in a single `dpkg` transaction, kernel package first:

```bash
sudo dpkg -i \
  edgeos-vxlan-kmod_0.3.0+edgeos3.0.1.e50_mipsel.deb \
  edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb
```

The upgrade replaces files and leaves live interfaces in place. The integration package now depends on
`vyatta-cfg-firewall` and `iptables`, both already present on the supported firmware. Verify with
`dpkg -V edgeos-vxlan edgeos-vxlan-kmod`, `show configuration commands`, and the firewall status
commands in the native firewall section.

The package upgrade RC5 → 0.3.0 was qualified on the EdgeRouter X with the operational `vxlan41913`
interface and its native attachments in place; the runtime payload is byte-identical to RC5, so a
loaded module stays valid until the next reboot.

### Upgrading from v0.2.1

Upgrade both packages in a single `dpkg` invocation, kernel package first:

```bash
sudo dpkg -i \
  edgeos-vxlan-kmod_0.2.2+edgeos3.0.1.e50_mipsel.deb \
  edgeos-vxlan_0.2.2+edgeos3.0.1.e50_all.deb
```

The upgrade replaces files only: it does not modify the saved configuration, recreate interfaces, or unload a loaded module (`depmod`/`modprobe` run, and an already-loaded `udp_tunnel` is left alone until a safe reload or reboot). Verify the result with `dpkg -V edgeos-vxlan edgeos-vxlan-kmod` (silent) and `dpkg --audit`.

The package-upgrade path has been exercised with a live tunnel on the supported platform (release-candidate pair) and in container simulations of the v0.2.1 ↔ release-candidate transactions. The exact v0.2.1 → v0.2.2 upgrade carrying an existing, active **IPv4** VXLAN has not been directly hardware-tested — after upgrading, review the tunnel (`ip -j -d link show dev vxlanN`, `show interfaces`) and re-commit if you want to exercise the configuration path.

A downgrade uses the same single invocation with the v0.2.1 files; `dpkg` prints a `downgrading ...` warning, which is expected.

## Configuration

The configuration tree is the same for every address-family combination: `local-ip`/`remote-ip`
select the underlay family, and `address` selects the overlay family. The order below is the
documentation order, not a requirement.

Complete two-endpoint configurations, verification commands and the IPv6 operational guidance are
in the [deployment guide](docs/deployment.md). The example below shows Router A; Router B uses the
peer addresses and the same VNI, port and MTU.

### Scenario 1: IPv6 underlay with IPv6 overlay (primary)

```text
configure

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 address 2001:db8:42::1/64
set interfaces vxlan vxlan42 mtu 1430

commit
save
exit
```

Router B uses `local-ip 2001:db8:10::2`, `remote-ip 2001:db8:10::1`, and
`address 2001:db8:42::2/64`, with the same VNI, port and MTU.

Verify with `ping6 -c 3 2001:db8:42::2` from Router A and the mirror command from Router B. The
underlay addresses must be reachable first.

### Address-family combinations

The primary example above is the model for a new IPv6 deployment. The full two-endpoint
configurations, verification steps and operational notes for every documented scenario are in the
deployment guide:

| Underlay | Overlay | Guide |
|---|---|---|
| IPv6 | IPv6 | [Scenario 1](docs/deployment.md#2-scenario-1-ipv6-underlay-with-ipv6-overlay) |
| IPv6 | Bridged Ethernet | [Scenario 2](docs/deployment.md#3-scenario-2-ipv6-underlay-with-bridged-ethernet) |
| IPv6 | Dual-stack IPv6 and IPv4 | [Scenario 3](docs/deployment.md#4-scenario-3-ipv6-underlay-with-a-dual-stack-overlay) |
| IPv4 | IPv6 | [Scenario 4](docs/deployment.md#5-scenario-4-ipv4-underlay-with-ipv6-overlay) |
| IPv6 | IPv4 | [Scenario 5](docs/deployment.md#6-scenario-5-ipv6-underlay-with-ipv4-overlay) |
| IPv4 | IPv4 | [Scenario 6](docs/deployment.md#7-scenario-6-ipv4-underlay-with-ipv4-overlay-legacy) |

The [address-family matrix](docs/address-family-support-matrix.md) records which combinations are
demonstrated on hardware, which have off-device evidence, and which are inferred from the Linux
VXLAN dataplane. The matrix also lists an IPv4-underlay/dual-stack variant: it is the scenario 6
underlay with the dual-stack addressing from scenario 3, not a separate scenario, and it is not
separately hardware-qualified.

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
        firewall {
            in {
                ipv6-name <IPv6 ruleset>
                name <IPv4 ruleset>
            }
            out {
                ipv6-name <IPv6 ruleset>
                name <IPv4 ruleset>
            }
            local {
                ipv6-name <IPv6 ruleset>
                name <IPv4 ruleset>
            }
        }
        local-ip <IPv6 or IPv4 address>
        mtu <68-8024>
        port <1-65535>
        remote-ip <IPv6 or IPv4 address>
        vni <1-16777215>
    }
}
```

The `firewall` subtree attaches existing `firewall name` / `firewall ipv6-name` rulesets; it does not create or modify policy. `firewall` attachments are supported on routed VXLAN interfaces and rejected when the interface is a bridge port. See the [native firewall guide](docs/native-firewall.md).

`vni`, `local-ip`, and `remote-ip` are required, and `local-ip`/`remote-ip` must be the same address family. The `mtu` minimum is the kernel's own VXLAN minimum (68): a value the kernel cannot apply is rejected at commit time instead of failing later.

The default UDP destination port is:

```text
4789
```

### MTU and IPv6 operational constraints

The VXLAN interface MTU is the maximum inner IP packet size. On a standard untagged 1500-byte path
the family defaults are 1430 over IPv6 and 1450 over IPv4. The component calculation, its
assumptions, VLAN/PPPoE adjustments and the IPv6 1280-byte minimum are in
[`architecture.md`](docs/architecture.md#6-encapsulation-overhead-and-mtu).

Path MTU Discovery (underlay and overlay), ICMPv6 Packet Too Big, Neighbor Discovery, Router
Advertisements and SLAAC, source-address selection, UDP checksums, routing asymmetry and overlay
link-local traffic are covered in
[`deployment.md`](docs/deployment.md#8-ipv6-operational-considerations).

## Lifecycle and persistence

A VXLAN identity change — VNI, local or remote endpoint, UDP port, or underlay address family —
recreates the interface. Mutable properties are applied in place: MTU, interface addresses, bridge
membership, description, administrative state and firewall attachments. Recreation captures and
restores the previous live state; a failed firewall dispatch leaves the interface down rather than
operational without policy. The interface index changes on recreation and is not preserved.

Deterministic MAC addresses, failed-commit handling, EdgeOS integration, boot persistence, removal
safeguards and platform diagnostics are in
[`interface-lifecycle.md`](docs/interface-lifecycle.md).

## Security and firewall

`remote-ip` is an outbound VXLAN destination, not an ingress allowlist or authentication. Restrict
outer UDP/4789 with a `firewall local` policy on the underlay interface, and apply inner policy with
`firewall in`/`out`/`local` on the VXLAN interface. The overlay policy families are independent of
the underlay family. Bridged VXLAN interfaces reject firewall attachments; bridged Layer 2
enforcement is not supported. VXLAN does not provide authentication or confidentiality.

See [`native-firewall.md`](docs/native-firewall.md) for syntax, lifecycle, underlay IPv6 and IPv4
examples, verification and the tested/unsupported cases. A full tunnelbroker policy example is in
[`deployment.md`](docs/deployment.md#5-scenario-4-ipv4-underlay-with-ipv6-overlay).

## Kernel and build

The firmware does not ship `vxlan.ko`; the package supplies it and a narrowly scoped `udp_tunnel.ko`
backport for CVE-2022-50405. Module hashes, GPL source provenance, RC9/EdgeOS compatibility evidence
and package build instructions are in
[`kernel-provenance.md`](docs/kernel-provenance.md).

## Repository layout

```text
.
├── .github/
├── debian/
├── docs/
├── modules/
│   └── 4.14.54-UBNT/
│       ├── udp_tunnel.ko
│       └── vxlan.ko
├── patches/
│   └── 4.14.54-UBNT/
│       └── CVE-2022-50405.patch
├── scripts/
├── src/
│   ├── Interface.pm
│   ├── vyatta-vxlan
│   ├── vyatta-vxlan-addr
│   ├── vyatta-vxlan-bridge
│   └── vyatta-vxlan-firewall
├── templates/
│   └── interfaces/
│       └── vxlan/
├── test/
│   ├── run.sh
│   ├── unit-helper.sh
│   ├── unit-firewall.sh
│   ├── unit-templates.sh
│   ├── mock.sh
│   ├── integration-netns.sh
│   ├── ipv6-only-netns.sh
│   └── lib/
│       └── ipv6-isolation.sh
├── upstream/
│   └── libvyatta-cfg1/
│       └── Interface.pm
├── install.sh
└── README.md
```

`upstream/libvyatta-cfg1/Interface.pm` is the pristine upstream reference.

`src/Interface.pm` is the package-installed version with the minimal VXLAN interface recognition change.

## Tested behavior

Hardware qualification and off-device evidence are recorded by address-family combination in the
[support matrix](docs/address-family-support-matrix.md). In summary: RC5 was hardware-qualified on
the ER-X for the native firewall matrix, lifecycle, `vxlan41913` migration and reboot; the
v0.2.1/v0.2.2 line validated the IPv4 dataplane and the IPv6-underlay IPv4, IPv6 and dual-stack
dataplane; the off-device suite currently has 376 checks (11 build + 64 helper + 122 firewall +
93 templates + 70 mock + 16 qualification-evidence contract). An additional isolated IPv6-only namespace suite (Level B) exercises a
routed IPv6 underlay, host-to-host TCP/UDP, NDP, MTU boundaries and explicit IPv4-isolation
assertions; it is not hardware evidence. Independent external OCI probes remain deferred. The matrix distinguishes demonstrated, partially demonstrated and inferred behavior.

## Known limitations

Version `0.3.0` remains intentionally small in scope.

* **VTEP endpoints are statically configured.** The tunnel is a fixed-remote point-to-point link; a delegated-prefix change on the underlay is not tracked automatically — update `local-ip`/`remote-ip` and commit after a prefix change. Dynamic underlay addressing (SLAAC/DHCPv6) at boot has not been validated.
* **EdgeOS commits are not universally atomic.** A failed commit can leave partially applied configuration in some cases; after a failed VXLAN commit, do not `save` — compare the active configuration with the kernel and re-converge first. See [failed commits and partial configuration](docs/interface-lifecycle.md#failed-commits-and-partial-configuration).
* **Upgrade from v0.2.2 with a live IPv4 VXLAN has not been directly hardware-tested.** The package-upgrade mechanism has been validated for the v0.2.x line (including with a live tunnel and container simulations), and the packages make no configuration or interface changes on upgrade. The RC5 → 0.3.0 upgrade with live native attachments was qualified on the ER-X.
* **Firewall policy is the operator's responsibility.** The package attaches existing `firewall name`/`firewall ipv6-name` rulesets; it does not create, rename, or modify them. `remote-ip` is not an ingress allowlist — see the [native firewall guide](docs/native-firewall.md).
* **Bridged L2 firewall enforcement is not supported.** VXLAN bridge ports reject firewall attachments; global bridge netfilter is not enabled. Routed VXLAN is the supported enforcement case.
* **`modify` and `ipv6-modify` (mangle) attachments are not exposed** for VXLAN in this release. `in`, `out` and `local` are the supported directions.
* **`firewall out` follows native EdgeOS semantics**: it matches forwarded traffic leaving the interface, not traffic originated by the router.
* **No continuous out-of-band firewall monitor.** If a dispatch is removed outside a configuration commit, the next VXLAN lifecycle commit detects and repairs it; there is no daemon watching the dataplane.
* **IPv6-only management, package acquisition and CI infrastructure are not validated.** The VXLAN dataplane and the isolated Level B namespace environment can run with IPv6 only. Level C (installation and management over IPv6 only) and Level D (an IPv6-only runner and CI control plane) remain gaps; see [`docs/ipv6-only-qualification.md`](docs/ipv6-only-qualification.md).
* **Bridged VXLAN dataplane over an IPv6 underlay is not fully validated.** Bridge membership, path cost and priority are verified; packets over the bridged tunnel are not part of the published hardware record.
* **Hardware qualification is complete for the RC5 scope, not for every combination.** The RC5 qualification covers the isolated firewall matrix, lifecycle, the `vxlan41913` migration and reboot. Independent external OCI probes and the combinations listed as gaps in the [support matrix](docs/address-family-support-matrix.md) remain unverified.
* **The vendor `ip -d` human output is defective** on EdgeOS 3.0.1; use `ip -j -d`. The reconciler does.

Future engineering work is tracked in [`docs/engineering-backlog.md`](docs/engineering-backlog.md).

Not yet validated or implemented as configuration features:

* EVPN control plane
* multicast VXLAN
* dynamic peer discovery
* VLAN-to-VNI mapping
* flood-and-learn configuration beyond the basic Linux defaults
* multiple remote VTEPs
* VXLAN-specific FDB configuration
* hardware offload
* other EdgeRouter models
* other EdgeOS releases

The implementation has been hardware-validated for routed point-to-point VXLAN with IPv6
underlays carrying IPv4, IPv6, or dual-stack overlays, and with IPv4 underlays carrying IPv4
overlays; native bridge state is validated on the supported platform. The
[support matrix](docs/address-family-support-matrix.md) records the remaining gaps, including
IPv4-underlay/IPv6-overlay, IPv4-underlay/dual-stack, and bridged dataplane over IPv6. The project
remains a fixed-remote, Linux VXLAN dataplane integration rather than a VXLAN control-plane
implementation.

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
