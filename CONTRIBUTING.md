# Contributing to edgeos-vxlan

This project is a fixed-remote Linux VXLAN integration for EdgeOS 3.0.1 on the Ubiquiti
EdgeRouter X (`ER-e50`, Linux `4.14.54-UBNT`). Contributions are welcome, but the supported scope is
deliberately narrow. Read `AGENTS.md` first; it contains the engineering rules that apply to human
and automated contributors.

## 1. Before you start

* **Do not use the maintainer's production router for development.** The project has one physical
  ER-X, and it is a production home router. Use the namespace, container, mock/unit and documented
  hardware-session procedures. A hardware session requires explicit authorization.
* **IPv6 is the default** for new architecture and examples. IPv4 remains supported for
  interoperability; do not remove or weaken IPv4/dual-stack coverage.
* **Do not change product runtime semantics** (installer, package payload, kernel modules,
  templates, public CLI, firewall behavior) as part of a test/documentation/CI contribution. Such a
  change needs a separate design and maintainer approval.
* Check `docs/engineering-backlog.md` before starting a larger piece of work. The backlog is the
  repository-local planning record; no remote issue is required.

## 2. Prerequisites

For the off-device suite:

* Bash, Perl with `JSON::PP`, GNU coreutils, `git`, `dpkg-dev`, `debhelper`, `fakeroot`;
* ShellCheck for the lint step;
* a POSIX shell for the installer and package scripts.

For the privileged namespace suites:

* root or `CAP_NET_ADMIN` (network namespaces, veth, VXLAN);
* iproute2, iputils-ping, Python 3, coreutils;
* tcpdump for optional packet-capture evidence;
* the `vxlan` kernel module (`modprobe vxlan udp_tunnel ip6_udp_tunnel`).

If your host cannot create network namespaces, use a privileged container. Do not report a skipped
privileged test as a pass.

## 3. Build and test

Off-device suite (no root, no network, no real `/sys`):

```bash
bash test/run.sh
```

Expected current result: **376 checks** — 11 build + 64 helper + 122 firewall + 93 templates +
70 mock + 16 qualification-evidence contract — all passing.

Static validation:

```bash
shellcheck install.sh scripts/*.sh test/*.sh test/lib/*.sh \
  debian/*.preinst debian/*.postinst debian/*.prerm debian/*.postrm \
  src/vyatta-vxlan src/vyatta-vxlan-bridge src/vyatta-vxlan-firewall
perl -c src/vyatta-vxlan-addr
git diff --check
```

Dual-stack namespace/firewall regression:

```bash
sudo REQUIRE_NETNS_TEST=1 bash test/integration-netns.sh
```

Isolated IPv6-only Level B qualification (uses the actual reconciler path; requires Perl
`JSON::PP` for that section):

```bash
sudo REQUIRE_NETNS_TEST=1 REQUIRE_CAPTURE=1 REQUIRE_RECONCILER=1 \
  EVIDENCE_DIR=/tmp/ipv6-only-evidence \
  bash test/ipv6-only-netns.sh
```

Candidate-package mode executes the packaged reconciler and address helper from a hash-checked
integration `.deb` (N6-R-P):

```bash
IPV6_ONLY_CANDIDATE_PACKAGE=/path/edgeos-vxlan_<version>_all.deb \
IPV6_ONLY_CANDIDATE_PACKAGE_SHA256=<expected-sha256> \
IPV6_ONLY_CANDIDATE_ID=sha256:<candidate-id> \
IPV6_ONLY_SOURCE_COMMIT=<source-commit> \
GITHUB_RUN_ID=<run> GITHUB_RUN_ATTEMPT=<attempt> \
GITHUB_WORKFLOW_REF=<owner/repo/.github/workflows/ci.yml@refs/...> \
GITHUB_REF=<ref> GITHUB_SHA=<workflow-commit> \
sudo -E REQUIRE_NETNS_TEST=1 REQUIRE_CAPTURE=1 REQUIRE_RECONCILER=1 \
  EVIDENCE_DIR=/tmp/ipv6-only-candidate-evidence \
  bash test/ipv6-only-netns.sh
```

`python3 scripts/validate-ipv6-qualification-evidence.py` verifies the resulting summary against
expected source/candidate/package/workflow/harness identities and recomputes every evidence hash.
`test/unit-ipv6-evidence.sh` covers the positive and negative binding cases. The suite prints
`PASS`/`FAIL`/`SKIP` and a summary. The evidence directory contains the topology, environment, raw
captures, `captures/analysis.txt`, `summary.txt` and `summary.json`. A capture skip
is not capture evidence. The authoritative CI job requires capture and installs tcpdump from the
distribution source in a separate step when needed; local developer runs may leave it optional.
See `docs/ipv6-only-qualification.md` for the Level A–D model and the isolation contract.

Canonical package build and validation:

```bash
./scripts/build-reproducible.sh --output-dir /tmp/edgeos-vxlan-build
./scripts/validate-release.sh /tmp/edgeos-vxlan-build
```

The build must run from a clean tree. Do not modify release assets, checksums or version pins to
make a validation pass.

## 4. CI

The CI workflow is `.github/workflows/ci.yml`; `.github/workflows/release.yml` owns the Phase III
candidate/publication lifecycle.

* Pull requests run static analysis, the off-device suite, the package build and validation, and
  reproducibility verification.
* Privileged namespace jobs run only on trusted events: pushes to `main`/`ci/**`, tags, published
  releases and manual dispatch. They are explicitly excluded from pull requests.
* The `ipv6-only` job establishes the Level B topology, asserts isolation, runs the dataplane and
  reconciler checks, uploads evidence, and cleans up.
* Do not add `pull_request_target`, write permissions or secrets to run untrusted PR code. Pin
  third-party actions by commit SHA.
* If a CI dependency is missing, make the failure explicit. Do not add unconditional `|| true` or
  retries that hide an infrastructure or product regression. Package acquisition uses
  `scripts/apt-update-ubuntu-only.sh`, which scopes the refresh to the distribution source.

Hosted CI is evidence only after it has actually run. A branch that has not been pushed has
**pending** CI, not a passing CI result.

Keep development, qualification and publication separate. Published releases are immutable. A
canonical rebuild is not expected to be byte-identical to a historical release whose mtimes were
not normalized; compare member contents and record the distinction between published integrity,
canonical reproducibility and payload equivalence. The current reconciliation is in
`docs/ipv6-only-qualification-evidence.md`.

PR #8 is merged. The `ipv6-only` job is in `ci.yml` and binds its evidence to the same-run package
artifact by artifact ID/digest, source commit, workflow run/attempt/path/ref/commit and packaged
reconciler hashes. Its `summary.json` is not yet wired into the Phase III candidate manifest or
publication gate; that is a separate focused change. Do not modify publication policy as part of a
qualification change. See `docs/ipv6-only-qualification-ci-integration.md`.

## 5. Documentation

* Update the current guide when behavior, evidence or CI changes. Do not rewrite historical release
  or qualification records; add a new dated record and link it from the current matrix.
* Keep `docs/address-family-support-matrix.md` authoritative for evidence by combination.
* State the evidence class (I/A/S/N/N6/N6-R/H/L/—) and the Level A–D boundary when you discuss
  "IPv6-only". A dual-stack runner with IPv6-only namespaces is Level B, not Level D.
* Use `2001:db8::/32` for IPv6 examples and RFC 5737 prefixes for IPv4 examples. Prefer `/64` for
  ordinary segments; use `/127` only with a stated reason.
* If you discover an IPv4 assumption, classify it in `docs/ipv4-dependency-inventory.md` and map it
  to the backlog. Do not silently "fix" product behavior in a test-only change.

## 6. Commits and pull requests

* Branch from the current `origin/main` unless the task says otherwise. Use a descriptive branch
  name (`ci/...`, `test/...`, `docs/...`, `fix/...`).
* Keep commits logical: one concern per commit where practical. Write a conventional commit message
  (`test:`, `ci:`, `docs:`, `fix:`, `feat:`, `refactor:`) that explains what and why.
* Run the relevant checks before committing. Never commit failing code.
* Do not merge to `main`, tag, publish a release or modify release assets without explicit
  authorization.
* In the pull request, state:
  * what changed and why;
  * the base commit and HEAD;
  * the commands run and their results;
  * the qualification level/evidence class affected;
  * any skipped test and why;
  * any remaining external-service or hardware dependency.

## 7. Hardware work

If a maintainer authorizes a hardware session:

* follow the existing runbook and evidence-capture procedure;
* use only the documented test interfaces and addresses;
* keep a console/management path independent of the tunnel;
* capture the commands, outputs, package hashes, kernel/module state and firewall state;
* record the hardware identity and firmware/kernel versions;
* do not publish credentials, serial numbers or operational addresses;
* record the limitations and do not generalize a namespace or mock result to hardware.

## 8. Reporting a problem

Include the commit, platform, exact command, exit status, relevant output and whether the failure is
a product regression, a missing privilege/tool, an unsupported platform or an external-service
failure. That distinction is required for the project's evidence trail.
