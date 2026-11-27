# Phase III — Implementation tasks (review-resolved)

Each task ends with a verification gate. The final diff gets an independent
review before the draft PR.

## T1 — Shared release primitives and contracts

- `scripts/release-common.sh`: failure helpers, canonical JSON, SHA-256,
  manifest field readers, candidate ID computation, validated temp handling.
  Runs on the host/CI (uses `jq`); the controlled image is not expected to
  contain `jq`.
- `release/release-policy.json`: `canonicalFrom: "0.3.1"`,
  `immutableFrom: "0.3.1"`, repository ID, package names/version suffix,
  required assets, pin-only allowlist, publication gates.
- `release/candidate-schema.json`: JSON Schema 2020-12 with pinned enums and
  unique artifact names.
- `scripts/packaging-inputs.sh`: digest over **all tracked files except the
  non-package allowlist** (`install.sh`, `SHA256SUMS`, `README.md`,
  `docs/**`, `.github/**`, `spec/**`, `test/**`). Includes `.gitattributes`,
  `release/**` (policy/schema), `scripts/**`, `containers/**`.
- `project.releasePolicySha256` binds the policy used at build.
- `scripts/check-pin-commit.sh A B`: A→B changed-path allowlist + packaging
  digest equality.
- `scripts/update-release-pins.sh`: render/check `install.sh` and
  `SHA256SUMS` from a candidate manifest; `--check` is also run against B.
- `scripts/install-supply-chain-tools.sh`: pinned `gh`, Syft, Grype, Crane
  with checksums.
- Tests: ID stability under key order; ID changes on identity change;
  docs-only no-op; `.gitattributes`, mode, symlink, rename, changelog and
  Dockerfile changes; pin-only commit accepted; package-affecting B rejected.
- Gate: shellcheck + unit tests.

## T2 — SBOM before candidate assembly

- `scripts/build-sbom.py`: deterministic SPDX 2.3 generation and validation
  (fixed creator/creation time/namespace, package verification codes over
  SHA-1 file checksums; SHA-256 remains primary).
- Tests: completeness, hashes, missing/extra package file, wrong
  package/version, false `GENERATED_FROM`, two-run byte equality.
- Gate: SBOM validates for real packages; Syft cross-check recorded.

## T3 — Controlled environment lifecycle

- `scripts/build-environment.sh`: Buildx OCI build; record OCI index,
  platform manifest, config digest, OCI archive checksum, Docker archive
  checksum (optional), inventory checksum, Dockerfile/CA/snapshot hashes;
  image SBOM; Grype report; qualification JSON.
- `scripts/verify-build-environment.sh`: independent archive/digest/inventory
  verification and test build; 404/absence handling.
- `containers/reproducible-build/vulnerability-exceptions.json`: reviewed,
  expiring exceptions; critical findings otherwise fail.
- `scripts/install-supply-chain-tools.sh`: pinned `gh`, Syft, Grype, Crane
  with checksums.
- GHCR publication job (gated, not run) using `buildx --push` or `crane push`,
  with remote digest read-back; a local-registry test proves digest
  preservation. Do not use `docker push` for the qualified OCI manifest.
- Preserve the Phase II qualified Docker archive where accessible: download
  artifact `15207216180`, verify its recorded SHA-256, and record the evidence;
  do not modify or publish it.
- Tests: digest parser, tampered archive, wrong inventory, wrong
  Dockerfile/CA/snapshot, expired exception, tag fallback rejection,
  config-digest-as-runnable rejection, local-registry digest preservation.
- Gate: local image build + verification; tests pass.

## T4 — Candidate construction

- `scripts/build-release-candidate.sh`:
  - production mode: assert `github.ref == refs/heads/main` and
    `github.sha == source commit A`; `nonRelease=false`;
  - dry-run mode: branch ref/commit, `nonRelease=true`;
  - always materialize `git archive A` in-job and re-derive its SHA-256;
  - re-run `verify-build-environment.sh`; load and run by manifest digest
    with `--pull=never`; config digest is metadata only;
  - one distribution build; comparison rebuild only;
  - artifact contract + Debian metadata + SBOM + qualification;
  - assemble identity → candidate ID → manifest → package-only `SHA256SUMS`.
- `scripts/validate-build-metadata.sh`: `.buildinfo`/`.changes` checks and
  negative cases (version/source/arch/checksum/size/missing/extra).
- `scripts/validate-candidate.sh`: post-construction verifier; not written
  into qualification.
- Tag/version gate: tag == `v<packageVersion>` (strip `v` for Debian
  comparison); reject versions <= latest published; A ancestor of B;
  packaging digest equality; `update-release-pins.sh --check` against B.
- Asset taxonomy: `SHA256SUMS` package-only; evidence assets are separate.
- Expired candidate abandons the release; retention covers the release window.
- Tests: positive candidate; tampered artifact/checksum/source/env digest/
  qualification; version reuse; nonRelease production rejection; asset
  taxonomy extras/missing; tag-prefix ordering.
- Gate: real non-release candidate built locally; tests pass.

## T5 — Provenance and attestations

- `actions/attest@v4.2.2` pinned to
  `1e69f48acb82d1966a394da916b4c1698aa569d6`.
- `scripts/verify-attestations.sh`: `--repo`, `--signer-workflow`,
  `--signer-digest`, `--source-digest`, `--source-ref`,
  `--cert-oidc-issuer https://token.actions.githubusercontent.com`,
  `--deny-self-hosted-runners`, predicate type, `--bundle`,
  `--custom-trusted-root`, repository-ID check from `--format json` (fail
  closed if the identifier is unavailable).
- Workflow fetches `gh attestation trusted-root`; candidate bundle saved.
- Tests: real branch-run bundle accepted; wrong artifact/repo/workflow/
  signer/source/ref/self-hosted/missing/tampered bundle rejected.
- Gate: actual GitHub Actions attestation bundle verified locally and in CI.

## T6 — Publication authorization and promotion

- `scripts/promote-release.sh`: explicit artifact ID/digest/candidate ID/
  manifest SHA/tag; reject `nonRelease`, unqualified status, tag mismatch,
  A not ancestor of B, packaging digest mismatch, expired artifact, existing
  published release mismatch; dry-run plan; draft create/resume; no-clobber
  upload; draft verification; publish; post-publish verification call.
- `scripts/check-release-gates.sh`: main-only, repo variable, environment
  name, immutable confirmation/admin token, API version handling (404=false,
  400/403=cannot-prove), tag/version equality, historical version reuse.
- `scripts/verify-release.sh`: legacy/canonical/draft/immutable, Debian
  version ordering (strip `v`), package-only validator view, full evidence
  set, attestation, draft download by release/asset ID, `--fixture` gate
  (local asset dir, tag absent on GitHub).
- Input validation: regex/length for tag, IDs, hashes, confirm string; all
  passed via `env:`; injection negative tests.
- Tests: unauthorized, wrong candidate/tag, nonRelease, duplicate/historical
  version, expired artifact, partial draft resume, conflicting draft,
  concurrent run, interrupted publish, missing/tampered evidence, legacy
  v0.1.1/v0.2.x/v0.3.0 matrix, hardware overclaim, fixture bypass rejection.
- Gate: dry-run against a real branch candidate succeeds without any release
  mutation; local fixture tests pass.

## T7 — Workflows and security audit

- `ci.yml`, `build-environment.yml`, `release.yml`, `verify-release.yml`,
  `security-audit.yml`; remove superseded workflows.
- Permission matrix, pinned actions, temporary branch push qualification
  trigger documented.
- `security-audit.yml`: scheduled/manual online zizmor; no privileged events;
  dependency-update procedure for actions, image packages, security/attestation/
  SBOM tools.
- Gate: actionlint, offline zizmor, shellcheck, YAML review.

## T8 — End-to-end and adversarial qualification

- Local E2E: image qualify → candidate build → SBOM → metadata → manifest →
  attestation fixture → release fixture → canonical/draft/legacy verification
  → dry-run promotion → local-registry digest preservation.
- Run every adversarial case and assert the intended error reason.
- Branch Actions: environment, candidate + attestations, dry-run promotion,
  online audit. Open a draft PR and run the `pull_request` workflows to
  capture PR evidence. Collect run IDs, artifact IDs/digests, bundle
  verification, image digests, SBOM hashes.
- Verify tool/flag/API claims against current docs in the report: attestation
  flags, immutable-release endpoint/API version, artifact digest/expiry
  fields, draft download APIs.
- Preserve/record the Phase II Docker archive evidence where accessible.
- Gate: every positive pass and every negative fail for the intended reason.

## T9 — Report, review, draft PR

- `docs/trusted-release-lifecycle.md`: architecture, threat model, permission
  matrix, manifest spec, contracts, image lifecycle, provenance/SBOM,
  verification, publication design, recovery, evidence, remaining risks,
  activation decisions, dependency-update procedures, cross-project reuse.
- Update `docs/README.md` and the stale Phase II limitations in
  `docs/reproducible-builds.md` (no retained image/attestations/SBOM).
- Run `/review` on the full diff and resolve findings.
- Commit, push branch, open draft PR. Do not merge.

## Verification commands

```sh
bash test/run.sh
bash test/unit-release-primitives.sh
bash test/unit-build-metadata.sh
bash test/unit-release-candidate.sh
bash test/unit-sbom.sh
bash test/unit-release-publication.sh
bash test/unit-release-verification.sh
bash test/release-lifecycle-e2e.sh   # Docker + network tool acquisition
./scripts/install-ci-tools.sh "$TMPDIR/ci-tools"
PATH="$TMPDIR/ci-tools:$PATH" actionlint
PATH="$TMPDIR/ci-tools:$PATH" zizmor --offline --collect all .github
PATH="$TMPDIR/ci-tools:$PATH" shellcheck install.sh scripts/*.sh test/*.sh
git diff --check
```
