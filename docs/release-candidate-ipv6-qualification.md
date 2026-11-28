# Release-candidate IPv6 qualification

**Status:** merged to `main` as `fffdedd` (PR #10). The development-branch hosted non-publication
qualification is recorded in §11. A production candidate cannot currently be constructed at the
published `0.3.0` version, so main-branch candidate qualification, attestation and
production-policy promotion validation are **not demonstrated**; the blocked run and its cause are
recorded in §12. Release publication remains **disabled**. This document is the canonical
description of how IPv6-only qualification is bound to a trusted release candidate.
**Scope:** the trusted release lifecycle (`release.yml`, `release/candidate-schema.json`,
`scripts/build-release-candidate.sh`, `scripts/validate-candidate.sh`,
`scripts/check-release-gates.sh`, `scripts/promote-release.sh`) and the qualification harness.
**Related:** [`trusted-release-lifecycle.md`](trusted-release-lifecycle.md),
[`ipv6-only-qualification-ci-integration.md`](ipv6-only-qualification-ci-integration.md),
[`ipv6-only-qualification.md`](ipv6-only-qualification.md),
[`ipv6-only-qualification-evidence.md`](ipv6-only-qualification-evidence.md),
[`engineering-backlog.md`](engineering-backlog.md).

## 1. Identity model

The candidate ID cannot be computed before qualification, because it covers the qualification
results. Qualification therefore binds to an **immutable build identity** established immediately
after build A, before any qualification runs.

```
trusted source + build inputs
        │
        ▼
immutable artifact construction (build A; build B compared, never shipped)
        │
        ▼
build identity = sha256(canonical JSON of
        {project, source, buildEnvironment, build{buildType,command,reproducibility}, artifacts})
        │            recorded as build.identity in qualification/build-record.json
        ▼
IPv6-only qualification against the exact integration .deb
        │
        ▼
qualification evidence + evidence hashes (summary.json and retained files)
        │
        ▼
candidate manifest: qualification.checks += four IPv6 checks; qualification.ipv6 block
        │
        ▼
candidate ID = sha256(canonical identity over the full manifest)
        │
        ▼
attestation (manifest, packages, metadata, SBOMs, build record) and publication eligibility
```

`build.identity` excludes the candidate object, the qualification object and the limitations, so it
is stable before qualification and unchanged by it. The candidate ID includes the build identity
and the qualification block, so it commits to both. There is no self-referential hash: the evidence
records the build identity, never the candidate ID.

The candidate schema version stays `https://edgeos-vxlan.dev/release-candidate/v1`; `build.identity`
and `qualification.ipv6` are required fields.

## 2. Pipeline

`release.yml` splits candidate construction into three jobs:

| Job | Permissions | Responsibility |
|---|---|---|
| `candidate-build` | `contents: read`, `actions: read` | Builds artifacts inside the qualified OCI environment, computes `build.identity`, writes `qualification/build-record.json`, uploads the `release-candidate-build` artifact. **No OIDC token, no attestation write.** |
| `ipv6-qualification` | `contents: read`, `actions: read` | Fetches that artifact by immutable ID/digest, verifies the build record and the integration package hash, runs N6-R-P against the packaged `.deb` with mandatory capture and reconciler execution, validates the summary, uploads `release-candidate-ipv6-evidence`. **Privileged namespace execution with read-only credentials; no publication credential, no OIDC token.** |
| `candidate` | `contents: read`, `actions: read`, `id-token: write`, `attestations: write`, `artifact-metadata: write` | Fetches build and evidence by ID/digest, attaches the four checks and the `qualification.ipv6` block, computes the candidate ID, runs full candidate validation, attests and uploads `release-candidate`. Executes no privileged namespace code. |

`build-release-candidate.sh --stage build` performs the build and identity step.
`build-release-candidate.sh --stage finalize` validates the evidence, copies it to
`qualification/ipv6-only/`, appends the checks, computes the candidate ID and runs the candidate
validator. Finalize requires `--ipv6-evidence-dir`; there is no mode that assembles a qualified
manifest without evidence.

## 3. Evidence binding

`qualification.ipv6` records:

| Field | Meaning |
|---|---|
| `status`, `level` | `passed`; level `B` (never `H`) |
| `buildIdentity` | The pre-qualification build identity |
| `sourceCommit` | Candidate source commit |
| `package`, `packageSha256` | Exact integration `.deb` and its hash |
| `reconcilerSha256`, `addrHelperSha256` | Packaged files actually exercised |
| `workflow` | `runId`, `runAttempt`, `repository`, `path`, `ref`, `commit` |
| `harness` | `path` (`test/ipv6-only-netns.sh`), `commit`, `version` |
| `evidence` | `dir` (`qualification/ipv6-only`), `summarySha256` |
| `capture` | `status=executed`, underlay/overlay/analysis hashes |
| `reconciler` | `status=executed`, evidence hash |
| `skips`, `workarounds` | The declared exceptions (see §5) |

The four required check IDs in `qualification.checks` are `ipv6-only-isolation`,
`ipv6-only-dataplane`, `ipv6-only-capture` and `ipv6-only-reconciler`. Each carries an
`evidenceSha256`; the IPv6 checks also record their retained `evidenceFile`.

Provenance is established twice:

1. **At finalize**, the workflow environment supplies the expected run ID/attempt/path/ref/commit
   independently of the evidence file, and the canonical validator
   (`scripts/validate-ipv6-qualification-evidence.py`) requires them to match. The evidence
   workflow path must also equal the candidate's trusted workflow path after normalization.
2. **At every candidate validation**, `validate-candidate.sh` recomputes the retained evidence
   hashes and cross-checks the manifest's provenance block against the retained `summary.json`
   (run ID, attempt, ref, commit, harness commit, build identity, package hash, source commit). A
   manifest that claims provenance its evidence does not carry is rejected.

Evidence is retrieved only by immutable artifact ID and digest from the same workflow run; there is
no latest-successful-run lookup. A rerun produces a new attempt and therefore new evidence with a
different run identity; the gate compares the attempt, so evidence from an earlier attempt is
rejected even when the package is unchanged.

**Trust limitation (explicit).** The qualification job both executes the candidate `.deb` as root
and writes/validates/uploads its own summary. A package that tampers with the runner could
therefore fabricate a "passed" summary. Finalize's independent binding prevents replay and
substitution across runs, candidates and artifacts, but it cannot prove a summary written by the
job that executed the package. The job holds no OIDC token, no secret and no publication
credential, and a source-level attacker already controls the workflow, so this does not widen the
release trust boundary; it is recorded here so the guarantee is not overstated.

## 3a. Attestation enforcement

Six properties are distinct and are enforced at different layers:

| Property | What it means | Where it is enforced |
|---|---|---|
| Manifest integrity | The manifest bytes were not altered after attestation | `verify-attestations.sh` verifies the manifest subject; `check_candidate_id` recomputes the candidate ID |
| Artifact integrity | Each distributed file matches the manifest and the attested subject | `validate-candidate.sh` hashes every artifact; `verify-attestations.sh` verifies each manifest artifact as a subject |
| Qualification evidence integrity | The retained evidence bytes match the manifest's hashes | `validate-candidate.sh` recomputes them and runs the canonical evidence validator on the retained summary |
| Workflow provenance | The attestation was produced by the trusted workflow, from the permitted source revision/ref | `verify-attestations.sh` binds `--repo`, `--signer-workflow` (policy workflow), `--signer-digest`, `--source-digest`, `--source-ref`, OIDC issuer and `--deny-self-hosted-runners`; the certificate repository identifier must equal the policy `repositoryId` |
| Attestation authenticity | The signature chain verifies against Sigstore | `gh attestation verify` (real run); fixtures pin the identity semantics, not the cryptography |
| Publication authorization | This candidate is permitted to publish now | `validate-candidate.sh --production/--release`, `check-release-gates.sh` (environment, variables, confirmation), `promote-release.sh` (tag/version/pins/draft) |

A cryptographically valid attestation is **not** by itself a publication authorization. A
development-branch candidate, an unrelated signer workflow, or an unauthorized source revision can
produce a valid attestation and still be rejected: `validate-candidate.sh --production` requires
`nonRelease=false`, `refs/heads/main`, and workflow commit equal to source commit; `release.yml`
only reaches the publish job from `workflow_dispatch` `mode=promote` on `refs/heads/main` behind
the `release-publication` environment. The transitive binding is enforced in both directions: the
attestation covers the manifest, the manifest covers every artifact and the evidence hashes, and
the candidate ID covers the entire manifest including `qualification.ipv6`.

## 3b. Rerun semantics

GitHub Actions full reruns and failed-job-only reruns are handled by binding evidence to the run
identity:

| Field | Behavior |
|---|---|
| Run ID | Evidence records `GITHUB_RUN_ID`; finalize requires it to equal the current run |
| Run attempt | Evidence records `GITHUB_RUN_ATTEMPT`; finalize requires it to equal the current attempt |
| Artifact ID/digest | Artifacts are fetched by immutable ID and digest from the current run; the API digest and downloaded bytes are verified |
| Artifacts from a previous attempt | A successful immutable build artifact may be reused by a failed-job-only rerun **only** because it is content-addressed (ID+digest) and its build record binds the source and workflow commit; it is never selected by name or by "latest" |
| Job outputs from a previous attempt | Used only as the immutable artifact ID/digest of the successful build job; outputs are never used as evidence |
| Evidence from a different attempt | **Rejected.** Finalize compares the recorded attempt with the current attempt; a failed-job-only rerun of finalization after a successful qualification therefore fails closed and requires "Re-run all jobs" |
| Finalization after a failed/interrupted qualification | Impossible: the finalize job `needs` the qualification job, and the implicit `success()` skips it when qualification fails |

The selected policy is: **cross-attempt evidence is always rejected; a complete workflow rerun is
required whenever evidence must be regenerated.** This is deliberate and matches "reject
cross-attempt evidence" rather than silently falling back to an earlier successful attempt. There is
no latest-run lookup anywhere in the path.

## 4. Gate semantics

- `validate-candidate.sh` rejects: missing `build.identity`; a build identity that does not
  recompute; missing or non-passed required checks; missing, modified or malformed evidence files;
  missing capture or reconciler execution; package/source/workflow/harness mismatch; an unpermitted
  skip or workaround; duplicate artifacts; a candidate ID mismatch; and any artifact whose size or
  hash differs from the manifest.
- `check-release-gates.sh --candidate-dir DIR` re-runs full candidate validation at publication
  authorization time. `promote-release.sh` always passes the candidate directory, so every
  promotion mode (qualification dry-run, preflight, publish) enforces the same contract. There is
  no alternative promotion command that skips it.
- Published-release verification (`verify-release.sh`) runs `validate-candidate.sh --release
  --published-assets`: the raw evidence directory is not a distributed asset, so file presence is
  not re-checked there, but the `qualification.ipv6` block is still fully validated and the
  manifest remains bound by the candidate ID and the provenance attestation.
- Existing controls are unchanged: fail-closed publication gates, protected `release-publication`
  environment, immutable-release confirmation, draft-first promotion, and draft verification of
  the downloaded asset bytes.

### 4a. Published-assets verification boundary

`validate-candidate.sh --published-assets` exists only for verifying **already published** release
assets, where the raw evidence directory is not a distributed asset (the release policy's
`requiredAssets` does not include `qualification/`). Its only caller is `verify-release.sh`, which
is used for published/draft release verification.

- It cannot be reached from promotion: `promote-release.sh` never passes it, and the candidate
  validation it performs (qualification dry-run, preflight, publication) always uses the strict
  mode.
- It cannot turn an unqualified candidate into a publishable one: it still requires the manifest's
  `qualification.ipv6` block, the four required check IDs, the build identity, package/source
  binding, provenance consistency and the skip/workaround allow-list. It skips only the *presence
  and hashing* of the raw evidence files.
- It is guarded: it is rejected unless `--release` is also set, and rejected when the raw evidence
  directory is present, so it cannot be used to silence evidence verification while the evidence
  exists.
- Historical releases remain functional and immutable: `verify-release.sh` classifies releases
  below `canonicalFrom` as legacy and verifies them with `validate-published-release.sh`; no
  historical asset, checksum or tag is touched.

## 5. Permitted exceptions

| Exception | Kind | Semantics |
|---|---|---|
| `host-global-ipv6-escape-unavailable` | skip | The runner has no global IPv6 address for the IPv4-escape negative control. The other escape and isolation controls still run. Never reported as a pass. |
| `iproute2-json-normalization` | skip **and** workaround | A modern iproute2/kernel combination emits a non-JSON diagnostic inside `ip -j -d` output. The harness normalizes only that known artifact and records the skip. This is a test-environment compatibility layer, not product behavior; ENG-IPV6-10 remains open. |

Both are allow-listed explicitly in the validator, the finalize stage and the candidate validator.
Neither can substitute for capture, isolation, dataplane or reconciler execution. Any other skip or
workaround is rejected.

## 6. Operational verification

```bash
# After a push/dispatch run, with the candidate artifact downloaded to ./candidate
./scripts/validate-candidate.sh --candidate-dir candidate --source-root . --rev <source-sha>
./scripts/promote-release.sh --candidate-dir candidate --qualification --dry-run \
  --candidate-id "$(jq -r .candidate.id candidate/release-candidate.json)" \
  --manifest-sha256 "$(sha256sum candidate/release-candidate.json | awk '{print $1}')"

# Standalone evidence re-validation
python3 scripts/validate-ipv6-qualification-evidence.py \
  --summary candidate/qualification/ipv6-only/summary.json \
  --evidence-dir candidate/qualification/ipv6-only \
  --expected-build-identity <identity> --expected-source-commit <sha> \
  --expected-package-sha256 <integration-deb-sha> \
  --require-workflow-binding --require-package-execution \
  --allow-skip host-global-ipv6-escape-unavailable \
  --allow-skip iproute2-json-normalization \
  --allow-workaround iproute2-json-normalization
```

## 7. Failure and recovery behavior

- A failed build job prevents qualification; a failed qualification job prevents finalize, so no
  qualified candidate artifact exists. There is nothing to promote.
- Failed evidence validation, an identity mismatch, a missing check, or a modified evidence file
  rejects the candidate at the next validation point. Recovery is a new candidate from a new run;
  the evidence is not edited in place.
- Reruns create a new attempt with new evidence. The gate compares the run attempt, so a rerun that
  fails cannot inherit the previous attempt's evidence. A failed-job-only rerun of finalization
  after a successful qualification is rejected by design; use "Re-run all jobs" to regenerate
  evidence in the new attempt. See §3b.
- Publication remains disabled until the maintainer enables `RELEASE_PUBLICATION_ENABLED` and
  confirms immutable releases. Nothing in this integration enables it.

## 8. Repository governance recommendations (not applied)

`main` currently has **no branch protection and no required status checks**. The trusted release
lifecycle therefore rests on branch/review discipline and on the gates above, not on repository
enforcement. If a ruleset is adopted later, these are the checks worth requiring (as written
here, not yet enforced):

| Context | Recommended required checks |
|---|---|
| `pull_request` → `main` | `Static analysis`, `Build and validate packages`, `Reproducibility verification` |
| `push` → `main` | the three above as required; `Network-namespace dataplane` and `IPv6-only qualification` are required for release eligibility but are skipped on `pull_request` by design, so they cannot be enabled as PR-required checks without false blocking |
| Release tags | publication is gated by the `release-publication` environment and `check-release-gates.sh`, not by a status check |

Do not treat these as enforced. A ruleset change requires maintainer approval and is out of scope
for this work.

## 9. Remaining limitations

1. **Hardware:** x86 Linux namespace evidence (N6/N6-R/N6-R-P) does not qualify the candidate MIPS
   kernel module, bridged EdgeOS dataplane or physical ER-X hardware (ENG-IPV6-04/05).
2. **Levels C and D:** IPv6-only installation, management, runner and control plane remain
   unachieved (ENG-IPV6-01/02).
3. **Hosted qualification:** the hosted non-publication run of the combined path on the development
   branch is recorded in §11. The merged `main` revision has post-merge CI and image-qualification
   evidence, but a production candidate cannot be constructed at the published `0.3.0` version; the
   blocked main-branch run and its cause are recorded in §12.
4. **`iproute2-json-normalization`:** still a test-only compatibility layer (ENG-IPV6-10).
5. **Release publication:** disabled. This integration does not authorize a release.
6. **Repository protections:** not configured (§8).

## 10. Local qualification record (2026-11-28)

**Classification: local contract test, not authenticated hosted provenance.** The N6-R-P workload
ran in a privileged local container against the exact package built by the local build stage. The
workflow identity fields in the evidence (`workflow.runId = 1`, `runAttempt = 1`) were supplied
synthetically as environment variables so the binding logic could be exercised; **they do not
correspond to any GitHub Actions execution**. The finalize stage, candidate validator, promotion
planner and gates were exercised against that clearly synthetic identity. This demonstrates the
contract, not hosted provenance; hosted qualification must establish the real workflow identity
independently (see the hosted run recorded in the pull request).

| Item | Value |
|---|---|
| Branch HEAD (qualification source) | `3554a36` (`ci/ipv6-release-qualification`; later commits are CI/test/documentation only) |
| Base commit | `f1cec15` (`origin/main`) |
| Environment image | `edgeos-vxlan-reproducible@sha256:82993432c25c191cbd812d8672bc5f4fd13f04a035793323e52c4b50b8ba1b79` |
| Build identity | `3fd1d8ebab63bc521d85e6dba266943a0483b33d3ca42721cba2f35cf9b09461` |
| Integration package | `edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb`, `6afa3f25e8145a6ebf31a947ab104b223b351aa615b51aa2a97389364a133e2a` |
| Kernel module | `7ffe10f611932f6543b96b3ce5683b93b6c678a51ac1b63bcdb3d630e58c7827` (identical at base and branch) |
| N6-R-P result | 113 pass, 0 fail, 1 skip (`host-global-ipv6-escape-unavailable`); `capture=executed`, `reconciler=executed` |
| Candidate ID | `sha256:fa7fe2e41612f598b45dd377850c5034aa9078e04b4d09085f0cf2b10aaed1c3` |
| Manifest SHA-256 | `c6f43758f612233668656ab448d836480ce95accac576a651c4ced7c6ad8a0e9` |
| Candidate validation | PASS |
| Promotion qualification dry-run | PASS |

Base and branch canonical builds produced byte-identical packages, so the change introduces no
payload difference. A separate run whose evidence carried no workflow binding was rejected by the
finalize stage (`workflow.runId is missing`), confirming fail-closed behavior. Evidence with a
different run ID or attempt is likewise rejected by finalize (§3b).

## 11. Hosted non-publication qualification record (2026-11-28)

Authorized development-branch qualification. The branch is listed in the `release.yml` push
trigger; push events always resolve `non_release=true`, the publication jobs are skipped, and
publication still requires a `workflow_dispatch` `promote` from `refs/heads/main` behind the
`release-publication` environment. This run is **not** a production publication authorization.

Workflow run
[46096392548](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548) —
`Trusted release`, event `push`, branch `ci/ipv6-release-qualification`, head
`97f9c76cf3229b51abe253453384bc3c145bddc9`, attempt 1, conclusion **success**.

| Job | Result | URL |
|---|---|---|
| Resolve immutable identities | success | [job](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548/job/140828586348) |
| Qualify build image | success | [job](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548/job/140828615064) |
| Build candidate | success | [job](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548/job/140829288967) |
| IPv6-only candidate qualification | success | [job](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548/job/140829441400) |
| Finalize qualified candidate (attest + verify) | success | [job](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548/job/140829581411) |
| Qualification dry-run (promotion planning) | success | [job](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392548/job/140829691570) |
| Authorized publication / preflight / post-publish | **skipped** (push event) | — |

Artifact and evidence identity (download independently validated):

| Item | Value |
|---|---|
| Build identity | `a1e3205e741a9ccb3d4a21ca73a5563fa9ea7eba1c9830f8a970267f3f5bee73` |
| Candidate ID | `sha256:73c4bd8b72011dfa247549a8a6591038dcda679bbf10e12c62dc21abb93cd817` |
| Manifest SHA-256 | `d25a07f392c3d6f39e15323ac9de9413ef09bc2b2b6f58edeaf17690de117621` |
| Integration package | `edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb`, `6afa3f25e8145a6ebf31a947ab104b223b351aa615b51aa2a97389364a133e2a` (identical before and after qualification, and identical to the canonical local build) |
| Kernel module | `edgeos-vxlan-kmod_0.3.0+edgeos3.0.1.e50_mipsel.deb`, `7ffe10f611932f6543b96b3ce5683b93b6c678a51ac1b63bcdb3d630e58c7827` |
| Evidence | 113 pass, 0 fail, 2 skip; `capture=executed`, `reconciler=executed`, `packageExecuted=true` |
| Evidence hashes | `summary.json` `b9d83bf7d33f6224ad3260a8225b08874be712d5393ade45f939fe081b5c3ef1`; `summary.txt` `6c1db02fbb452474f7547f5adb2f004f48c98c68540afe3a69ac69dae2ab2ab0`; `captures/analysis.txt` `4566ecfb86aaef625b23be90c9f498baa17e90b955ff65790117d9b1ef48af56`; `reconciler-evidence.txt` `6813645cea6f0762bd99e611e616721c032350a6aa92bb4eef92cca25cd0bed5` |
| Capture hashes | underlay `2dd52f9bd23db4cb17d3202e24fee404879261d8e006e6d1a5c5f7b85ba296af`, overlay `0eadf705786d67d80bdffe285523fc98d282840df4fb79c5f5510ba678e4da9c` |

Independent validation:

- `validate-candidate.sh --candidate-dir <downloaded release-candidate> --source-root . --rev
  97f9c76…` → **PASS** (candidate ID `sha256:73c4bd8b…`).
- `validate-ipv6-qualification-evidence.py` with expected source commit, build identity, package
  SHA-256, run `46096392548` attempt 1, workflow path
  `downwithbgp/edgeos-vxlan/.github/workflows/release.yml@refs/heads/ci/ipv6-release-qualification`,
  ref and commit, and harness commit → **PASS**.
- `verify-attestations.sh` with the pinned `gh` 2.106.0 and the Sigstore trusted root → **PASS**
  (repository, signer workflow `.github/workflows/release.yml`, signer digest = source commit
  `97f9c76…`, source ref `refs/heads/ci/ipv6-release-qualification`, certificate repository ID).
  The same bundle with `--source-ref refs/heads/main` is **rejected** (exit 1), which is the
  intended non-promotable behavior.

The ordinary CI run on the same push
[46096392518](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46096392518) also passed all
six jobs, including the `ci.yml` `ipv6-only` same-run package qualification. That CI run is not a
substitute for this combined release-qualification demonstration.

This record was committed after the qualifying run; the record commit changes documentation only
and does not alter the workflow, scripts, tests or package payload that were qualified.

## 12. Main-branch integration record (2026-11-28): candidate construction blocked

PR #10 was merged into `main` as merge commit `fffdedd45ccf73d45f19692ea2057e63fed69334`
(parents `f1cec1580501bcb53b8aa370b49e8e72ea6b77ef` and
`66715cf226bb6a0427fe6186e7da482e3642ffd8`). The approved head was
`dc9a993f926d6832508f7daa3e0da2285213e925`; `66715cf` removed the temporary
qualification-branch push trigger before the merge and changed no product payload.

Post-merge evidence on `fffdedd`:

| Run | Purpose | Result |
|---|---|---|
| [46102648705](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46102648705) | Canonical `ci.yml` push run | success — Static analysis, Build and validate packages, Reproducibility verification, Published-release fixtures, Network-namespace dataplane, IPv6-only qualification |
| [46102947016](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46102947016) | `build-environment.yml`, `publish_image=false` | success — Build and qualify image, Independent image qualification; Publish image to GHCR (gated) skipped |

Qualified build environment, from artifact `15245653394`
(`sha256:d14ce32e6017bc4fdedef1114299565013cf0554b2aeba0c9b6f5a952581b34a`):

| Item | Value |
|---|---|
| Image manifest digest | `sha256:19d599d997f5b19481215a0352b3c2099b806ca230322a0e1c2dac702bb05338` |
| Image config digest | `sha256:918567448616065c6538bbe70080754a686560a4ac5834b32e7fe5db94259a0f` |
| OCI index digest | `sha256:de163615a4c0d5068788ef241732b59c03ff506d93e293344b2b3b30fb86b8c1` |
| Qualification file SHA-256 | `c7fa53476e923a83ac59ae6c1961cfb85e66a009aba660bba159a1bc592da9e1` |

Candidate construction was dispatched against `main` at `fffdedd` as run
[46103291407](https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46103291407)
(`workflow_dispatch`, `mode=candidate`, attempt 1). `Resolve immutable identities` and
`Qualify build image` succeeded. `Build candidate` failed in "Build candidate artifacts and
establish the build identity":

```
ERROR: production version 0.3.0 is not newer than published 0.3.0
```

`workflow_dispatch` `mode=candidate` always sets `PRODUCTION=true`, and
`build-release-candidate.sh` requires the production version to be strictly newer than
`release.baselinePublishedVersion` (`0.3.0` in `release/release-policy.json`). The package version
is `0.3.0` and `v0.3.0` is published, so the gate behaves as designed. A version increment is
outside this assignment. The only non-release candidate path is a `push` event on a branch listed in
`release.yml`, which `main` is not; the temporary development-branch trigger was deliberately
removed in `66715cf`. The downstream jobs (`IPv6-only candidate qualification`,
`Finalize qualified candidate`, `Qualification dry-run`) were therefore skipped.

Consequences, stated explicitly:

- No qualified main-branch release candidate exists. Candidate identity, main-branch attestations,
  main-branch IPv6 candidate qualification and production-policy promotion validation could not be
  exercised and are **not** claimed.
- The post-merge CI and image-qualification runs above are real main-branch evidence, but they are
  not release-candidate qualification and are not a substitute for it.
- `ENG-IPV6-11` remains open and remains a precondition for enabling production publication.
- Publication controls are unchanged: no repository variables are configured
  (`RELEASE_PUBLICATION_ENABLED` unset), the repository API reports no configured environments, no
  release, draft or tag was created, `v0.3.0` remains the latest published release, and no tag
  contains `fffdedd`.

**Revision distinction.** The evidence above belongs to `fffdedd`. An evidence-record commit that
records this boundary advances `main` afterwards and is documentation-only; it does not qualify the
later revision, and the blocker applies equally to it.
