# Release activation runbook

**Status:** procedure only. Nothing in this document has been applied. Phase III
delivers the lifecycle; it does not grant it operational authority.

This runbook is the exact sequence a maintainer follows to activate and to
operate the trusted release lifecycle. It separates settings the workflow can
enforce from settings only a maintainer can confirm, because the second class is
where an activation mistake is invisible to CI.

Repository: `downwithbgp/edgeos-vxlan`. Workflow definitions:
`.github/workflows/release.yml` (release), `.github/workflows/build-environment.yml`
(image), `.github/workflows/verify-release.yml` (independent verification).

## 1. Settings the workflow cannot verify

These are repository or organisation settings. The workflow relies on them but
cannot prove them; each must be confirmed by hand and re-confirmed after any
administrative change.

| Setting | Required state | Why the workflow cannot verify it |
|---|---|---|
| Branch protection on `main` | Required status checks from `ci.yml`; no force-push; no deletion; linear history preferred | The workflow only sees the ref it runs on, not the protection rules |
| Tag protection | Rule matching `v*`: creation, update and deletion restricted to the maintainer | The workflow re-resolves the tag and refuses a moved/conflicting one, but cannot stop the move |
| `release-publication` environment | Created, required reviewers ≥ 1, deployment branches limited to `main` and `v*` | The job asserts the environment *name*; protection is a repository setting |
| `build-image-publication` environment | Created, required reviewers ≥ 1, deployment branches limited to `main` | Same |
| Immutable releases | Enabled for the repository before `IMMUTABLE_RELEASES_CONFIRMED=true` is set | The `immutable` flag is read only *after* publication |
| Actions permissions | Default `contents: read`; workflows declare their own | Visibility only |
| Administrator bypass | Understood and accepted: an administrator can bypass branch, tag and environment protection | Not observable from a workflow |

Self-review is permitted for this single-maintainer project. Required-reviewer
protection with self-review enabled is **not** independent two-person approval;
the runbook and the report must not describe it as such.

## 2. Enablement variables

Both enablement variables must be scoped to their **protected environment**, not
set as ordinary repository-wide variables. A job that declares
`environment: <name>` resolves `vars.<NAME>` to the environment-scoped value
when one exists, so an environment-scoped variable keeps the control inside the
protection boundary.

| Variable | Scope | Required value | Read by |
|---|---|---|---|
| `RELEASE_PUBLICATION_ENABLED` | environment `release-publication` | `true` | `release.yml` publish job |
| `IMMUTABLE_RELEASES_CONFIRMED` | environment `release-publication` | `true`, only after immutable releases are enabled and verified | `release.yml` publish job → `check-release-gates.sh` |
| `BUILD_IMAGE_PUBLICATION_ENABLED` | environment `build-image-publication` | `true` | `build-environment.yml` publish job |

`IMMUTABLE_RELEASES_ADMIN_TOKEN` must **not** exist anywhere: the gate fails
closed if it is set, because the publication path deliberately has no broad
administrative credential.

Confirmation values and names are policy-driven, not hardcoded: see
`release/release-policy.json` `.publication.environment`,
`.publication.enableVariable`, `.publication.immutableConfirmedVariable`,
`.publication.confirmValue` (currently `PUBLISH`), and `.image.registry` /
`.image.repository`. `test/unit-release-policy.sh` fails if the gates stop
reading them from policy or if an unimplemented key is added.

## 3. Activation sequence

Do these in order. Do not run step 8 and 9 in the same session as steps 1–7.

1. **Merge the lifecycle to `main`.** Confirm the post-merge `ci.yml` run is
   green on `main` before continuing.
2. **Protect `main`.** Required checks: the `ci.yml` jobs. Disable force-push
   and deletion.
3. **Protect tags.** Rule for `v*` restricting creation, update and deletion to
   the maintainer.
4. **Create the environments.** `release-publication` and
   `build-image-publication`, each with a required reviewer and deployments
   restricted to `main` (and `v*` for the release environment). Enable
   self-review only because this is a single-maintainer project.
5. **Enable immutable releases** for the repository, then verify the setting by
   reading it back. Do not set `IMMUTABLE_RELEASES_CONFIRMED` yet.
6. **Add the environment-scoped variables** from section 2, with the values
   shown. `RELEASE_PUBLICATION_ENABLED` and
   `IMMUTABLE_RELEASES_CONFIRMED` go on `release-publication`;
   `BUILD_IMAGE_PUBLICATION_ENABLED` goes on `build-image-publication`.
7. **Record the activation decision.** Add the date, the head SHA, the reviewer
   and the confirmed settings to `docs/trusted-release-lifecycle.md`. Stages 4–6
   of section 11.1 are still unexercised at this point.
8. **First canonical release** — follow section 4.
9. **First GHCR publication**, if and when approved — follow section 5.

## 4. Candidate selection and approval (per release)

1. Choose the source commit A on `main`. It must be the commit that was built.
2. Run the **Trusted release** workflow from `main` with `mode=candidate`,
   `source_commit=<A>`, `release_tag=v<version>`, and the qualified image
   artifact ID, digest, run ID, manifest digest, config digest and qualification
   hash. Record the candidate ID, manifest SHA-256, artifact ID and artifact
   digest from the run.
3. Confirm the candidate run is green, including attestation verification.
4. Create tag `v<version>` at the pin commit B, whose `install.sh` and
   `SHA256SUMS` match the candidate and whose packaging inputs are identical to
   A. Tag creation is a maintainer action; the workflow never creates it.
5. Run **Trusted release** from `main` with `mode=promote`, `dry_run=true`, and
   the candidate identity. This is the production preflight (stage 4). Record
   `promotion-verification.json`.
6. Approve and run with `dry_run=false`, `confirm_publish=PUBLISH`. The
   `release-publication` environment requires explicit human approval. This is
   stage 5.
7. The `post-publish-verify` job then runs independently with read-only
   permissions (stage 6). Do not treat stage 5 as complete until stage 6 is
   green.

## 5. GHCR staging and promotion

The image is not published by this workstream. When it is approved:

1. Dispatch **Build environment** from `main` with `publish_image=true`.
2. The publish job pushes under `staging-<run_id>-<run_attempt>`, verifies the
   remotely stored digest against the qualified manifest, refuses to replace an
   existing `<sha>` tag that resolves elsewhere, promotes exactly the verified
   digest to the `<sha>` tag, re-reads it, and deletes the staging tag.
3. Record the promoted digest. The staging tag must not exist afterwards.
4. Visibility and retention are repository/registry settings, not workflow
   settings: private visibility is the default assumption; retention follows the
   package settings for the repository.

## 6. Emergency disable

Any one of these stops publication; do them in this order, fastest first.

1. **Remove the environment variable.** Delete `RELEASE_PUBLICATION_ENABLED`
   (or set it to `false`) in `release-publication`. The gate fails closed on the
   next run. Do the same for `BUILD_IMAGE_PUBLICATION_ENABLED` in
   `build-image-publication`.
2. **Restrict the environment.** Remove all reviewers or set the deployment
   branch policy to a non-existent branch so approval cannot be granted.
3. **Disable the workflow** in the Actions UI if a run is in flight.
4. **Revoke the tag protection exception** — remove the maintainer from the tag
   rule if tag authority itself is in question.

Emergency disable does **not** unpublish anything. A published release stays
published; only a new version supersedes it.

## 7. Failed publication recovery

The publish path is draft-first and resumable, so most failures are fixed by
re-running the same dispatch.

| Failure point | State left behind | Recovery |
|---|---|---|
| Before draft creation | No release | Correct the cause and re-run the same dispatch |
| During asset upload | Draft with a subset of assets | Re-run with the same candidate identity; matching assets are skipped, missing ones are uploaded, and a conflicting asset aborts |
| Draft has an unexpected asset | Draft with surplus | Delete the surplus asset by hand, then re-run; the workflow refuses to clobber |
| Draft verification fails | Draft, unverified | Do not promote by hand. Fix the evidence or rebuild the candidate; the draft is safe to delete and recreate |
| `PATCH draft=false` fails | Draft | Re-run; the release is found as a draft and re-verified |
| Tag moved or deleted after preflight | Nothing published, or a release on a moved tag | Restore the tag to the preflight commit, or abandon the version and rebuild. Never hand-edit the release to point elsewhere |
| Published but not immutable | **Published, mutable** | This is the failure the design cannot undo. Record it, disable publication, and either enable immutable releases and supersede with a new version, or accept the mutable release explicitly. Do not describe it as immutable |

## 8. Post-publication verification failure

The `post-publish-verify` job runs with read-only permissions after a successful
`publish`. A red result means the release exists but does not verify.

1. Treat the release as suspect immediately; it is already public.
2. Re-run `verify-release.yml` by dispatch with the tag to confirm the failure is
   reproducible, not a transient tooling issue.
3. If it reproduces: mark the release as a pre-release in the UI (to stop
   it being the "latest"), document the failure, and supersede the version. No
   workflow in this repository deletes or edits a published release.
4. Record the incident and the superseding version in the engineering report.

## 9. First canonical release acceptance criteria

All must hold before the first canonical release is called accepted:

- Candidate run green: build A/B identical, artifact contract, Debian metadata,
  SBOM generation and validation, real attestations, offline verification with
  the wrong-source-ref negative control.
- Candidate ID, manifest SHA-256, artifact ID and artifact digest recorded.
- Tag commit B verified: A is an ancestor, packaging inputs identical,
  `install.sh` differs only in its four pins, `SHA256SUMS` matches the candidate.
- Production preflight (stage 4) green with `promotion-verification.json`
  recorded.
- Privileged publication (stage 5) approved through the protected environment and
  green.
- Post-publication verification (stage 6) green in its own read-only job.
- Immutable flag confirmed true after publication.
- No unresolved critical vulnerability, or an explicit artifact-bound exception
  with a stated expiry.
- Hardware scope statement recorded (required / not required, with evidence
  class).
- No SLSA level or certification claim made.

## 10. What this runbook deliberately does not do

- It does not create releases, move tags, enable environments or set variables.
- It does not claim that a mocked publication test is evidence of publication.
- It does not grant a backport or maintenance-branch exception. Any such
  exception requires a separate, explicitly reviewed change to
  `scripts/check-version-eligibility.sh`; there is no bypass flag.
- It does not describe self-review as independent two-person approval.
