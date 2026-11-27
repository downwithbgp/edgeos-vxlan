#!/bin/bash
# Verify a constructed release candidate without trusting its manifest.
#
# Checks identity, qualification status, artifact sizes/hashes, source and
# workflow binding, Debian version/tag agreement, hardware claims, and the
# package-only SHA256SUMS. Attestation verification is a separate step.
#
# Usage:
#   validate-candidate.sh --candidate-dir DIR [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

DIR=
SOURCE_ROOT=$ROOT
REV=
PRODUCTION=no
RELEASE=no
LATEST_VERSION=
PUBLISHED_ASSETS=no

usage()
{
    cat <<'EOF'
Usage: validate-candidate.sh --candidate-dir DIR [options]

Options:
  --candidate-dir DIR   Directory containing release-candidate.json
  --source-root DIR     Git source tree used to recompute packaging inputs
  --rev REV             Source commit expected in the manifest
  --production          Enforce production-only rules (nonRelease=false,
                        main ref, exact workflow/source commit, newer version)
  --release             Enforce release rules (nonRelease=false, main ref,
                        exact workflow/source commit; allow re-verification)
  --latest-version V    Latest published version for production version reuse
  --published-assets    Verify a published release asset set: the raw evidence
                        directory is not published, so presence and file hashes
                        are not recomputed; the attested manifest still binds
                        them and the IPv6 block is fully validated.
  -h, --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --candidate-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            DIR=$2
            shift 2
            ;;
        --source-root)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_ROOT=$2
            shift 2
            ;;
        --rev)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            REV=$2
            shift 2
            ;;
        --production)
            PRODUCTION=yes
            shift
            ;;
        --release)
            RELEASE=yes
            shift
            ;;
        --latest-version)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            LATEST_VERSION=$2
            shift 2
            ;;
        --published-assets)
            PUBLISHED_ASSETS=yes
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$DIR" ] || { usage >&2; exit 2; }
if [ "$PUBLISHED_ASSETS" = "yes" ] && [ "$RELEASE" != "yes" ]; then
    fail "--published-assets is only valid with --release"
fi
require_cmd jq sha256sum find sort awk sed cmp
require_dir "$DIR"
MANIFEST=$DIR/release-candidate.json
require_file "$MANIFEST"
require_file "$ROOT/release/release-policy.json"
python3 "$ROOT/scripts/validate-candidate-schema.py" \
    --manifest "$MANIFEST" \
    --schema "$ROOT/release/candidate-schema.json" >/dev/null ||
    fail "candidate manifest does not satisfy the schema"

POLICY=$ROOT/release/release-policy.json
check_candidate_id "$MANIFEST"
check_build_identity "$MANIFEST"

[ "$(manifest_get "$MANIFEST" '.schemaVersion')" = \
  "https://edgeos-vxlan.dev/release-candidate/v1" ] ||
    fail "unsupported candidate schemaVersion"

STATUS=$(manifest_get "$MANIFEST" '.candidate.status')
QUAL_STATUS=$(manifest_get "$MANIFEST" '.qualification.status')
NON_RELEASE=$(manifest_get "$MANIFEST" '.candidate.nonRelease')
[ "$STATUS" = "qualified" ] || fail "candidate status is not qualified: $STATUS"
[ "$QUAL_STATUS" = "passed" ] || fail "qualification status is not passed: $QUAL_STATUS"

[ "$(manifest_get "$MANIFEST" '.project.name')" = \
  "$(jq -r '.project.name' "$POLICY")" ] || fail "project name mismatch"
[ "$(manifest_get "$MANIFEST" '.project.repository')" = \
  "$(jq -r '.project.repository' "$POLICY")" ] || fail "project repository mismatch"
[ "$(manifest_get "$MANIFEST" '.project.repositoryId')" = \
  "$(jq -r '.project.repositoryId' "$POLICY")" ] || fail "repository ID mismatch"

TAG=$(manifest_get "$MANIFEST" '.project.releaseTag')
PKG_VERSION=$(manifest_get "$MANIFEST" '.project.packageVersion')
is_release_tag "$TAG" || fail "invalid release tag: $TAG"
VERSION=${PKG_VERSION%%+*}
[ "${TAG#v}" = "$VERSION" ] ||
    fail "tag $TAG does not match package version $PKG_VERSION"

EPOCH=$(manifest_get "$MANIFEST" '.project.sourceDateEpoch')
case "$EPOCH" in
    ''|*[!0-9]*) fail "sourceDateEpoch is not an integer: $EPOCH" ;;
esac

SOURCE_COMMIT=$(manifest_get "$MANIFEST" '.source.commit')
require_commit_field "source commit" "$SOURCE_COMMIT"
require_sha256_field "source archive" "$(manifest_get "$MANIFEST" '.source.archiveSha256')"
require_sha256_field "packaging inputs" "$(manifest_get "$MANIFEST" '.source.packagingInputsSha256')"

WORKFLOW_REPO=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.repository')
WORKFLOW_PATH=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.path')
WORKFLOW_REF=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.ref')
WORKFLOW_COMMIT=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.commit')
[ "$WORKFLOW_REPO" = "$(jq -r '.project.repository' "$POLICY")" ] ||
    fail "trusted workflow repository mismatch: $WORKFLOW_REPO"
[ "$WORKFLOW_PATH" = "$(jq -r '.attestation.workflowPath' "$POLICY")" ] ||
    fail "trusted workflow path mismatch: $WORKFLOW_PATH"
is_commit "$WORKFLOW_COMMIT" || fail "invalid trusted workflow commit: $WORKFLOW_COMMIT"

if [ "$PRODUCTION" = "yes" ] || [ "$RELEASE" = "yes" ]; then
    [ "$NON_RELEASE" = "false" ] || fail "release candidate is marked nonRelease"
    [ "$WORKFLOW_REF" = "refs/heads/main" ] ||
        fail "release candidate workflow ref is not refs/heads/main: $WORKFLOW_REF"
    [ "$WORKFLOW_COMMIT" = "$SOURCE_COMMIT" ] ||
        fail "release candidate workflow commit != source commit"
    if [ "$PRODUCTION" = "yes" ]; then
        if [ -z "$LATEST_VERSION" ]; then
            LATEST_VERSION=$(jq -r '.release.baselinePublishedVersion' "$POLICY")
        fi
        dpkg --compare-versions "$VERSION" gt "$LATEST_VERSION" ||
            fail "candidate version $VERSION is not newer than published $LATEST_VERSION"
    fi
else
    [ "$NON_RELEASE" = "true" ] ||
        note "non-production validation of a nonRelease=false candidate"
fi

for field in ociIndexDigest manifestDigest configDigest; do
    require_digest_field "$field" "$(manifest_get "$MANIFEST" ".buildEnvironment.$field")"
done
for field in ociArchiveSha256 dockerfileSha256 caBundleSha256 \
             dependencyInventorySha256 qualificationSha256 imageSbomSha256; do
    require_sha256_field "$field" "$(manifest_get "$MANIFEST" ".buildEnvironment.$field")"
done

[ "$(manifest_get "$MANIFEST" '.build.reproducibility.status')" = "passed" ] ||
    fail "candidate reproducibility status is not passed"
[ "$(jq '.build.reproducibility.comparedArtifacts | length' "$MANIFEST")" -gt 0 ] ||
    fail "candidate reproducibility records no compared artifacts"
[ "$(manifest_get "$MANIFEST" '.qualification.hardware.required')" = "true" ] &&
    [ "$(manifest_get "$MANIFEST" '.qualification.hardware.status')" = "qualified" ] ||
    [ "$(manifest_get "$MANIFEST" '.qualification.hardware.required')" = "false" ] ||
    fail "hardware qualification is required but not qualified"
if [ "$(manifest_get "$MANIFEST" '.qualification.hardware.status')" = "qualified" ]; then
    [ "$(jq '.qualification.hardware.evidence | length' "$MANIFEST")" -gt 0 ] ||
        fail "hardware status is qualified but no evidence is recorded"
fi

[ "$(jq '.limitations | length' "$MANIFEST")" -gt 0 ] ||
    fail "candidate has no explicit limitations"

POLICY_SHA=$(sha256_file "$POLICY")
[ "$POLICY_SHA" = "$(manifest_get "$MANIFEST" '.project.releasePolicySha256')" ] ||
    fail "release-policy hash does not match the manifest"
if [ -f "$DIR/source.tar" ]; then
    [ "$(sha256_file "$DIR/source.tar")" = \
      "$(manifest_get "$MANIFEST" '.source.archiveSha256')" ] ||
        fail "source archive hash does not match the manifest"
fi

# Every qualification check must have passed; an empty list proves nothing.
[ "$(jq '.qualification.checks | length' "$MANIFEST")" -gt 0 ] ||
    fail "candidate records no qualification checks"
if jq -e '.qualification.checks[] | select(.status != "passed")' "$MANIFEST" >/dev/null; then
    fail "one or more qualification checks did not pass"
fi

NAMES=$(mktemp "${TMPDIR:-/tmp}/edgeos-vxlan-artifact-names.XXXXXX") ||
    fail "cannot create temporary artifact-name list"
trap 'rm -f "$NAMES"' EXIT HUP INT TERM
jq -r '.artifacts[].name' "$MANIFEST" | LC_ALL=C sort > "$NAMES"
duplicates=$(LC_ALL=C uniq -d "$NAMES")
[ -z "$duplicates" ] || fail "duplicate artifact names: $duplicates"

while IFS=$'\t' read -r name size sha role; do
    validate_artifact_name "$name"
    require_sha256_field "artifact $name" "$sha"
    case "$role" in
        package|debian-metadata|sbom|environment-qualification) ;;
        *) fail "invalid artifact role for $name: $role" ;;
    esac
    [ -f "$DIR/$name" ] || fail "artifact file is missing: $name"
    actual_size=$(stat -c '%s' "$DIR/$name")
    [ "$actual_size" = "$size" ] ||
        fail "artifact size mismatch for $name: $actual_size != $size"
    actual_sha=$(sha256_file "$DIR/$name")
    [ "$actual_sha" = "$sha" ] ||
        fail "artifact hash mismatch for $name: $actual_sha != $sha"
done < <(jq -r '.artifacts[] | [.name, .size, .sha256, .role] | @tsv' "$MANIFEST")

INTEGRATION="edgeos-vxlan_${PKG_VERSION}_all.deb"
KMOD="edgeos-vxlan-kmod_${PKG_VERSION}_mipsel.deb"
BUILDINFO="edgeos-vxlan_${PKG_VERSION}_mipsel.buildinfo"
CHANGES="edgeos-vxlan_${PKG_VERSION}_mipsel.changes"
for required in "$INTEGRATION" "$KMOD" "$BUILDINFO" "$CHANGES" \
    sbom-edgeos-vxlan.spdx.json sbom-edgeos-vxlan-kmod.spdx.json \
    build-environment-qualification.json; do
    grep -Fx "$required" "$NAMES" >/dev/null ||
        fail "candidate is missing required artifact: $required"
done

for spec in "$INTEGRATION:package" "$KMOD:package" \
    "$BUILDINFO:debian-metadata" "$CHANGES:debian-metadata" \
    "sbom-edgeos-vxlan.spdx.json:sbom" \
    "sbom-edgeos-vxlan-kmod.spdx.json:sbom" \
    "build-environment-qualification.json:environment-qualification"; do
    name=${spec%:*}
    role=${spec##*:}
    actual=$(jq -r --arg n "$name" '.artifacts[] | select(.name == $n) | .role' "$MANIFEST")
    [ "$actual" = "$role" ] ||
        fail "artifact $name has role $actual, expected $role"
done

[ "$(sha256_file "$DIR/build-environment-qualification.json")" = \
  "$(manifest_get "$MANIFEST" '.buildEnvironment.qualificationSha256')" ] ||
    fail "environment qualification hash does not match the manifest"

if [ -f "$DIR/build-environment-image.spdx.json" ]; then
    [ "$(sha256_file "$DIR/build-environment-image.spdx.json")" = \
      "$(manifest_get "$MANIFEST" '.buildEnvironment.imageSbomSha256')" ] ||
        fail "image SBOM hash does not match the manifest"
fi

# SHA256SUMS is package-only for historical/installer compatibility.
SUMS=$DIR/SHA256SUMS
require_file "$SUMS"
[ "$(wc -l < "$SUMS")" -eq 2 ] || fail "SHA256SUMS must contain exactly two packages"
grep -Fx "$(sha256_file "$DIR/$INTEGRATION")  $INTEGRATION" "$SUMS" >/dev/null ||
    fail "SHA256SUMS is missing the integration package"
grep -Fx "$(sha256_file "$DIR/$KMOD")  $KMOD" "$SUMS" >/dev/null ||
    fail "SHA256SUMS is missing the kernel-module package"
( cd "$DIR" && sha256sum --strict --quiet -c SHA256SUMS ) >/dev/null ||
    fail "SHA256SUMS verification failed"

# --- IPv6-only qualification evidence --------------------------------------
# The four required checks, their retained evidence bytes, the build identity
# and the workflow provenance are all verified here. Any mismatch rejects the
# candidate; a permitted skip or workaround is checked against an explicit
# allow-list rather than accepted from the manifest.
REQUIRED_IPV6_CHECKS="ipv6-only-isolation ipv6-only-dataplane ipv6-only-capture ipv6-only-reconciler"
ALLOWED_IPV6_SKIPS="host-global-ipv6-escape-unavailable iproute2-json-normalization"
ALLOWED_IPV6_WORKAROUNDS="iproute2-json-normalization"

[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.status')" = "passed" ] ||
    fail "IPv6-only qualification status is not passed"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.level')" = "B" ] ||
    fail "IPv6-only qualification level is not B"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.buildIdentity')" = \
  "$(manifest_get "$MANIFEST" '.build.identity')" ] ||
    fail "IPv6 qualification build identity does not match the candidate build identity"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.sourceCommit')" = \
  "$(manifest_get "$MANIFEST" '.source.commit')" ] ||
    fail "IPv6 qualification source commit does not match the candidate source commit"

IPV6_PACKAGE=$(manifest_get "$MANIFEST" '.qualification.ipv6.package')
[ "$IPV6_PACKAGE" = "edgeos-vxlan_${PKG_VERSION}_all.deb" ] ||
    fail "IPv6 qualification package $IPV6_PACKAGE is not the candidate integration package"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.packageSha256')" = \
  "$(sha256_file "$DIR/$IPV6_PACKAGE")" ] ||
    fail "IPv6 qualification package hash does not match the candidate integration package"
for field in reconcilerSha256 addrHelperSha256; do
    require_sha256_field "IPv6 $field" "$(manifest_get "$MANIFEST" ".qualification.ipv6.$field")"
done

WF_PATH=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.path')
WF_REF=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.ref')
WF_COMMIT=$(manifest_get "$MANIFEST" '.source.trustedWorkflow.commit')
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.path')" = "$WF_PATH" ] ||
    fail "IPv6 qualification workflow path does not match the trusted workflow path"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.ref')" = "$WF_REF" ] ||
    fail "IPv6 qualification workflow ref does not match the trusted workflow ref"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.commit')" = "$WF_COMMIT" ] ||
    fail "IPv6 qualification workflow commit does not match the trusted workflow commit"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.repository')" = \
  "$(manifest_get "$MANIFEST" '.project.repository')" ] ||
    fail "IPv6 qualification workflow repository does not match the project repository"
RUN_ID=$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.runId')
RUN_ATTEMPT=$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.runAttempt')
printf '%s' "$RUN_ID" | grep -Eq '^[0-9]+$' ||
    fail "IPv6 qualification workflow run ID is not numeric: $RUN_ID"
printf '%s' "$RUN_ATTEMPT" | grep -Eq '^[0-9]+$' ||
    fail "IPv6 qualification workflow run attempt is not numeric: $RUN_ATTEMPT"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.harness.path')" = \
  "test/ipv6-only-netns.sh" ] ||
    fail "IPv6 qualification harness path is not the repository harness"
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.harness.commit')" = "$WF_COMMIT" ] ||
    fail "IPv6 qualification harness commit does not match the trusted workflow commit"

[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.evidence.dir')" = \
  "qualification/ipv6-only" ] ||
    fail "IPv6 qualification evidence directory is not qualification/ipv6-only"
IPV6_EVIDENCE=$DIR/qualification/ipv6-only
if [ "$PUBLISHED_ASSETS" = "yes" ] && [ -e "$IPV6_EVIDENCE" ]; then
    fail "--published-assets is not valid when the raw evidence directory is present"
fi
if [ "$PUBLISHED_ASSETS" = "no" ]; then
    require_dir "$IPV6_EVIDENCE"
    require_file "$IPV6_EVIDENCE/summary.json"
    [ "$(sha256_file "$IPV6_EVIDENCE/summary.json")" = \
      "$(manifest_get "$MANIFEST" '.qualification.ipv6.evidence.summarySha256')" ] ||
        fail "retained IPv6 qualification summary hash does not match the manifest"

    # The manifest's self-reported evidence identity must agree with the
    # retained summary. The finalize stage independently bound the summary to
    # the workflow environment; this cross-check prevents a manifest that
    # claims provenance the evidence does not carry.
    SUMMARY=$IPV6_EVIDENCE/summary.json
    check_summary_field()
    {
        _field=$1 _expected=$2
        _actual=$(jq -r "$_field // empty" "$SUMMARY")
        [ "$_actual" = "$_expected" ] ||
            fail "IPv6 evidence $_field ($_actual) does not match the manifest ($_expected)"
    }
    check_summary_field '.workflow.runId' \
        "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.runId')"
    check_summary_field '.workflow.runAttempt' \
        "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.runAttempt')"
    check_summary_field '.workflow.ref' \
        "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.ref')"
    check_summary_field '.workflow.commit' \
        "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.commit')"
    check_summary_field '.harness.commit' \
        "$(manifest_get "$MANIFEST" '.qualification.ipv6.harness.commit')"
    check_summary_field '.candidate.buildIdentity' \
        "$(manifest_get "$MANIFEST" '.qualification.ipv6.buildIdentity')"
    check_summary_field '.candidate.packageSha256' \
        "$(manifest_get "$MANIFEST" '.qualification.ipv6.packageSha256')"
    check_summary_field '.candidate.sourceCommit' \
        "$(manifest_get "$MANIFEST" '.qualification.ipv6.sourceCommit')"

    # The manifest's pass/fail claims are copies. Enforce the retained summary
    # itself with the canonical validator: result, fail count, required check
    # statuses, capture and reconciler execution, and the declared
    # skips/workarounds are all checked against the evidence bytes.
    python3 "$ROOT/scripts/validate-ipv6-qualification-evidence.py" \
        --summary "$SUMMARY" \
        --evidence-dir "$IPV6_EVIDENCE" \
        --expected-source-commit "$SOURCE_COMMIT" \
        --expected-build-identity "$(manifest_get "$MANIFEST" '.build.identity')" \
        --expected-package-sha256 "$(manifest_get "$MANIFEST" '.qualification.ipv6.packageSha256')" \
        --expected-workflow-run-id "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.runId')" \
        --expected-workflow-run-attempt "$(manifest_get "$MANIFEST" '.qualification.ipv6.workflow.runAttempt')" \
        --require-workflow-binding \
        --require-package-execution \
        --allow-skip host-global-ipv6-escape-unavailable \
        --allow-skip iproute2-json-normalization \
        --allow-workaround iproute2-json-normalization >/dev/null ||
        fail "retained IPv6 qualification evidence does not validate"
fi

for check_id in $REQUIRED_IPV6_CHECKS; do
    entry=$(jq -c --arg id "$check_id" \
        '[.qualification.checks[] | select(.id == $id)]' "$MANIFEST")
    [ "$(jq 'length' <<<"$entry")" -eq 1 ] ||
        fail "required IPv6 qualification check $check_id must appear exactly once"
    [ "$(jq -r '.[0].status' <<<"$entry")" = "passed" ] ||
        fail "required IPv6 qualification check $check_id did not pass"
    file=$(jq -r '.[0].evidenceFile // empty' <<<"$entry")
    [ -n "$file" ] || fail "check $check_id records no evidence file"
    validate_relative_path "$file"
    require_sha256_field "$check_id evidence" "$(jq -r '.[0].evidenceSha256' <<<"$entry")"
    if [ "$PUBLISHED_ASSETS" = "no" ]; then
        require_file "$IPV6_EVIDENCE/$file"
        [ "$(sha256_file "$IPV6_EVIDENCE/$file")" = \
          "$(jq -r '.[0].evidenceSha256' <<<"$entry")" ] ||
            fail "retained evidence for $check_id does not match the manifest"
    fi
done

for field in underlay overlay analysis; do
    sha=$(manifest_get "$MANIFEST" ".qualification.ipv6.capture.${field}Sha256")
    require_sha256_field "IPv6 capture $field" "$sha"
done
[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.capture.status')" = "executed" ] ||
    fail "IPv6 qualification capture did not execute"
if [ "$PUBLISHED_ASSETS" = "no" ]; then
    for field in underlay overlay; do
        require_file "$IPV6_EVIDENCE/captures/$field.pcap"
        [ "$(sha256_file "$IPV6_EVIDENCE/captures/$field.pcap")" = \
          "$(manifest_get "$MANIFEST" ".qualification.ipv6.capture.${field}Sha256")" ] ||
            fail "retained IPv6 $field capture hash does not match the manifest"
    done
    require_file "$IPV6_EVIDENCE/captures/analysis.txt"
    [ "$(sha256_file "$IPV6_EVIDENCE/captures/analysis.txt")" = \
      "$(manifest_get "$MANIFEST" '.qualification.ipv6.capture.analysisSha256')" ] ||
        fail "retained IPv6 capture analysis hash does not match the manifest"
fi

[ "$(manifest_get "$MANIFEST" '.qualification.ipv6.reconciler.status')" = "executed" ] ||
    fail "IPv6 qualification reconciler path did not execute"
if [ "$PUBLISHED_ASSETS" = "no" ]; then
    require_file "$IPV6_EVIDENCE/reconciler-evidence.txt"
    [ "$(sha256_file "$IPV6_EVIDENCE/reconciler-evidence.txt")" = \
      "$(manifest_get "$MANIFEST" '.qualification.ipv6.reconciler.evidenceSha256')" ] ||
        fail "retained IPv6 reconciler evidence hash does not match the manifest"
fi

while IFS= read -r skip; do
    [ -n "$skip" ] || continue
    case " $ALLOWED_IPV6_SKIPS " in
        *" $skip "*) ;;
        *) fail "candidate declares an unpermitted IPv6 skip: $skip" ;;
    esac
done < <(jq -r '.qualification.ipv6.skips[]' "$MANIFEST")
while IFS= read -r workaround; do
    [ -n "$workaround" ] || continue
    case " $ALLOWED_IPV6_WORKAROUNDS " in
        *" $workaround "*) ;;
        *) fail "candidate declares an unpermitted IPv6 workaround: $workaround" ;;
    esac
done < <(jq -r '.qualification.ipv6.workarounds[].id' "$MANIFEST")


# No unexpected top-level files. qualification/ holds logs and reproducibility
# evidence; source.tar is the exact materialized input. promotion-plan.json and
# promotion-verification.json are trusted promote-time transients: they are
# written into the candidate directory by scripts/promote-release.sh, are not
# release assets, and are not covered by the candidate identity.
ALLOWED="release-candidate.json
SHA256SUMS
source.tar
release-attestation.jsonl
promotion-plan.json
promotion-verification.json
$INTEGRATION
$KMOD
$BUILDINFO
$CHANGES
sbom-edgeos-vxlan.spdx.json
sbom-edgeos-vxlan-kmod.spdx.json
build-environment-qualification.json
build-environment-image.spdx.json"
while IFS= read -r entry; do
    case "$entry" in
        qualification) continue ;;
    esac
    if ! printf '%s\n' "$ALLOWED" | grep -Fx "$entry" >/dev/null; then
        fail "unexpected candidate file: $entry"
    fi
done < <(find "$DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)

if [ -n "$REV" ] && [ -e "$SOURCE_ROOT/.git" ]; then
    actual_commit=$(git -C "$SOURCE_ROOT" rev-parse --verify --quiet "${REV}^{commit}") ||
        fail "cannot resolve source revision: $REV"
    [ "$actual_commit" = "$SOURCE_COMMIT" ] ||
        fail "source commit $SOURCE_COMMIT does not match $actual_commit"
    actual_inputs=$("$ROOT/scripts/packaging-inputs.sh" \
        --repo "$SOURCE_ROOT" --rev "$actual_commit") ||
        fail "cannot compute packaging inputs"
    [ "$actual_inputs" = "$(manifest_get "$MANIFEST" '.source.packagingInputsSha256')" ] ||
        fail "packaging-inputs digest does not match the source tree"
elif [ -n "$REV" ]; then
    fail "source root is not a Git checkout; cannot recompute packaging inputs"
fi

echo "Candidate validation: PASS"
echo "Candidate ID:        $(manifest_get "$MANIFEST" '.candidate.id')"
echo "Tag:                 $TAG"
echo "Package version:     $PKG_VERSION"
echo "Source commit:       $SOURCE_COMMIT"
echo "Non-release:         $NON_RELEASE"
