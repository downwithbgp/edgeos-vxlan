# Documentation map

This is the entry point for the repository's documentation. The current guides describe the
implementation and its supported deployment models. Historical release records and point-in-time
audit records are kept separate so that an old candidate result is not mistaken for current
guidance.

The primary deployment model uses IPv6; IPv4 remains supported for interoperability and existing
deployments. The documentation starts with IPv6 because that is the primary model for new
deployments, not because IPv4 is unsupported.

## Current guides

| Document | Purpose |
|---|---|
| [`../README.md`](../README.md) | Install, package summary, primary configuration, limitations |
| [`architecture.md`](architecture.md) | Layer model, VTEP endpoint rules, MTU terminology, scope, standards and applicability |
| [`deployment.md`](deployment.md) | Six deployment scenarios with both endpoints, IPv6 operations, IPv6-only assessment, troubleshooting |
| [`native-firewall.md`](native-firewall.md) | Firewall attachments, underlay peer filtering, lifecycle, bridged and routed semantics, verification |
| [`interface-lifecycle.md`](interface-lifecycle.md) | Reconciliation, rollback, deterministic MACs, EdgeOS integration, boot, removal, diagnostics |
| [`kernel-provenance.md`](kernel-provenance.md) | Kernel module provenance, CVE-2022-50405 backport, compatibility evidence, package build |
| [`address-family-support-matrix.md`](address-family-support-matrix.md) | Implementation, inferred, automated, simulated, namespace and hardware evidence by combination |
| [`engineering-backlog.md`](engineering-backlog.md) | Repository-local engineering proposals and acceptance criteria; no remote issues created |
| [`ipv6-only-qualification.md`](ipv6-only-qualification.md) | Level A–D qualification model, Level B isolation contract, threat model and CI integration |
| [`ipv4-dependency-inventory.md`](ipv4-dependency-inventory.md) | Repository-wide IPv4 dependency audit and external service limitations |
| [`ipv6-only-qualification-evidence.md`](ipv6-only-qualification-evidence.md) | Validation record for the Level B suite and the current CI status |

## Current release records

| Document | Scope |
|---|---|
| [`v0.3.0-release-notes.md`](v0.3.0-release-notes.md) | v0.3.0 release notes and artifacts |
| [`v0.3.0-support-boundary.md`](v0.3.0-support-boundary.md) | Supported firewall configuration workflows and security contract |
| [`v0.3.0-edgeos-scripted-commit-limitation.md`](v0.3.0-edgeos-scripted-commit-limitation.md) | EdgeOS 3.0.1 scripted-commit firewall limitation |
| [`v0.3.0-architecture.md`](v0.3.0-architecture.md) | Native firewall integration architecture decision |
| [`v0.3.0-hardware-qualification-report.md`](v0.3.0-hardware-qualification-report.md) | RC5 hardware qualification report |
| [`v0.3.0-vxlan41913-migration-record.md`](v0.3.0-vxlan41913-migration-record.md) | Operational `vxlan41913` migration record |
| [`release-engineering-hardening.md`](release-engineering-hardening.md) | Post-v0.3.0 release engineering hardening record |

These are dated records. Where a record says a procedure was not executed, that statement remains
true for that record; use the current guides for current status.

## Point-in-time audit records

| Document | Scope |
|---|---|
| [`audit/2026-11-documentation-audit.md`](audit/2026-11-documentation-audit.md) | Documentation audit and final maintainer-review record. It records what was reviewed and changed at a point in time; it is not current operational guidance. |

## Historical records

These are preserved as the evidence trail for the v0.2.1 → v0.2.2 IPv6-underlay work and the
earlier release candidates. They are not the current entry point and are not rewritten when a later
qualification changes the status.

| Group | Documents |
|---|---|
| Issue #3 investigation and planning | [`issue-3-ipv6-assessment.md`](issue-3-ipv6-assessment.md), [`issue-3-implementation-plan.md`](issue-3-implementation-plan.md), [`issue-3-change-inventory.md`](issue-3-change-inventory.md), [`issue-3-risks-and-open-questions.md`](issue-3-risks-and-open-questions.md), [`issue-3-test-plan.md`](issue-3-test-plan.md), [`issue-3-pr-draft.md`](issue-3-pr-draft.md) |
| Issue #3 evidence and acceptance | [`issue-3-hardware-evidence.md`](issue-3-hardware-evidence.md), [`issue-3-acceptance-criteria.md`](issue-3-acceptance-criteria.md), [`issue-3-hardware-validation-runbook.md`](issue-3-hardware-validation-runbook.md), [`issue-3-partial-commit-analysis.md`](issue-3-partial-commit-analysis.md) |
| Issue #3 release records | [`issue-3-release-candidate.md`](issue-3-release-candidate.md), [`issue-3-release-candidate-rc2.md`](issue-3-release-candidate-rc2.md), [`issue-3-deployment-runbook.md`](issue-3-deployment-runbook.md), [`issue-3-stable-release-readiness.md`](issue-3-stable-release-readiness.md), [`issue-3-v0.2.2-release-gate.md`](issue-3-v0.2.2-release-gate.md), [`release-notes-v0.2.2.md`](release-notes-v0.2.2.md) |
| v0.3.0 candidate and evidence records | [`v0.3.0-platform-investigation.md`](v0.3.0-platform-investigation.md), [`v0.3.0-implementation-plan.md`](v0.3.0-implementation-plan.md), [`v0.3.0-off-device-evidence.md`](v0.3.0-off-device-evidence.md), [`v0.3.0-rc1-artifacts.md`](v0.3.0-rc1-artifacts.md), [`v0.3.0-rc2-artifacts.md`](v0.3.0-rc2-artifacts.md), [`v0.3.0-rc3-artifacts.md`](v0.3.0-rc3-artifacts.md), [`v0.3.0-rc3-evidence.md`](v0.3.0-rc3-evidence.md), [`v0.3.0-rc4-artifacts.md`](v0.3.0-rc4-artifacts.md), [`v0.3.0-rc5-artifacts.md`](v0.3.0-rc5-artifacts.md), [`v0.3.0-first-hardware-session.md`](v0.3.0-first-hardware-session.md), [`v0.3.0-first-hardware-session-record.md`](v0.3.0-first-hardware-session-record.md), [`v0.3.0-hardware-acceptance.md`](v0.3.0-hardware-acceptance.md), [`v0.3.0-maintainer-review.md`](v0.3.0-maintainer-review.md), [`v0.3.0-release-readiness.md`](v0.3.0-release-readiness.md), [`v0.3.0-security-invariants-review.md`](v0.3.0-security-invariants-review.md) |

## Evidence classes

The repository uses these labels consistently:

* **Implementation** — code, templates, or configuration grammar supports the behaviour.
* **Automated off-device** — the `test/` suites; no router required.
* **Simulated EdgeOS** — the vendor configuration engine under qemu, or the emulated-engine records.
* **Linux network namespace** — general-Linux dataplane semantics; not EdgeOS validation.
* **N6** — the isolated IPv6-only Linux namespace topology; no usable external IPv4 connectivity
  in the workload. **N6-R** is the same topology with the actual reconciler and test doubles for the
  EdgeOS configuration API and firewall dispatch. Neither is hardware evidence.
* **Physical hardware** — demonstrated on the supported ER-X; the record is cited.
* **Inferred** — expected from Linux VXLAN behaviour or the implementation, but not directly
  demonstrated on the supported platform. It is not a hardware result.
* **Not exercised** — no evidence at that class. Do not infer a pass from another class.

The authoritative combination-by-combination view is
[`address-family-support-matrix.md`](address-family-support-matrix.md).

## Maintenance rules

1. Keep current guides, release records, audit records and historical records separate.
2. Put the primary deployment example first; keep IPv4 examples complete but not as the default
   mental model.
3. Keep one canonical source per claim: deployment for configuration examples and operations,
   architecture for the layer model and MTU, native-firewall for firewall semantics,
   interface-lifecycle for reconciliation, kernel-provenance for module/build evidence, and the
   support matrix for validation status.
4. Use `2001:db8::/32` for IPv6 examples and RFC 5737 prefixes for IPv4 examples.
5. Do not claim a combination, IPv6-only environment, or external probe result without citing the
   evidence class. State the Level A–D boundary when discussing "IPv6-only"; a dual-stack runner
   with IPv6-only namespaces is Level B, not Level D.
