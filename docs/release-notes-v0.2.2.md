# edgeos-vxlan v0.2.2 — Release Notes

**Released 2026-10-11.** The artifact manifest and release record are in
`docs/issue-3-v0.2.2-release-gate.md`.

v0.2.2 adds native IPv6 VXLAN underlay support on the supported EdgeRouter platform. It is the
stable continuation of the 0.2.2 release candidates (`0.2.2~rc1`, `0.2.2~rc2`): the runtime payload
is byte-identical to RC2 — only the changelog and version metadata differ.

## Highlights

* `local-ip`/`remote-ip` accept IPv4 **or** IPv6 literals (both endpoints must be the same family);
  malformed, prefix-carrying, mixed-family and unusable endpoints are rejected before anything is
  changed.
* The tunnel identity is read from the kernel's `local6`/`remote6` JSON fields, so IPv6 tunnels
  reconcile correctly, and endpoints are compared canonically so equivalent re-spellings do not
  recreate the interface.
* Family-aware default MTU: 1450 over IPv4 underlays and 1430 over IPv6 underlays; an explicit
  `mtu` is always honoured.
* The `mtu` minimum is the kernel's own 68 — values the kernel cannot apply are rejected at commit
  time instead of failing afterwards.
* Fail-closed live-state capture and deterministic-failure rollback, including bridge membership,
  path cost and port priority.
* No changes to the kernel module payloads (`vxlan.ko`, `udp_tunnel.ko`), their hashes, or the
  CVE-2022-50405 backport.

## Supported platform

Unchanged and deliberately narrow:

```text
Device:       Ubiquiti EdgeRouter X / ER-e50
EdgeOS:       3.0.1, build 5862409
Firmware:     EdgeRouter.ER-e50.v3.0.1.5862409.*
Kernel:       4.14.54-UBNT
Architecture: mipsel (kernel package), all (integration package)
```

The packages refuse installation on unsupported firmware, and the kernel-module package requires the
running kernel to be `4.14.54-UBNT`.

## Hardware validation summary

Validated on the supported platform (RC1 and RC2 hardware runs; full record in
`docs/issue-3-hardware-evidence.md`):

* native IPv6-underlay configuration through the EdgeOS templates, with malformed, CIDR-prefixed,
  mixed-family and unusable endpoints rejected without touching live state;
* native interface creation and deletion, with the correct VNI, UDP port, MTU, endpoint identity,
  MAC and overlay addresses;
* bidirectional IPv4 **and** IPv6 overlay traffic over an IPv6 VXLAN underlay — including after a
  reboot (**20/20 packets, zero loss**);
* IPv6 endpoint canonicalisation and no-op commits;
* family-aware MTU defaulting (1430 over IPv6, 1450 over IPv4), mutable MTU changes, and restoration
  of the family default when an override is removed;
* VNI recreation and IPv4↔IPv6 underlay transitions;
* deterministic-failure rollback restoring the captured kernel state, including bridge membership,
  path cost and port priority;
* minimum-MTU validation (values the kernel cannot apply rejected at commit, candidate unchanged);
* package upgrade with a live tunnel (release-candidate pair; no interface recreation);
* save + reboot restoration of the tunnel, its identity, MTU 1430, the deterministic MAC and both
  overlay addresses.

Off-device: **132/132 automated checks** pass; the packaged payloads were verified byte-identical to
the repository; the kernel module hashes are unchanged from v0.2.1.

## Compatibility and upgrade notes

* Upgrading from v0.2.1: install both v0.2.2 packages in one `dpkg` invocation, kernel package
  first. The upgrade replaces files only and does not modify configuration or interfaces. Details,
  expected output and downgrade instructions: `README.md` (Installation → Upgrading from v0.2.1).
* The exact v0.2.1 → v0.2.2 upgrade carrying an existing, active **IPv4** VXLAN has not been
  directly hardware-tested — see Known limitations. The package-upgrade mechanism has been
  validated, including with a live tunnel and in container simulations.
* Keep the published v0.2.1 packages available as recovery media (their SHA-256 hashes are pinned in
  that release's tagged `install.sh`).

## Known limitations

* **VTEP endpoints are statically configured.** A delegated-prefix change on the underlay is not
  tracked automatically; update `local-ip`/`remote-ip` and commit after a prefix change. Dynamic
  underlay addressing (SLAAC/DHCPv6) at boot has not been validated.
* **EdgeOS commits are not universally atomic.** A failed commit can leave partially applied
  configuration in some cases — after a failed VXLAN commit, do not `save`; compare the active
  configuration with the kernel and re-converge first (`README.md`, "Failed commits and partial
  configuration").
* **Existing live IPv4 VXLAN upgrade compatibility has not been directly hardware-tested.**
* **Firewall configuration is the operator's responsibility.** The package does not create or modify
  firewall policy, and `remote-ip` is not an ingress allowlist.

## Remaining untested scenarios

* The exact v0.2.1 → v0.2.2 upgrade with an existing, active IPv4 tunnel.
* Dynamic underlay addressing at boot (SLAAC/DHCPv6) and behaviour after an ISP prefix change.
* Traffic over a bridged tunnel in the IPv6-underlay bridge test (membership and port options were
  validated; no packets were sent).
* The IPv6 firewall drop path for alternate sources (the extended local ruleset was active during
  validation; the drop direction was not separately demonstrated).
* The RC2-specific failure injection (256-character description) on the router; the RC1 rollback
  evidence covers the same reconciler code.

## Release artifacts

| Artifact | File |
|---|---|
| Integration package | `edgeos-vxlan_0.2.2+edgeos3.0.1.e50_all.deb` |
| Kernel-module package | `edgeos-vxlan-kmod_0.2.2+edgeos3.0.1.e50_mipsel.deb` |

Sizes and SHA-256 checksums are recorded in `docs/issue-3-v0.2.2-release-gate.md`, committed in
`SHA256SUMS`, and pinned in the tagged `install.sh`, which verifies them automatically.

## Installation

Quick install:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.2.2/install.sh |
  sudo sh
```

For the manual procedure, upgrade notes, security guidance and removal instructions, see
`README.md`.
