# Issue #3 — Hardware Evidence: IPv6 VXLAN Dataplane on the EdgeRouter X

This document records what has actually been demonstrated on real hardware, what it does and does
not establish, and what remains untested. It is deliberately separated from the acceptance criteria,
which continue to track the integration as a whole.

**Method note.** These results were produced by hand on the router — a VXLAN interface created with
the platform's `ip` command — not through the package's configuration integration. They establish
that the kernel, the module payload and the platform's userspace support the feature. They do **not**
establish that this release candidate's native EdgeOS configuration path works; that is the purpose
of the validation runbook and it has not been executed yet.

**Environment** (results reported to this repository on 2026-10-10; the owner's delegated prefix is
not published, and `<PREFIX>` stands for it):

| Property | Value |
|---|---|
| Hardware | EdgeRouter X 5-Port / ER-e50 |
| Firmware | EdgeOS v3.0.1, build 5862409 |
| Kernel | `4.14.54-UBNT` |
| `ip` binary | `iproute2-ss171113` |
| Installed integration | `edgeos-vxlan 0.2.1+edgeos3.0.1.e50` |
| Installed module package | `edgeos-vxlan-kmod 0.2.1+edgeos3.0.1.e50` |
| Modules | `vxlan` loads successfully; `udp_tunnel` and `ip6_udp_tunnel` loaded |
| Router underlay | `switch0.65`, `<PREFIX>::1/64` |
| Peer host | peer uplink `<PEER_IF>`, `<PREFIX>:<PEER_IID>/64`, kernel `6.8.0-139-generic` |

Underlay connectivity between the two hosts was verified bidirectionally before the tunnel tests.

**Test configuration under test:** `vxlan900`, VNI 900, UDP destination port 4789, MTU 1430,
IPv4 overlay `10.255.254.1/30` ↔ `10.255.254.2/30`, IPv6 overlay `fd42:900::1/64` ↔ `fd42:900::2/64`.

## Results

| Observation | Result |
|---|---|
| IPv6 VXLAN netdevice creation | Successful |
| `ip -j -d link show dev vxlan900` fields | `id: 900`, `local6: <PREFIX>::1`, `remote6: <PREFIX>:<PEER_IID>`, `port: 4789` — all correct |
| VNI and UDP destination port in JSON | Correct |
| IPv4 overlay over the IPv6 tunnel | Router → peer 5/5 replies, 0% loss, avg 1.173 ms; peer → router 5/5, 0% loss, avg 1.009 ms |
| IPv6 overlay over the IPv6 tunnel | Router → peer 5/5 replies, 0% loss, avg 1.800 ms; peer → router 5/5, 0% loss, avg 1.147 ms |
| IPv6 Neighbor Discovery on both VTEPs | Reachable link-layer neighbours confirmed on both ends |
| IPv6 UDP checksum | Enabled |
| IPv6 zero-checksum options | Disabled |
| Sysfs administrative-state format | `0x1003` on an active VLAN interface, `0x1002` on a down VXLAN — hexadecimal, as the reconciler's `read_iface_flags` assumes |

## Two observations worth keeping

**The human-readable `ip -d link show` output is unusable on this platform.** It displays obviously
corrupted numeric fields, including wrong VNI and destination-port values, while the JSON form of
the same query is correct. This project's live-state parsing reads the JSON form
(`ip -j -d link show`) and must continue to; any future diagnostic guidance should tell operators to
do the same rather than trusting the non-JSON output. This is a known quirk of the platform's
`iproute2-ss171113` build, and chasing it further is out of scope for this feature.

**IPv6 endpoints cannot be configured through the installed v0.2.1 templates.** An attempt fails with
`is not a valid value of type "ipv4"`, which is exactly what a 0.2.1 userspace is supposed to do.
That is expected, and it is not evidence about the new implementation either way.

## What this evidence establishes

The Linux 4.14.54 kernel shipped with EdgeOS 3.0.1, the shipped `vxlan.ko`, and the platform's `ip`
binary together support an IPv6 underlay for VXLAN: creation, identity reporting in the JSON form,
and bidirectional forwarding of both IPv4 and IPv6 overlay traffic, with Neighbor Discovery working
over the tunnel. It also confirms the two kernel-side assumptions the implementation depends on: the
hexadecimal sysfs flags format, and the `local6`/`remote6` JSON field names.

## What remains untested

Everything on the integration path. Still to be demonstrated on hardware, in the order given in the
validation runbook:

1. Evaluation of the native EdgeOS endpoint templates with IPv6 literals (and rejection of
   malformed or mixed-family input without disturbing live state).
2. Native commit behaviour: interface creation through the configuration system.
3. Leaf-handler ordering effects beyond what the mocked tests pin.
4. Family-aware MTU defaults with `mtu` unset, and removal of an explicit `mtu`.
5. IPv4 → IPv6 and IPv6 → IPv4 identity transitions.
6. Rollback after a deterministic recreation failure.
7. Bridge membership and bridge port-option restoration on IPv6 underlay.
8. Persistence across `save` and reboot, including a dynamically-arriving underlay address.
9. Package upgrade compatibility on the router itself.
10. Previously accepted non-canonical IPv4 syntax end to end.

None of these may be marked as passed until they are executed. In particular, no document in this
repository should describe the native integration as hardware-validated before that runbook has been
executed and its captures attached.
