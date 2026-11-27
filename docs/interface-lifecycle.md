# Interface lifecycle, persistence and diagnostics


This document is the canonical description of interface reconciliation, rollback, deterministic
MAC addresses, EdgeOS integration, boot persistence, removal and platform diagnostics. Deployment
scenarios and operational guidance are in [`deployment.md`](deployment.md); firewall semantics are
in [`native-firewall.md`](native-firewall.md); validation evidence is in
[`address-family-support-matrix.md`](address-family-support-matrix.md).


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

## Platform diagnostics


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
