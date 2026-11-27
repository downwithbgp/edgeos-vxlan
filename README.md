# edgeos-vxlan

Native VXLAN for IPv6 and IPv4 underlays on the Ubiquiti EdgeRouter X running EdgeOS 3.0.1.

This project adds the missing Linux `vxlan.ko` kernel module and integrates VXLAN interfaces into
the native EdgeOS/Vyatta configuration system. IPv6 is the primary deployment model: the project
supports IPv6 and IPv4 VXLAN underlays, with the overlay Layer 3 family chosen independently. IPv4
remains supported for interoperability and existing deployments. The kernel package also carries a
narrowly scoped `udp_tunnel.ko` backport for CVE-2022-50405 on the supported EdgeOS 3.0.1 kernel.

> **Documentation orientation.** Configuration examples are ordered IPv6-first. The
> [architecture note](docs/ipv6-first-architecture.md) explains the underlay/overlay distinction;
> the [deployment guide](docs/ipv6-first-deployment.md) provides both endpoints for all six
> supported combinations; the [support matrix](docs/address-family-support-matrix.md) records what
> has been validated and what remains unverified. Historical release records are preserved in
> `docs/`; the full map is [`docs/README.md`](docs/README.md).

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

The matching Router B configuration and the other address-family combinations are in the
[IPv6-first deployment guide](docs/ipv6-first-deployment.md).

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

The configuration tree is the same for every address-family combination: `local-ip`/`remote-ip`
select the underlay family, and `address` selects the overlay family. The order below is the
documentation order, not a requirement.

Complete two-endpoint configurations, verification commands and the IPv6 operational guidance are
in the [IPv6-first deployment guide](docs/ipv6-first-deployment.md). The examples below show Router
A; Router B uses the peer addresses and the same VNI, port and MTU.

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

### Scenario 2: IPv6 underlay with bridged Ethernet

```text
configure

set interfaces bridge br42 address 2001:db8:42::1/64

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1430
set interfaces vxlan vxlan42 bridge-group bridge br42
set interfaces vxlan vxlan42 bridge-group cost 200
set interfaces vxlan vxlan42 bridge-group priority 10

commit
save
exit
```

The VXLAN interface is a bridge port and must not also have a direct `address`. Put the Layer 3
address on the bridge. Bridged VXLAN interfaces reject `firewall` attachments; bridged Layer 2
firewall enforcement is not supported. Router B uses `address 2001:db8:42::2/64` on `br42` and the
peer endpoint values.

For a legacy IPv4-underlay bridged deployment, use the same bridge structure with IPv4 VTEP and
bridge addresses. Router A:

```text
set interfaces bridge br42 address 198.51.100.1/30
set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 mtu 1450
set interfaces vxlan vxlan42 bridge-group bridge br42
set interfaces vxlan vxlan42 bridge-group cost 200
set interfaces vxlan vxlan42 bridge-group priority 10
```

Router B mirrors this with `br42` `198.51.100.2/30`, `local-ip 192.0.2.2`, and
`remote-ip 192.0.2.1`.

### Scenario 3: IPv6 underlay with a dual-stack overlay

```text
configure

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 address 2001:db8:42::1/64
set interfaces vxlan vxlan42 address 198.51.100.1/30
set interfaces vxlan vxlan42 mtu 1430

commit
save
exit
```

Both overlay families can be active at once. The overlay firewall families are independent of the
underlay family; `firewall in name` and `firewall in ipv6-name` may both be attached.

### Scenario 4: IPv4 underlay with IPv6 overlay

```text
configure

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 address 2001:db8:42::1/64
set interfaces vxlan vxlan42 mtu 1450

commit
save
exit
```

This is an interoperability case: the outer IP header is IPv4 and the inner Layer 3 protocol is
IPv6. The underlay peer filter uses an IPv4 `firewall name` ruleset; the overlay policy uses
`firewall ipv6-name`. This combination is implemented but is not separately hardware-qualified in
the published record; see the [support matrix](docs/address-family-support-matrix.md).

### Scenario 5: IPv6 underlay with IPv4 overlay

```text
configure

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 2001:db8:10::1
set interfaces vxlan vxlan42 remote-ip 2001:db8:10::2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 address 198.51.100.1/30
set interfaces vxlan vxlan42 mtu 1430

commit
save
exit
```

The outer IPv6 path still depends on IPv6 reachability, Neighbor Discovery and ICMPv6 Packet Too
Big handling. The underlay peer filter uses an IPv6 `firewall ipv6-name` ruleset; the overlay policy
uses `firewall name`.

### Scenario 6: IPv4 underlay with IPv4 overlay (legacy)

```text
configure

set interfaces vxlan vxlan42 vni 42
set interfaces vxlan vxlan42 local-ip 192.0.2.1
set interfaces vxlan vxlan42 remote-ip 192.0.2.2
set interfaces vxlan vxlan42 port 4789
set interfaces vxlan vxlan42 address 198.51.100.1/30
set interfaces vxlan vxlan42 mtu 1450

commit
save
exit
```

Existing IPv4 configurations with canonical literals keep their meaning. Non-canonical IPv4
literals follow the platform's octal interpretation; see the [documentation audit](docs/documentation-audit-2026-11.md).

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

The `firewall` subtree attaches existing `firewall name` / `firewall ipv6-name` rulesets; it does not create or modify policy. `firewall` attachments are supported on routed VXLAN interfaces and rejected when the interface is a bridge port. See [Native interface firewall](#native-interface-firewall).

`vni`, `local-ip`, and `remote-ip` are required, and `local-ip`/`remote-ip` must be the same address family. The `mtu` minimum is the kernel's own VXLAN minimum (68): a value the kernel cannot apply is rejected at commit time instead of failing later.

The default UDP destination port is:

```text
4789
```

The default MTU is family-aware: `1430` over an IPv6 underlay and `1450` over an IPv4 underlay on a standard untagged 1500-byte path.

### MTU guidance

The VXLAN interface MTU must fit inside the underlay path MTU. A full-size inner Ethernet frame adds:

| Component | IPv6 underlay | IPv4 underlay |
|---|---:|---:|
| Outer IP header | 40 bytes | 20 bytes |
| UDP header | 8 bytes | 8 bytes |
| VXLAN header | 8 bytes | 8 bytes |
| Inner Ethernet header | 14 bytes | 14 bytes |
| **Total overhead** | **70 bytes** | **50 bytes** |
| **Overlay IP MTU over a 1500-byte underlay** | **1430** | **1450** |

The calculation assumes a 1500-byte underlay path, one untagged outer Ethernet header, no IPv4
options, no IPv6 extension headers, no additional encapsulation, and no inner VLAN tag. An inner
802.1Q tag reduces the overlay IP MTU by 4 bytes; an outer 802.1Q tag reduces the usable path MTU by
4 bytes. A PPPoE path whose MTU is already 1492 has already accounted for its 8-byte PPPoE overhead;
do not subtract it twice. These are calculations for the stated assumptions, not universal values.

The integration does not rely on over-sized outer packets being fragmented: size the tunnel for the
path, and set an explicit `mtu` when the underlay differs from the standard case. An explicit `mtu`
is authoritative. The kernel's VXLAN minimum of 68 is not an IPv6 deployment target: an IPv6 link
must support at least 1280 bytes (RFC 8200), so an underlay path used for an IPv6 overlay must leave
at least 1280 bytes after the 70-byte overhead. On a 1500-byte path the default 1430 does so; on a
1280-byte underlay path the calculated 1210 is below the IPv6 minimum.

### IPv6 operational considerations

IPv6 requirements do not disappear because VXLAN is carrying the packets. The
[deployment guide](docs/ipv6-first-deployment.md#8-ipv6-operational-considerations) covers the
details; the points that most often break a deployment are:

* **Path MTU Discovery and ICMPv6 Packet Too Big.** Permit Packet Too Big (type 2) on the underlay
  and through the overlay policy. Do not rely on outer IPv6 fragmentation; the integration does not
  fragment oversized outer packets. Clamp TCP MSS when the deployment requires it; the interface
  MTU is not an MSS clamp.
* **Neighbor Discovery.** Permit NS/NA (ICMPv6 types 135/136) on the underlay and overlay. If
  Router Advertisements and SLAAC are used, also permit RS/RA (types 133/134) as appropriate.
* **IPv6 minimum MTU.** An IPv6 overlay needs at least 1280 bytes; with 70 bytes of VXLAN overhead,
  the underlay path must be at least 1350 bytes.
* **Source address selection.** Configure a `local-ip` that the peer can reach, or verify the
  kernel's selected source when `local-ip` is unspecified. Ensure the return path reaches that
  source.
* **Endpoint scope.** For IPv6, link-local, multicast, loopback, IPv4-mapped, and unspecified
  remote endpoints are rejected. An unspecified local endpoint is accepted. IPv4 endpoint
  acceptance is unchanged from v0.2.x; the IPv6 class checks do not apply to IPv4. IPv6 endpoint
  text is canonicalised before comparison.
* **UDP checksums.** IPv6 UDP checksums are enabled by default and the integration does not expose
  zero-checksum options. Local capture warnings caused by checksum offload are not authoritative.
* **Firewall boundaries.** Restrict outer UDP/4789 on the underlay interface; apply inner policy with
  `firewall in`/`out`/`local` on the VXLAN interface. `remote-ip` is not an ingress allowlist.
  Bridged VXLAN interfaces reject firewall attachments.
* **Routing and asymmetry.** The remote VTEP must have a return route to the configured local
  address. A route that sends the peer back through the tunnel, or an asymmetric policy-routing
  choice, can produce a tunnel that is up but carries no traffic.
* **Management plane.** Keep management access independent of the tunnel. IPv6-only management,
  package acquisition, and CI are not validated project capabilities; only the dataplane is.

## Interface update behavior

The integration distinguishes between mutable properties and VXLAN identity.

The following properties are changed in place without recreating the interface:

* MTU
* interface addresses
* bridge membership
* description
* administrative state
* firewall attachments (`in`, `out`, `local`; IPv6 and IPv4)

Firewall attachments are applied by the reconciler **before** any netdevice mutation, then verified.
A firewall-only change therefore does not recreate the interface. The pre-change dispatch is captured
so a failed recreation can restore it.

The following properties define the VXLAN tunnel identity and require interface recreation:

* VNI
* local IP
* remote IP
* UDP destination port
* the underlay address family (implied by the endpoints; an IPv4 ↔ IPv6 change is an identity change)

When an identity change is committed, the integration:

1. captures the existing live VXLAN state, including the effective firewall dispatch;
2. applies the desired firewall attachment set and verifies it;
3. removes the old interface;
4. creates the requested VXLAN interface;
5. restores the configured mutable state, including bridge membership;
6. verifies the required firewall attachments immediately before bringing the interface up;
7. brings the interface to the requested administrative state.

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
* firewall attachments (`in`, `out`, `local`, IPv6 and IPv4)
* administrative state

If the previous firewall dispatch cannot be reconstructed, the interface is left administratively
down and the failure is reported; it is not brought up with an unknown policy.

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

After reboot, the VXLAN kernel module, patched UDP-tunnel dependency, native configuration, deterministic MAC address, MTU, interface address or bridge membership, and operational state are restored. Save + reboot restoration was re-validated with an IPv6 underlay on the release candidate: the tunnel, its identity, MTU 1430, the deterministic MAC and both overlay addresses came back automatically, and bidirectional IPv6 and IPv4 overlay traffic passed afterwards.

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

* removing `edgeos-vxlan` while saved VXLAN configuration exists (this includes any `firewall` attachments under `interfaces vxlan`);
* removing `edgeos-vxlan` while live VXLAN interfaces exist;
* removing `edgeos-vxlan-kmod` while live VXLAN interfaces remain.

Removing the integration package also restores the original diverted `Vyatta::Interface` file. Removing the kernel package restores the original EdgeOS `udp_tunnel.ko` preserved by its separate `dpkg-divert`.

Package removal does not silently leave an active VXLAN interface without its integration: remove or
disable the interfaces and save the configuration first.

## Underlay trust and security

`remote-ip` configures the normal outbound VXLAN destination. It is not an inbound peer allowlist
and does not authenticate a sender.

Hardware testing on the supported EdgeRouter X confirmed that a VNI 42 VXLAN interface configured
with one `remote-ip` still accepted and decapsulated valid VNI 42 packets arriving from a different
underlay source address. The project therefore does not treat `remote-ip` as a security boundary
for either address family.

### Restricting a fixed VXLAN peer (IPv6 underlay)

For a fixed-peer IPv6 deployment, an EdgeOS IPv6 `local` firewall policy on the underlay interface
can restrict UDP/4789 to the intended remote VTEP. If the underlay interface already has a local
IPv6 policy (for example a VLAN ruleset with a default drop), extend that existing ruleset with the
VXLAN rules; do not replace it, and keep the management path in mind.

```text
configure

set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 default-action accept

set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 action accept
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 description 'Allow configured VXLAN peer'
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 protocol udp
set firewall ipv6-name VXLAN_UNDERLAY_LOCAL6 rule 10 source address 2001:db8:10::2
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

The example deliberately uses `default-action accept`; it restricts VXLAN traffic without changing
the treatment of unrelated traffic destined for the router on that interface. If you extend an
existing default-drop policy instead, also permit the ICMPv6 messages the underlay needs: Neighbor
Solicitation/Advertisement (types 135/136) and Packet Too Big (type 2). A policy that drops all
ICMPv6 can break Neighbor Discovery and PMTUD.

On the supported EdgeRouter X, the IPv6 underlay was validated with an extension of the existing
local IPv6 ruleset (default drop) in place; the tunnel, its IPv6 overlay, and its dual-stack overlay
traffic continued to work. The alternate-source IPv6 drop path is not separately produced in the
published record; see the [support matrix](docs/address-family-support-matrix.md).

### Restricting a fixed VXLAN peer (IPv4 underlay, legacy)

For an IPv4 fixed-peer deployment, the same restriction uses an IPv4 `name` ruleset. For example,
if the VXLAN underlay uses `eth1` and the intended remote VTEP is `192.0.2.2`:

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

If the VXLAN underlay is carried on a VLAN or another EdgeOS interface type, attach the same
`local` ruleset to that interface instead. This policy also uses `default-action accept` for the
same reason: it restricts VXLAN traffic without changing unrelated traffic handling.

On the supported EdgeRouter X, this IPv4 behaviour was validated with a VXLAN interface configured
for one `remote-ip`:

* packets from the configured peer were accepted and decapsulated;
* otherwise identical VNI-matching packets from another underlay source were accepted before
  filtering;
* after applying the policy above, packets from the configured peer remained accepted;
* packets from the alternate source were dropped before reaching the VXLAN interface.

`edgeos-vxlan` does not automatically create or modify firewall policy. Underlay filtering remains an
explicit deployment responsibility.

This is a source-address allowlist, not cryptographic authentication. On an untrusted or spoofable
underlay, use an authenticated and encrypted transport when peer authenticity or confidentiality is
required.

## Native interface firewall

`interfaces vxlan vxlanN firewall ...` attaches ordinary EdgeOS `firewall name` and
`firewall ipv6-name` rulesets to the traffic carried by the VXLAN interface. The attachment is applied
by the stock EdgeOS `ubnt-fw` engine to the decapsulated inner traffic; it is not a filter on the outer
UDP transport.

This is the native alternative to maintaining independent iptables scripts or startup hooks. The
package attaches operator-owned policies; it never creates permissive or restrictive rulesets, and it
does not infer trust from interface addressing.

### Syntax

```text
set interfaces vxlan vxlan42 firewall in ipv6-name VXLANv6_IN
set interfaces vxlan vxlan42 firewall in name VXLAN_IN

set interfaces vxlan vxlan42 firewall out ipv6-name VXLANv6_OUT
set interfaces vxlan vxlan42 firewall out name VXLAN_OUT

set interfaces vxlan vxlan42 firewall local ipv6-name VXLANv6_LOCAL
set interfaces vxlan vxlan42 firewall local name VXLAN_LOCAL
```

| Direction | Native hook | Matches | Meaning |
|---|---|---|---|
| `in` | `FORWARD`, `VYATTA_FW_IN_HOOK` | `-i vxlanN` | forwarded packets arriving on the VXLAN interface |
| `out` | `FORWARD`, `VYATTA_FW_OUT_HOOK` | `-o vxlanN` | forwarded packets leaving the VXLAN interface |
| `local` | `INPUT`, `VYATTA_FW_LOCAL_HOOK` | `-i vxlanN` | packets destined for the router itself |

`ipv6-name` is an IPv6 ruleset; `name` is an IPv4 ruleset. The overlay policy family is independent
of the underlay family and both overlay families may be active at the same time. A VXLAN interface
can therefore use an IPv6 underlay with IPv4-only inner policy, an IPv4 underlay with IPv6-only inner
policy, or any other combination. The primary IPv6-underlay example is
[deployment scenario 1](docs/ipv6-first-deployment.md#2-scenario-1-ipv6-underlay-with-ipv6-overlay);
the dual-stack variant is
[deployment scenario 3](docs/ipv6-first-deployment.md#4-scenario-3-ipv6-underlay-with-a-dual-stack-overlay).

`out` follows native EdgeOS semantics: it matches **forwarded** traffic leaving the interface. Traffic
originated by the router itself is handled by `OUTPUT` and is not matched by `firewall out`.

### Policy ownership and validation

* The rulesets must already exist under `firewall name` / `firewall ipv6-name`.
* A missing ruleset, a mixed direction/family, an unsafe ruleset name, or a bridge-port attachment is
  rejected at commit time, before any interface or firewall change.
* Tab completion lists the configured rulesets of the matching family.
* The package does not create, rename, or delete rules. A ruleset still referenced by an attachment
  cannot be deleted by the EdgeOS engine.
* Firewall policy on other interfaces, NAT, routing, conntrack state and hardware offload is not
  modified.

### Lifecycle and failure behavior

The attachment is part of the interface's desired operational state:

1. The reconciler captures the current live firewall dispatch.
2. It applies the complete desired attachment set through `ubnt-fw` and verifies every jump with
   `iptables -C` / `ip6tables -C`.
3. It creates or recreates the netdevice only after the desired dispatch is in place.
4. Immediately before bringing the interface up it verifies the required attachments again.

If a **new** attachment cannot be established on an already-operational interface, the helper restores
the pre-change dispatch and takes the interface administratively down; the commit fails with an
explicit error. If a **replacement** fails, the previous dispatch remains in place and the interface
stays up, still protected by the previous policy.

On a failed recreation, the previous netdevice state **and** the previous firewall dispatch are
restored. If the dispatch cannot be reconstructed, the interface is left down and the commit fails;
the integration does not bring up an interface with an unknown policy.

On interface deletion, the netdevice is removed first and its dispatches are removed afterwards. A
failed deletion therefore leaves the still-live interface protected.

All of this is bounded by the EdgeOS commit engine: commits are not atomic, and a failed commit can
still write the successful part of the configuration. Follow the existing rule: after a failed
commit, do not `save`; compare the active configuration with the kernel and re-commit the correct
values first.

### Routed and bridged operation

Routed VXLAN interfaces support the full `in`/`out`/`local` attachment set described above.

Bridged VXLAN interfaces **reject** firewall attachments. A frame forwarded by the Linux bridge
between two ports is not seen by the routed `FORWARD` chain with `-i <vxlan-port>`; with bridge
netfilter the logical input is the bridge device, and enabling `br_netfilter` would change the
handling of all bridged traffic on the router. A port attachment would therefore look like
enforcement while leaving L2-forwarded traffic unfiltered. This release does not enable bridge
netfilter or claim bridged L2 firewall enforcement. Existing bridge functionality is unchanged.

### Underlay and overlay boundaries

Keep the four security concerns distinct:

* **Transport reachability** — the route to the remote VTEP. `remote-ip` sets the normal outbound
  destination; it is not an authenticated peer identity or an ingress allowlist.
* **Underlay peer filtering** — a `firewall local` policy on the physical/VLAN interface carrying the
  outer UDP/4789 traffic. This is where you restrict which underlay source may send VXLAN packets.
* **Overlay firewall enforcement** — `firewall in`/`out`/`local` on the VXLAN interface, which sees the
  decapsulated inner traffic.
* **Cryptographic authentication and confidentiality** — not provided by VXLAN. Use IPsec or another
  authenticated transport where required.

An overlay attachment does not filter the outer VXLAN transport, and an underlay policy does not
filter the inner traffic. Both are needed for a complete deployment.

### Worked example: IPv4 underlay with IPv6 overlay (tunnelbroker)

This is the IPv4-underlay/IPv6-overlay interoperability case. The example is deliberately generic.
It uses documentation address ranges; replace them with your provider's transfer subnet, routed
allocation, and peer address.

Assume:

* IPv4 Internet underlay on `eth1`, router address `192.0.2.10/24`, gateway `192.0.2.1`;
* tunnelbroker VTEP `192.0.2.2`, VNI `5002`, UDP port `4789`;
* IPv6 transfer subnet `2001:db8:5002::/64`, broker transfer address `2001:db8:5002::1`;
* routed IPv6 allocation `2001:db8:5002:100::/56`, routed via the transfer address;
* the router provides IPv6-only transit; inner IPv4 is blocked.

Underlay peer filtering (outer UDP/4789) on `eth1`:

```text
set firewall name VXLAN_UNDERLAY4 default-action accept
set firewall name VXLAN_UNDERLAY4 description 'Restrict VXLAN underlay peer'
set firewall name VXLAN_UNDERLAY4 rule 10 action accept
set firewall name VXLAN_UNDERLAY4 rule 10 protocol udp
set firewall name VXLAN_UNDERLAY4 rule 10 source address 192.0.2.2
set firewall name VXLAN_UNDERLAY4 rule 10 destination port 4789
set firewall name VXLAN_UNDERLAY4 rule 20 action drop
set firewall name VXLAN_UNDERLAY4 rule 20 protocol udp
set firewall name VXLAN_UNDERLAY4 rule 20 destination port 4789
set interfaces ethernet eth1 firewall local name VXLAN_UNDERLAY4
```

The routed VXLAN interface, overlay addresses and policy:

```text
set interfaces vxlan vxlan5002 vni 5002
set interfaces vxlan vxlan5002 local-ip 192.0.2.10
set interfaces vxlan vxlan5002 remote-ip 192.0.2.2
set interfaces vxlan vxlan5002 port 4789
set interfaces vxlan vxlan5002 mtu 1450
set interfaces vxlan vxlan5002 address 2001:db8:5002::2/64

# The routed /56 is reached through the broker's transfer address.
set protocols static route6 2001:db8:5002:100::/56 next-hop 2001:db8:5002::1

# IPv6 overlay ingress: NDP/ICMPv6 essentials, established/related, then deny.
set firewall ipv6-name VXLAN6_IN default-action drop
set firewall ipv6-name VXLAN6_IN rule 10 action accept
set firewall ipv6-name VXLAN6_IN rule 10 description 'IPv6 NDP and essential ICMPv6'
set firewall ipv6-name VXLAN6_IN rule 10 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 10 icmpv6 type neighbour-solicitation
set firewall ipv6-name VXLAN6_IN rule 11 action accept
set firewall ipv6-name VXLAN6_IN rule 11 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 11 icmpv6 type neighbour-advertisement
set firewall ipv6-name VXLAN6_IN rule 12 action accept
set firewall ipv6-name VXLAN6_IN rule 12 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 12 icmpv6 type router-solicitation
set firewall ipv6-name VXLAN6_IN rule 13 action accept
set firewall ipv6-name VXLAN6_IN rule 13 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 13 icmpv6 type router-advertisement
set firewall ipv6-name VXLAN6_IN rule 14 action accept
set firewall ipv6-name VXLAN6_IN rule 14 description 'IPv6 Path MTU Discovery'
set firewall ipv6-name VXLAN6_IN rule 14 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 14 icmpv6 type packet-too-big
set firewall ipv6-name VXLAN6_IN rule 15 action accept
set firewall ipv6-name VXLAN6_IN rule 15 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 15 icmpv6 type destination-unreachable
set firewall ipv6-name VXLAN6_IN rule 16 action accept
set firewall ipv6-name VXLAN6_IN rule 16 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 16 icmpv6 type time-exceeded
set firewall ipv6-name VXLAN6_IN rule 17 action accept
set firewall ipv6-name VXLAN6_IN rule 17 protocol icmpv6
set firewall ipv6-name VXLAN6_IN rule 17 icmpv6 type parameter-problem
set firewall ipv6-name VXLAN6_IN rule 20 action accept
set firewall ipv6-name VXLAN6_IN rule 20 state established enable
set firewall ipv6-name VXLAN6_IN rule 20 state related enable
# Add the services this router or its downstream networks may receive here.

# IPv4 overlay is explicitly blocked: this deployment is IPv6-only transit.
set firewall name VXLAN4_IN default-action drop
set firewall name VXLAN4_IN description 'Inner IPv4 is not part of this transit service'

set interfaces vxlan vxlan5002 firewall in ipv6-name VXLAN6_IN
set interfaces vxlan vxlan5002 firewall in name VXLAN4_IN
```

If the router itself terminates IPv6 services over the tunnel, add a separate `local` ruleset with
NDP/ICMPv6 essentials, established/related, and explicit management rules; do not rely on the
forwarded-ingress ruleset for router-destined traffic.

MTU: over an untagged 1500-byte IPv4 underlay the VXLAN MTU is `1500 - 50 = 1450`. One 802.1Q tag
reduces it by another 4 bytes; PPPoE paths may be lower. If the customer traffic and provider path
require it, clamp TCP MSS as well; the MTU setting alone is not an MSS clamp.

Verification:

```bash
show configuration commands | grep vxlan5002
show interfaces
show firewall ipv6-name VXLAN6_IN
show firewall name VXLAN4_IN
for chain in VYATTA_FW_IN_HOOK VYATTA_FW_OUT_HOOK VYATTA_FW_LOCAL_HOOK; do
    sudo iptables -S "$chain"
done
for chain in VYATTA_FW_IN_HOOK VYATTA_FW_OUT_HOOK VYATTA_FW_LOCAL_HOOK; do
    sudo ip6tables -S "$chain"
done
ip -j -d link show dev vxlan5002
ip -6 neigh show dev vxlan5002
ip -6 route show 2001:db8:5002:100::/56
bridge fdb show dev vxlan5002
```

Then verify from an external host:

* the overlay transfer address and an address from the routed /56 are reachable;
* IPv6 NDP resolves the peer and the FDB learns its MAC;
* a permitted IPv6 TCP/TLS service works;
* a denied IPv6 port is blocked;
* an inner IPv4 probe is blocked;
* an underlay UDP/4789 probe from a source other than the configured VTEP is blocked by
  `VXLAN_UNDERLAY4` before decapsulation.

### Verification and troubleshooting

The authoritative state is the live netfilter dispatch, not just the configuration text:

```bash
show configuration commands | grep -A6 'vxlan vxlan42'
show firewall name VXLAN_IN
show firewall ipv6-name VXLANv6_IN
sudo iptables-save -t filter | grep vxlan42
sudo ip6tables-save -t filter | grep vxlan42
ip -j -d link show dev vxlan42
```

The expected dispatch is one jump per configured direction/family, for example:

```text
-A VYATTA_FW_IN_HOOK -i vxlan42 -j VXLAN_IN
-A VYATTA_FW_OUT_HOOK -o vxlan42 -j VXLAN_OUT
-A VYATTA_FW_LOCAL_HOOK -i vxlan42 -j VXLAN_LOCAL
```

If the interface is up but a configured jump is missing, the commit-time gate has not been satisfied;
the commit should have failed. If the interface was brought up by an older package or the jump was
removed out-of-band, commit the interface again to reconcile it, or take the interface down until the
policy is restored.

### `ip -d` reporting defect on EdgeOS 3.0.1

The vendor `iproute2-ss171113` binary on EdgeOS 3.0.1 prints corrupt numeric attributes in its
human-readable `ip -d link show` output (VNI, UDP port, ageing, queue counts, promiscuity). The defect
is in the MIPS build of the display path, not in the kernel and not in VXLAN: `ip -d` on `lo` and
`eth0` shows the same corruption, while `ip -j -d` reports the correct values. Packet captures and
working connectivity confirm the dataplane values are correct.

Use the JSON form for diagnostics and automation:

```bash
ip -j -d link show dev vxlan42
```

The reconciler has always used `ip -j -d`; a regression test now pins that. Do not replace the
platform's iproute2 package just to fix the human-readable output.

### Checksum offload

Local `tcpdump` captures of VXLAN traffic can show apparently invalid UDP checksums while checksum
offload is enabled. In the validated deployment this was a capture artifact; disabling TX offload
changed the capture but not the connectivity, and the actual fault was an incorrect VNI. Keep
offload enabled unless there is independent evidence of a dataplane checksum problem, and treat local
capture checksum warnings as non-authoritative.

IPv6 UDP checksums are enabled by default and the integration does not expose zero-checksum options.
Do not disable them. See RFC 6935 and RFC 6936 for the protocol guidance; this implementation does
not rely on the zero-checksum exception.

### Upgrade from v0.2.2

Existing VXLAN configurations have no `firewall` nodes and keep their established behavior. The
attachment subtree is optional. The package adds `vyatta-cfg-firewall` and `iptables` dependencies;
both are part of the supported firmware. Package removal is refused while saved VXLAN configuration
or live VXLAN interfaces exist, so an active interface cannot be left behind without its integration.

### Hardware validation status

The native attachment path has been exercised against the official EdgeOS 3.0.1 configuration engine
under emulation and in Linux network namespaces. The RC5 hardware qualification on the ER-X then
completed the isolated six-combination dataplane matrix, the lifecycle scenarios, interrupted
transactions, the `vxlan41913` migration and saved-configuration reboot; the final v0.3.0 runtime
payload is byte-identical to RC5. Independent external OCI probes remain **deferred**. See
[`docs/v0.3.0-hardware-qualification-report.md`](docs/v0.3.0-hardware-qualification-report.md).

The emulated and namespace results are not a substitute for hardware. The hardware record defines the
qualified scope; do not extend it to the deferred external probes.

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

The kernel package applies the repository patch:

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

The build produces files whose version comes from `debian/changelog`:

```text
edgeos-vxlan_<version>_all.deb

edgeos-vxlan-kmod_<version>_mipsel.deb
```

For the v0.3.0 release the package version is `0.3.0+edgeos3.0.1.e50`.

Packages are compressed using gzip for compatibility with the older `dpkg` version shipped by EdgeOS.

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
│   └── integration-netns.sh
├── upstream/
│   └── libvyatta-cfg1/
│       └── Interface.pm
├── install.sh
└── README.md
```

`upstream/libvyatta-cfg1/Interface.pm` is the pristine upstream reference.

`src/Interface.pm` is the package-installed version with the minimal VXLAN interface recognition change.

## Tested behavior

Version `0.2.2` has been tested on the supported platform (EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409, kernel `4.14.54-UBNT`). v0.3.0 was hardware-qualified as RC5 on the same platform; the final 0.3.0 runtime payload is byte-identical to the qualified RC5 build (verified by package payload comparison). The v0.2.1/v0.2.2 results remain as noted.

### v0.3.0 hardware qualification

The RC5 candidate completed hardware qualification on the ER-X: the isolated six-combination
`in`/`out`/`local` × IPv4/IPv6 dataplane matrix, the lifecycle scenarios, interrupted transactions,
the quiesced `vxlan41913` migration, and saved-configuration restoration after reboot. The final
v0.3.0 runtime payload is byte-identical to RC5. Independent external OCI positive/negative probes
remain **deferred**; they are a limitation on Internet-facing acceptance claims, not on the generic
VXLAN implementation. See
[`docs/v0.3.0-hardware-qualification-report.md`](docs/v0.3.0-hardware-qualification-report.md).

### v0.3.0 off-device evidence

Version `0.3.0` adds native firewall attachment. Its configuration-engine behavior, failure
injection and dataplane semantics have also been exercised **off-device**:

* the official EdgeOS 3.0.1 configuration engine (MIPS, under qemu in a privileged container) parsed the new templates, created the `firewall name`/`firewall ipv6-name` chains, installed the expected `in`/`out`/`local` jumps for IPv6 and IPv4, and brought the routed VXLAN interface up;
* an injected `ubnt-fw update-interface` failure on a fresh interface prevented interface creation and left no dispatch;
* an injected failure when adding an attachment to an already-up interface restored the previous (empty) dispatch and took the interface administratively down;
* an attachment-only commit installed and then removed the dispatch without recreating the netdevice;
* a recreation failure with a changed VNI and a changed attachment rolled the interface back to the old identity and the old dispatch;
* deletion removed the dispatch only after the netdevice was gone, and a failed deletion kept the interface and dispatch intact;
* a Linux network-namespace test passed an IPv4 overlay over an IPv4 underlay and an IPv6 overlay over an IPv6 underlay, local/forwarded-ingress/forwarded-egress policy, established/related, unsolicited inbound, NDP under an IPv6 local policy, multiple VXLAN interfaces, and dispatch survival across netdevice recreation under traffic.

The emulated and namespace results are not a substitute for the hardware qualification recorded
above. The v0.2.2 hardware results remain:

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
* bidirectional IPv6 and IPv4 overlay traffic over an IPv6 VXLAN underlay, including a post-reboot run (20/20 packets, zero loss);
* IPv6 endpoint canonicalisation: an equivalent re-spelling does not recreate the interface, and no-op commits leave it in place;
* family-aware MTU defaulting (1430 over IPv6, 1450 over IPv4), mutable MTU changes without recreation, and restoration of the family default when overrides are removed;
* IPv4 ↔ IPv6 underlay transitions as identity changes with the correct endpoints applied;
* minimum-MTU validation: values the kernel cannot apply (below the VXLAN minimum of 68, or above the platform maximum) are rejected at commit, leaving the candidate configuration unchanged;
* deterministic-failure rollback with bridge state (membership, path cost, port priority) preserved across recreation and restored after a failed one (release-candidate build);
* package upgrade with a live tunnel (release-candidate pair; no interface recreation).

Point-to-point tests between the EdgeRouter X and a Linux host passed bidirectional IPv6 and IPv4
overlay traffic over an IPv6 VXLAN underlay; the earlier (v0.2.1) hardware testing validated
bidirectional IPv4 overlay traffic over an IPv4 VXLAN underlay. The
[support matrix](docs/address-family-support-matrix.md) distinguishes these results from the
combinations that are implemented but not separately hardware-qualified.

## Known limitations

Version `0.3.0` remains intentionally small in scope.

* **VTEP endpoints are statically configured.** The tunnel is a fixed-remote point-to-point link; a delegated-prefix change on the underlay is not tracked automatically — update `local-ip`/`remote-ip` and commit after a prefix change. Dynamic underlay addressing (SLAAC/DHCPv6) at boot has not been validated.
* **EdgeOS commits are not universally atomic.** A failed commit can leave partially applied configuration in some cases; after a failed VXLAN commit, do not `save` — compare the active configuration with the kernel and re-converge first (see the failed-commit guidance above).
* **Upgrade from v0.2.2 with a live IPv4 VXLAN has not been directly hardware-tested.** The package-upgrade mechanism has been validated for the v0.2.x line (including with a live tunnel and container simulations), and the packages make no configuration or interface changes on upgrade. The RC5 → 0.3.0 upgrade with live native attachments was qualified on the ER-X.
* **Firewall policy is the operator's responsibility.** The package attaches existing `firewall name`/`firewall ipv6-name` rulesets; it does not create, rename, or modify them. `remote-ip` is not an ingress allowlist — see the native firewall and underlay trust sections.
* **Bridged L2 firewall enforcement is not supported.** VXLAN bridge ports reject firewall attachments; global bridge netfilter is not enabled. Routed VXLAN is the supported enforcement case.
* **`modify` and `ipv6-modify` (mangle) attachments are not exposed** for VXLAN in this release. `in`, `out` and `local` are the supported directions.
* **`firewall out` follows native EdgeOS semantics**: it matches forwarded traffic leaving the interface, not traffic originated by the router.
* **No continuous out-of-band firewall monitor.** If a dispatch is removed outside a configuration commit, the next VXLAN lifecycle commit detects and repairs it; there is no daemon watching the dataplane.
* **IPv6-only management, package acquisition and CI are not validated.** The VXLAN dataplane can run with IPv6 only; the rest of the operational stack must be assessed separately.
* **Bridged VXLAN dataplane over an IPv6 underlay is not fully validated.** Bridge membership, path cost and priority are verified; packets over the bridged tunnel are not part of the published hardware record.
* **Hardware qualification is complete for the RC5 scope, not for every combination.** The RC5 qualification covers the isolated firewall matrix, lifecycle, the `vxlan41913` migration and reboot. Independent external OCI probes and the combinations listed as gaps in the [support matrix](docs/address-family-support-matrix.md) remain unverified.
* **The vendor `ip -d` human output is defective** on EdgeOS 3.0.1; use `ip -j -d`. The reconciler does.

Not yet validated or implemented as first-class configuration features:

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
