# Trusted release lifecycle

Status: Phase III implementation on `ci/trusted-release-lifecycle`.
No production release, container-image publication, immutable-release
activation, signing key, tag move, historical asset change or repository
setting change was performed.

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
| `build-environment.yml` | dispatch, branch push | build/qualify read-only; gated publish adds `packages: write`, `id-token: write`, `attestations: write` | Image qualification, SBOM, vulnerability review, gated GHCR |
| `release.yml` | dispatch, qualification branch push | candidate adds `id-token: write`, `attestations: write`; publish adds `contents: write` + environment | Candidate build/attestation, dry-run, authorized draft publication |
| `verify-release.yml` | reusable, dispatch, `release: published` | `contents: read`, `attestations: read` | Independent downloaded-release verification |
| `security-audit.yml` | schedule, dispatch | `contents: read` | Online zizmor and actionlint |

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

## 9. Local verification evidence

| Check | Result |
|---|---|
| `test/unit-release-primitives.sh` | 24/24 pass (ID stability, packaging/pin contracts, tag ordering, pin rendering) |
| `test/unit-image-qualification.sh` | 8/8 pass (OCI index/manifest/config selection, tampered/missing blobs, ambiguity, traversal) |
| SPDX SBOM build/validate on published v0.3.0 packages | PASS (integration 30 files; kernel 5 files) |
| `.buildinfo`/`.changes` validation on published v0.3.0 | PASS |
| `bash test/run.sh` (existing suite) | previously green on `origin/main`; not re-run after this branch's script-only additions |
| Local OCI image build/export | Image built locally (681 MB), but Buildx OCI export stalled; no local OCI archive was produced |
| Local candidate build/E2E | Not completed because the local OCI archive was unavailable |

The local OCI export stall is the same class of limitation recorded in Phase
II. The GitHub-hosted workflows are the intended environment evidence path.
Run IDs and artifact IDs are recorded in the draft PR/commit follow-up after
the branch runs.

## 10. Remaining risks and limitations

- GitHub Actions environment protection cannot be proven from `GITHUB_TOKEN`;
  the maintainer must create/protect the environment before enabling
  publication. An auto-created unprotected environment is a residual risk.
- Immutable releases are currently disabled (`enabled:false`). Canonical
  publication cannot succeed until the maintainer enables the setting and
  provides the proof variable/token.
- No production candidate was built because the local OCI export stalled and
  no branch Actions run has completed yet.
- The Phase II Docker archive (artifact `15207216180`, 484 MB, 14-day
  retention) was not re-downloaded/verified in this pass.
- Kernel module source-to-binary reproducibility, hardware qualification and
  Internet-facing probes remain out of scope/separate.
- A failed post-publish immutable verification can only be superseded by a new
  version, not repaired in place.

## 11. Maintainer decisions before activation

1. Enable immutable releases.
2. Create/protect `release-publication` with required reviewers and restrict
   deployments to `main`/`v*`.
3. Set `RELEASE_PUBLICATION_ENABLED=true` and, after verifying the setting,
   `IMMUTABLE_RELEASES_CONFIRMED=true`, or provide an admin token for the API
   proof.
4. Decide whether published tags must be signed and provision keys.
5. Approve GHCR image publication, visibility and retention.
6. Approve the A→B pin commit/tag sequence.
7. Approve the first canonical version (>= 0.3.1).
8. Decide whether critical vulnerabilities block publication.
9. Approve hardware evidence requirements.
10. Approve any SLSA claim beyond the provenance-attested GitHub build.

## 12. Cross-project reuse

Reusable without a shared runtime: manifest schema/ID canonicalization,
packaging-inputs and pin-commit contracts, explicit artifact-ID/digest
selection, SPDX builder, legacy/canonical verifier, permission matrix and
attestation wrapper. Package names, version suffix, environment image and
hardware status remain project-owned. The SADR repository was not modified.
