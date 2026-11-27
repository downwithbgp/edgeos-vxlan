# IPv6-only qualification — CI integration contract with the trusted release lifecycle

**Status:** proposed coordination record, 2026-11-27. This document does not modify PR #8 or the
trusted-release-lifecycle branch. It records the conflict between the current branch and PR #8 and
the contract to apply after that workstream lands.
**Related:** [`ipv6-only-qualification.md`](ipv6-only-qualification.md),
[`engineering-backlog.md`](engineering-backlog.md), and the trusted-release-lifecycle report on
`ci/trusted-release-lifecycle` (`docs/trusted-release-lifecycle.md`).

## 1. Current state and conflict

The `ipv6-only` job is currently in `.github/workflows/release-validation.yml` on
`ci/ipv6-native-qualification`. That workflow is the architecture on `main` at the review baseline
(`5958bc4`).

PR #8 (`ci/trusted-release-lifecycle`) is a parallel draft that:

* deletes `.github/workflows/release-validation.yml`;
* splits CI into `.github/workflows/ci.yml`, `build-environment.yml`, `release.yml`,
  `verify-release.yml` and `security-audit.yml`;
* adds a `scripts/apt-update-ubuntu-only.sh` helper with a different implementation;
* adds a release-candidate manifest (`release/candidate-schema.json`,
  `scripts/build-release-candidate.sh`, `scripts/validate-candidate.sh`) with a
  `qualification.checks[]` array;
* adds a fail-closed publication gate and draft-first promotion.

The current `ipv6-only` job therefore **conflicts structurally** with PR #8:

| Conflict | Effect | Resolution |
|---|---|---|
| Job lives in `release-validation.yml` | PR #8 deletes the file; the job would be lost | Port the job block to `ci.yml` after PR #8 lands |
| `scripts/apt-update-ubuntu-only.sh` exists on both branches with different implementations | Merge conflict; two dependency policies | Choose one canonical helper; see §3 |
| PR #8's `ci.yml` has no `ipv6-only` job | Level B qualification is not part of the candidate/release gate | Add the job and wire its evidence into the candidate manifest |
| PR #8's `dataplane` job still uses `modprobe ... || true` | A missing VXLAN module could be hidden | The `ipv6-only` job already fails on `modprobe`; the dataplane job should be aligned in a separate PR #8 change |

The two branches do not execute at the same time on `main`: our job runs in the current workflow,
and PR #8's workflows run on its branch. The conflict is at merge/port time, not at runtime.

## 2. Proposed job placement

Port the existing job block into `.github/workflows/ci.yml` with the same semantics:

```yaml
  ipv6-only:
    name: IPv6-only qualification
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - checkout (SHA-pinned, persist-credentials: false)
      - verify tools (ip, ping, python3, timeout, awk, sed, grep)
      - prepare packet-capture tooling (install tcpdump only if absent)
      - verify tcpdump
      - modprobe vxlan udp_tunnel ip6_udp_tunnel (strict)
      - REQUIRE_NETNS_TEST=1 REQUIRE_CAPTURE=1 REQUIRE_RECONCILER=1
        EVIDENCE_DIR=$RUNNER_TEMP/ipv6-only-evidence
        sudo -E bash test/ipv6-only-netns.sh
      - upload evidence (always)
      - cleanup (always)
```

No new permissions are required: `contents: read` remains sufficient. No `pull_request_target` is
used. The job runs only on trusted events: pushes to `main`/`ci/**`, tags, and manual dispatch.
`release` events are not currently part of PR #8's `ci.yml`; if candidate verification needs the job
on a release event, the release workflow should call or depend on the same job rather than
duplicating it.

## 3. APT helper consolidation

Both branches provide `scripts/apt-update-ubuntu-only.sh` for the same failure mode, but the
implementations differ:

* **Our branch:** transient APT options read only the distribution source file
  (`Dir::Etc::sourcelist`) and disable source-parts for that invocation. It does not modify runner
  files and cannot fall back to a third-party source.
* **PR #8:** temporarily renames source files containing `packages.microsoft.com`, runs a plain
  `apt-get update`, and restores the files on exit.

Both preserve signature/TLS verification and avoid a permanent runner change. The transient
source-selection implementation is stricter: it excludes every non-selected source, not only the
known Microsoft endpoint, and does not touch files. Recommended contract:

1. Keep the helper name `scripts/apt-update-ubuntu-only.sh`.
2. Adopt the transient source-selection implementation from this branch (reviewed by the PR #8
   owner) or document why the masking implementation is preferred.
3. Ensure all package-acquisition call sites in `ci.yml`, `build-environment.yml`,
   `release.yml` and `verify-release.yml` use the single helper.
4. Keep the tcpdump install in a separate dependency-preparation step, before the isolated workload.

No package is installed inside the isolated network namespaces.

## 4. Qualification evidence → candidate manifest

The suite writes `summary.json` with schema `edgeos-vxlan.ipv6-only-qualification/v1`. The stable
fields intended for a candidate manifest are:

| Field | Use |
|---|---|
| `commit` | Source commit under qualification |
| `result` | `passed` / `failed` |
| `counts` | Pass/fail/skip counts for diagnostics |
| `checks[]` | `{id, status, evidenceSha256}` entries for `ipv6-only-isolation`, `ipv6-only-dataplane`, `ipv6-only-capture`, `ipv6-only-reconciler` |
| `capture.*Sha256` | Raw underlay/overlay capture and analysis hashes |
| `reconciler.evidenceSha256` | Reconciler-path evidence hash |
| `hardware` | `{status: not-qualified, required: false, evidence: []}` |
| `limitations` | Explicit residual limitations |

Proposed mapping into PR #8's `release/candidate-schema.json` `qualification` object:

```json
{
  "status": "passed",
  "checks": [
    {"id": "ipv6-only-isolation", "status": "passed", "evidenceSha256": "<from summary.json>"},
    {"id": "ipv6-only-dataplane", "status": "passed", "evidenceSha256": "<from summary.json>"},
    {"id": "ipv6-only-capture", "status": "passed", "evidenceSha256": "<from summary.json>"},
    {"id": "ipv6-only-reconciler", "status": "passed", "evidenceSha256": "<from summary.json>"}
  ],
  "hardware": {"status": "not-qualified", "required": false, "evidence": []}
}
```

The evidence files themselves should be retained as workflow artifacts and their SHA-256 values
should be computed from the retained bytes, not copied from a mutable working directory. A
candidate manifest must not be considered qualified if any required check is `failed` or
`not-performed`.

## 5. Release gating

The current `main` workflow does not prevent a release from being published merely because the
`ipv6-only` job failed: the release is published outside that workflow. PR #8 introduces a
candidate/publication gate; the proposed contract is:

1. `build-release-candidate.sh` records the `ipv6-only` checks in the candidate manifest (or
   `validate-candidate.sh` consumes a qualification artifact).
2. `validate-candidate.sh` fails closed when a required check is missing, failed or
   not-performed, and when the evidence hash does not match.
3. `check-release-gates.sh` requires the candidate status `qualified` before publication.
4. `release.yml`'s candidate job depends on (or consumes the artifact from) the `ipv6-only` job;
   publication remains behind the existing `release-publication` environment and draft-first
   promotion.
5. The publish path never rebuilds or substitutes the qualification target: the candidate ID and
   source commit are the same ones the qualification job used.

This is a design contract, not an implementation on PR #8. It must be reviewed by the PR #8 owner
and the maintainer before the two branches are merged.

## 6. Trust boundaries and branch-triggered execution

* The job runs on `ci/**` pushes because the current CI architecture treats that namespace as
  trusted write-access branches. Any collaborator with write access can push a `ci/**` branch and
  run privileged code on an ephemeral GitHub-hosted runner. The job has `contents: read`, no
  secrets, and no write token; the residual risk is code execution on that runner, not repository
  compromise.
* Recommend protecting `ci/**` and `main` with required review, and limiting who can push to
  `ci/**`. This is a repository setting, not a workflow change.
* Never add `pull_request_target`, repository secrets, write permissions or artifact consumption
  from untrusted PRs to this job.
* The job does not execute downloaded packages; it executes repository source and pinned tools.
* A dual-stack GitHub-hosted runner that creates IPv6-only namespaces is Level B. It is not
  Level D and must not be described as an IPv6-only CI infrastructure.

## 7. Merge sequencing

1. Land or stabilise PR #8's workflow split.
2. Port the `ipv6-only` job into `ci.yml`; resolve the APT-helper duplication.
3. Add the candidate-manifest mapping and release gate in a focused change owned by the release
   lifecycle workstream.
4. Re-run the hosted qualification from the trusted workflow path and retain the run URL,
   evidence artifact and `summary.json` hash.
5. Only then make the job a required release acceptance check.

Until step 2, this branch remains based on `main` and its `release-validation.yml` job is the
development/qualification entry point. It must not be merged in a way that silently drops the job
when `release-validation.yml` is deleted.
