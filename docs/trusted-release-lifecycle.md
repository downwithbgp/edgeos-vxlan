# Trusted release lifecycle

Status: Phase III implementation on `ci/trusted-release-lifecycle`, draft PR
#8, unmerged. Final branch head covered by this report:
`d6a5d4f5b776fb8131d77d5d9d19a22bf15788b2`.

No production release, container-image publication, immutable-release
activation, signing key, tag move, historical asset change or repository
setting change was performed. The trusted release infrastructure works and
fails safely in non-production; it has no operational authority until the
decisions in section 11 are made.

## 1. Architecture and trust model

The central invariant is: **the artifacts distributed to users are the exact
artifacts qualified and approved; publication never substitutes a new build.**

```
source commit A -- git archive in-job --> source.tar (SHA-256)
       |                                     |
       | packaging-inputs digest             v
       +-----------------------> qualified OCI image (manifest/config digests)
                                             |
                                             v
                                  one distribution build
                                  + comparison build (never shipped)
                                             |
                        packages + .buildinfo/.changes + SPDX SBOMs
                                             |
                                  release-candidate.json (candidate ID)
                                             |
                              GitHub Actions provenance + SBOM attestations
                                             |
                              explicit artifact ID/digest + candidate ID
                                             |
                              dry-run plan --or-- draft -> verify -> publish
                                             |
                              explicit verify-release invocation
```

Trust boundaries:

| Boundary | Trusted side | Threats | Mitigations |
|---|---|---|---|
| Source → build | Exact commit on `main`, trusted workflow commit | Dirty tree, untracked files, PR code | Clean check, in-job `git archive`, archive hash, packaging-inputs digest |
| Workflow → execution | Default-branch workflow, protected environment | PR workflow edits, branch dispatch | Read-only PR jobs, pinned actions, `main`-only dispatch, environment approval |
| Build environment | OCI manifest/config + inventory | Floating tags, snapshot/registry outage | Retained OCI archive, distinct digests, independent verification, no tag fallback |
| Candidate | One exact build set | Rebuild substitution | Build once; comparison build only; manifest and attestation bind hashes |
| Selection | Artifact ID + ZIP digest + candidate ID | Mutable names/latest run | Explicit inputs, API expiry/digest checks, candidate ID recomputation |
| Qualification | Evidence bound to candidate ID | Forged/stale evidence | Recompute hashes, fail closed, attestation over manifest/assets |
| Publication | Draft-verified asset set | Partial draft, concurrent run | Draft-first, no-clobber upload, draft verification, concurrency group, idempotent rerun |
| Verification | Downloaded release assets | Local rebuild confusion | Verify downloaded bytes, not local output |

Explicit non-claims:

- Attestations do not prove correctness, vulnerability absence or hardware
  compatibility.
- Kernel module source-to-binary reproducibility is not established; modules
  remain prebuilt inputs.
- No SLSA build level is claimed.

## 2. Candidate manifest and identity

Schema: `release/candidate-schema.json` (JSON Schema 2020-12), format
`https://edgeos-vxlan.dev/release-candidate/v1`.

The manifest binds project/repository identity, release tag, Debian package
version, source commit, source archive SHA-256, packaging-inputs SHA-256,
release-policy SHA-256, trusted workflow repository/path/ref/commit, OCI
index/manifest/config digests, OCI archive checksum, Dockerfile/CA/snapshot
hashes, dependency inventory hash, artifact names/sizes/SHA-256, SBOMs,
qualification checks and explicit limitations.

Candidate ID:

```
identity = {schemaVersion, candidate:{status,nonRelease}, project, source,
            buildEnvironment, build, artifacts(sorted), qualification,
            limitations}
candidate.id = "sha256:" + sha256(canonical JSON of identity)
```

The `candidate` object's `id` and `createdAt` are excluded from the identity.
Construction order is: build once → validate artifacts/metadata/SBOM →
comparison build → qualification record → candidate ID → manifest →
package-only `SHA256SUMS` → attestations → post-construction validator.
The validator result is not written back into the manifest.

The manifest does **not** contain the tag commit B. B is created after the
build, so embedding it would create a hash fixed point. Promotion/verification
resolves the tag, requires A to be an ancestor of B, and requires
`packagingInputsSha256(A) == packagingInputsSha256(B)`.

## 3. Artifact pinning and versioning contract

Investigation:

- `install.sh` and repository `SHA256SUMS` are not packaged in either `.deb`.
- `debian/changelog` **is** packaged and defines the package version.
- Therefore updating installer pins does not change package bytes; changing
  the changelog is package-affecting.

Policy:

1. A published package version identifies an immutable artifact.
2. Historical release hashes remain authoritative.
3. CI artifacts are non-release artifacts.
4. Byte-affecting changes require a new package version.
5. CI-only changes do not inherently require a version bump.
6. Historical assets are never silently replaced.
7. Future releases use canonical qualified artifacts.

Release preparation:

1. Commit A contains the release code and changelog version.
2. Build/qualify the candidate once from A.
3. Commit B updates `install.sh`/`SHA256SUMS` from the candidate with
   `scripts/update-release-pins.sh`.
4. `scripts/check-pin-commit.sh A B` requires every changed path to be in the
   pin-only allowlist and the packaging-inputs digest to be equal.
5. Tag `vX.Y.Z` at B. The candidate records A and the tag name; verification
   checks ancestry, digest equality and `update-release-pins.sh --check` on B.
6. Publish the exact candidate assets to the draft; verify; publish.

The packaging-inputs digest covers all tracked files except installer pins,
docs, workflows, specs and tests. It includes `.gitattributes`, `release/**`,
`scripts/**`, `containers/**`, `debian/**`, `src/**`, `templates/**` and
`modules/**`.

## 4. Controlled build environment lifecycle

The Dockerfile remains digest-pinned with a fixed Ubuntu snapshot and a
committed CA bundle. `scripts/build-environment.sh` builds an OCI archive,
loads it, and records distinct identities:

- OCI index digest;
- platform image manifest digest (execution identity);
- config digest (metadata only, not a runnable pull reference);
- OCI archive SHA-256;
- dependency inventory SHA-256;
- Dockerfile, CA bundle and snapshot hashes.

`scripts/verify-build-environment.sh` independently re-reads the archive,
recomputes all digests, loads the image by manifest digest with
`--pull=never`, recomputes the inventory, and checks a smoke build toolchain.
The candidate job re-runs this verification; a qualification JSON alone is
never trusted. Syft creates the image SBOM and Grype creates the vulnerability
report; critical findings require an unexpired reviewed exception.

GHCR publication is implemented in `build-environment.yml` behind the
`build-image-publication` environment and the
`BUILD_IMAGE_PUBLICATION_ENABLED` variable. It uses `crane push` and checks
the remote manifest contains the qualified digest. It was not run.

Recovery: use the retained OCI archive/qualification first; if unavailable,
rebuild from the Dockerfile and re-qualify as a new candidate. Never use a
floating tag.

## 5. Provenance, SBOM and Debian metadata

- `actions/attest@v4.2.2` pinned to
  `1e69f48acb82d1966a394da916b4c1698aa569d6`.
- Candidate job permissions: `contents: read`, `id-token: write`,
  `attestations: write`.
- Provenance covers the manifest, packages, `.buildinfo`, `.changes`, SBOMs,
  environment qualification and image SBOM. Two SBOM attestations cover the
  integration and kernel packages.
- Bundles are concatenated into `release-attestation.jsonl`; verification uses
  offline `--bundle`, repository/workflow/signer/source digests and refs,
  OIDC issuer, repository ID and self-hosted-runner denial.

The release SBOM is deterministic SPDX 2.3 generated from the actual package
payload, control/dependency metadata, licensing, kernel source/patch
provenance and explicit limitations. It does not claim a `GENERATED_FROM`
relationship for prebuilt kernel modules. The image SBOM is separate.

`validate-build-metadata.py` checks `.buildinfo`/`.changes` source, version,
architecture, package set, sizes, SHA-256 checksums, direct build-dependency
coverage and `SOURCE_DATE_EPOCH`. Independent builds are compared on package
bytes only.

## 6. Workflow responsibilities and permissions

| Workflow | Trigger | Permissions | Responsibility |
|---|---|---|---|
| `ci.yml` | PR, push main/`ci/**`, tags | `contents: read` | Lint, tests, package build, metadata validation, reproducibility, historical fixtures, dataplane |
| `build-environment.yml` | dispatch from `main`, branch push | build/qualify read-only; gated publish (`refs/heads/main` only) adds `packages: write`, `id-token: write`, `attestations: write`, plus the protected `build-image-publication` environment | Image qualification, SBOM, vulnerability review, gated GHCR |
| `release.yml` | dispatch from `main`, qualification branch push | resolve/qualify/preflight read-only (`actions: read`, `attestations: read`); candidate adds `id-token: write`, `attestations: write`, `artifact-metadata: write`; publication adds `contents: write` + the protected `release-publication` environment | Candidate build/attestation, dry-run, authorized draft publication |
| `verify-release.yml` | reusable, dispatch, `release: published` | `contents: read`, `attestations: read` | Independent downloaded-release verification |
| `security-audit.yml` | schedule, dispatch | `contents: read` | Online zizmor and actionlint |

Post-publication verification runs as its own `post-publish-verify` job with
`contents: read` and `attestations: read`, after a successful `publish`. It
therefore cannot reach a write token, and a publication failure and a
verification failure are reported independently. Both this job and the
standalone `verify-release.yml` install the pinned `gh`/`syft` release-tools
set; the remaining tools (`git`, `jq`, `dpkg`/`dpkg-deb`, `readelf`,
`modinfo`, `python3`, `tar`, `gzip`, coreutils) are deliberately
platform-provided and are listed explicitly in `verify-release.yml` so that
trust assumption is stated rather than implied.

PR jobs are read-only. The new-workflow dispatch limitation is documented:
before this branch is merged, the branch-push qualification trigger is the
entry point; manual dispatch becomes available once the workflow exists on
`main`.

## 7. Publication authorization and recovery

Real publication requires:

1. `workflow_dispatch` from `refs/heads/main`;
2. the `release-publication` environment with required reviewers
   (maintainer-configured; not activated here);
3. `RELEASE_PUBLICATION_ENABLED=true`;
4. immutable-release proof (`IMMUTABLE_RELEASES_ADMIN_TOKEN` query of
   `GET /repos/.../immutable-releases` or `IMMUTABLE_RELEASES_CONFIRMED=true`
   followed by the post-publish `immutable` check);
5. exact candidate artifact ID and ZIP digest, candidate ID and manifest
   SHA-256;
6. tag == `v<packageVersion>`, A ancestor of B, equal packaging-inputs digest,
   matching tag pins;
7. `confirm_publish=PUBLISH`.

Sequence: verify candidate/attestations → create/resume draft → upload only
missing assets, compare existing assets and never clobber → download the
draft by release/asset ID → verify in draft mode → publish → check immutable →
explicitly invoke `verify-release.yml` (GITHUB_TOKEN-created releases do not
generate a release event).

Recovery: rerun before draft; resume partial drafts; idempotent verification
after publication; conflicting assets/drafts fail closed. An expired candidate
abandons the release; a new version is required because the production source
commit may no longer be the `main` tip.

## 8. Independent release verification

`verify-release.sh` classifies using Debian version ordering:

- **Legacy** (< 0.3.1, no manifest): existing pinned installer/`SHA256SUMS`
  verification. v0.1.0 has no GitHub release; v0.1.1 has no committed
  `SHA256SUMS`; v0.2.x and v0.3.0 have committed manifests and pins.
- **Canonical** (manifest present or >= 0.3.1): manifest, SBOM, metadata,
  complete asset set, attestation; missing evidence fails closed.
- **Immutable** (from 0.3.1 after activation): canonical plus release API
  `immutable: true`.
- `--draft` skips published/immutable checks; `--fixture` is local-only and
  refuses a tag that exists on GitHub.

Verification always downloads release assets; local build output is not
trusted. Negative cases include missing/extra/modified assets, manifest/source
mismatch, wrong image/workflow identity, missing evidence and historical
version reuse.

## 9. Verification evidence

Final branch head for every result below:
`d6a5d4f5b776fb8131d77d5d9d19a22bf15788b2`.

### 9.1 Off-device suites

| Suite | Result | Covers |
|---|---|---|
| `bash test/run.sh` | 360/360 pass | build 11, helper 64, firewall 122, templates 93, mock 70 |
| `test/unit-release-primitives.sh` | 46/46 | packaging-input digest, A→B pin-only contract across every protected input category, pin rendering, candidate identity |
| `test/unit-artifact-archive.sh` | 15/15 | safe extraction (traversal, duplicates, symlinks, special files, size bomb, empty), verified fetch, expired/failed-run/wrong-name/wrong-path/API-digest rejection, bare-hex digest acceptance and malformed-digest rejection |
| `test/unit-candidate-schema.sh` | 7/7 | malformed JSON, duplicate object keys, invalid types, schema version, unexpected properties, digest formats |
| `test/unit-image-qualification.sh` | 8/8 | OCI index/manifest/config selection, tampered and missing blobs, ambiguity, traversal |
| `test/unit-release-contracts.sh` | 39/39 | schema/semantic separation, candidate-ID substitution, artifact substitution, modified SBOM and predicate, wrong subject name and wrong subject bytes, malformed bundle and malformed SBOM, missing evidence, failed qualification check, duplicate artifacts, wrong workflow ref, historical reuse, canonical-to-legacy downgrade, the full publication-gate matrix, attestation identity semantics, concurrent candidates |
| `test/unit-release-publication.sh` | 9/9 | publication path against an isolated mocked API: expired artifact, digest mismatch, conflicting draft asset, unexpected draft assets, resume without mutation, interrupted draft completion, tampered tag-side `install.sh` |

`shellcheck -x -e SC1091,SC2015` over the canonical file set and
`perl -c src/vyatta-vxlan-addr` are clean. All seven suites are wired into the
CI "Release contract tests" step.

### 9.2 Environment evidence (real GitHub Actions, no mocks)

Run
<https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46043324448>
at head `4ea9a0c`, all six jobs successful:

| Identity | Value |
|---|---|
| Candidate ID | `sha256:ee10e5d3b50e831feb3d9e8940ed20d33b28108cebc5e2bf1818f965ae80ff01` |
| Manifest SHA-256 | `956e780175496b49f021427a298b44682b0f74f1722c3d0a931313ed387008a3` |
| Package version | `0.3.0+edgeos3.0.1.e50` |
| Candidate artifact | ID `15221433192`, digest `sha256:e104e48ebb37aa2203514c3be44569aeb786ddcc5fc0d01c5236ddf1ccc281e8`, 8 616 870 bytes, `expired=false` |
| Image manifest / config | `sha256:81ba37e8…b7f0b` / `sha256:8f606027…def13` |
| OCI archive SHA-256 | `61e15c1dc1a432ffa25371d03b639c97a613c405d73d681c07e2b3db02673634` |
| Attestation bundle SHA-256 | `a0b6960bda9eb58f8e7bdbdc243b6afa1d8a006192fbcb426b2e5f01094ce69d` |

Real Sigstore attestations were created by `actions/attest` (GitHub-native,
Public Good instance): provenance over nine subjects, an SBOM attestation for
the integration package (`…all.deb@sha256:6afa3f25…`), and one for the kernel
package (`…mipsel.deb@sha256:7ffe10f6…`). Offline verification used
`gh attestation trusted-root` plus the bundle, binding repository ID
`1357738281`, signer workflow `.github/workflows/release.yml` at the resolved
workflow commit, source digest and ref, OIDC issuer, subject digests, with
self-hosted runners denied; a paired negative control against
`refs/heads/definitely-wrong` was required to fail and did. The qualification
dry-run then re-fetched the artifact with full identity checks, re-verified the
bundle and wrote `promotion-plan.json` — no tag, draft, asset or registry
mutation.

The stored predicate type was confirmed against GitHub's own attestation store:
`https://spdx.dev/Document/v2.3` for the SPDX-2.3 document, which is why the
policy pins the versioned URI. The SBOM predicate is additionally proven equal
to the shipped SBOM by `verify-sbom-predicate.sh`.

The same head's CI run
<https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46043324477> passed
all jobs including "Published-release fixtures" against the real published
v0.3.0 asset set.

After the security fixes, head `d6a5d4f` re-ran cleanly: trusted release
<https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46050666946> and CI
<https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46050667701>, all
jobs successful.

### 9.3 What remains unexercised

Successful publication end to end has not been executed. It needs real Debian
packages for SBOM re-validation and real Sigstore signatures, so the mocked
publication suite stops at draft verification. No production tag, release,
asset or registry publication was performed, and no production hardware was
touched.

## 10. Remaining risks and limitations

Activation prerequisites (maintainer action, not code):

- GitHub Actions environment protection cannot be proven from `GITHUB_TOKEN`.
  `release-publication` must exist with required reviewers and deployments
  restricted to `main`/`v*` before publication is enabled.
- The immutable-release "proof" is a maintainer-confirmed variable. The actual
  `immutable` state is verified only after `draft=false`, so a post-publication
  failure leaves a published, mutable release that only a new version can
  supersede. Verify the setting before enabling, and treat the flag as
  activation-blocking.
- `RELEASE_PUBLICATION_ENABLED` and `IMMUTABLE_RELEASES_CONFIRMED` must be set
  from the protected environment, not repository-wide.

Recorded code-level limitations:

- GHCR staging is implemented in `scripts/publish-image-staged.sh` but not
  activated: the publish job still requires a `refs/heads/main` dispatch, the
  protected `build-image-publication` environment and
  `BUILD_IMAGE_PUBLICATION_ENABLED=true`, and no image has been pushed. The
  script pushes the archive under a candidate-specific staging tag
  (`staging-<run_id>-<run_attempt>`), verifies the remotely stored digest
  against the qualified manifest (accepting an index only when it contains
  that manifest), refuses to replace an existing target tag that resolves
  elsewhere, promotes exactly the verified digest, re-reads the target digest,
  and deletes the staging tag. A failure between push and promote leaves only
  the staging marker, which the next run overwrites or deletes; a conflicting
  target tag is never replaced, so recovery is a deliberate maintainer action.
  `test/unit-release-image-publish.sh` exercises all of this against a
  recording fake `crane`; the real registry has not been contacted.
- `verify-release.yml` uses the runner's preinstalled `gh`/`jq`/`dpkg`
  toolchain rather than the pinned release tools; the release workflow pins
  them. A mutated runner toolchain would weaken independent verification.
- The post-publication verifier runs inside the `contents: write` publish job.
  Splitting it into a read-only job is the safer shape.
- Decorative policy controls were removed rather than retained: the
  `signedTagsVariable` key, the `pinCommit.allowlist` and the
  `packagingInputs.exclude` copy. None was read by any script, so each implied
  a guarantee that did not exist. Signed production tags are deferred to a
  separate operational workstream; the enforced packaging-input and pin-only
  contracts live in `scripts/packaging-inputs.sh` and
  `scripts/check-pin-commit.sh`, and `test/unit-release-policy.sh` fails if an
  unimplemented policy key is reintroduced.
- Publication eligibility now resolves the newest published stable release
  (`scripts/check-version-eligibility.sh`) and rejects regression below it;
  `baselinePublishedVersion` is retained only as the legacy classification
  floor and as a coarse construction-time check. Drafts, prereleases and
  tags without a release do not raise the published version. No backport
  bypass exists; a future maintenance-branch exception requires a separate
  reviewed change.
- Published-release fixtures use synthetic assets; hardware qualification,
  kernel source-to-binary reproducibility and Internet-facing probes remain
  separate workstreams and are not claimed here.

## 11. Maintainer decisions before activation

1. Enable immutable releases, then set `IMMUTABLE_RELEASES_CONFIRMED=true`.
2. Create and protect `release-publication`; restrict deployments to
   `main`/`v*`.
3. Set `RELEASE_PUBLICATION_ENABLED=true` in that environment.
4. Signed production tags are deferred to a separate operational workstream.
   No tag-signature control exists in this lifecycle, so enabling publication
   does not imply signature enforcement.
5. Approve GHCR image publication, visibility and retention. Registry
   publication now requires a `refs/heads/main` dispatch.
6. Approve the A→B pin commit/tag sequence and who may create tags.
7. Approve the first canonical version (>= 0.3.1).
8. Decide whether unresolved critical vulnerabilities block publication.
9. Approve hardware evidence requirements.
10. Approve any SLSA claim beyond provenance-attested GitHub build provenance.

## 12. Cross-project reuse

Reusable without a shared runtime: manifest schema/ID canonicalization,
packaging-inputs and pin-commit contracts, explicit artifact-ID/digest
selection, SPDX builder, legacy/canonical verifier, permission matrix and
attestation wrapper. Package names, version suffix, environment image and
hardware status remain project-owned. The SADR repository was not modified.

## 13. Branch Actions evidence: failures, root causes, resolutions

Earlier runs failed. Each root cause below was established from the
authenticated job logs, not guessed:

| Symptom in the log | Root cause | Resolution |
|---|---|---|
| Image qualification stalled/exited before producing an archive | Buildx default driver cannot export an OCI archive | Use the `docker-container` driver and export both an OCI and a Docker archive (`6c0c848`, `9b9fbb7`) |
| CI apt step failed | Ubuntu package source handling in CI | `scripts/apt-update-ubuntu-only.sh` used by the CI jobs |
| `ERROR: unexpected candidate file: .artifact-names.4859` | `validate-candidate.sh` wrote its temporary name list **inside** the candidate directory, so the contract rejected the validator's own file | Moved to `mktemp` outside the candidate tree (`663dfc5`) |
| `ERROR: unexpected candidate file: .work` | `build-release-candidate.sh` created its working directory inside the output directory; cleanup ran only after validation | Work directory moved to `mktemp` outside the tree with a `trap` (`d0b3f5d`) |
| `no attestations found with predicate type: https://spdx.dev/Document` | `actions/attest` derives the SPDX predicate type from the document, so an SPDX-2.3 SBOM is attested as `…/v2.3`; policy expected the unversioned URI | Pin the versioned predicate in policy, read both predicate types from policy, and prove the predicate equals the shipped SBOM (`c573450`) |
| `expected digest must be sha256:<hex>` | `actions/upload-artifact` emits a bare 64-character hex digest | `normalize_digest()` canonicalizes at both boundaries (`4ea9a0c`) |
| CI "Static analysis" failed on `SC2129` | Pre-existing style finding in the contract fixture | Grouped redirects (`da96fbf`) |

After those fixes the full lifecycle is green in the environment:
`46043324448` (first complete run, real attestations and qualification
dry-run), `46043324477` (CI plus published-release fixtures), and `d6a5d4f`
after the security review (`46050666946`, `46050667701`).

## 14. Independent reviews

Phase III was reviewed twice by independent reviewers working from a fresh
session.

**Review 1 (implementation).** Three blocking issues, all fixed: artifact-ZIP
digest parsing disagreed with the API's `sha256:<hex>` form; promotion jobs
lacked `actions: read`; the image verifier accepted a skipped vulnerability
scan. Should-fix items applied: canonical re-verification enforces
`nonRelease=false`, `main` and exact source-workflow commit; the candidate
validator checks the policy hash, source-archive hash and worktree `.git`
presence; the container mounts the archived build script rather than the host
tree; `.buildinfo` fails when `SOURCE_DATE_EPOCH` is absent. The
previously-listed gap "JSON Schema is not wired" is closed: the schema is
enforced in candidate construction, verification, promotion and published
release verification.

**Review 2 (security, at head `05f06f6`).** One release-blocking functional
defect and four substantive gaps; all resolved in `d6a5d4f`:

- *Blocking.* The publish job fetched its own run's preflight artifact without
  `--allow-run-in-progress`. The run is `in_progress` at that point, so the job
  failed before `promote-release.sh` and the whole authorized publication path
  was unreachable. It failed closed, but it had never run. Fixed; artifact
  identity is still bound by ID, digest, run ID, head SHA, workflow path and
  name.
- *Supply chain.* The distributed `install.sh` is excluded from the packaging
  digest and was constrained only in its four pins, so a tag commit could
  append arbitrary code that users execute through the documented
  `curl … | sh` path. `check_installer_pins_only()` now derives the expected
  installer from commit A plus the pin substitutions and requires the tag
  commit's `install.sh` to match byte-for-byte; it runs in preflight and in
  published-release verification, and a tampered-installer test covers it.
- *Privileged execution.* The GHCR publish job held `packages: write` and
  `id-token: write` with no ref guard and ran the dispatched ref's tooling. It
  is now restricted to `refs/heads/main`, checks out `github.workflow_sha`, and
  asserts the checkout matches.
- *Mutable references.* Tag movement was checked only against a local
  checkout. `gh release create` now passes `--target TAG_COMMIT`, and the tag
  is re-resolved remotely immediately before `draft=false`.
- *Verification integrity.* `qualification.checks` and
  `comparedArtifacts` are now required non-empty; the requested tag is bound to
  the candidate before any draft exists; the schema fails closed on formats the
  installed validator cannot enforce, and the decorative `date-time` keyword was
  replaced by an enforced RFC 3339 pattern.
- *Test honesty.* The subject-digest case used a byte-identical copy and only
  exercised the name check; it now also uses the same name with different
  bytes.

Review 2 confirmed as sound, with file:line evidence: no tag or candidate
content is executed in the privileged path; pinned tooling cannot be shadowed
by candidate content; artifact identity is re-checked before extraction and
again before publication; attestation verification binds repository, signer
workflow and digest, source digest and ref, issuer, runner class, predicate
type and subject digest; the gate matrix cannot be satisfied without every
precondition and the admin token is unusable; archive extraction rejects
traversal, absolute paths, duplicates, symlinks, hardlinks, special files and
size bombs; draft contents are fully verified before publication and
conflicting drafts are refused; canonical verification cannot fall back to the
legacy path; no error is swallowed in a way that lets a check pass without
running.

## 15. Maintainer activation summary

The trusted release infrastructure now works and fails safely in
non-production. Nothing in this branch grants it operational authority. The
branch remains a draft PR and must not be merged, tagged or released until the
decisions in section 11 are made and the limitations in section 10 are accepted
or closed.
