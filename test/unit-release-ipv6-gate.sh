#!/bin/bash
# Release-candidate and promotion-gate tests for IPv6-only qualification.
#
# These fixtures drive the real scripts/validate-candidate.sh and
# scripts/promote-release.sh paths against synthetic candidates. They assert
# that an unqualified, mismatched or substituted candidate cannot satisfy the
# implemented production publication gates, and that a correctly qualified
# candidate with only the two permitted exceptions is accepted.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"
# shellcheck source=lib/ipv6-qualification-fixture.sh
. "$ROOT/test/lib/ipv6-qualification-fixture.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-ipv6-gate.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0
HEX=$(printf 'a%.0s' {1..64})
B64=$(printf 'b%.0s' {1..64})
C64=$(printf 'c%.0s' {1..64})
B40=$(printf 'b%.0s' {1..40})
SHA=$(git -C "$ROOT" rev-parse HEAD)
VERSION=0.3.1+edgeos3.0.1.e50
TAG=v0.3.1
INTEGRATION="edgeos-vxlan_${VERSION}_all.deb"
KMOD="edgeos-vxlan-kmod_${VERSION}_mipsel.deb"
BUILDINFO="edgeos-vxlan_${VERSION}_mipsel.buildinfo"
CHANGES="edgeos-vxlan_${VERSION}_mipsel.changes"

ok() { PASS=$((PASS + 1)); }
bad()
{
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
}
expect_pass()
{
    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        ok
    else
        bad "expected success: $*"
        sed 's/^/    /' "$TMP/err" | tail -6 >&2
    fi
}
expect_fail_with()
{
    local pattern=$1
    shift
    if "$@" >"$TMP/out" 2>"$TMP/err"; then
        bad "expected failure ($pattern): $*"
    elif grep -Fq -- "$pattern" "$TMP/err"; then
        ok
    else
        bad "failed for the wrong reason; wanted '$pattern': $*"
        sed 's/^/    /' "$TMP/err" | tail -6 >&2
    fi
}

# Recompute only the derived candidate ID (identity inputs unchanged).
resign_id()
{
    local manifest=$1 id
    id=$(candidate_id_from_manifest "$manifest")
    jq --arg id "$id" '.candidate.id=$id' "$manifest" > "$TMP/id.json"
    mv "$TMP/id.json" "$manifest"
}

# Recompute the build identity and the candidate ID after a mutation that
# changes a build-identity input (artifacts, source, environment).
reseal()
{
    local manifest=$1 identity
    identity=$(build_identity_from_manifest "$manifest")
    jq --arg identity "$identity" \
        '.build.identity=$identity | .qualification.ipv6.buildIdentity=$identity' \
        "$manifest" > "$TMP/reseal.json"
    mv "$TMP/reseal.json" "$manifest"
    resign_id "$manifest"
}

# Copy a candidate and apply a jq mutation. The common values are available to
# filters as $hex, $b64, $c64 and $b40.
mutate_copy()
{
    local src=$1 dst=$2 filter=$3
    rm -rf "$dst"
    cp -a "$src" "$dst"
    jq --arg hex "$HEX" --arg b64 "$B64" --arg c64 "$C64" --arg b40 "$B40" \
        "$filter" "$dst/release-candidate.json" > "$TMP/mut.json"
    mv "$TMP/mut.json" "$dst/release-candidate.json"
}

# A complete, qualified candidate with valid retained evidence.
make_candidate()
{
    local dir=$1 non_release=${2:-false}
    rm -rf "$dir"
    mkdir -p "$dir/qualification"
    printf 'integration package\n' > "$dir/$INTEGRATION"
    printf 'kernel package\n' > "$dir/$KMOD"
    printf 'buildinfo\n' > "$dir/$BUILDINFO"
    printf 'changes\n' > "$dir/$CHANGES"
    printf '{"spdxVersion":"SPDX-2.3"}\n' > "$dir/sbom-edgeos-vxlan.spdx.json"
    printf '{"spdxVersion":"SPDX-2.3"}\n' > "$dir/sbom-edgeos-vxlan-kmod.spdx.json"
    printf '{"qualified":true}\n' > "$dir/build-environment-qualification.json"
    printf '{"spdxVersion":"SPDX-2.3"}\n' > "$dir/build-environment-image.spdx.json"
    local qsha isha
    qsha=$(sha256_file "$dir/build-environment-qualification.json")
    isha=$(sha256_file "$dir/build-environment-image.spdx.json")

    : > "$TMP/entries.jsonl"
    while IFS=$'\t' read -r name role; do
        jq -cn --arg name "$name" --arg role "$role" \
            --argjson size "$(stat -c '%s' "$dir/$name")" \
            --arg sha256 "$(sha256_file "$dir/$name")" \
            '{name:$name,role:$role,size:$size,sha256:$sha256}' \
            >> "$TMP/entries.jsonl"
    done < <(printf '%s\t%s\n' \
        "$INTEGRATION" package "$KMOD" package \
        "$BUILDINFO" debian-metadata "$CHANGES" debian-metadata \
        sbom-edgeos-vxlan.spdx.json sbom sbom-edgeos-vxlan-kmod.spdx.json sbom \
        build-environment-qualification.json environment-qualification)
    jq -s . "$TMP/entries.jsonl" > "$TMP/entries.json"

    printf '%s  %s\n%s  %s\n' \
        "$(sha256_file "$dir/$KMOD")" "$KMOD" \
        "$(sha256_file "$dir/$INTEGRATION")" "$INTEGRATION" > "$dir/SHA256SUMS"

    jq -n \
        --arg hex "$HEX" --arg sha "$SHA" --arg qsha "$qsha" --arg isha "$isha" \
        --arg policy "$(sha256_file "$ROOT/release/release-policy.json")" \
        --arg pinputs "$("$ROOT/scripts/packaging-inputs.sh" --repo "$ROOT" --rev "$SHA")" \
        --arg v "$VERSION" --arg tag "$TAG" \
        --argjson nonrelease "$non_release" \
        --slurpfile arts "$TMP/entries.json" \
        '{
          schemaVersion:"https://edgeos-vxlan.dev/release-candidate/v1",
          candidate:{id:"",createdAt:"2026-11-27T00:00:00Z",
                     status:"qualified",nonRelease:$nonrelease},
          project:{name:"edgeos-vxlan",repository:"downwithbgp/edgeos-vxlan",
                   repositoryId:1357738281,releaseTag:$tag,packageVersion:$v,
                   sourceDateEpoch:1795743000,releasePolicySha256:$policy},
          source:{commit:$sha,archiveSha256:$hex,packagingInputsSha256:$pinputs,
                  trustedWorkflow:{repository:"downwithbgp/edgeos-vxlan",
                                   path:".github/workflows/release.yml",
                                   ref:"refs/heads/main",commit:$sha}},
          buildEnvironment:{image:("edgeos-vxlan-reproducible@sha256:"+$hex),
                   ociIndexDigest:("sha256:"+$hex),manifestDigest:("sha256:"+$hex),
                   configDigest:("sha256:"+$hex),ociArchiveSha256:$hex,
                   dockerArchiveSha256:$hex,dockerfileSha256:$hex,caBundleSha256:$hex,
                   dependencySnapshot:"20261127T000000Z",
                   dependencyInventorySha256:$hex,qualificationSha256:$qsha,
                   imageSbomSha256:$isha},
          build:{buildType:"edgeos-vxlan-canonical-v1",command:"synthetic",
                 reproducibility:{status:"passed",comparedArtifacts:["x"]}},
          artifacts:$arts[0],
          qualification:{status:"passed",
                 checks:[{id:"artifact-contract",status:"passed",evidenceSha256:$hex}],
                 hardware:{status:"not-required",required:false,evidence:[]}},
          limitations:["synthetic fixture"]
        }' > "$dir/release-candidate.json"

    local identity
    identity=$(build_identity_from_manifest "$dir/release-candidate.json")
    jq --arg identity "$identity" '.build.identity=$identity' \
        "$dir/release-candidate.json" > "$TMP/identity.json"
    mv "$TMP/identity.json" "$dir/release-candidate.json"
    ipv6_fixture_write "$dir" "$identity" "$SHA" "$INTEGRATION" \
        "$(sha256_file "$dir/$INTEGRATION")"
    jq --slurpfile fragment "$dir/qualification/ipv6-fragment.json" \
        '.qualification.checks += $fragment[0].checks
         | .qualification.ipv6 = $fragment[0].ipv6' \
        "$dir/release-candidate.json" > "$TMP/cand.json"
    mv "$TMP/cand.json" "$dir/release-candidate.json"
    resign_id "$dir/release-candidate.json"
}

# --- positive controls -------------------------------------------------------

CAND=$TMP/candidate
make_candidate "$CAND"
expect_pass "$ROOT/scripts/validate-candidate.sh" \
    --candidate-dir "$CAND" --release

# A candidate with only the permitted environmental skip is accepted.
SKIP=$TMP/permitted-skip
mutate_copy "$CAND" "$SKIP" \
    '.qualification.ipv6.skips=["host-global-ipv6-escape-unavailable"]
     | .qualification.ipv6.workarounds=[]'
resign_id "$SKIP/release-candidate.json"
expect_pass "$ROOT/scripts/validate-candidate.sh" \
    --candidate-dir "$SKIP" --release

# A candidate with only the explicitly authorized workaround is accepted.
WORK=$TMP/permitted-workaround
mutate_copy "$CAND" "$WORK" \
    '.qualification.ipv6.skips=[]
     | .qualification.ipv6.workarounds=[{id:"iproute2-json-normalization",applied:true}]'
resign_id "$WORK/release-candidate.json"
expect_pass "$ROOT/scripts/validate-candidate.sh" \
    --candidate-dir "$WORK" --release

# A non-release candidate passes promotion planning with its qualification
# intact, and the plan preserves the immutable artifact identity.
PROMOTE=$TMP/nonrelease
make_candidate "$PROMOTE" true
pid=$(jq -r '.candidate.id' "$PROMOTE/release-candidate.json")
psha=$(sha256_file "$PROMOTE/release-candidate.json")
expect_pass "$ROOT/scripts/promote-release.sh" \
    --candidate-dir "$PROMOTE" --qualification --dry-run --fixture \
    --candidate-id "$pid" --manifest-sha256 "$psha"
if [ "$(jq -r '.candidate.id' "$PROMOTE/release-candidate.json")" = "$pid" ] &&
    [ "$(sha256_file "$PROMOTE/release-candidate.json")" = "$psha" ] &&
    jq -e --arg n "$INTEGRATION" --arg s "$(sha256_file "$PROMOTE/$INTEGRATION")" \
        '.assets[] | select(.name == $n and .sha256 == $s)' \
        "$PROMOTE/promotion-plan.json" >/dev/null; then
    ok
else
    bad "promotion planning mutated the candidate identity or assets"
fi

# --- negative controls: required rejection cases -----------------------------

# 1. Missing IPv6 qualification evidence (rejected by the schema layer).
D=$TMP/no-ipv6
mutate_copy "$CAND" "$D" 'del(.qualification.ipv6)'
resign_id "$D/release-candidate.json"
expect_fail_with "is a required property" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 2. Missing mandatory check identifiers.
D=$TMP/missing-check
mutate_copy "$CAND" "$D" \
    '.qualification.checks |= map(select(.id != "ipv6-only-reconciler"))'
resign_id "$D/release-candidate.json"
expect_fail_with "must appear exactly once" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 3. Failed isolation assertion.
D=$TMP/failed-isolation
mutate_copy "$CAND" "$D" \
    '.qualification.checks |= map(if .id == "ipv6-only-isolation" then .status="failed" else . end)'
resign_id "$D/release-candidate.json"
expect_fail_with "qualification checks did not pass" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 4. Failed dataplane qualification.
D=$TMP/failed-dataplane
mutate_copy "$CAND" "$D" \
    '.qualification.checks |= map(if .id == "ipv6-only-dataplane" then .status="failed" else . end)'
resign_id "$D/release-candidate.json"
expect_fail_with "qualification checks did not pass" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 5. Missing mandatory packet capture.
D=$TMP/no-capture
mutate_copy "$CAND" "$D" '.qualification.ipv6.capture.status="skipped"'
resign_id "$D/release-candidate.json"
expect_fail_with "capture/status" "$ROOT/scripts/validate-candidate.sh" \
    --candidate-dir "$D" --release

# 6. Missing packaged reconciler execution.
D=$TMP/no-reconciler
mutate_copy "$CAND" "$D" '.qualification.ipv6.reconciler.status="not-performed"'
resign_id "$D/release-candidate.json"
expect_fail_with "reconciler/status" "$ROOT/scripts/validate-candidate.sh" \
    --candidate-dir "$D" --release

# 7. Incorrect immutable build identity (identity does not recompute).
D=$TMP/bad-identity
# shellcheck disable=SC2016 # jq variable, not a shell expansion
mutate_copy "$CAND" "$D" '.build.identity=$b64'
resign_id "$D/release-candidate.json"
expect_fail_with "build identity mismatch" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 8. Incorrect package digest.
D=$TMP/bad-package
# shellcheck disable=SC2016 # jq variable, not a shell expansion
mutate_copy "$CAND" "$D" '.qualification.ipv6.packageSha256=$b64'
resign_id "$D/release-candidate.json"
expect_fail_with "package hash does not match" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 9. Incorrect source commit in the evidence block.
D=$TMP/bad-source
# shellcheck disable=SC2016 # jq variable, not a shell expansion
mutate_copy "$CAND" "$D" '.qualification.ipv6.sourceCommit=$b40'
resign_id "$D/release-candidate.json"
expect_fail_with "source commit does not match" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 10. Incorrect harness identity.
D=$TMP/bad-harness
# shellcheck disable=SC2016 # jq variable, not a shell expansion
mutate_copy "$CAND" "$D" '.qualification.ipv6.harness.commit=$b40'
resign_id "$D/release-candidate.json"
expect_fail_with "harness commit does not match" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 11. Unrelated workflow run or attempt.
D=$TMP/wrong-run
mutate_copy "$CAND" "$D" '.qualification.ipv6.workflow.runId="999"'
resign_id "$D/release-candidate.json"
expect_fail_with "does not match the manifest" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

D=$TMP/wrong-attempt
mutate_copy "$CAND" "$D" '.qualification.ipv6.workflow.runAttempt="9"'
resign_id "$D/release-candidate.json"
expect_fail_with "does not match the manifest" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 12. Unauthorized workflow provenance (a different workflow file).
D=$TMP/wrong-workflow
mutate_copy "$CAND" "$D" \
    '.source.trustedWorkflow.path=".github/workflows/evil.yml"
     | .qualification.ipv6.workflow.path=".github/workflows/evil.yml"'
reseal "$D/release-candidate.json"
expect_fail_with "trusted workflow path mismatch" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 13a. Modified retained evidence file.
D=$TMP/modified-evidence
rm -rf "$D"; cp -a "$CAND" "$D"
printf 'tampered\n' >> "$D/qualification/ipv6-only/summary.txt"
expect_fail_with "evidence hash mismatch" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 13b. Missing retained evidence file.
D=$TMP/missing-evidence
rm -rf "$D"; cp -a "$CAND" "$D"
rm "$D/qualification/ipv6-only/topology-after.txt"
expect_fail_with "evidence file is missing" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 14. Unexpected skipped check.
D=$TMP/unexpected-skip
mutate_copy "$CAND" "$D" '.qualification.ipv6.skips += ["unexpected-required-check"]'
resign_id "$D/release-candidate.json"
expect_fail_with "unpermitted IPv6 skip" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 15. Unauthorized compatibility workaround.
D=$TMP/unexpected-workaround
mutate_copy "$CAND" "$D" \
    '.qualification.ipv6.workarounds += [{id:"unexpected-workaround",applied:true}]'
resign_id "$D/release-candidate.json"
expect_fail_with "unpermitted IPv6 workaround" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 16. Malformed manifest.
D=$TMP/malformed
rm -rf "$D"; cp -a "$CAND" "$D"
printf '{' > "$D/release-candidate.json"
expect_fail_with "malformed candidate JSON" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 16b. Inconsistent manifest (duplicate artifact entries).
D=$TMP/duplicate-artifact
mutate_copy "$CAND" "$D" '.artifacts += [.artifacts[0]]'
reseal "$D/release-candidate.json"
expect_fail_with "duplicate artifact names" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 17. Incorrect candidate identity.
D=$TMP/bad-candidate-id
# shellcheck disable=SC2016 # jq variable, not a shell expansion
mutate_copy "$CAND" "$D" '.candidate.id=("sha256:"+$b64)'
expect_fail_with "candidate ID mismatch" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 18. Artifact replacement after qualification.
D=$TMP/replaced-artifact
rm -rf "$D"; cp -a "$CAND" "$D"
printf 'swapped payload\n' > "$D/$INTEGRATION"
expect_fail_with "artifact size mismatch" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 19. Promotion attempt that omits IPv6 qualification. The manifest keeps a
# schema-valid ipv6 block but loses the four required check entries, so this
# reaches the semantic layer through the real promotion planner.
D=$TMP/promote-unqualified
make_candidate "$D" true
jq '.qualification.checks |= map(select(.id | startswith("ipv6-only") | not))' \
    "$D/release-candidate.json" > "$TMP/d19.json"
mv "$TMP/d19.json" "$D/release-candidate.json"
resign_id "$D/release-candidate.json"
d19id=$(jq -r '.candidate.id' "$D/release-candidate.json")
d19sha=$(sha256_file "$D/release-candidate.json")
expect_fail_with "must appear exactly once" "$ROOT/scripts/promote-release.sh" \
    --candidate-dir "$D" --qualification --dry-run --fixture \
    --candidate-id "$d19id" --manifest-sha256 "$d19sha"

# 20. The publication gate rejects an unqualified candidate and accepts the
# genuinely qualified one.
GATE_ENV=(env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch
    GITHUB_REF=refs/heads/main RELEASE_ENVIRONMENT=release-publication
    RELEASE_PUBLICATION_ENABLED=true IMMUTABLE_RELEASES_CONFIRMED=true)
D=$TMP/gate-unqualified
mutate_copy "$CAND" "$D" '.qualification.checks |= map(select(.id != "ipv6-only-capture"))'
resign_id "$D/release-candidate.json"
expect_fail_with "publication qualification contract" \
    "${GATE_ENV[@]}" "$ROOT/scripts/check-release-gates.sh" \
    --tag v0.3.1 --confirm PUBLISH --candidate-dir "$D"
expect_pass "${GATE_ENV[@]}" "$ROOT/scripts/check-release-gates.sh" \
    --tag v0.3.1 --confirm PUBLISH --candidate-dir "$CAND"

# 21. Evidence substitution from another successful candidate.
OTHER=$TMP/other-candidate
make_candidate "$OTHER"
# Regenerate the other candidate's evidence bound to a different build
# identity, so its evidence does not belong to the first candidate.
rm -rf "$OTHER/qualification/ipv6-only"
ipv6_fixture_write "$OTHER" "$C64" "$SHA" "$INTEGRATION" \
    "$(sha256_file "$OTHER/$INTEGRATION")"
D=$TMP/substituted-evidence
rm -rf "$D"; cp -a "$CAND" "$D"
rm -rf "$D/qualification/ipv6-only"
cp -a "$OTHER/qualification/ipv6-only" "$D/qualification/ipv6-only"
jq --arg s "$(sha256_file "$D/qualification/ipv6-only/summary.json")" \
    '.qualification.ipv6.evidence.summarySha256=$s' \
    "$D/release-candidate.json" > "$TMP/d20.json"
mv "$TMP/d20.json" "$D/release-candidate.json"
resign_id "$D/release-candidate.json"
expect_fail_with "does not match the manifest" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 22. The retained summary itself must pass, not only the manifest's copy of
# its claims: a failed summary is rejected even when the manifest says passed
# and the evidence hashes agree.
D=$TMP/summary-failed
rm -rf "$D"; cp -a "$CAND" "$D"
python3 - "$D/qualification/ipv6-only/summary.json" <<'PYFAIL'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["result"] = "failed"
data["counts"]["fail"] = 3
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYFAIL
jq --arg s "$(sha256_file "$D/qualification/ipv6-only/summary.json")" \
    '.qualification.ipv6.evidence.summarySha256=$s' \
    "$D/release-candidate.json" > "$TMP/d22.json"
mv "$TMP/d22.json" "$D/release-candidate.json"
resign_id "$D/release-candidate.json"
expect_fail_with "result is not passed" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 23. An evidence path that escapes the evidence directory is rejected.
D=$TMP/evidence-traversal
rm -rf "$D"; cp -a "$CAND" "$D"
jq '.qualification.checks |= map(
      if .id == "ipv6-only-isolation" then .evidenceFile="../release-candidate.json" else . end)' \
    "$D/release-candidate.json" > "$TMP/d23.json"
mv "$TMP/d23.json" "$D/release-candidate.json"
resign_id "$D/release-candidate.json"
expect_fail_with "unsafe relative path" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$D" --release

# 24. Published-asset mode accepts the manifest without the raw evidence
# directory, but still rejects a failed qualification status.
D=$TMP/published-assets
rm -rf "$D"; cp -a "$CAND" "$D"
rm -rf "$D/qualification/ipv6-only"
expect_pass "$ROOT/scripts/validate-candidate.sh" \
    --candidate-dir "$D" --release --published-assets
jq '.qualification.ipv6.status="failed"' "$D/release-candidate.json" > "$TMP/d24.json"
mv "$TMP/d24.json" "$D/release-candidate.json"
resign_id "$D/release-candidate.json"
expect_fail_with "status is not passed" "$ROOT/scripts/validate-candidate.sh" \
    --candidate-dir "$D" --release --published-assets

echo "unit-release-ipv6-gate: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
