# AGENTS.md — repository engineering rules

This file is the standing instruction set for human and autonomous contributors. It is deliberately
short. The authoritative details are in `docs/`; follow the linked document when a rule needs
context.

## 1. Product scope

`edgeos-vxlan` is a fixed-remote Linux VXLAN integration for EdgeOS 3.0.1 on the ER-X
(`ER-e50`, Linux `4.14.54-UBNT`). It is not an EVPN/control-plane implementation, a dynamic tunnel
manager, or a general-purpose router configuration framework. Do not expand the product scope as a
side effect of a test or documentation change.

The supported platform, package payload and public CLI are narrow by design. Changes to installer
behavior, package payload, kernel modules, templates, runtime semantics or public CLI require
explicit maintainer approval; they are not part of a CI/test-infrastructure task.

## 2. IPv6-first, IPv4 interoperable

* **IPv6 is the default** for new architecture, examples and test topology.
* **IPv4 remains supported** for interoperability and existing deployments. Preserve IPv4 and
  dual-stack regression coverage; do not replace it with IPv6-only tests.
* **Do not make IPv4 connectivity an implicit prerequisite** for a new IPv6 feature. If a path
  needs IPv4, state why and record the limitation.
* Use documentation addressing: `2001:db8::/32` for IPv6, RFC 5737 prefixes for IPv4. Use `/64` for
  ordinary segments; use `/127` only with a stated reason.
* Distinguish the underlay, VTEP endpoint, encapsulation, overlay Ethernet, overlay Layer 3 and
  management layers. An IPv6 underlay does not imply an IPv6 overlay.

## 3. Qualification levels and evidence

Do not write "IPv6-only" without stating the level:

| Level | Meaning |
|---|---|
| **A** | IPv6 dataplane over dual-stack infrastructure |
| **B** | Isolated IPv6-only workload environment |
| **C** | IPv6-only installation, management and lifecycle |
| **D** | IPv6-only runner, CI control plane, source/dependency/artifact acquisition |

A dual-stack GitHub-hosted runner that creates IPv6-only namespaces is **Level B, not Level D**.
The current status is in `docs/ipv6-only-qualification.md` and the support matrix.

Evidence classes are not interchangeable:

* **I** implementation, **A** automated off-device, **S** simulated EdgeOS, **N** general Linux
  namespace, **N6** isolated IPv6-only namespace, **N6-R** isolated namespace with the actual
  reconciler and test doubles, **H** physical hardware, **L** inferred, **—** not exercised.
* A namespace result is not hardware qualification. A generic Linux bridge result is not EdgeOS
  bridged-dataplane qualification. A mock is not the vendor configuration engine.
* Do not claim absence of an IPv4 dependency because one ping or capture passed. Use the explicit
  assertions and negative controls, and state what was not inspected.

Technical claims must cite reproducible evidence: a command, a test name, a CI job, a commit, a
recorded artifact or a cited document. If a claim cannot be established without hardware or an
external service, record the limitation and defer it; do not weaken the requirement or fabricate a
result.

## 4. Build, test and validation

Run the relevant checks before committing:

```bash
bash test/run.sh
shellcheck install.sh scripts/*.sh test/*.sh test/lib/*.sh \
  debian/*.preinst debian/*.postinst debian/*.prerm debian/*.postrm \
  src/vyatta-vxlan src/vyatta-vxlan-bridge src/vyatta-vxlan-firewall
perl -c src/vyatta-vxlan-addr
git diff --check
```

The off-device baseline is **360 checks** (11 build + 64 helper + 122 firewall + 93 templates +
70 mock). Keep it green. If you add or remove checks, update the count in the current docs, not in
historical release records.

Privileged namespace suites:

```bash
sudo REQUIRE_NETNS_TEST=1 bash test/integration-netns.sh
sudo REQUIRE_NETNS_TEST=1 REQUIRE_CAPTURE=1 REQUIRE_RECONCILER=1 \
  EVIDENCE_DIR=/tmp/ipv6-only-evidence bash test/ipv6-only-netns.sh
```

If the local host cannot grant `CAP_NET_ADMIN`, use a privileged container or record the validation
as pending. A missing privilege must not be reported as a pass.

For changes that affect packaging or releases, run the canonical build and validation from a clean
tree:

```bash
./scripts/build-reproducible.sh --output-dir /tmp/edgeos-vxlan-build
./scripts/validate-release.sh /tmp/edgeos-vxlan-build
```

Reproducibility, package contents and provenance are release properties. Do not change
`SOURCE_DATE_EPOCH`, archive ordering, dependency pins or the package payload to make a test pass
without documenting the reason.

## 5. CI trust boundaries

* Untrusted pull-request code must not run with `CAP_NET_ADMIN`, repository secrets or write
  credentials. Privileged namespace jobs are guarded by `if: github.event_name != 'pull_request'`.
* Do not use `pull_request_target` to execute untrusted code. Do not add workflow permissions
  without a documented technical justification; the default is `contents: read`.
* Pin third-party actions by commit SHA, with a version comment.
* Keep dependency acquisition separate from isolated dataplane execution. Prefer the runner's
  preinstalled tools. When a package is needed, use `scripts/apt-update-ubuntu-only.sh` for the
  distribution source and do not disable signature or TLS verification.
* Do not hide infrastructure failures with unconditional retries or `|| true`. Distinguish a
  product regression, a missing privilege, an unsupported platform and an external-service failure.
* A test that could not execute must be reported as skipped/unsupported/blocked, not passed.

## 6. Production infrastructure safety

The project has one physical ER-X, and it is the maintainer's production home router. Unless the
maintainer explicitly authorizes a hardware session:

* do not SSH into it;
* do not install packages, change configuration, routes, firewall, kernel modules or startup;
* do not create VXLAN interfaces;
* do not reboot it;
* do not use live credentials or production configuration as test fixtures;
* do not interfere with its IPv6 tunnel or concurrent EdgeOS work.

Namespace, container, emulated-engine and off-device tests are the default. Record a hardware
limitation instead of weakening a requirement.

## 7. Branches, commits and review

* Work on a dedicated branch. Do not merge into `main`, tag, publish a release or modify release
  assets unless explicitly authorized.
* Keep commits logical and reviewable: test infrastructure, CI, documentation, inventory, and
  instructions are separate where practical.
* Do not mix unrelated refactors into a feature commit. Remove imports/variables your change made
  unused; leave pre-existing dead code alone.
* Run an independent review pass for network isolation, CI security and qualification-accuracy
  changes when the environment provides one.
* Before declaring a branch ready, inspect the full diff, the working-tree status and the final
  commit list. Do not push or open a pull request without explicit authorization.

## 8. Documentation and history

* Update the current guide when behavior, evidence or CI changes. Keep one canonical source per
  claim: deployment for configuration, architecture for the layer model/MTU, native-firewall for
  firewall semantics, interface-lifecycle for reconciliation, kernel-provenance for modules/build,
  and the support matrix for validation status.
* Do not rewrite historical release or qualification records. A later result is recorded in a new
  record and linked from the current matrix; the old record remains true for its date.
* When adding a claim, state the evidence class and the level (A–D). When a limitation is known,
  keep it visible in the current docs and in `docs/engineering-backlog.md`.
* Keep documentation examples standards-aligned and IPv6-first, with complete IPv4 examples where
  interoperability requires them.

## 9. Security and supply chain

* Do not commit secrets, tokens, private keys, production addresses or live credentials.
* Do not disable checksum verification, package signature verification, TLS validation or the
  release pin checks.
* Treat downloaded assets, tagged source and workflow inputs as untrusted data. Do not execute
  downloaded packages or untrusted PR code in a privileged job.
* Preserve the release trust boundary: release events verify published assets with validation
  logic from the trusted default branch; they do not execute tagged source as part of validation.

## 10. Where to look

* `docs/architecture.md` — layers, endpoint rules, MTU, standards.
* `docs/deployment.md` — deployment scenarios and operations.
* `docs/address-family-support-matrix.md` — evidence by combination.
* `docs/ipv6-only-qualification.md` — Level A–D model, Level B isolation contract, threat model.
* `docs/ipv4-dependency-inventory.md` — IPv4 assumptions and external limitations.
* `docs/engineering-backlog.md` — open engineering work.
* `docs/kernel-provenance.md` — module provenance and reproducible build.
* `docs/native-firewall.md` and `docs/interface-lifecycle.md` — product behavior.
