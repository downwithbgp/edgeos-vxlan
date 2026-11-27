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

## 8. Current PR #8 review (head `c573450`, 2026-11-27)

PR #8 is still an **open draft**. It has advanced since the first contract draft; the findings below
are against `c573450357810c19732ccd9434c4a726ec3a1396`, not against an assumed merged state.

### 8.1 `ci.yml`

`ci.yml` currently has `lint`, `package`, `reproducibility`, `published-fixtures` and `dataplane`.
Privileged jobs are guarded by `if: github.event_name != 'pull_request'`; workflow permissions are
`contents: read`; actions are SHA-pinned. There is no IPv6-only job. The port is therefore additive
but must use the new workflow rather than retaining `release-validation.yml`.

### 8.2 Candidate builder and manifest

`scripts/build-release-candidate.sh` builds two independent packages inside the qualified OCI
environment, compares them, and creates `release-candidate.json`. Its `qualification.checks` is
currently four entries:

* `artifact-contract`
* `build-metadata`
* `sbom`
* `reproducibility`

There is no IPv6-only check, and the candidate manifest/ID is created before any IPv6
qualification. The candidate ID is a canonical hash of the manifest identity, so IPv6 evidence
must be present **before** the candidate ID and attestations are created. A post-hoc edit of
`release-candidate.json` would invalidate the candidate ID/attestation and is not acceptable.

`release.yml` currently builds and attests the candidate in one job and has a
`qualification-dry-run` job that only exercises promotion planning. It does not consume an IPv6
qualification artifact.

### 8.3 Candidate validator and release gate

`scripts/validate-candidate.sh` requires every `qualification.checks[].status` to be `passed`, but
it does not require a named set of check IDs. The current candidate can therefore be qualified
without IPv6-only evidence because no IPv6 check exists. `check-release-gates.sh` enforces the
human/environment/variable publication gates; it does not inspect qualification checks.
`promote-release.sh` is the relevant promotion path but has no IPv6 check dependency.

A fail-closed integration needs all of the following:

1. A required-check set (at minimum `ipv6-only-isolation`, `ipv6-only-dataplane`,
   `ipv6-only-capture`, `ipv6-only-reconciler`).
2. Evidence identity validation (source commit, workflow run/attempt, workflow path/ref/commit,
   candidate package SHA-256, candidate ID where available, harness commit).
3. Evidence hash recomputation from retained bytes, not trust in `summary.json` self-reporting.
4. A rejection path for missing/failed/not-performed/unexpectedly-skipped checks.
5. A positive acceptance path for the permitted host-global-IPv6 skip and the documented
   iproute2 normalization workaround.

### 8.4 Trusted execution context

`ci.yml` treats `ci/**` pushes as trusted write-access branches. A branch name is not proof of
trust; branch protection and required review remain the control. The candidate workflow records
`source.trustedWorkflow.ref` and `.commit`, and production candidates require `refs/heads/main` with
the workflow commit equal to the source commit. IPv6 evidence must carry the same workflow
identity, not just a run ID. Evidence from a non-release candidate must not be accepted for a
production candidate.

The candidate artifact fetch helper already verifies artifact ID/digest, run ID, head SHA, workflow
path and artifact name. The IPv6 evidence fetcher should use the same immutability checks, plus a
run-attempt check where relevant.

### 8.5 APT helper duplication

PR #8's `scripts/apt-update-ubuntu-only.sh` masks only source files that mention
`packages.microsoft.com` and runs a plain `apt-get update`. The implementation on this branch
selects exactly one distribution source file and disables source-parts for that invocation. Both
preserve signature/TLS verification and avoid a permanent runner change. The transient
source-selection implementation is stricter and is the recommended canonical helper; PR #8's
call sites can keep the same path and arguments after consolidation.

## 9. Candidate-bound port plan (not implemented while PR #8 is open)

1. Merge PR #8 under its own authorization; update PR #9 onto the resulting `main`.
2. Add `ipv6-only` to `ci.yml` with the existing trusted-event guard, no new permissions, mandatory
   capture and `REQUIRE_RECONCILER=1`.
3. Add a candidate-package qualification step after build A in the candidate job (or a dedicated
   job that produces an evidence bundle). The step must run the packaged integration `.deb`, not
   only source files, and must record:
   * candidate package name/SHA-256;
   * source commit and candidate ID;
   * workflow run ID/attempt, path, ref and commit;
   * harness commit and exercised packaged file hashes;
   * capture and reconciler evidence hashes.
   `test/ipv6-only-netns.sh` already supports `IPV6_ONLY_CANDIDATE_PACKAGE`,
   `IPV6_ONLY_CANDIDATE_PACKAGE_SHA256`, `IPV6_ONLY_CANDIDATE_ID`,
   `IPV6_ONLY_SOURCE_COMMIT`, and records `candidate`, `workflow`, `harness`, `skips` and
   `workarounds` in `summary.json`.
4. Extend `build-release-candidate.sh` to accept the validated IPv6 evidence and append the four
   checks **before** computing the candidate ID and attesting the manifest.
5. Extend `validate-candidate.sh` to require the four IDs and recompute each `evidenceSha256` from
   the retained candidate evidence.
6. Extend `check-release-gates.sh`/`promote-release.sh` to reject a candidate without the required
   IPv6 checks, without mandatory capture, without reconciler execution, with a failed isolation
   check, with identity mismatch, or with an unpermitted skip.
7. Extend `qualification-dry-run` to exercise the new path without publishing.
8. Port the 16 evidence-binding fixtures from `test/unit-ipv6-evidence.sh` and add candidate-gate
   fixtures for the candidate ID/package-digest/workflow-identity cases.
9. Re-run the combined hosted workflow and retain the run URL, evidence bundle, `summary.json`
   hash and candidate manifest hash.

Until steps 1–4 are complete, IPv6-only qualification is **not** an enforceable component of the
trusted release lifecycle. PR #9 must remain a draft; a green PR check or source-level workflow run
is not candidate qualification.

## 10. Candidate-package evidence produced by PR #9 (not yet release-wired)

`test/ipv6-only-netns.sh` now supports execution of the packaged reconciler and address helper
extracted from a candidate `.deb`:

```bash
IPV6_ONLY_CANDIDATE_PACKAGE=/path/edgeos-vxlan_<version>_all.deb \
IPV6_ONLY_CANDIDATE_PACKAGE_SHA256=<expected> \
IPV6_ONLY_CANDIDATE_ID=sha256:<candidate-id> \
IPV6_ONLY_SOURCE_COMMIT=<source-commit> \
GITHUB_RUN_ID=<run> GITHUB_RUN_ATTEMPT=<attempt> \
GITHUB_WORKFLOW_REF=<owner/repo/.github/workflows/ci.yml@refs/...> \
GITHUB_REF=<ref> GITHUB_SHA=<workflow-commit> \
sudo -E REQUIRE_NETNS_TEST=1 REQUIRE_CAPTURE=1 REQUIRE_RECONCILER=1 \
  EVIDENCE_DIR=... bash test/ipv6-only-netns.sh
```

The package SHA-256 is checked before extraction; the extracted reconciler and address-helper
hashes are recorded; `candidate.packageExecuted=true` and evidence class `N6-R-P` are recorded.
The packaged EdgeOS configuration API, firewall and bridge helpers remain test doubles (as in
N6-R). The x86 CI kernel does not qualify the candidate MIPS kernel module.

`scripts/validate-ipv6-qualification-evidence.py` validates the summary against expected identity
and recomputes evidence hashes. `test/unit-ipv6-evidence.sh` provides the positive and negative
fixtures, including missing evidence, failed isolation, missing capture, missing reconciler,
wrong source/candidate/package identity, modified evidence, unrelated workflow, unexpected skip,
missing required check, missing package execution, unreported workaround and malformed JSON.

These artifacts are integration-ready but are **not yet called by PR #8's candidate builder or
release gate**.
