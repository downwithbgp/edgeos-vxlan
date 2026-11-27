# Documentation map

This repository's current documentation is IPv6-first. IPv6 is the preferred protocol for new
deployments; IPv4 remains supported for interoperability and existing deployments. The documentation
keeps historical release records separate from current guidance so that an old candidate record is
not mistaken for the current support statement.

## Start here

| Document | Purpose |
|---|---|
| [`../README.md`](../README.md) | Install, feature summary, configuration scenarios, current limitations |
| [`ipv6-first-architecture.md`](ipv6-first-architecture.md) | Layer model, VTEP endpoint rules, MTU model, scope, standards and applicability |
| [`ipv6-first-deployment.md`](ipv6-first-deployment.md) | Six deployment scenarios with both endpoints, IPv6 operations, IPv6-only assessment, troubleshooting |
| [`address-family-support-matrix.md`](address-family-support-matrix.md) | Implementation, automated, simulated, namespace and hardware evidence by combination |
| [`documentation-audit-2026-11.md`](documentation-audit-2026-11.md) | Audit report: corrections, remaining IPv4 assumptions, IPv6-only findings, prioritized follow-ups |

## Current operational and release records

| Document | Scope |
|---|---|
| [`v0.3.0-release-notes.md`](v0.3.0-release-notes.md) | v0.3.0 release notes and artifacts |
| [`v0.3.0-support-boundary.md`](v0.3.0-support-boundary.md) | Supported firewall configuration workflows and security contract |
| [`v0.3.0-edgeos-scripted-commit-limitation.md`](v0.3.0-edgeos-scripted-commit-limitation.md) | EdgeOS 3.0.1 scripted-commit firewall limitation |
| [`v0.3.0-architecture.md`](v0.3.0-architecture.md) | Native firewall integration architecture decision |
| [`v0.3.0-hardware-qualification-report.md`](v0.3.0-hardware-qualification-report.md) | RC5 hardware qualification report |
| [`v0.3.0-vxlan41913-migration-record.md`](v0.3.0-vxlan41913-migration-record.md) | Operational `vxlan41913` migration record |
| [`release-engineering-hardening.md`](release-engineering-hardening.md) | Post-v0.3.0 release engineering hardening record |

The release notes and qualification records are dated records. Where a record says a procedure was
not executed, that statement remains true for that record; use the current guides for current status.

## Historical records

These are preserved as the evidence trail for the v0.2.1 → v0.2.2 IPv6-underlay work and the
earlier release candidates. They are not the current entry point and are not rewritten when a later
qualification changes the status.

| Group | Documents |
|---|---|
| Issue #3 investigation and planning | [`issue-3-ipv6-assessment.md`](issue-3-ipv6-assessment.md), [`issue-3-implementation-plan.md`](issue-3-implementation-plan.md), [`issue-3-change-inventory.md`](issue-3-change-inventory.md), [`issue-3-risks-and-open-questions.md`](issue-3-risks-and-open-questions.md), [`issue-3-test-plan.md`](issue-3-test-plan.md) |
| Issue #3 evidence and acceptance | [`issue-3-hardware-evidence.md`](issue-3-hardware-evidence.md), [`issue-3-acceptance-criteria.md`](issue-3-acceptance-criteria.md), [`issue-3-hardware-validation-runbook.md`](issue-3-hardware-validation-runbook.md), [`issue-3-partial-commit-analysis.md`](issue-3-partial-commit-analysis.md) |
| Issue #3 release records | [`issue-3-release-candidate.md`](issue-3-release-candidate.md), [`issue-3-release-candidate-rc2.md`](issue-3-release-candidate-rc2.md), [`issue-3-deployment-runbook.md`](issue-3-deployment-runbook.md), [`issue-3-stable-release-readiness.md`](issue-3-stable-release-readiness.md), [`issue-3-v0.2.2-release-gate.md`](issue-3-v0.2.2-release-gate.md), [`release-notes-v0.2.2.md`](release-notes-v0.2.2.md) |
| v0.3.0 candidate and evidence records | [`v0.3.0-platform-investigation.md`](v0.3.0-platform-investigation.md), [`v0.3.0-implementation-plan.md`](v0.3.0-implementation-plan.md), [`v0.3.0-off-device-evidence.md`](v0.3.0-off-device-evidence.md), [`v0.3.0-rc1-artifacts.md`](v0.3.0-rc1-artifacts.md), [`v0.3.0-rc2-artifacts.md`](v0.3.0-rc2-artifacts.md), [`v0.3.0-rc3-artifacts.md`](v0.3.0-rc3-artifacts.md), [`v0.3.0-rc3-evidence.md`](v0.3.0-rc3-evidence.md), [`v0.3.0-rc4-artifacts.md`](v0.3.0-rc4-artifacts.md), [`v0.3.0-rc5-artifacts.md`](v0.3.0-rc5-artifacts.md), [`v0.3.0-first-hardware-session.md`](v0.3.0-first-hardware-session.md), [`v0.3.0-first-hardware-session-record.md`](v0.3.0-first-hardware-session-record.md), [`v0.3.0-hardware-acceptance.md`](v0.3.0-hardware-acceptance.md), [`v0.3.0-maintainer-review.md`](v0.3.0-maintainer-review.md), [`v0.3.0-release-readiness.md`](v0.3.0-release-readiness.md), [`v0.3.0-security-invariants-review.md`](v0.3.0-security-invariants-review.md) |

## Evidence classes

The repository uses these labels consistently:

* **Implementation** — code, templates, or configuration grammar supports the behaviour.
* **Automated off-device** — the `test/` suites; no router required.
* **Simulated EdgeOS** — the vendor configuration engine under qemu, or the emulated-engine records.
* **Linux network namespace** — general-Linux dataplane semantics; not EdgeOS validation.
* **Physical hardware** — demonstrated on the supported ER-X; the record is cited.
* **Not exercised** — no evidence at that class. Do not infer a pass from another class.

The authoritative combination-by-combination view is
[`address-family-support-matrix.md`](address-family-support-matrix.md).

## Maintenance rules

1. Keep the current/historical split. Add a new dated record instead of rewriting an old one.
2. Put the primary example first: IPv6 underlay with IPv6 overlay.
3. Keep IPv4 examples complete and technically accurate, but do not make them the default mental
   model.
4. Use `2001:db8::/32` for IPv6 examples and RFC 5737 prefixes for IPv4 examples.
5. Do not claim a combination, IPv6-only management path, or external probe result without citing
   the evidence class.
