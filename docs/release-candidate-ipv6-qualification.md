# Release-candidate IPv6 qualification

**Status:** implemented on `ci/ipv6-release-qualification`; PR pending maintainer review. Release
publication remains **disabled**. This document is the canonical description of how IPv6-only
qualification is bound to a trusted release candidate.
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
  fails cannot inherit the previous attempt's evidence.
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
3. **Hosted run pending:** the hosted non-publication qualification of this combined path has not
   been executed for this branch because publishing the branch requires separate authorization.
   Local qualification is complete and recorded in §10; it is not hosted evidence.
4. **`iproute2-json-normalization`:** still a test-only compatibility layer (ENG-IPV6-10).
5. **Release publication:** disabled. This integration does not authorize a release.
6. **Repository protections:** not configured (§8).

## 10. Local qualification record (2026-11-27)

Local, non-release evidence; not hosted CI and not hardware.

| Item | Value |
|---|---|
| Branch HEAD | `68b2212` (`ci/ipv6-release-qualification`) |
| Base commit | `f1cec15` (`origin/main`) |
| Environment image | `edgeos-vxlan-reproducible@sha256:82993432c25c191cbd812d8672bc5f4fd13f04a035793323e52c4b50b8ba1b79` |
| Build identity | `07b769dc3deea5d3594a60ffe18862cd4c4bd9e2a78739879949837df1b77997` |
| Integration package | `edgeos-vxlan_0.3.0+edgeos3.0.1.e50_all.deb`, `6afa3f25e8145a6ebf31a947ab104b223b351aa615b51aa2a97389364a133e2a` |
| Kernel module | `7ffe10f611932f6543b96b3ce5683b93b6c678a51ac1b63bcdb3d630e58c7827` (identical at base and branch) |
| N6-R-P result | 113 pass, 0 fail, 1 skip (`host-global-ipv6-escape-unavailable`); `capture=executed`, `reconciler=executed` |
| Candidate ID | `sha256:8ced729262850fed5e41a911a2ab1d8e43a5369c80f2c1d6922a45eda89722ea` |
| Manifest SHA-256 | `dafa2bba923d5ceabbd937cd4c2dbe65ca7d3814513249687fcc47b86da9d098` |
| Candidate validation | PASS |
| Promotion qualification dry-run | PASS |

Base and branch canonical builds produced byte-identical packages, so the change introduces no
payload difference. A separate run whose evidence carried no workflow binding was rejected by the
finalize stage (`workflow.runId is missing`), confirming fail-closed behavior.
