# IPv6-only qualification in the trusted release lifecycle

**Status:** integration record, 2026-11-27. PR #8 (`Phase III: trusted release lifecycle`) merged
to `main` at `0771455504056fcf45b6fc041cc541e20e12f0f2`. PR #9 is rebased onto that main and ports
the IPv6-only job into the canonical `ci.yml`.
**Scope:** CI integration and candidate-bound evidence. This document does **not** modify the
publication policy, release workflows, historical assets or release gates.
**Related:** [`ipv6-only-qualification.md`](ipv6-only-qualification.md),
[`ipv6-only-qualification-evidence.md`](ipv6-only-qualification-evidence.md),
[`trusted-release-lifecycle.md`](trusted-release-lifecycle.md).

## 1. Integration baseline and conflict resolution

| Item | Value |
|---|---|
| Original PR #9 HEAD | `a7bc214520c17a3567f3d0f4d7d1c820388ce3c0` |
| Recoverable backup | `backup/pr9-pre-phase3-integration` = `a7bc214520c17a3567f3d0f4d7d1c820388ce3c0` |
| Merged Phase III main | `0771455504056fcf45b6fc041cc541e20e12f0f2` |
| Integration model | Rebase onto `origin/main`; no merge commit |
| Obsolete workflow | `release-validation.yml` removed; not resurrected |
| APT helper | Main's masking implementation replaced by the stricter transient source-selection implementation; all main call sites use the same path |
| PR #8 branch | Not modified |

Conflicts were limited to the obsolete workflow deletion and the two APT helper implementations.
The IPv6 qualification code, tests and documentation were preserved; the workflow was re-homed in
`ci.yml`.

## 2. Canonical CI architecture

`ci.yml` is the canonical CI workflow:

| Job | Trigger | Privilege |
|---|---|---|
| `lint` | push, pull_request, tags | `contents: read` |
| `package` | push, pull_request, tags | `contents: read` |
| `reproducibility` | push, pull_request, tags | `contents: read` |
| `published-fixtures` | non-PR push/tags | `contents: read` |
| `dataplane` | non-PR push/tags | `contents: read` |
| **`ipv6-only`** | non-PR push/tags | `contents: read`, `actions: read` |

`ipv6-only` is **not** run on `pull_request`, so untrusted PR code never receives
`CAP_NET_ADMIN`. No `pull_request_target` is used. Actions are SHA-pinned. The `package` job
publishes a non-release package artifact; the IPv6 job never publishes or promotes anything.

### 2.1 Same-run package binding

The `package` job exposes the uploaded artifact ID and ZIP digest as job outputs. The `ipv6-only`
job:

1. `needs: package`, so it cannot run without a successful package build in the same workflow run;
2. fetches the artifact by immutable ID/digest with `scripts/fetch-github-artifact.sh`, verifying
   repository identity, run ID, head SHA, workflow path, artifact name and the downloaded ZIP
   digest;
3. verifies `SHA256SUMS` and selects the integration `.deb`;
4. runs `test/ipv6-only-netns.sh` in N6-R-P mode with the package SHA-256, source commit, workflow
   run/attempt/path/ref/commit and harness commit;
5. validates the resulting `summary.json` with
   `scripts/validate-ipv6-qualification-evidence.py`, requiring workflow binding and packaged
   execution;
6. uploads raw captures, analysis, `summary.json`, per-test logs and the rest of the evidence
   directory.

The artifact is a **non-release CI package** built from the same source commit in the same run, not
a release candidate. It is not evidence for a separately rebuilt or later release candidate. The
candidate identity is the run's source commit plus the package SHA-256; the release candidate ID is
not used because this job does not build or publish a release candidate.

### 2.2 Permissions and trust

`actions: read` is required only to fetch the artifact by ID and verify its run metadata. It is
granted only to `ipv6-only`; the workflow default remains `contents: read`. `GH_TOKEN` is scoped to
the current repository and is not a publication credential. `sudo -E` preserves the GitHub run
identity for the summary, but the job receives no write token or secrets.

`ci/**` branch pushes remain the existing trusted write-access model. A branch name is not proof of
trust; branch protection and required review remain the control. A production candidate/build must
be produced by the Phase III `release.yml` path and must not accept this job's non-release evidence
as a release-candidate qualification without the binding described in §4.

## 3. APT helper consolidation

`scripts/apt-update-ubuntu-only.sh` is now one canonical implementation:

- selects exactly one distribution source file (`/etc/apt/sources.list.d/ubuntu.sources` or
  `/etc/apt/sources.list`);
- passes transient `Dir::Etc::sourceparts="-"` and `Dir::Etc::sourcelist` options;
- does not modify runner source files;
- preserves signature and TLS verification;
- fails clearly if the distribution source is unavailable.

The `ci.yml` package/reproducibility/dataplane/ipv6 jobs and
`scripts/install-schema-validator.sh` use this path. The obsolete masking implementation from PR #8
was not retained.

## 4. Candidate manifest and release-gate contract (recommended, not implemented)

The Phase III candidate builder currently creates `qualification.checks` from `artifact-contract`,
`build-metadata`, `sbom` and `reproducibility`, then computes the candidate ID and attests the
manifest. `validate-candidate.sh` requires every listed check to pass but does not require IPv6
check IDs. `release.yml` does not consume IPv6 evidence.

Recommended contract for a future focused change (not part of PR #9):

1. Run the N6-R-P suite against the **exact candidate package** built by
   `build-release-candidate.sh`, after build A and before candidate ID/attestation.
2. Pass the resulting `summary.json` and its SHA-256 into the candidate builder.
3. Validate it with `scripts/validate-ipv6-qualification-evidence.py` using:
   * source commit = candidate source commit;
   * package SHA-256 = candidate integration package;
   * workflow run/attempt/path/ref/commit = trusted release workflow identity;
   * harness commit = the workflow commit;
   * permitted skip `host-global-ipv6-escape-unavailable`;
   * permitted workaround `iproute2-json-normalization`;
   * required checks `ipv6-only-isolation`, `ipv6-only-dataplane`, `ipv6-only-capture`,
     `ipv6-only-reconciler`.
4. Append those four checks to `release/candidate-schema.json` `qualification.checks[]` **before**
   computing the candidate ID and attesting the manifest.
5. Make `validate-candidate.sh` require the four IDs and recompute each evidence hash from the
   retained candidate evidence.
6. Make `check-release-gates.sh`/`promote-release.sh` reject missing/failed/not-performed checks,
   mandatory-capture failure, missing reconciler execution, identity mismatch, evidence hash
   mismatch and unpermitted skips.
7. Keep candidate eligibility separate from maintainer publication approval; do not rebuild after
   qualification.
8. Add candidate-gate fixtures for candidate ID/package digest/workflow identity and publication
   ordering.

This is a contract, not a change to Phase III publication policy. PR #9 does not modify
`release.yml`, `release/candidate-schema.json`, `validate-candidate.sh`,
`check-release-gates.sh` or `promote-release.sh`.

## 5. Superseded `qualify-build-image.yml`

`qualify-build-image.yml` is absent from the merged `main` workflow set. Grepping `origin/main`
finds no consumers or path references; the Phase III `build-environment.yml` owns image
qualification. Historical records may mention the old qualification run/image, but no live workflow
depends on the file. Removing stale historical references, if any, is a separate documentation
cleanup and is **not** part of this integration. No workflow file was deleted in this PR.

## 6. Verification model

- **PR-triggered CI:** `lint`, `package`, `reproducibility` run; privileged `dataplane` and
  `ipv6-only` are skipped by their event guards. This is intentional and must not be reported as
  IPv6 qualification.
- **Push/tag CI:** `package` produces the same-run artifact; `ipv6-only` fetches and qualifies it;
  evidence is retained.
- **Failure behavior:** a failed package job prevents the IPv6 job; a missing artifact, ID/digest
  mismatch, failed package hash, absent capture, missing reconciler or failed isolation prevents a
  pass. The validator is fail-closed.
- **Permissions:** only `contents: read` and `actions: read`; no `pull_request_target`, no write
  token, no publication path.
- **Regression:** the existing package, reproducibility, static analysis and dual-stack dataplane
  jobs remain unchanged except for the consolidated APT helper.

## 7. Remaining limitations

1. The IPv6 job qualifies a non-release CI package, not a Phase III release candidate. The
   candidate-manifest/release-gate contract in §4 is not implemented.
2. The x86 hosted kernel does not qualify the candidate MIPS kernel module or physical ER-X
   hardware. Level B remains N6/N6-R-P, not H.
3. Level C (IPv6-only installation/management) and Level D (IPv6-only runner/control plane)
   remain unachieved.
4. `iproute2-json-normalization` is a test-environment shim; ENG-IPV6-10 remains open for the
   product/version decision.
5. Candidate-gate negative fixtures remain future work; the 16 evidence-binding fixtures are in
   place.
6. `qualify-build-image.yml` historical-reference cleanup, if wanted, is a separate change.

## 8. Integration recommendation

PR #9 is integration-ready for review. Merge only after the maintainer approves the `ci.yml`
placement and the same-run artifact binding. Follow with a **separate** candidate-bound Phase III
change implementing §4; do not widen this PR into a publication-policy redesign. No release or
image publication is authorized by this integration.
