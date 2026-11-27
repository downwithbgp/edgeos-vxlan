#!/bin/bash
# Build, qualify and describe one release candidate.
#
# The distribution build is built once inside the qualified environment; a
# second build is compared but never shipped. The candidate manifest binds the
# exact source archive, environment digests, artifacts, SBOMs and
# qualification evidence under a canonical candidate ID.
#
# Usage:
#   build-release-candidate.sh --stage build|finalize [options]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

REPO=$ROOT
SOURCE_REF=HEAD
OUTPUT_DIR=
IMAGE_DIR=
PRODUCTION=no
RELEASE_TAG=
WORKFLOW_REF=${GITHUB_REF:-refs/heads/ci/trusted-release-lifecycle}
WORKFLOW_COMMIT=${GITHUB_SHA:-}
EXPECTED_SOURCE_COMMIT=
EXPECTED_WORKFLOW_COMMIT=
EXPECTED_IMAGE_MANIFEST_DIGEST=
EXPECTED_IMAGE_CONFIG_DIGEST=
EXPECTED_IMAGE_QUALIFICATION_SHA256=
STAGE=
IPV6_EVIDENCE_DIR=
EXPECTED_WORKFLOW_RUN_ID=${GITHUB_RUN_ID:-}
EXPECTED_WORKFLOW_RUN_ATTEMPT=${GITHUB_RUN_ATTEMPT:-}
EXPECTED_WORKFLOW_PATH=${GITHUB_WORKFLOW_REF:-}
EXPECTED_EVIDENCE_REF=${GITHUB_REF:-}
EXPECTED_EVIDENCE_COMMIT=${GITHUB_SHA:-}
EXPECTED_HARNESS_COMMIT=
EXPECTED_BUILD_IDENTITY=

usage()
{
    cat <<'EOF'
Usage: build-release-candidate.sh --stage build|finalize [options]

Build stage (produces the artifacts and the immutable build identity):
  --stage build --output-dir DIR --image-archive-dir DIR
  --repo DIR --source-ref REV --production --release-tag TAG ...

Finalize stage (attaches IPv6 qualification evidence and computes the
candidate identity; no build environment or Docker is used):
  --stage finalize --output-dir DIR --ipv6-evidence-dir DIR
  --expected-workflow-run-id ID --expected-workflow-run-attempt N ...

Options:
  --stage build|finalize     Required; selects the stage
  --repo DIR                 Git repository (default: this repository)
  --source-ref REV           Source revision to build (default: HEAD)
  --output-dir DIR           Build output / existing candidate directory
  --image-archive-dir DIR    Qualified image artifact directory (build)
  --ipv6-evidence-dir DIR    Retained N6-R-P evidence (finalize)
  --expected-build-identity SHA  Require this exact build identity
  --expected-workflow-run-id ID       Evidence workflow run ID
  --expected-workflow-run-attempt N   Evidence workflow run attempt
  --expected-workflow-path P          Evidence workflow path@ref
  --expected-evidence-ref REF         Evidence workflow ref
  --expected-evidence-commit SHA      Evidence workflow commit
  --expected-harness-commit SHA       Evidence harness commit
  --production               Production candidate: require main ref at the
                             exact source commit and a newer version
  --release-tag TAG          Release tag (default: v<changelog version>)
  --workflow-ref REF         Trusted workflow ref recorded in the manifest
  --workflow-commit SHA      Trusted workflow commit recorded in the manifest
  --expected-source-commit SHA   Require this exact source commit
  --expected-workflow-commit SHA Require this exact workflow commit
  --expected-image-manifest-digest DIGEST Require this OCI manifest digest
  --expected-image-config-digest DIGEST   Require this config digest
  --expected-image-qualification-sha256 SHA Require this qualification hash
  -h, --help                 Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            REPO=$2
            shift 2
            ;;
        --source-ref)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_REF=$2
            shift 2
            ;;
        --output-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            OUTPUT_DIR=$2
            shift 2
            ;;
        --image-archive-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            IMAGE_DIR=$2
            shift 2
            ;;
        --production)
            PRODUCTION=yes
            shift
            ;;
        --release-tag)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            RELEASE_TAG=$2
            shift 2
            ;;
        --workflow-ref)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            WORKFLOW_REF=$2
            shift 2
            ;;
        --workflow-commit)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            WORKFLOW_COMMIT=$2
            shift 2
            ;;
        --expected-source-commit)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_SOURCE_COMMIT=$2
            shift 2
            ;;
        --expected-workflow-commit)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_WORKFLOW_COMMIT=$2
            shift 2
            ;;
        --expected-image-manifest-digest)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_IMAGE_MANIFEST_DIGEST=$2
            shift 2
            ;;
        --expected-image-config-digest)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_IMAGE_CONFIG_DIGEST=$2
            shift 2
            ;;
        --expected-image-qualification-sha256)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_IMAGE_QUALIFICATION_SHA256=$2
            shift 2
            ;;
        --stage)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            STAGE=$2
            shift 2
            ;;
        --ipv6-evidence-dir)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            IPV6_EVIDENCE_DIR=$2
            shift 2
            ;;
        --expected-build-identity)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_BUILD_IDENTITY=$2
            shift 2
            ;;
        --expected-workflow-run-id)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_WORKFLOW_RUN_ID=$2
            shift 2
            ;;
        --expected-workflow-run-attempt)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_WORKFLOW_RUN_ATTEMPT=$2
            shift 2
            ;;
        --expected-workflow-path)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_WORKFLOW_PATH=$2
            shift 2
            ;;
        --expected-evidence-ref)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_EVIDENCE_REF=$2
            shift 2
            ;;
        --expected-evidence-commit)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_EVIDENCE_COMMIT=$2
            shift 2
            ;;
        --expected-harness-commit)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_HARNESS_COMMIT=$2
            shift 2
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

finalize_candidate()
{
    require_cmd jq sha256sum python3 tar stat find sort awk sed cmp
    require_dir "$OUTPUT_DIR"
    require_dir "$IPV6_EVIDENCE_DIR"
    require_file "$IPV6_EVIDENCE_DIR/summary.json"
    OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd) ||
        fail "cannot resolve candidate directory"
    IPV6_EVIDENCE_DIR=$(cd "$IPV6_EVIDENCE_DIR" && pwd) ||
        fail "cannot resolve evidence directory"
    BUILD_RECORD=$OUTPUT_DIR/qualification/build-record.json
    require_file "$BUILD_RECORD"

    [ "$(manifest_get "$BUILD_RECORD" '.candidate.status')" = "built" ] ||
        fail "build record candidate status is not built"
    [ "$(manifest_get "$BUILD_RECORD" '.qualification.status')" = "pending" ] ||
        fail "build record qualification status is not pending"
    check_build_identity "$BUILD_RECORD"
    BUILD_IDENTITY=$(manifest_get "$BUILD_RECORD" '.build.identity')
    if [ -n "$EXPECTED_BUILD_IDENTITY" ]; then
        [ "$BUILD_IDENTITY" = "$EXPECTED_BUILD_IDENTITY" ] ||
            fail "build identity $BUILD_IDENTITY != expected $EXPECTED_BUILD_IDENTITY"
    fi

    SOURCE_COMMIT=$(manifest_get "$BUILD_RECORD" '.source.commit')
    PKG_VERSION=$(manifest_get "$BUILD_RECORD" '.project.packageVersion')
    INTEGRATION="edgeos-vxlan_${PKG_VERSION}_all.deb"
    require_file "$OUTPUT_DIR/$INTEGRATION"
    INTEGRATION_SHA=$(sha256_file "$OUTPUT_DIR/$INTEGRATION")
    RECORDED_SHA=$(jq -r --arg n "$INTEGRATION" \
        '.artifacts[] | select(.name == $n) | .sha256' "$BUILD_RECORD")
    [ "$INTEGRATION_SHA" = "$RECORDED_SHA" ] ||
        fail "integration package changed after the build stage"

    # Provenance must be supplied independently of the evidence file itself.
    for pair in \
        "workflow run ID:$EXPECTED_WORKFLOW_RUN_ID" \
        "workflow run attempt:$EXPECTED_WORKFLOW_RUN_ATTEMPT" \
        "workflow path:$EXPECTED_WORKFLOW_PATH" \
        "workflow ref:$EXPECTED_EVIDENCE_REF" \
        "workflow commit:$EXPECTED_EVIDENCE_COMMIT"; do
        [ -n "${pair#*:}" ] || fail "missing ${pair%%:*}"
    done
    [ -n "$EXPECTED_HARNESS_COMMIT" ] ||
        fail "missing expected harness commit; provenance must be supplied independently"
    [ "$EXPECTED_HARNESS_COMMIT" = \
      "$(manifest_get "$BUILD_RECORD" '.source.trustedWorkflow.commit')" ] ||
        fail "harness commit does not match the candidate trusted workflow commit"

    # The evidence records GITHUB_WORKFLOW_REF (owner/repo/path@ref); the
    # manifest binds the canonical workflow file path. Normalize and require
    # the evidence workflow to be the trusted workflow of this candidate.
    TRUSTED_WORKFLOW_PATH=$(manifest_get "$BUILD_RECORD" '.source.trustedWorkflow.path')
    EVIDENCE_WORKFLOW_PATH=$EXPECTED_WORKFLOW_PATH
    EVIDENCE_WORKFLOW_PATH=${EVIDENCE_WORKFLOW_PATH%@*}
    EVIDENCE_WORKFLOW_PATH=${EVIDENCE_WORKFLOW_PATH#*/}
    EVIDENCE_WORKFLOW_PATH=${EVIDENCE_WORKFLOW_PATH#*/}
    [ "$EVIDENCE_WORKFLOW_PATH" = "$TRUSTED_WORKFLOW_PATH" ] ||
        fail "qualification evidence workflow $EVIDENCE_WORKFLOW_PATH is not the trusted workflow $TRUSTED_WORKFLOW_PATH"

    echo "Validating IPv6-only qualification evidence"
    python3 "$ROOT/scripts/validate-ipv6-qualification-evidence.py" \
        --summary "$IPV6_EVIDENCE_DIR/summary.json" \
        --evidence-dir "$IPV6_EVIDENCE_DIR" \
        --expected-source-commit "$SOURCE_COMMIT" \
        --expected-build-identity "$BUILD_IDENTITY" \
        --expected-package-sha256 "$INTEGRATION_SHA" \
        --expected-workflow-run-id "$EXPECTED_WORKFLOW_RUN_ID" \
        --expected-workflow-run-attempt "$EXPECTED_WORKFLOW_RUN_ATTEMPT" \
        --expected-workflow-path "$EXPECTED_WORKFLOW_PATH" \
        --expected-workflow-ref "$EXPECTED_EVIDENCE_REF" \
        --expected-workflow-commit "$EXPECTED_EVIDENCE_COMMIT" \
        --expected-harness-commit "$EXPECTED_HARNESS_COMMIT" \
        --require-workflow-binding \
        --require-package-execution \
        --allow-skip host-global-ipv6-escape-unavailable \
        --allow-skip iproute2-json-normalization \
        --allow-workaround iproute2-json-normalization

    EVIDENCE_DIR=$OUTPUT_DIR/qualification/ipv6-only
    [ ! -e "$EVIDENCE_DIR" ] ||
        fail "qualification evidence directory already exists: $EVIDENCE_DIR"
    mkdir -p "$EVIDENCE_DIR"
    cp -a "$IPV6_EVIDENCE_DIR/." "$EVIDENCE_DIR/"
    require_file "$EVIDENCE_DIR/summary.json"
    SUMMARY_SHA=$(sha256_file "$EVIDENCE_DIR/summary.json")

    # Each retained evidence file must hash to the summary's recorded value.
    while IFS=$'\t' read -r check_id file sha; do
        [ -n "$file" ] || fail "check $check_id has no evidence file"
        validate_relative_path "$file"
        require_file "$EVIDENCE_DIR/$file"
        [ "$(sha256_file "$EVIDENCE_DIR/$file")" = "$sha" ] ||
            fail "retained evidence for $check_id does not match the summary"
    done < <(jq -r '.checks[] | [.id, .evidenceFile, .evidenceSha256] | @tsv' \
        "$EVIDENCE_DIR/summary.json")

    ipv6_checks=$(jq -c '[.checks[] |
        {id, status, evidenceFile, evidenceSha256}]' "$EVIDENCE_DIR/summary.json")
    ipv6_block=$(jq -c \
        --arg buildIdentity "$BUILD_IDENTITY" \
        --arg summarySha "$SUMMARY_SHA" \
        --arg workflowPath "$TRUSTED_WORKFLOW_PATH" \
        '{
          status: .result,
          level: .level,
          buildIdentity: $buildIdentity,
          sourceCommit: .candidate.sourceCommit,
          package: .candidate.package,
          packageSha256: .candidate.packageSha256,
          reconcilerSha256: .candidate.reconcilerSha256,
          addrHelperSha256: .candidate.addrHelperSha256,
          workflow: {
            runId: .workflow.runId,
            runAttempt: .workflow.runAttempt,
            repository: .workflow.repository,
            path: $workflowPath,
            ref: .workflow.ref,
            commit: .workflow.commit
          },
          harness: {
            path: .harness.path,
            commit: .harness.commit,
            version: .harness.version
          },
          evidence: {dir: "qualification/ipv6-only", summarySha256: $summarySha},
          capture: {
            status: .capture.status,
            underlaySha256: .capture.underlaySha256,
            overlaySha256: .capture.overlaySha256,
            analysisSha256: .capture.analysisSha256
          },
          reconciler: {
            status: .reconciler.status,
            evidenceSha256: .reconciler.evidenceSha256
          },
          skips: [.skips[] | split(":")[0] | gsub("\\s+$"; "")],
          workarounds: [.workarounds[] | {id, applied}]
        }' "$EVIDENCE_DIR/summary.json") ||
        fail "cannot build the IPv6 qualification manifest block"

    jq --argjson ipv6checks "$ipv6_checks" --argjson ipv6 "$ipv6_block" \
        '.candidate.status = "qualified"
         | .qualification.status = "passed"
         | .qualification.checks += $ipv6checks
         | .qualification.ipv6 = $ipv6' \
        "$BUILD_RECORD" > "$OUTPUT_DIR/release-candidate.json" ||
        fail "cannot assemble the candidate manifest"

    ID=$(candidate_id_from_manifest "$OUTPUT_DIR/release-candidate.json")
    jq --arg id "$ID" '.candidate.id = $id' "$OUTPUT_DIR/release-candidate.json" \
        > "$OUTPUT_DIR/release-candidate.json.new"
    mv "$OUTPUT_DIR/release-candidate.json.new" "$OUTPUT_DIR/release-candidate.json"

    if [ "$(manifest_get "$OUTPUT_DIR/release-candidate.json" '.candidate.nonRelease')" = "false" ]; then
        "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$OUTPUT_DIR" \
            --source-root "$REPO" --rev "$SOURCE_COMMIT" --production
    else
        "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$OUTPUT_DIR" \
            --source-root "$REPO" --rev "$SOURCE_COMMIT"
    fi

    echo
    echo "Release candidate: PASS"
    echo "Candidate ID:      $ID"
    echo "Build identity:    $BUILD_IDENTITY"
    echo "Manifest SHA-256:  $(sha256_file "$OUTPUT_DIR/release-candidate.json")"
    echo "Package version:   $PKG_VERSION"
    echo "Source commit:     $SOURCE_COMMIT"
    echo "Output:            $OUTPUT_DIR"
}

if [ "$STAGE" = "finalize" ]; then
    [ -n "$OUTPUT_DIR" ] || { usage >&2; exit 2; }
    [ -n "$IPV6_EVIDENCE_DIR" ] || { usage >&2; exit 2; }
    finalize_candidate
    exit 0
fi

case "$STAGE" in
    build) ;;
    '') usage >&2; exit 2 ;;
    *) fail "invalid stage: $STAGE (expected build or finalize)" ;;
esac

if [ -z "$OUTPUT_DIR" ] || [ -z "$IMAGE_DIR" ]; then
    usage >&2
    exit 2
fi
require_cmd git docker jq sha256sum tar stat find sort awk sed cmp \
    dpkg-parsechangelog dpkg-deb python3
require_file "$ROOT/release/release-policy.json"
require_file "$ROOT/scripts/build-reproducible.sh"
require_file "$ROOT/scripts/build-sbom.py"
require_file "$ROOT/scripts/validate-build-metadata.py"
require_file "$ROOT/scripts/validate-artifacts.sh"
require_dir "$IMAGE_DIR"
require_file "$IMAGE_DIR/image.oci.tar"
require_file "$IMAGE_DIR/image.docker.tar"
require_file "$IMAGE_DIR/build-environment-qualification.json"
require_file "$IMAGE_DIR/image.spdx.json"

REPO=$(cd "$REPO" && pwd)
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || fail "not a Git checkout: $REPO"
OUTPUT_DIR=$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd) ||
    fail "cannot resolve output directory"
[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    fail "output directory is not empty: $OUTPUT_DIR"

if [ -e "$OUTPUT_DIR" ]; then
    :
fi
COMMIT=$(git -C "$REPO" rev-parse --verify --quiet "${SOURCE_REF}^{commit}") ||
    fail "cannot resolve source revision: $SOURCE_REF"
if [ -n "$EXPECTED_SOURCE_COMMIT" ]; then
    [ "$COMMIT" = "$EXPECTED_SOURCE_COMMIT" ] ||
        fail "source commit $COMMIT != expected $EXPECTED_SOURCE_COMMIT"
fi

DIRTY=$(GIT_OPTIONAL_LOCKS=0 git -C "$REPO" status --porcelain --untracked-files=no)
if [ -n "$DIRTY" ]; then
    if [ "$SOURCE_REF" = "HEAD" ]; then
        printf '%s\n' "$DIRTY" >&2
        fail "working tree has tracked changes; commit/stash them or pass --source-ref"
    fi
    note "working tree is dirty; building archived revision $COMMIT"
fi

# Transient build state must live outside the candidate directory: the
# candidate contract rejects every unexpected top-level entry.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-candidate.XXXXXX") ||
    fail "cannot create candidate work directory"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
SOURCE_TAR=$OUTPUT_DIR/source.tar
git -C "$REPO" archive --format=tar "$COMMIT" > "$SOURCE_TAR" ||
    fail "git archive failed for $COMMIT"
ARCHIVE_SHA=$(sha256_file "$SOURCE_TAR")
require_sha256_field "source archive" "$ARCHIVE_SHA"

mkdir -p "$WORK/source"
tar -xf "$SOURCE_TAR" -C "$WORK/source" ||
    fail "cannot extract source archive"
[ -f "$WORK/source/debian/changelog" ] ||
    fail "source archive has no debian/changelog"

PKG_VERSION=$(dpkg-parsechangelog -l "$WORK/source/debian/changelog" -S Version) ||
    fail "cannot read package version"
EPOCH=$(dpkg-parsechangelog -l "$WORK/source/debian/changelog" -S Timestamp) ||
    fail "cannot read SOURCE_DATE_EPOCH"
VERSION=${PKG_VERSION%%+*}
is_release_tag "v$VERSION" || fail "package version is not a stable release: $PKG_VERSION"

if [ -n "$RELEASE_TAG" ]; then
    TAG=$RELEASE_TAG
else
    TAG="v$VERSION"
fi
is_release_tag "$TAG" || fail "invalid release tag: $TAG"
[ "${TAG#v}" = "$VERSION" ] ||
    fail "release tag $TAG does not match package version $VERSION"
NON_RELEASE=true

if [ "$PRODUCTION" = "yes" ]; then
    NON_RELEASE=false
    [ "${GITHUB_ACTIONS:-}" = "true" ] ||
        fail "production candidates must be built in GitHub Actions"
    [ "$WORKFLOW_REF" = "refs/heads/main" ] ||
        fail "production candidates must run on refs/heads/main"
    if [ -z "$WORKFLOW_COMMIT" ] || [ "$WORKFLOW_COMMIT" != "$COMMIT" ]; then
        fail "production workflow commit ($WORKFLOW_COMMIT) must equal source commit ($COMMIT)"
    fi
    baseline=$(jq -r '.release.baselinePublishedVersion' "$ROOT/release/release-policy.json")
    dpkg --compare-versions "$VERSION" gt "$baseline" ||
        fail "production version $VERSION is not newer than published $baseline"
fi

PACKAGING_INPUTS=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$COMMIT") ||
    fail "cannot compute packaging-inputs digest"
POLICY_SHA=$(sha256_file "$ROOT/release/release-policy.json")
REPOSITORY=$(jq -r '.project.repository' "$ROOT/release/release-policy.json")
REPOSITORY_ID=$(jq -r '.project.repositoryId' "$ROOT/release/release-policy.json")

if [ -z "$WORKFLOW_COMMIT" ]; then
    WORKFLOW_COMMIT=$COMMIT
fi
if [ -n "$EXPECTED_WORKFLOW_COMMIT" ]; then
    [ "$WORKFLOW_COMMIT" = "$EXPECTED_WORKFLOW_COMMIT" ] ||
        fail "workflow commit $WORKFLOW_COMMIT != expected $EXPECTED_WORKFLOW_COMMIT"
fi

echo "Verifying qualified build environment"
"$ROOT/scripts/verify-build-environment.sh" --archive-dir "$IMAGE_DIR"

QUAL=$IMAGE_DIR/build-environment-qualification.json
IMAGE_NAME=$(jq -er '.imageName' "$QUAL")
MANIFEST_DIGEST=$(jq -er '.manifestDigest' "$QUAL")
OCI_INDEX_DIGEST=$(jq -er '.ociIndexDigest' "$QUAL")
CONFIG_DIGEST=$(jq -er '.configDigest' "$QUAL")
OCI_ARCHIVE_SHA=$(jq -er '.ociArchiveSha256' "$QUAL")
DOCKER_ARCHIVE_SHA=$(jq -er '.dockerArchiveSha256' "$QUAL")
IMAGE_CONFIG_JSON_SHA=$(jq -er '.imageConfigJsonSha256' "$QUAL")
DOCKERFILE_SHA=$(jq -er '.dockerfileSha256' "$QUAL")
CA_BUNDLE_SHA=$(jq -er '.caBundleSha256' "$QUAL")
DEPENDENCY_SNAPSHOT=$(jq -er '.dependencySnapshot' "$QUAL")
DEPENDENCY_INVENTORY_SHA=$(jq -er '.dependencyInventorySha256' "$QUAL")
QUALIFICATION_SHA=$(sha256_file "$QUAL")
IMAGE_SBOM_SHA=$(sha256_file "$IMAGE_DIR/image.spdx.json")
if [ -n "$EXPECTED_IMAGE_MANIFEST_DIGEST" ]; then
    [ "$MANIFEST_DIGEST" = "$EXPECTED_IMAGE_MANIFEST_DIGEST" ] ||
        fail "image manifest digest does not match the expected digest"
fi
if [ -n "$EXPECTED_IMAGE_CONFIG_DIGEST" ]; then
    [ "$CONFIG_DIGEST" = "$EXPECTED_IMAGE_CONFIG_DIGEST" ] ||
        fail "image config digest does not match the expected digest"
fi
if [ -n "$EXPECTED_IMAGE_QUALIFICATION_SHA256" ]; then
    [ "$QUALIFICATION_SHA" = "$EXPECTED_IMAGE_QUALIFICATION_SHA256" ] ||
        fail "image qualification hash does not match the expected hash"
fi
[ "$(sha256_file "$IMAGE_DIR/image.docker.tar")" = "$DOCKER_ARCHIVE_SHA" ] ||
    fail "Docker archive checksum does not match the qualification"

docker load -i "$IMAGE_DIR/image.docker.tar" > "$WORK/docker-load.log" 2>&1 ||
    { cat "$WORK/docker-load.log" >&2; fail "cannot load qualified Docker archive"; }
RUN_REF=$(resolve_loaded_image_ref "$IMAGE_NAME" "$MANIFEST_DIGEST" "$CONFIG_DIGEST") ||
    fail "qualified image cannot be bound to its manifest/config digest"
[ -n "$RUN_REF" ] || fail "qualified image has no verified execution reference"
LOCAL_CONFIG_JSON_SHA=$(
    docker image inspect "$RUN_REF" --format '{{json .Config}}' |
        sha256sum | awk '{print $1}'
)
[ "$LOCAL_CONFIG_JSON_SHA" = "$IMAGE_CONFIG_JSON_SHA" ] ||
    fail "qualified image config JSON hash does not match the qualification"

build_once()
{
    local out=$1
    mkdir -p "$out"
    docker run --rm --network none --pull=never \
        --cap-drop ALL --security-opt no-new-privileges \
        --user "$(id -u):$(id -g)" \
        --tmpfs /tmp:rw,mode=1777 -e HOME=/tmp --read-only \
        -v "$WORK/source/scripts/build-reproducible.sh:/usr/local/bin/build-reproducible.sh:ro" \
        -v "$SOURCE_TAR:/input/source.tar:ro" \
        -v "$out:/out" \
        "$RUN_REF" \
        /usr/local/bin/build-reproducible.sh \
            --source-archive /input/source.tar \
            --source-archive-sha256 "$ARCHIVE_SHA" \
            --source-commit "$COMMIT" \
            --source-rev "$SOURCE_REF" \
            --output-dir /out
}

echo "Building distribution candidate (build A)"
build_once "$WORK/build-a" > "$WORK/build-a.log" 2>&1 ||
    { cat "$WORK/build-a.log" >&2; fail "build A failed"; }

echo "Building independent comparison (build B)"
build_once "$WORK/build-b" > "$WORK/build-b.log" 2>&1 ||
    { cat "$WORK/build-b.log" >&2; fail "build B failed"; }

find "$WORK/build-a" -mindepth 1 -maxdepth 1 -name '*.deb' -printf '%f\n' |
    LC_ALL=C sort > "$WORK/a.debs"
find "$WORK/build-b" -mindepth 1 -maxdepth 1 -name '*.deb' -printf '%f\n' |
    LC_ALL=C sort > "$WORK/b.debs"
cmp -s "$WORK/a.debs" "$WORK/b.debs" ||
    fail "independent builds produced different package name sets"

while IFS= read -r deb; do
    cmp -s "$WORK/build-a/$deb" "$WORK/build-b/$deb" ||
        fail "independent build mismatch: $deb"
done < "$WORK/a.debs"
cmp -s "$WORK/build-a/SHA256SUMS" "$WORK/build-b/SHA256SUMS" ||
    fail "independent build SHA256SUMS mismatch"

hashes_a=$(cd "$WORK/build-a" && sha256sum -- *.deb |
    awk '{print $1 "\t" $2}' |
    jq -Rn '[inputs | split("\t") | {(.[1]): .[0]}] | add')
hashes_b=$(cd "$WORK/build-b" && sha256sum -- *.deb |
    awk '{print $1 "\t" $2}' |
    jq -Rn '[inputs | split("\t") | {(.[1]): .[0]}] | add')
jq -n \
    --argjson a "$hashes_a" \
    --argjson b "$hashes_b" \
    --arg commit "$COMMIT" \
    '{status:"passed", sourceCommit:$commit, buildA:$a, buildB:$b,
      comparedArtifacts: ($a | keys)}' > "$WORK/reproducibility.json"

INTEGRATION="edgeos-vxlan_${PKG_VERSION}_all.deb"
KMOD="edgeos-vxlan-kmod_${PKG_VERSION}_mipsel.deb"
BUILDINFO="edgeos-vxlan_${PKG_VERSION}_mipsel.buildinfo"
CHANGES="edgeos-vxlan_${PKG_VERSION}_mipsel.changes"
for name in "$INTEGRATION" "$KMOD" "$BUILDINFO" "$CHANGES"; do
    [ -f "$WORK/build-a/$name" ] ||
        fail "build did not produce $name"
    cp "$WORK/build-a/$name" "$OUTPUT_DIR/$name"
done
INTEGRATION_SHA=$(sha256_file "$OUTPUT_DIR/$INTEGRATION")
KMOD_SHA=$(sha256_file "$OUTPUT_DIR/$KMOD")

# Create a validation source tree whose install.sh matches the candidate
# version/pins. This is used only by the artifact-contract validator; the
# distributed source archive and packages are unchanged.
sed \
    -e "s|^VERSION=\".*\"$|VERSION=\"$VERSION\"|" \
    -e "s|^PKG_VERSION=\".*\"$|PKG_VERSION=\"$PKG_VERSION\"|" \
    -e "s|^KMOD_SHA256=\".*\"$|KMOD_SHA256=\"$KMOD_SHA\"|" \
    -e "s|^INTEGRATION_SHA256=\".*\"$|INTEGRATION_SHA256=\"$INTEGRATION_SHA\"|" \
    "$WORK/source/install.sh" > "$WORK/source/install.sh.new"
mv "$WORK/source/install.sh.new" "$WORK/source/install.sh"

(
    cd "$OUTPUT_DIR"
    sha256sum -- "$INTEGRATION" "$KMOD" > SHA256SUMS
)

mkdir -p "$OUTPUT_DIR/qualification"
"$ROOT/scripts/validate-artifacts.sh" --build "$OUTPUT_DIR" "$WORK/source" \
    > "$OUTPUT_DIR/qualification/artifact-contract.log" 2>&1 ||
    { cat "$OUTPUT_DIR/qualification/artifact-contract.log" >&2; fail "artifact contract failed"; }

python3 "$ROOT/scripts/validate-build-metadata.py" "$OUTPUT_DIR" "$WORK/source" \
    > "$OUTPUT_DIR/qualification/build-metadata.log" 2>&1 ||
    { cat "$OUTPUT_DIR/qualification/build-metadata.log" >&2; fail "build metadata validation failed"; }

SBOM_INT=$OUTPUT_DIR/sbom-edgeos-vxlan.spdx.json
SBOM_KMOD=$OUTPUT_DIR/sbom-edgeos-vxlan-kmod.spdx.json
python3 "$ROOT/scripts/build-sbom.py" build \
    --package "$OUTPUT_DIR/$INTEGRATION" \
    --source-root "$WORK/source" \
    --output "$SBOM_INT" \
    --source-commit "$COMMIT" \
    --source-date-epoch "$EPOCH" \
    --release-tag "$TAG" \
    --repository "$REPOSITORY" > "$OUTPUT_DIR/qualification/sbom.log" 2>&1 ||
    { cat "$OUTPUT_DIR/qualification/sbom.log" >&2; fail "integration SBOM generation failed"; }
python3 "$ROOT/scripts/build-sbom.py" build \
    --package "$OUTPUT_DIR/$KMOD" \
    --source-root "$WORK/source" \
    --output "$SBOM_KMOD" \
    --source-commit "$COMMIT" \
    --source-date-epoch "$EPOCH" \
    --release-tag "$TAG" \
    --repository "$REPOSITORY" >> "$OUTPUT_DIR/qualification/sbom.log" 2>&1 ||
    { cat "$OUTPUT_DIR/qualification/sbom.log" >&2; fail "kernel SBOM generation failed"; }
python3 "$ROOT/scripts/build-sbom.py" validate \
    --sbom "$SBOM_INT" --package "$OUTPUT_DIR/$INTEGRATION" \
    --source-root "$WORK/source" >> "$OUTPUT_DIR/qualification/sbom.log" 2>&1
python3 "$ROOT/scripts/build-sbom.py" validate \
    --sbom "$SBOM_KMOD" --package "$OUTPUT_DIR/$KMOD" \
    --source-root "$WORK/source" >> "$OUTPUT_DIR/qualification/sbom.log" 2>&1

cp "$QUAL" "$OUTPUT_DIR/build-environment-qualification.json"
cp "$IMAGE_DIR/image.spdx.json" "$OUTPUT_DIR/build-environment-image.spdx.json"

mv "$WORK/reproducibility.json" "$OUTPUT_DIR/qualification/reproducibility.json"
printf '%s\n' "$(sha256_file "$OUTPUT_DIR/qualification/artifact-contract.log")" \
    > "$OUTPUT_DIR/qualification/artifact-contract.sha256"
printf '%s\n' "$(sha256_file "$OUTPUT_DIR/qualification/build-metadata.log")" \
    > "$OUTPUT_DIR/qualification/build-metadata.sha256"
printf '%s\n' "$(sha256_file "$OUTPUT_DIR/qualification/sbom.log")" \
    > "$OUTPUT_DIR/qualification/sbom.sha256"
printf '%s\n' "$(sha256_file "$OUTPUT_DIR/qualification/reproducibility.json")" \
    > "$OUTPUT_DIR/qualification/reproducibility.sha256"

artifact_tsv=$OUTPUT_DIR/qualification/artifacts.tsv
: > "$artifact_tsv"
add_artifact()
{
    local name=$1 role=$2
    validate_artifact_name "$name"
    printf '%s\t%s\t%s\t%s\n' "$name" "$role" \
        "$(stat -c '%s' "$OUTPUT_DIR/$name")" \
        "$(sha256_file "$OUTPUT_DIR/$name")" >> "$artifact_tsv"
}
add_artifact "$INTEGRATION" package
add_artifact "$KMOD" package
add_artifact "$BUILDINFO" debian-metadata
add_artifact "$CHANGES" debian-metadata
add_artifact "sbom-edgeos-vxlan.spdx.json" sbom
add_artifact "sbom-edgeos-vxlan-kmod.spdx.json" sbom
add_artifact "build-environment-qualification.json" environment-qualification

jq -R -s '[split("\n")[] | select(length > 0) | split("\t") |
    {name:.[0], role:.[1], size:(.[2]|tonumber), sha256:.[3]}]
    | sort_by(.name)' "$artifact_tsv" > "$OUTPUT_DIR/qualification/artifacts.json"

checks=$(jq -n \
    --arg a "$(cat "$OUTPUT_DIR/qualification/artifact-contract.sha256")" \
    --arg b "$(cat "$OUTPUT_DIR/qualification/build-metadata.sha256")" \
    --arg c "$(cat "$OUTPUT_DIR/qualification/sbom.sha256")" \
    --arg d "$(cat "$OUTPUT_DIR/qualification/reproducibility.sha256")" \
    '[
        {id:"artifact-contract", status:"passed", evidenceSha256:$a},
        {id:"build-metadata", status:"passed", evidenceSha256:$b},
        {id:"sbom", status:"passed", evidenceSha256:$c},
        {id:"reproducibility", status:"passed", evidenceSha256:$d}
    ]')

jq -n \
    --arg schemaVersion "https://edgeos-vxlan.dev/release-candidate/v1" \
    --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg status built \
    --argjson nonRelease "$([ "$NON_RELEASE" = true ] && echo true || echo false)" \
    --arg projectName "edgeos-vxlan" \
    --arg repository "$REPOSITORY" \
    --argjson repositoryId "$REPOSITORY_ID" \
    --arg tag "$TAG" \
    --arg pkgVersion "$PKG_VERSION" \
    --argjson epoch "$EPOCH" \
    --arg policySha "$POLICY_SHA" \
    --arg commit "$COMMIT" \
    --arg archiveSha "$ARCHIVE_SHA" \
    --arg packagingInputs "$PACKAGING_INPUTS" \
    --arg workflowRef "$WORKFLOW_REF" \
    --arg workflowCommit "$WORKFLOW_COMMIT" \
    --arg workflowPath "$(jq -r '.attestation.workflowPath' "$ROOT/release/release-policy.json")" \
    --arg image "$IMAGE_NAME@$MANIFEST_DIGEST" \
    --arg ociIndexDigest "$OCI_INDEX_DIGEST" \
    --arg manifestDigest "$MANIFEST_DIGEST" \
    --arg configDigest "$CONFIG_DIGEST" \
    --arg ociArchiveSha "$OCI_ARCHIVE_SHA" \
    --arg dockerArchiveSha "$DOCKER_ARCHIVE_SHA" \
    --arg dockerfileSha "$DOCKERFILE_SHA" \
    --arg caBundleSha "$CA_BUNDLE_SHA" \
    --arg dependencySnapshot "$DEPENDENCY_SNAPSHOT" \
    --arg inventorySha "$DEPENDENCY_INVENTORY_SHA" \
    --arg qualificationSha "$QUALIFICATION_SHA" \
    --arg imageSbomSha "$IMAGE_SBOM_SHA" \
    --argjson checks "$checks" \
    --slurpfile artifacts "$OUTPUT_DIR/qualification/artifacts.json" \
    '{schemaVersion:$schemaVersion,
      candidate:{id:"", createdAt:$createdAt, status:$status, nonRelease:$nonRelease},
      project:{name:$projectName, repository:$repository, repositoryId:$repositoryId,
               releaseTag:$tag, packageVersion:$pkgVersion,
               sourceDateEpoch:$epoch, releasePolicySha256:$policySha},
      source:{commit:$commit, archiveSha256:$archiveSha,
              packagingInputsSha256:$packagingInputs,
              trustedWorkflow:{repository:$repository, path:$workflowPath,
                               ref:$workflowRef, commit:$workflowCommit}},
      buildEnvironment:{image:$image, ociIndexDigest:$ociIndexDigest,
              manifestDigest:$manifestDigest, configDigest:$configDigest,
              ociArchiveSha256:$ociArchiveSha,
              dockerArchiveSha256:$dockerArchiveSha,
              dockerfileSha256:$dockerfileSha,
              caBundleSha256:$caBundleSha,
              dependencySnapshot:$dependencySnapshot,
              dependencyInventorySha256:$inventorySha,
              qualificationSha256:$qualificationSha,
              imageSbomSha256:$imageSbomSha},
      build:{buildType:"edgeos-vxlan-canonical-v1",
             command:"build-reproducible.sh inside qualified OCI image; network none",
             reproducibility:{status:"passed",
                comparedArtifacts:($artifacts[0] | map(select(.role=="package") | .name))}},
      artifacts:$artifacts[0],
      qualification:{status:"pending", checks:$checks,
             hardware:{status:"not-required", required:false, evidence:[]}},
      limitations:[
        "Kernel module binaries are prebuilt repository inputs; source-to-binary reproducibility is not established.",
        "Build-environment dependencies are recorded in the image SBOM and are not release components.",
        "Attestations establish build provenance, not software correctness or hardware compatibility.",
        "Hardware qualification is a separate workstream and is not claimed by this candidate."
      ]}
    ' > "$OUTPUT_DIR/qualification/build-record.json"

BUILD_RECORD=$OUTPUT_DIR/qualification/build-record.json
BUILD_IDENTITY=$(build_identity_from_manifest "$BUILD_RECORD")
is_sha256 "$BUILD_IDENTITY" || fail "computed build identity is not a SHA-256"
jq --arg identity "$BUILD_IDENTITY" '.build.identity = $identity' "$BUILD_RECORD" \
    > "$BUILD_RECORD.new"
mv "$BUILD_RECORD.new" "$BUILD_RECORD"
check_build_identity "$BUILD_RECORD"
if [ -n "$EXPECTED_BUILD_IDENTITY" ]; then
    [ "$BUILD_IDENTITY" = "$EXPECTED_BUILD_IDENTITY" ] ||
        fail "build identity $BUILD_IDENTITY != expected $EXPECTED_BUILD_IDENTITY"
fi

echo
echo "Build stage: PASS"
echo "Build identity:  $BUILD_IDENTITY"
echo "Tag:             $TAG"
echo "Package version: $PKG_VERSION"
echo "Source commit:   $COMMIT"
echo "Non-release:     $NON_RELEASE"
echo "Build record:    $BUILD_RECORD"
echo "Output:          $OUTPUT_DIR"
