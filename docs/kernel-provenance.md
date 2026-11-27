# Kernel module provenance and package build


This document records why the kernel modules exist, how they were built, the CVE-2022-50405
backport, the RC9/EdgeOS 3.0.1 compatibility evidence, and how to build the Debian packages. It is
the canonical source for module hashes and build provenance. Installation and package layout are in
[`../README.md`](../README.md); the supported platform boundary is in
[`architecture.md`](architecture.md).


The EdgeRouter X firmware does not ship `vxlan.ko`.

The `vxlan.ko` module included with this project was built from Ubiquiti's published EdgeOS GPL source. The kernel package also rebuilds the vendor `udp_tunnel.ko` dependency from the same corresponding source with one security backport.

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

This provides strong evidence that the relevant kernel and Vyatta interface code did not materially change between the published GPL release and the tested final firmware. The packaged `udp_tunnel.ko` intentionally differs from the vendor binary because it includes the CVE-2022-50405 backport.

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
