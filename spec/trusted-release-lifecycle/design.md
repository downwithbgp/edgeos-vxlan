# Phase III — Trusted release lifecycle design (review-resolved)

## 1. Architecture

```
source commit A ── git archive in-job ──► source.tar (SHA-256 re-derived)
        │                                      │
        │ packaging-inputs digest              │
        ▼                                      ▼
 qualified OCI archive ─────────────► build once (network none, read-only)
 (index/manifest/config digests)             │
        │                                    ├── packages + .buildinfo + .changes
        │                                    ├── SPDX 2.3 SBOM + validator
        │                                    ├── comparison rebuild B (never shipped)
        │                                    └── release-candidate.json
        │                                    │
        ▼                                    ▼
  verified qualification ──────────► candidate artifact (ID + ZIP digest)
                                             │
                              explicit artifact ID + digest selection
                                             │
                              candidate verification + attestation check
                                             │
                              dry-run plan ──or── draft → verify → publish
                                             │
                                             ▼
                              explicit verify-release invocation
```

Components:

- `scripts/build-environment.sh` — Buildx OCI build, distinct identities,
  inventory, image SBOM via Syft, vulnerability report via Grype,
  `release/build-environment-qualification.json`.
- `scripts/verify-build-environment.sh` — independent OCI archive verification
  (archive checksum, index/manifest/config digests, Dockerfile/base/snapshot/CA
  hashes, inventory checksum, test build).
- `scripts/build-release-candidate.sh` — exact in-job archive, verified image,
  one distribution build, comparison rebuild, artifact contract, Debian
  metadata validation, SPDX SBOM, qualification object, candidate ID, manifest,
  package-only `SHA256SUMS`.
- `scripts/build-sbom.py` — deterministic SPDX 2.3 generation and validation.
- `scripts/validate-build-metadata.sh` — `.buildinfo`/`.changes` consistency.
- `scripts/validate-candidate.sh` — post-construction verifier (never part of
  the qualification object).
- `scripts/verify-attestations.sh` — offline/online attestation policy.
- `scripts/verify-release.sh` — legacy/canonical/draft/immutable release
  verification.
- `scripts/promote-release.sh` — explicit selection, dry-run, draft
  create/resume, no-clobber upload, draft verification, publication.
- `scripts/check-pin-commit.sh` / `scripts/update-release-pins.sh` — the
  A→B pin-only contract and pin rendering.
- `scripts/packaging-inputs.sh` — package-affecting digest.
- `scripts/check-release-gates.sh` — publication enablement, environment,
  immutable-release proof and input validation.
- Workflows: `ci.yml`, `build-environment.yml`, `release.yml`,
  `verify-release.yml`, `security-audit.yml`.
- External tools used by release jobs (`gh`, Syft, Grype, Crane) are installed
  from pinned versions with verified checksums, not taken from mutable
  runner state.

## 2. Trust boundaries and threat model

| Boundary | Trusted side | Lower-trust side | Threats | Mitigations |
|---|---|---|---|---|
| Source → build | Exact commit A, immutable ref, trusted workflow commit | Working tree, untracked files, PR code | Dirty-tree substitution, source/binary mismatch | Clean check, in-job `git archive`, archive SHA-256, packaging-inputs digest, source/ref binding |
| Workflow → execution | Default-branch workflow, protected environment, exact run commit | PR workflow edits, branch dispatch | Privileged job runs attacker code, token theft | PR jobs read-only, no PR artifacts executed in publish jobs, pinned actions, `main`-only dispatch, environment approval |
| Build environment | Qualified OCI manifest/config + inventory | Mutable tags, registry/snapshot outage | Floating image, dependency substitution | OCI archive retained, digests distinguished, re-verified in candidate job, snapshot pin, no tag fallback |
| Candidate | One exact build set | Rebuilds, CI artifacts, local builds | Publication substitutes a new build | Build once; comparison build never shipped; hashes and candidate ID bound |
| Selection | Artifact ID + artifact digest + candidate ID | Mutable names/latest run/branch | Wrong, stale or concurrent candidate | Explicit inputs; API expiry/digest/repository checks; candidate ID recomputation; no name/latest logic |
| Qualification | Evidence bound to candidate ID | Forged/stale evidence | Publication of unqualified artifacts | Recompute every hash; verify qualification evidence; fail closed |
| Authorization | Protected environment + repo enablement + exact confirmation | Branch push, ordinary dispatch | Unauthorized publication | Environment required reviewers, repo variable, `main`-only dispatch, exact confirm string, immutable preflight |
| Publication | Draft-verified exact asset set | Interrupted/partial drafts, concurrent runs | Partial release, asset replacement | Draft-first, asset-by-asset hash compare, concurrency group, resumable idempotent rerun, no clobber |
| Verification | Downloaded release assets | Local build output | False assurance | Download and verify distributed bytes only |
| Signing | GitHub OIDC + Sigstore | Self-hosted runner, wrong workflow | Forged provenance | `--signer-workflow`, `--signer-digest`, `--source-digest`, `--source-ref`, `--deny-self-hosted-runners`, repository-ID check |

Non-claims:

- Attestations do not prove correctness, vulnerability absence or hardware
  compatibility.
- Kernel module source-to-binary reproducibility is not established; modules
  remain prebuilt inputs.
- No SLSA build level is claimed. The path is a provenance-attested
  GitHub-hosted build, not a certified SLSA level.

## 3. Candidate and release modes

Two explicit modes:

- **Production candidate** — dispatched on `main` at the exact source commit
  A. The job asserts `github.ref == refs/heads/main` and
  `github.sha == manifest.source.commit == A`. Therefore the GitHub
  attestation's source digest/ref are exactly A/`refs/heads/main`. `nonRelease`
  is false. The release tag B (pin commit) is created later and is never
  built.
- **Dry-run candidate** — branch push or dispatch on a non-main ref. The
  manifest records the actual branch ref and commit and sets
  `nonRelease: true`. Promotion rejects it. This is the only way to exercise
  the pipeline before the workflow exists on `main`.

The manifest does **not** contain `tagCommit`; that would create a circular
hash dependency because B is created after the build. Promotion/verification
resolves the tag to B, checks A is an ancestor of B, and checks that
`packagingInputsSha256(A) == packagingInputsSha256(B)`.

## 4. Candidate manifest

Schema: `release/candidate-schema.json`, JSON Schema 2020-12, format URI
`https://edgeos-vxlan.dev/release-candidate/v1`.

Required fields:

- `schemaVersion`; `candidate` (`id`, `createdAt`, `status`, `nonRelease`,
  `status` and `nonRelease` are inside the identity).
- `project` (`name`, `repository`, `releaseTag`, `packageVersion`,
  `sourceDateEpoch`, `releasePolicySha256`).
- `source` (`commit` A, `archiveSha256`,
  `packagingInputsSha256`, `trustedWorkflow` with repository/path/ref/commit).
- `buildEnvironment` (`image`, `ociIndexDigest`, `manifestDigest`,
  `configDigest`, `ociArchiveSha256`, `dockerArchiveSha256` optional,
  `dockerfileSha256`, `caBundleSha256`, `dependencySnapshot`,
  `dependencyInventorySha256`, `qualificationSha256`, `imageSbomSha256`).
- `build` (`buildType`, `command`, `reproducibility` result).
- `artifacts` (unique names, sorted; role enum: `package`, `debian-metadata`,
  `sbom`, `environment-qualification`; size, SHA-256) for every
  identity-bound distributed file.
- `qualification` (status enum, checks with evidence hashes, hardware status
  enum).
- `limitations` (explicit unverified relationships; inside identity).

Excluded from `artifacts`/identity because they are derived or created after
the manifest:

- `SHA256SUMS` (package-only, derived);
- `release-attestation.jsonl` (created by the attestation step).

Candidate ID:

```
identity = {schemaVersion, candidate: {status, nonRelease},
            project, source, buildEnvironment, build,
            artifacts (sorted by name), qualification, limitations}
candidate.id = "sha256:" + sha256(canonical JSON of identity)
```

Canonical JSON: sorted keys, compact separators, UTF-8, no trailing newline.
The manifest file itself is written with a trailing newline; its SHA-256 is
recorded by the workflow/API and verified by the release verifier.

Construction order (no self-reference):

1. Build once; keep distribution build A.
2. Run artifact contract, Debian metadata, SBOM generation/validation,
   comparison rebuild.
3. Assemble `qualification` (checks completed above; no candidate ID).
4. Assemble identity and compute candidate ID; write manifest.
5. Generate package-only `SHA256SUMS`.
6. Attest manifest + packages + metadata + SBOM + environment qualification.
7. Run `validate-candidate.sh` as a post-construction verifier; its result is
   not written back into the manifest.

Immutability: identity fields, artifacts and qualification are immutable after
step 4. Any change means a new candidate.

## 5. Artifact identity, versioning and pinning contract

Findings:

- `install.sh` and repository `SHA256SUMS` are not packaged.
- `debian/changelog` is packaged (changelog.gz) and defines the version; any
  change requires a new version.

Policy:

1. A published package version identifies an immutable artifact.
2. Historical hashes remain authoritative.
3. CI artifacts are non-release.
4. Byte-affecting changes require a new package version.
5. CI-only changes do not inherently require a version increment.
6. Historical assets are never silently replaced.
7. Future releases use canonical qualified artifacts.

Release preparation (documented; no rebuild):

1. Commit A = release source and `debian/changelog` version.
2. Production candidate is built/qualified from A; never rebuilt for
   distribution.
3. Commit B updates `install.sh`, `SHA256SUMS` and release notes from the
   candidate using `update-release-pins.sh`.
4. `check-pin-commit.sh A B` requires every changed path to be in the pin-only
   allowlist (`install.sh`, `SHA256SUMS`, `README.md`, `docs/**`, `.github/**`,
   `spec/**`, `test/**`) and
   `packagingInputsSha256(A) == packagingInputsSha256(B)`.
5. `update-release-pins.sh --check` is run against the resolved tag tree B; it
   must render exactly B's `install.sh`/`SHA256SUMS` from the candidate.
6. Tag `vX.Y.Z` at B. Manifest records A and the tag name; verifier resolves
   B and checks ancestry + packaging digest equality.
7. Publish the exact candidate to the draft; verify; publish.

`packagingInputsSha256` covers **all tracked files except** the non-package
allowlist above (`install.sh`, `SHA256SUMS`, `README.md`, `docs/**`,
`.github/**`, `spec/**`, `test/**`). This includes
`.gitattributes`, `scripts/**`, `containers/**`, `debian/**`, `src/**`,
`templates/**`, `modules/**`, and `release/**` (the release policy/schema).
The policy hash is also bound in `project.releasePolicySha256`. The A→B
changed-path allowlist is the primary gate; the digest is the secondary
equality proof.

Tests cover docs-only no-op, `.gitattributes` change, mode change, symlink,
rename, changelog change and Dockerfile change.

Installer solution: pins remain in `install.sh` for the legacy one-command
install; B updates them from the manifest. Canonical verification uses the
manifest as authority; legacy verification uses tagged pins. No circular
dependency and no rebuild.

## 6. Controlled environment lifecycle

- Dockerfile digest-pinned base, fixed Ubuntu snapshot, committed CA bundle,
  APT signature verification.
- Buildx OCI output. Identities recorded separately:
  - OCI index digest (multi-manifest / registry index) — `ociIndexDigest`;
  - platform image manifest digest — `manifestDigest` (run identity);
  - config digest — `configDigest` (metadata, not a runnable pull ref);
  - OCI archive SHA-256 — retention/transport;
  - Docker archive SHA-256 — optional local transport;
  - inventory SHA-256 — package selection.
- Execution: load the OCI archive, confirm the OCI manifest's
  `.config.digest` equals `configDigest`, and run the loaded image through a
  repository name recorded by the load (`<repo>@sha256:<manifestDigest>`) with
  `--pull=never`; assert `docker image inspect <repo>@sha256:<manifestDigest>`
  succeeds and reports the expected image identity. The config digest is
  metadata only and is not used as a runnable reference. If the local store
  cannot resolve the manifest digest, fail closed with diagnostics; never fall
  back to a floating tag.
- Candidate job re-runs `verify-build-environment.sh` against the OCI archive
  and qualification JSON before use; the qualification file alone is never
  trusted.
- Image SBOM: Syft over the OCI archive. Vulnerability review: Grype report;
  critical findings fail unless listed in a reviewed, expiring exception file.
- GHCR publication: implemented but gated by
  `BUILD_IMAGE_PUBLICATION_ENABLED` and `build-image-publication`; not run.
  Publication uses `buildx --push` or `crane push` (not `docker push`, which
  may re-serialise an OCI manifest); the remote digest is read back and must
  equal the qualified manifest digest.
- Recovery: retained OCI archive + qualification first; if unavailable,
  rebuild from the Dockerfile and re-qualify (new qualification, new
  candidate). Never a floating tag.

## 7. Provenance and attestations

- `actions/attest@v4` pinned to commit
  `1e69f48acb82d1966a394da916b4c1698aa569d6` (v4.2.2).
- Candidate job in `release.yml` permissions: `contents: read`,
  `id-token: write`, `attestations: write`. The only other job with these
  writes is the gated image-publication job in `build-environment.yml`.
- Provenance over packages, manifest, metadata, SBOM, environment
  qualification. SBOM attestation over the packages with the SPDX JSON.
- Bundle output saved as `release-attestation.jsonl`.
- `verify-attestations.sh` enforces:
  - `--repo downwithbgp/edgeos-vxlan`;
  - `--signer-workflow downwithbgp/edgeos-vxlan/.github/workflows/release.yml`;
  - `--signer-digest` = manifest `trustedWorkflow.commit`;
  - `--source-digest` = manifest `source.commit`;
  - `--source-ref` = manifest `trustedWorkflow.ref` (production:
    `refs/heads/main`);
  - `--cert-oidc-issuer https://token.actions.githubusercontent.com`;
  - `--deny-self-hosted-runners`;
  - predicate type for provenance and SBOM;
  - `--bundle` + `--custom-trusted-root` (trusted root fetched in CI);
  - repository ID parsed from `--format json` certificate fields and compared
    to `release/release-policy.json.repositoryId`; if the CLI does not expose
    the identifier, fail closed rather than accepting names alone.
- Negative tests: wrong artifact, repository, workflow, signer digest, source
  digest/ref, missing/tampered bundle, self-hosted runner.
- Dry-run candidates are explicitly non-release; no historical package is
  attested as a new-pipeline release.

## 8. SBOM

- SPDX 2.3 JSON generated deterministically from:
  - extracted `.deb` payloads (all package files, SHA-256, modes);
  - control metadata and package relationships;
  - `debian/copyright` licensing;
  - kernel-module binary hashes, Ubiquiti GPL source archive hash and patch;
  - explicit annotations for unverified source-to-binary relationships.
- Determinism: `creationInfo.created` from `SOURCE_DATE_EPOCH`, fixed creator,
  deterministic `documentNamespace` from commit + artifact hashes, SPDX
  package verification codes over SHA-1 file checksums (SHA-256 remains the
  primary hash), and a two-run byte-equality test.
- Build-environment components are excluded from the release SBOM and recorded
  in the image SBOM.
- Validation: every package payload file appears exactly once, hashes match,
  correct packages/version, no `GENERATED_FROM` claim for kernel modules.
- Syft cross-check is recorded, not used as the authoritative release SBOM.

## 9. Debian metadata validation

`validate-build-metadata.sh` checks:

- one `.buildinfo` and one `.changes` for the version;
- `Format`, `Source`, `Binary`, `Architecture`, `Version`;
- every `Checksums-Sha256`/`Files` entry exists and matches size/hash;
- `.changes` lists exactly the two `.deb` files plus `.buildinfo`;
- `.buildinfo` lists exactly the two `.deb` files;
- `Installed-Build-Depends` is non-empty and covers `debian/control`
  `Build-Depends`;
- `Environment` `SOURCE_DATE_EPOCH` equals the candidate epoch where present;
- no missing/extra metadata files.
- Negative cases: altered version/source/architecture/checksum/size, extra
  file, missing file, wrong package set.
- Independent builds compare package bytes only; `.buildinfo`/`.changes`
  timestamps/paths may legitimately differ.

Asset taxonomy:

- `SHA256SUMS` remains package-only (two debs) for installer/historical
  compatibility.
- Canonical release assets: two debs, `.buildinfo`, `.changes`,
  `release-candidate.json`, `sbom-*.spdx.json`,
  `build-environment-qualification.json`, `release-attestation.jsonl`,
  `SHA256SUMS`.
- The release verifier creates a package-only view for the existing
  `validate-artifacts.sh --published` and separately validates the full asset
  set against the manifest. Extra, missing or substituted evidence fails.

## 10. Publication authorization and immutable releases

Layers:

1. Workflow dispatch only from `main`; jobs assert
   `github.ref == refs/heads/main`.
2. `release-publication` environment with required reviewers. The environment
   must be created and protected **before** the enable variable is set. An
   auto-created unprotected environment is a documented residual risk.
3. Repository variable `RELEASE_PUBLICATION_ENABLED=true`.
4. Immutable releases:
   - maintainer sets `IMMUTABLE_RELEASES_CONFIRMED=true` only after enabling
     the setting;
   - if `IMMUTABLE_RELEASES_ADMIN_TOKEN` is configured, the workflow queries
     `GET /repos/.../immutable-releases` with
     `X-GitHub-Api-Version: 2026-03-10`; 404 means not enabled; 400/403 means
     the caller cannot prove the setting and also fails closed with a
     distinct diagnostic;
   - post-publication the release API `immutable` field is checked;
   - without either proof, publication fails closed.
5. Exact inputs: candidate artifact ID, artifact digest, candidate ID,
   manifest SHA-256, tag, `confirm_publish=PUBLISH`.
6. Tag gate: the tag must equal `v<project.packageVersion>` (strip the leading
   `v` before Debian version comparison), exist, be contained in `main`, and
   resolve to B such that A is an ancestor of B,
   `packagingInputsSha256(A) == packagingInputsSha256(B)`, and
   `update-release-pins.sh --check` renders exactly B's
   `install.sh`/`SHA256SUMS`. A version at or below the latest published
   version is rejected as historical reuse.
7. Signed tags are enforced only if `RELEASE_REQUIRE_SIGNED_TAG=true`; Phase
   III creates no keys.

Publication sequence:

1. Download by explicit artifact ID; verify `expired=false`, artifact digest,
   repository/run identity.
2. Recompute candidate ID and manifest hash; run candidate validation and
   attestation verification.
3. If a published release exists: verify exact candidate/assets; never modify.
   Mismatch fails closed.
4. Create or resume a draft for the exact tag.
5. Upload missing assets only; compare existing assets; never clobber a
   differing asset.
6. Download the draft through the API by release/asset ID (`GET
   /releases/{id}` and `GET /releases/assets/{asset_id}` with
   `Accept: application/octet-stream`; `GET /releases/tags/{tag}` does not
   return drafts) and verify in `--draft` mode (evidence, hashes, provenance;
   immutable checks deferred).
7. Publish. Then explicitly invoke `verify-release.yml`; do not rely on a
   release event because `GITHUB_TOKEN` suppresses recursive runs.
8. Check `immutable` after publish. A failure is an incident; immutable assets
   cannot be replaced, only superseded with a new version.

Recovery:

- before draft: rerun with same inputs;
- partial draft: resume matching assets, upload missing, fail on conflicts;
- after publish: idempotent verification, no mutation;
- concurrent: concurrency group per tag, `cancel-in-progress: false`; a second
  candidate must match the existing release;
- expired artifact: the release is abandoned; a new version/candidate is
  required because the production source commit A may no longer be the `main`
  tip and `workflow_dispatch` cannot target an arbitrary SHA. Artifact
  retention is set to cover the planned release window (up to 90 days).

All dispatch inputs are validated by regex/length and passed through `env:`,
never interpolated into shell. Negative tests cover injection strings.

## 11. Independent release verification

Classification uses Debian version ordering (`dpkg --compare-versions`),
policy `canonicalFrom: "0.3.1"` and `immutableFrom: "0.3.1"`:

- **Legacy** — version < canonicalFrom and no manifest: existing pinned
  `install.sh`/`SHA256SUMS` verification; provenance not required.
- **Canonical** — manifest present, or version >= canonicalFrom: requires
  manifest, SBOM, metadata, complete asset set, and a valid attestation.
  Missing evidence fails closed.
- **Immutable** — canonical with release API `immutable: true`; required from
  `immutableFrom` after activation.
- If a manifest is present below canonicalFrom, canonical rules apply.
- `--fixture` is a local-only test mode that requires an explicit local
  `--asset-dir` and refuses when the tag resolves on GitHub; it permits a
  synthetic unsigned bundle only for that local fixture. It is rejected for a
  real published release and covered by a negative test.
- `--draft` validates assets/evidence but skips immutable/published checks.
- Tags are `v<packageVersion>`; strip the leading `v` before Debian version
  comparison so `v0.3.1` cannot sort below `0.3.1`.

Historical matrix:

- v0.1.0: tag exists, no GitHub release; not a verification fixture.
- v0.1.1: release; no committed `SHA256SUMS`; install pins used.
- v0.2.0, v0.2.1, v0.2.2: release; committed `SHA256SUMS` + install pins.
- v0.3.0: release; committed `SHA256SUMS`, install pins, metadata.

The verifier downloads release assets; local build output is never trusted.

## 12. Workflow responsibilities and permissions

| Workflow | Trigger | Permissions | Responsibilities |
|---|---|---|---|
| `ci.yml` | PR, push main/`ci/**`, tags | `contents: read` | Lint, tests, package build, reproducibility, dataplane (trusted refs), historical fixtures |
| `build-environment.yml` | dispatch, push qualification branch | build/qualify: `contents: read`; publish: `contents: read`, `packages: write`, `id-token: write`, `attestations: write`, environment | Image build/qualify/SBOM/vulnerability; gated GHCR publication |
| `release.yml` | dispatch; temporary push qualification branch | candidate: `contents: read`, `id-token: write`, `attestations: write`; dry-run: `contents: read`, `attestations: read`; publish: `contents: write` + environment | Candidate build/attest, dry-run, authorized draft publication, explicit post-publish verify |
| `verify-release.yml` | `workflow_call`, dispatch, `release: published` | `contents: read`, `attestations: read` | Independent release verification |
| `security-audit.yml` | schedule, dispatch | `contents: read` | Online zizmor audit, pinned-tool report, dependency-update guidance |

PR jobs are read-only. All actions are pinned by commit. The temporary
`ci/trusted-release-lifecycle` push trigger is documented as the qualification
entry point because a new workflow cannot be dispatched before it exists on
`main`.

## 13. Test strategy

- Unit: canonical JSON/ID; packaging-inputs and pin-commit contract; build
  metadata; SBOM determinism/completeness; image identity parsing; publication
  gates/recovery; release classification; input validation.
- Integration: real image build/qualification; real non-release candidate;
  synthetic release fixture; all adversarial mutations; each negative fails
  for its intended reason.
- GitHub Actions: branch environment run, candidate + attestations, dry-run
  promotion, online audit; collect run/artifact IDs, digests, bundles.
- Property-style: candidate ID stable under key reordering and changes on any
  identity field; promotion state machine idempotent under replay.

## 14. Known limitations / activation decisions

1. Enable immutable releases.
2. Create/protect `release-publication`; restrict deployments.
3. Set `RELEASE_PUBLICATION_ENABLED=true` and
   `IMMUTABLE_RELEASES_CONFIRMED=true` only after settings are verified.
4. Decide signed-tag requirement and provision keys.
5. Approve GHCR publication/visibility/retention.
6. Approve the A→B pin commit and tag sequence.
7. Approve the first canonical version (>= 0.3.1).
8. Decide critical-vulnerability blocking policy.
9. Approve SLSA claims (none claimed here).
10. Approve hardware evidence requirements.
11. Environment protection cannot be proven from `GITHUB_TOKEN`; an
    unprotected environment remains a residual risk.
12. A failed post-publish immutable verification can only be superseded, not
    repaired in place.

## 15. Cross-project reuse

Reusable: manifest schema/ID, packaging-inputs/pin-commit contract, explicit
artifact ID/digest selection, SPDX builder, legacy/canonical verifier,
permission matrix and attestation wrapper. Project-specific package names,
version suffix, image and hardware status remain local. No SADR changes and no
shared framework in Phase III.
