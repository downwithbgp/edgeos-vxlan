# IPv4 dependency inventory

**Status:** repository-local audit, 2026-11-27. This is an investigation record for ENG-IPV6-03.
It does not authorize product runtime changes; findings that require behavior changes are mapped
to the engineering backlog.
**Scope:** installer and acquisition paths, package repositories, DNS resolution, build and CI
dependencies, runtime helpers, address-family validation, diagnostics, management workflows, test
fixtures, shell utilities, and documentation claims.
**Related:** [`ipv6-only-qualification.md`](ipv6-only-qualification.md),
[`address-family-support-matrix.md`](address-family-support-matrix.md), and
[`engineering-backlog.md`](engineering-backlog.md).

## 1. Method

The inventory combined:

* full-tree pattern searches for IPv4 literals, `ip -4`/`ip -6`, `AF_INET`/`AF_INET6`,
  `iptables`/`ip6tables`, `ping`/`ping6`, `curl`/`wget`, `apt-get`, `ssh`/`scp`, and URL schemes;
* reading the installer, reconciler, address helper, firewall helper, bridge helper, package
  maintainer scripts, CI workflows, test fixtures, release validators and hardware runbook;
* checking DNS AAAA availability for the external endpoints used by the project, with the local
  resolver on 2026-11-27;
* distinguishing **code that forces IPv4** from **code that is family-neutral but reaches an
  external service that is not IPv6-reachable**.

This is not a claim about every network environment. DNS and external-service reachability vary by
resolver, location and time; the observations below record what this repository's development and
CI environment actually returned.

## 2. Classification legend

| Class | Meaning |
|---|---|
| **Intentional IPv4 interoperability** | IPv4 support or an IPv4 scenario is deliberate product or test scope. It should be preserved and regression-tested. |
| **Unnecessary IPv4 preference** | The behavior prefers or requires IPv4 without a product need, or the validation is inconsistent across families. |
| **Hard IPv4 dependency** | A path cannot work without IPv4 or IPv4 tooling, even when the product function is IPv6-only. |
| **External service limitation** | The project's code is family-neutral, but an external endpoint or CI service is not reachable over IPv6 in the audited environment. |
| **Unverified behavior** | The behavior is not demonstrated either way; it must not be presented as qualified. |
| **Not applicable** | The item is address-family neutral, or belongs to a boundary this audit does not cover. |

## 3. Summary

| Finding group | Count | Disposition |
|---|---:|---|
| Intentional IPv4 interoperability | 6 | Preserve; regression-tested by the existing suites and scenarios |
| Unnecessary IPv4 preference | 1 | ENG-IPV6-06; product runtime change requires separate approval |
| Hard IPv4 dependency | 3 | One is an external service (ENG-IPV6-01); one is CI tooling (fixed); one is firewall capture tooling (ENG-IPV6-08 proposed) |
| External service limitation | 4 | Recorded; Level C/Level D blockers, not product defects |
| Unverified behavior | 4 | Recorded; not claimed |
| Not applicable | 8 | No action |

The audit changed one CI dependency path (`scripts/apt-update-ubuntu-only.sh`) and the namespace
jobs' package acquisition. It did not change the installer, package payload, runtime helper
semantics, public CLI or release assets.

## 4. Findings

| ID | Area | Finding and evidence | Classification | Disposition |
|---|---|---|---|---|
| **AUD-01** | Installer acquisition | `install.sh` downloads two release assets from `https://github.com/.../releases/download/...`. The code uses `curl` without `-4` or `-6`, so it is family-neutral. In this environment `github.com`, `api.github.com`, `codeload.github.com` and `objects.githubusercontent.com` returned no AAAA records; an IPv6-only host would have no IPv6 path to those release assets. | External service limitation; Hard IPv4 dependency for the *acquisition path* | ENG-IPV6-01. Do not change installer behavior in this assignment; a mirror or an offline pre-staged `dpkg` procedure is the backlog work. |
| **AUD-02** | CI tool acquisition | `scripts/install-ci-tools.sh` downloads actionlint, zizmor and ShellCheck release archives from `github.com` with pinned SHA-256 checks. It uses `curl` without a family flag. | External service limitation (CI-only) | Documented; the lint job is not part of Level B. A future IPv6-only CI runner would need an IPv6-reachable tool mirror or pre-baked tools. |
| **AUD-03** | Published-release fixtures | `test/published-release-fixtures.sh` runs `gh release download`, and the workflow's published-release job uses `gh` and `git` against GitHub. The validators themselves (`validate-artifacts.sh`, `validate-published-release.sh`) are offline and inspect local files. | External service limitation (CI-only) | Keep the trust model; Level D remains unachieved. |
| **AUD-04** | GitHub Actions control plane | `actions/checkout`, `actions/upload-artifact`, `gh`, `git fetch` and the workflow control plane all depend on GitHub-hosted services. The runner is dual-stack, but the workflow cannot be described as IPv6-only. | External service limitation; Level D blocker | Explicitly out of scope. Do not claim Level D. |
| **AUD-05** | APT source scope | The original `dataplane` job ran a plain `sudo apt-get update`, which refreshed every configured source, including unrelated third-party repositories. The post-PR-#7 transient failure was an HTTP 403 from `packages.microsoft.com`; a rerun passed without source changes. | Hard IPv4 dependency (incidental CI dependency) | **Fixed:** `scripts/apt-update-ubuntu-only.sh` refreshes only the distribution source file with transient APT options. The dataplane job checks for tools first; the IPv6-only job uses the runner image and performs no acquisition. |
| **AUD-06** | Dataplane dependencies | The `dataplane` job installed `iproute2`, `iptables`, `iputils-ping` and `python3` unconditionally, even though the runner image normally provides most or all of them. | Unnecessary dependency (not address-family-specific) | **Fixed:** check tool presence first; acquire only when a required tool is missing. The IPv6-only job checks tools and fails with a clear message rather than installing. |
| **AUD-07** | Dual-stack namespace test | `test/integration-netns.sh` configures IPv4 and IPv6 underlays and overlays and uses `iptables`/`ip6tables`. It is the existing dual-stack/firewall regression suite. | Intentional IPv4 interoperability | Preserve. The new `test/ipv6-only-netns.sh` is an additional Level B suite, not a replacement. |
| **AUD-08** | Mock and unit tests | `test/mock.sh` and the unit suites use IPv4 fixtures and fake `iptables`/`ip6tables` to test family-aware dispatch, endpoint rules and negative paths. | Intentional IPv4 interoperability / Not applicable (offline test data) | Preserve. |
| **AUD-09** | Endpoint validation | `src/vyatta-vxlan-addr` applies multicast, loopback, unspecified and IPv4-mapped class checks to IPv6 endpoints. IPv4 endpoints are checked for format and family consistency but not for those classes. The behavior is documented in `docs/architecture.md` and the support matrix. | Unnecessary IPv4 preference / validation inconsistency | ENG-IPV6-06. A product runtime change would need separate approval; do not change it here. |
| **AUD-10** | Firewall state capture | `src/vyatta-vxlan-firewall` `capture_state()` iterates `name` and `ipv6-name` and reads both `iptables -S` and `ip6tables -S`, even when only an IPv6 attachment is configured. On the supported EdgeOS platform both tools exist, so this is not a current deployment failure. On a kernel/userspace without IPv4 tooling it would be a hard dependency for an IPv6-only attachment. | Hard IPv4 dependency (tooling), unverified on an IPv4-less kernel | **ENG-IPV6-08 proposed.** Investigate family-selective capture; do not change firewall semantics in this assignment. |
| **AUD-11** | MAC derivation | `src/vyatta-vxlan` derives the stable MAC from `/sys/class/net/eth0/address`. `eth0` is an interface-name assumption, not an address-family dependency; the namespace test provides `eth0` for the reconciler path. | Not applicable (interface-name assumption) | Recorded; no change. |
| **AUD-12** | Bridge helper | `src/vyatta-vxlan-bridge` uses `brctl` and sysfs bridge-port state; it is family-neutral. | Not applicable | No change. |
| **AUD-13** | Templates | `templates/interfaces/vxlan/*` use `type: ipv4,ipv6` and family-aware default MTU helpers; there is no IPv4 preference in the grammar. | Not applicable | No change. |
| **AUD-14** | Installer address-family code | `install.sh` has no `-4`/`-6` flag, no IPv4 literal in its URL, and no address-family branching. Its acquisition failure on an IPv6-only host would be a DNS/endpoint reachability failure, not an IPv4 code path. | Not applicable (code) / External service limitation (observed endpoint) | Covered by AUD-01. |
| **AUD-15** | Documentation examples | `README.md` and the deployment scenarios keep complete IPv4 examples for interoperability (scenarios 4–6); the primary model is IPv6. | Intentional IPv4 interoperability | Preserve; documentation order remains IPv6-first. |
| **AUD-16** | Hardware runbook | `scripts/first-hardware-session.sh` captures and compares both IPv4 and IPv6 firewall tables and uses IPv4 test fixtures. It is a hardware qualification script, not a Level B dependency. | Intentional IPv4 interoperability / Not applicable to Level B | Preserve; do not run against the production router as part of this work. |
| **AUD-17** | Package maintainer scripts | `debian/*.preinst`, `*.postinst`, `*.prerm`, `*.postrm` perform local firmware/divert/interface checks and `dpkg` work; they contain no network access or IPv4 address literal. | Not applicable | No change. |
| **AUD-18** | Shell utilities in tests | IPv4 `ping`/`ip -4`/`iptables` appear only in the intentional dual-stack and hardware suites. The IPv6-only suite uses `ip -6`, `ping -6`, `ip -6 neigh`, `ip -4` only in its assertion/negative-control code, and Python `AF_INET` only to prove that external IPv4 sends fail. | Not applicable (intentional use) | No change. |
| **AUD-19** | DNS | The resolver is used by the installer and CI acquisition. The repository does not set `AI_ADDRCONFIG` or force a family. AAAA availability is endpoint-specific (see §5). | External service limitation / Unverified behavior | Level C/D assessment; no code change. |
| **AUD-20** | SSH and management | The repository does not implement router management. The hardware runbook uses the operator's existing SSH path; no IPv6-only management procedure is validated. | Not applicable to this repository / Unverified behavior | ENG-IPV6-02; no change. |
| **AUD-21** | Diagnostics | The reconciler uses `ip -j -d` for machine parsing, avoiding the defective vendor `ip -d` human output. `ip -4`/`ip -6` are used only where the family is intentional. The IPv6-only suite reads `/proc/net/route`, `/proc/sys/net/ipv4/...` and `ip -4` state to assert their absence. | Not applicable | No change. |
| **AUD-22** | Release assets and checksums | `SHA256SUMS`, `scripts/validate-artifacts.sh` and `scripts/validate-published-release.sh` operate on local files. Downloading the files is the external-service step (AUD-03). | Not applicable (local validation) | No change to assets or checksums. |
| **AUD-23** | Gateway/VTEP defaults | `src/vyatta-vxlan` represents an unspecified local endpoint as `::` for IPv6 and `0.0.0.0` for IPv4. This is family-specific syntax, not a preference for IPv4. | Not applicable | No change. |

## 5. External IPv6 reachability observations

Checked on 2026-11-27 from the development environment with the local resolver; these are
environment-specific observations, not a global statement about the services.

| Endpoint | AAAA observed? | Observation |
|---|---|---|
| `github.com` | No | `dig +short AAAA github.com` returned empty; `getent ahosts` returned IPv4 only |
| `codeload.github.com` | No | IPv4 only |
| `api.github.com` | No | IPv4 only |
| `objects.githubusercontent.com` | No | IPv4 only |
| `raw.githubusercontent.com` | Yes | `2606:50c0:8000::154` observed |
| `archive.ubuntu.com` | Yes | Multiple AAAA records observed |
| `security.ubuntu.com` | Yes | Multiple AAAA records observed |

Consequences:

* An IPv6-only host cannot download the GitHub Release assets through the audited endpoints. This
  is an external service limitation and a Level C blocker for ENG-IPV6-01.
* An IPv6-only CI runner would still need IPv6 reachability to the GitHub control plane, source
  hosting and artifact service. Level D is not achieved by the current GitHub-hosted setup.
* The Ubuntu archive has IPv6 reachability at the audited time. The scoped APT helper is still
  correct because it avoids unrelated third-party sources and does not assume that the network is
  IPv6-only.

## 6. Backlog mapping

| Backlog item | Findings | Current status after this audit |
|---|---|---|
| **ENG-IPV6-01** — IPv6-only installation and package acquisition | AUD-01, AUD-14, AUD-19 | Open. External GitHub endpoints are IPv4-only at the audited time; installer code is family-neutral. |
| **ENG-IPV6-02** — IPv6-only router management | AUD-20 | Open; requires lab hardware and is outside this repository's test environment. |
| **ENG-IPV6-03** — Native IPv6-only CI and test execution | AUD-05, AUD-06; new N6/N6-R suite | **Level B implemented**; Level C/D remain open. See the backlog status update. |
| **ENG-IPV6-04** — IPv6-underlay bridged Ethernet dataplane validation | Generic bridge section in the new suite only | Open; namespace bridge feasibility is not hardware qualification. |
| **ENG-IPV6-05** — Remaining address-family hardware qualification | AUD-16 | Open; no hardware access in this assignment. |
| **ENG-IPV6-06** — Consistent IPv4 and IPv6 endpoint validation | AUD-09 | Open; product runtime change requires separate approval. |
| **ENG-IPV6-07** — External VTEP qualification over routed networks | AUD-03, AUD-04, AUD-19 | Open; external infrastructure deferred. |
| **ENG-IPV6-08** — Family-selective firewall state capture (proposed) | AUD-10 | New proposal recorded in the backlog; no runtime change in this assignment. |

## 7. What this audit did not change

* No installer, package payload, kernel module, public CLI, template grammar or runtime helper
  semantics were changed.
* No release assets, checksums, tags or version numbers were changed.
* No production router was accessed.
* The existing dual-stack and IPv4 regression coverage was preserved.
* The new CI and test code is additive; the only CI behavior change is the scoped APT refresh and
  the check-first dataplane tool preparation.
