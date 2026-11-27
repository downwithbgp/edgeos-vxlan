# IPv6-only qualification in the trusted release lifecycle

**Status:** integration record, 2026-11-27. PR #8 (`Phase III: trusted release lifecycle`) merged
to `main` at `0771455504056fcf45b6fc041cc541e20e12f0f2`. PR #9 integrated that main and ports
the IPv6-only job into the canonical `ci.yml`. Hosted CI has passed for the integration merge and
for every documentation-only commit on this branch; the runs are listed in §9. Documentation-only
commits change no workflow, test or package input, so that verification applies to the branch
content described here.
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
| Merged Phase III main (integration base) | `0771455504056fcf45b6fc041cc541e20e12f0f2` |
| Reviewed integration tree | `251c1cb` (rebase result); tree `eee30a20361c2d3111b2cb2eea6aeb548dc52845` |
| Hosted verification recorded for | `ec1a5c27767d787344d4b4e18224dd11aaa51869` (runs 46063199151 / 46063207150, §9) |
| Integration model | The reviewed rebase result was recorded as a merge commit with parents `a7bc214` and `0771455`. The merged tree is byte-identical to the reviewed rebase tree (`eee30a2…`), so review applies unchanged and no force-push of the published branch was required. |
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

## 4. Candidate manifest and release-gate contract

**Implemented** by ENG-IPV6-11 on `ci/ipv6-release-qualification`; the canonical description is
[`release-candidate-ipv6-qualification.md`](release-candidate-ipv6-qualification.md). This section
keeps the original recommended contract and notes where the implementation follows it.

When this section was written (PR #9), the Phase III candidate builder created
`qualification.checks` from `artifact-contract`, `build-metadata`, `sbom` and `reproducibility`,
then computed the candidate ID and attested the manifest. `validate-candidate.sh` required every
listed check to pass but did not require IPv6 check IDs, and `release.yml` did not consume IPv6
evidence.

The recommended contract was:

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

This was a contract, not a change to Phase III publication policy; PR #9 did not modify
`release.yml`, `release/candidate-schema.json`, `validate-candidate.sh`,
`check-release-gates.sh` or `promote-release.sh`.

The later implementation follows steps 1–8 and adds an explicit pre-qualification build identity
(the four checks are attached before the candidate ID is computed, but qualification binds to
`build.identity`, not to the not-yet-existing candidate ID). It also wires the four checks into
`check-release-gates.sh --candidate-dir`, which `promote-release.sh` always supplies.

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

1. The `ci.yml` IPv6 job still qualifies a non-release CI package; release-candidate
   qualification is implemented separately by ENG-IPV6-11
   ([`release-candidate-ipv6-qualification.md`](release-candidate-ipv6-qualification.md)). The
   hosted non-publication run of that combined path is pending branch-publication authorization.
2. The x86 hosted kernel does not qualify the candidate MIPS kernel module or physical ER-X
   hardware. Level B remains N6/N6-R-P, not H.
3. Level C (IPv6-only installation/management) and Level D (IPv6-only runner/control plane)
   remain unachieved.
4. `iproute2-json-normalization` is a test-environment shim; ENG-IPV6-10 remains open for the
   product/version decision.
5. Candidate-gate negative fixtures remain future work; the 16 evidence-binding fixtures are in
   place.
6. `qualify-build-image.yml` historical-reference cleanup, if wanted, is a separate change.

## 8. Changed-file inventory

Net change of the integration merge `92336a3` against its base `0771455` (`origin/main`):
**19 files, +4712 −74**. The subsequent documentation-only record commits add
`docs/ipv6-only-qualification-ci-integration.md` content (+128 −21) and touch no other file.

| File | Change |
|---|---|
| `.github/workflows/ci.yml` | Modified: `package` job outputs (`artifact_id`, `artifact_digest`) and the ported `ipv6-only` job. The only workflow file changed; no other Phase III workflow is touched. |
| `scripts/apt-update-ubuntu-only.sh` | Modified: replaced main's masking helper with the transient single-source implementation. |
| `test/ipv6-only-netns.sh`, `test/lib/ipv6-isolation.sh` | Added: isolated IPv6-only suite and isolation assertions. |
| `test/unit-ipv6-evidence.sh` | Added: 16 evidence-binding contract fixtures. |
| `test/run.sh` | Modified: registers the new evidence-contract suite. |
| `scripts/validate-ipv6-qualification-evidence.py` | Added: candidate-bound evidence validator. |
| `AGENTS.md`, `CONTRIBUTING.md` | Added/modified: current engineering rules and contributor guidance. |
| `README.md`, `docs/README.md` | Modified: documentation index and entry points. |
| `docs/ipv6-only-qualification.md`, `docs/ipv6-only-qualification-evidence.md`, `docs/ipv6-only-qualification-ci-integration.md` | Added: qualification guide, evidence record and this integration record. |
| `docs/ipv4-dependency-inventory.md` | Added: IPv4 assumption inventory. |
| `docs/address-family-support-matrix.md`, `docs/architecture.md`, `docs/deployment.md`, `docs/engineering-backlog.md` | Modified: current claims, layer model, scenarios and backlog. |

No file under `release/`, `src/`, `templates/`, `debian/` or any Phase III release script is changed.
The package payload is unchanged: the integration `.deb` is still
`6afa3f25e8145a6ebf31a947ab104b223b351aa615b51aa2a97389364a133e2a`.

## 9. Hosted verification of the integrated workflow

Selected runs. Every documentation-only commit on this branch has passed the same workflows; the
table records the integration merge and the commits that carried verification-relevant changes.

| Run | Event | Result |
|---|---|---|
| [46064486700](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46064486700) | push at `a53fb0d` | **success** — all six jobs passed, including IPv6-only qualification |
| [46064492288](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46064492288) | pull_request at `a53fb0d` | **success** — Static analysis, Build and validate packages and Reproducibility verification passed; the three privileged jobs skipped |
| [46063740562](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46063740562) | push at `c315fa1` | **success** — all six jobs passed, including IPv6-only qualification |
| [46063748970](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46063748970) | pull_request at `c315fa1` | **success** — the three privileged jobs skipped |
| [46063199151](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46063199151) | push at `ec1a5c2` | **success** — all six jobs passed, including IPv6-only qualification |
| [46063207150](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46063207150) | pull_request at `ec1a5c2` | **success** — the three privileged jobs skipped |
| [46062441889](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46062441889) | push at `8d952e0` | **success** — all six jobs passed |
| [46060990232](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46060990232) | push at `92336a3` (integration merge) | **success** — all six jobs passed |

The PR runs confirm the trust boundary: untrusted PR code never reaches the privileged jobs. The
skips are event guards, not qualifications, and are not reported as IPv6 evidence.

### 9.1 Candidate-bound evidence from the integrated push run

The `ipv6-only-qualification-evidence` artifact of run `46060990232` attempt 1 records:

| Identity | Value |
|---|---|
| Source commit | `92336a3840d167ff475d5422755c3570ef65421a` |
| Workflow run | `46060990232`, attempt 1 |
| Workflow path/ref | `downwithbgp/edgeos-vxlan/.github/workflows/ci.yml@refs/heads/ci/ipv6-native-qualification` |
| Harness commit | `92336a3840d167ff475d5422755c3570ef65421a` |
| Package | `edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb`, SHA-256 `6afa3f25e8145a6ebf31a947ab104b223b351aa615b51aa2a97389364a133e2a` |
| Packaged files | reconciler `814bf8074775c45a41b89eb9ef7ffd689426ee63c7435de4191d81940ed304b7`, address helper `a484717ad975ff429368e66d638f3d1bc05e17a61c37b0cd50ff9ec82866c7d7` |
| Counts | 113 pass, 0 fail, 2 skip; `capture=executed`, `reconciler=executed`, `packageExecuted=true` |
| Evidence classes | N6, N6-R, N6-R-P |

Retained evidence hashes: `summary.json` `73b32231e15fe9b0e8303b685a3fe04d144256de5d88e162680bb5f1e52490ff`,
`summary.txt` `74b8b5f598f53da07dc49ad607d8b059d7eae0ab8f3de71f77c0a1c2b055ceb5` (isolation),
`topology-after.txt` `22498d4840db471e1cff81342e12666ab9c5a3ce9460c7a60399d58db98e6fc9` (dataplane),
`captures/analysis.txt` `4566ecfb86aaef625b23be90c9f498baa17e90b955ff65790117d9b1ef48af56` (capture),
`reconciler-evidence.txt` `6813645cea6f0762bd99e611e616721c032350a6aa92bb4eef92cca25cd0bed5` (reconciler).
The two skips are the permitted host-global-IPv6 escape control and the documented
`iproute2-json-normalization` workaround.

Re-validating the downloaded artifact against that identity returned **PASS**, with only the two
permitted skips:

```bash
python3 scripts/validate-ipv6-qualification-evidence.py \
  --summary summary.json --evidence-dir . \
  --expected-source-commit 92336a3… --expected-package-sha256 6afa3f25… \
  --expected-workflow-run-id 46060990232 --expected-workflow-run-attempt 1 \
  --expected-workflow-path 'downwithbgp/edgeos-vxlan/.github/workflows/ci.yml@refs/heads/ci/ipv6-native-qualification' \
  --expected-workflow-ref refs/heads/ci/ipv6-native-qualification \
  --expected-workflow-commit 92336a3… --expected-harness-commit 92336a3… \
  --require-workflow-binding --require-package-execution \
  --allow-skip host-global-ipv6-escape-unavailable \
  --allow-skip iproute2-json-normalization \
  --allow-workaround iproute2-json-normalization
```

Local gates at `92336a3`: `bash test/run.sh` **376 checks passed** (11 build + 64 helper + 122
firewall + 93 templates + 70 mock + 16 qualification-evidence contract); `shellcheck -x -e
SC1091,SC2015` clean; `perl -c src/vyatta-vxlan-addr` OK; `actionlint` 1.7.12 clean; `zizmor
--offline --collect all` 1.33.1 no findings; `git diff --check` clean. The same gates pass at
`8d952e0`.

### 9.2 Reproduction at the final verified HEAD

Run [46062441889](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46062441889) at
`8d952e0` reproduced the result: 113 pass, 0 fail, 2 skip; the same integration package
`6afa3f25…`; `capture=executed`, `reconciler=executed`, `packageExecuted=true`. Re-validating that
artifact returned **PASS** with the same two permitted skips. Its `summary.json` is
`02038888ddaaeb29ac44bf9d1c5b6ab976a4cb03ca34b36790f014ccf390025f`; the capture analysis and
reconciler evidence hashes are unchanged, because those bytes depend on the package and topology,
not on the run timestamp.

This is a **documentation-only** commit on top of the integration merge; it changes no workflow,
test or package input, so the `8d952e0` verification applies to the branch content described here.

## 10. Integration recommendation

PR #9 is integration-ready for review and remains a **draft, unmerged**. Merge only after the
maintainer approves the `ci.yml` placement and the same-run artifact binding. Follow with a
**separate** candidate-bound Phase III change implementing §4; do not widen this PR into a
publication-policy redesign. No release, image publication, version change or historical asset
change is part of this integration.
