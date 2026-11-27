# Phase III — Trusted release lifecycle requirements

## Goal

Turn the Phase II reproducible package build into a build-once, qualify-once,
verify-always release lifecycle. The core invariant is:

> The artifacts distributed to users must be the exact artifacts that were
> qualified and approved. Publication never substitutes a new build.

Phase III is implemented on `ci/trusted-release-lifecycle`. It does not create
a production release, publish a container image, move a tag, modify a
historical asset, increment the product version, or change repository
settings.

## Functional requirements

1. **Explicit release architecture and threat model.** Document trust
   boundaries for source, workflows, build environments, candidates,
   qualification evidence, maintainer authorization, and publication.
2. **Controlled environment lifecycle.** Build and qualify the Dockerfile
   image, distinguish image config ID, OCI manifest digest, archive checksum,
   and inventory checksum, and make release builds consume an explicitly
   qualified digest. Support GHCR without activating publication.
3. **Release candidate identity.** Produce a machine-readable manifest that
   binds project, tag/version, source commit, workflow revision, source
   archive hash, environment digest, dependency snapshot, `SOURCE_DATE_EPOCH`,
   artifact names/sizes/hashes, qualification, SBOM, release-policy hash and
   hardware status. Provenance is a separate attestation bundle over the
   manifest and assets; it is not a manifest field.
4. **Artifact pinning contract.** Determine the relationship between
   `install.sh` pins, repository `SHA256SUMS`, package versions, tags and
   candidate artifacts. Avoid circular build/pin dependencies. Enforce the
   approved stable-build policy where possible without touching history.
5. **Workflow separation.** Split ordinary CI, environment construction,
   release candidate/promotion, independent published-release verification,
   and online security auditing. Ordinary PR workflows stay read-only.
6. **Build-once promotion.** Select an explicit candidate by immutable
   artifact ID/digest and candidate ID, verify manifest/hashes/source/evidence,
   and publish without compiling. Handle reruns, cancellation, concurrency and
   partial drafts.
7. **Provenance and attestations.** Use GitHub-native artifact attestations
   for candidate packages and SBOMs, retain offline verification bundles, and
   verify repository, workflow identity, source commit/ref and subject
   digests. Test both acceptance and rejection.
8. **SBOM.** Produce an SPDX 2.3 SBOM that accurately lists distributed
   files/components, package dependencies, licensing, kernel-module binary
   provenance, and explicit source-to-binary limitations. Distinguish image
   dependencies from release components.
9. **Debian metadata validation.** Validate `.buildinfo` and `.changes`
   against source/version/architecture/artifact hashes/build dependencies.
   Add positive and negative tests; do not require independent builds to
   produce byte-identical metadata.
10. **Publication authorization.** Fail closed on environment approval,
    repository enablement, exact candidate identity, tag/source binding,
    immutable-release readiness and explicit confirmation. Use draft-first,
    verify-before-publish, and resumable recovery.
11. **Independent release verification.** Preserve historical release
    compatibility; fail closed for canonical releases. Verify downloaded
    release assets, not local build output. Classify legacy, canonical
    (provenance-attested after `canonicalFrom`) and immutable releases.
12. **Security auditing.** Add scheduled/manual online zizmor auditing while
    keeping ordinary offline workflow checks deterministic. Document
    dependency update procedures.
13. **End-to-end qualification.** Exercise the complete candidate lifecycle
    without creating a release, including adversarial cases and actual GitHub
    Actions runs.
14. **Hardware boundary.** Record hardware qualification status without
    claiming unavailable evidence. Do not access production hardware.
15. **Deliverables.** A review-ready draft PR and
    `docs/trusted-release-lifecycle.md` with architecture, evidence, risks and
    maintainer activation decisions.
16. **Cross-project reuse.** Identify reusable interfaces for the IPv6 SADR
    project without modifying that repository or creating a premature shared
    framework.

## Non-goals / prohibitions

- No production release, no new product version, no tag move, no historical
  asset change.
- No GHCR image publication or permanent image permission activation.
- No immutable-release activation, signed-tag creation, signing keys, or
  repository settings changes.
- No kernel-module recompilation or replacement.
- No production EdgeRouter access; no SADR repository modification.
- No merge to `main` without maintainer approval.

## Acceptance criteria

- All new scripts and tests pass locally; the existing suite remains green.
- At least one actual GitHub Actions branch run builds a non-release candidate,
  creates provenance/SBOM attestations, verifies them, and exercises the
  dry-run promotion path. A production candidate is accepted only when the
  run is on `main` at the exact source commit A, so the attestation's
  source-digest/source-ref equal A/`refs/heads/main`; branch candidates are
  `nonRelease: true` and cannot be promoted.
- Canonical releases require a valid provenance attestation, not merely a
  manifest; `--fixture` is local-only.
- The canonical verifier rejects tampering, missing evidence, wrong source or
  workflow identity, wrong environment digest, unauthorized promotion, and
  historical version reuse; historical v0.1–v0.3 releases still verify.
- The full lifecycle can be executed without mutating a GitHub Release.
- The engineering report records what was and was not executed, and lists the
  exact maintainer decisions required before production activation.
