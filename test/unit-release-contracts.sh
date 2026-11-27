#!/bin/bash
# Contract tests for the canonical release verifier, image qualification
# policy, and publication authorization gates. Uses synthetic artifacts; no
# network, Docker or GitHub API is required.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-contracts.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0
HEX=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA=0123456789abcdef0123456789abcdef01234567

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
        sed 's/^/    /' "$TMP/err" | tail -10 >&2
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
        sed 's/^/    /' "$TMP/err" | tail -8 >&2
    fi
}

add_file()
{
    local dir=$1 name=$2 role=$3 content=$4
    printf '%s\n' "$content" > "$dir/$name"
    printf '%s\t%s\n' "$name" "$role"
}

make_candidate()
{
    local dir=$1 version=$2 tag=$3 non_release=$4
    rm -rf "$dir"
    mkdir -p "$dir"
    local tsv=$TMP/artifacts.tsv
    : > "$tsv"
    add_file "$dir" "edgeos-vxlan_${version}_all.deb" package "integration" >> "$tsv"
    add_file "$dir" "edgeos-vxlan-kmod_${version}_mipsel.deb" package "kmod" >> "$tsv"
    add_file "$dir" "edgeos-vxlan_${version}_mipsel.buildinfo" debian-metadata "buildinfo" >> "$tsv"
    add_file "$dir" "edgeos-vxlan_${version}_mipsel.changes" debian-metadata "changes" >> "$tsv"
    add_file "$dir" "sbom-edgeos-vxlan.spdx.json" sbom "{}" >> "$tsv"
    add_file "$dir" "sbom-edgeos-vxlan-kmod.spdx.json" sbom "{}" >> "$tsv"
    add_file "$dir" "build-environment-qualification.json" environment-qualification "{}" >> "$tsv"
    printf '{}\n' > "$dir/build-environment-image.spdx.json"

    jq -R -s '[split("\n")[] | select(length > 0) | split("\t") | {name:.[0], role:.[1]}]' "$tsv" > "$TMP/names.json"
    jq -n \
        --arg version "$version" --arg tag "$tag" --argjson nonrelease "$non_release" \
        --arg hex "$HEX" --arg sha "$SHA" \
        --arg policy "$(sha256_file "$ROOT/release/release-policy.json")" \
        --argjson names "$(cat "$TMP/names.json")" \
        'def art($n): {
            name:$n.name, role:$n.role,
            size: (input_filename | length),
            sha256: $hex
        };
        {
          schemaVersion:"https://edgeos-vxlan.dev/release-candidate/v1",
          candidate:{id:"",createdAt:"2026-11-27T00:00:00Z",status:"qualified",nonRelease:$nonrelease},
          project:{name:"edgeos-vxlan",repository:"downwithbgp/edgeos-vxlan",repositoryId:1357738281,
                   releaseTag:$tag,packageVersion:$version,sourceDateEpoch:1795743000,releasePolicySha256:$policy},
          source:{commit:$sha,archiveSha256:$hex,packagingInputsSha256:$hex,
                  trustedWorkflow:{repository:"downwithbgp/edgeos-vxlan",path:".github/workflows/release.yml",
                                   ref:"refs/heads/main",commit:$sha}},
          buildEnvironment:{image:("edgeos-vxlan-reproducible@sha256:"+$hex),
                   ociIndexDigest:("sha256:"+$hex),manifestDigest:("sha256:"+$hex),
                   configDigest:("sha256:"+$hex),ociArchiveSha256:$hex,dockerArchiveSha256:$hex,
                   dockerfileSha256:$hex,caBundleSha256:$hex,dependencySnapshot:"20261127T000000Z",
                   dependencyInventorySha256:$hex,qualificationSha256:$hex,imageSbomSha256:$hex},
          build:{buildType:"type",command:"cmd",
                 reproducibility:{status:"passed",comparedArtifacts:["x"]}},
          artifacts: $names,
          qualification:{status:"passed",checks:[{id:"check",status:"passed",evidenceSha256:$hex}],
                         hardware:{status:"not-required",required:false,evidence:[]}},
          limitations:["synthetic"]
        }' > "$dir/release-candidate.json"

    # Fill real sizes/hashes for the synthetic artifact files.
    local entries=""
    while IFS=$'\t' read -r name role; do
        [ -n "$name" ] || continue
        entry=$(jq -n --arg name "$name" --arg role "$role" \
            --argjson size "$(stat -c '%s' "$dir/$name")" \
            --arg sha256 "$(sha256_file "$dir/$name")" \
            '{name:$name,role:$role,size:$size,sha256:$sha256}')
        entries="${entries}${entries:+,}$entry"
    done < "$tsv"
    jq --argjson entries "[$entries]" '.artifacts=$entries' \
        "$dir/release-candidate.json" > "$TMP/candidate.json"
    mv "$TMP/candidate.json" "$dir/release-candidate.json"

    # Qualification and image SBOM hashes must match their files.
    local qsha isha
    qsha=$(sha256_file "$dir/build-environment-qualification.json")
    isha=$(sha256_file "$dir/build-environment-image.spdx.json")
    jq --arg q "$qsha" --arg i "$isha" \
        '.buildEnvironment.qualificationSha256=$q | .buildEnvironment.imageSbomSha256=$i' \
        "$dir/release-candidate.json" > "$TMP/candidate.json"
    mv "$TMP/candidate.json" "$dir/release-candidate.json"

    # Package-only SHA256SUMS.
    printf '%s  %s\n' \
        "$(sha256_file "$dir/edgeos-vxlan_${version}_all.deb")" "edgeos-vxlan_${version}_all.deb" \
        "$(sha256_file "$dir/edgeos-vxlan-kmod_${version}_mipsel.deb")" "edgeos-vxlan-kmod_${version}_mipsel.deb" \
        > "$dir/SHA256SUMS"

    local id
    id=$(candidate_id_from_manifest "$dir/release-candidate.json")
    jq --arg id "$id" '.candidate.id=$id' "$dir/release-candidate.json" > "$TMP/candidate.json"
    mv "$TMP/candidate.json" "$dir/release-candidate.json"
}

# --- candidate semantic validity ---------------------------------------
CAND=$TMP/candidate
make_candidate "$CAND" "0.3.1+edgeos3.0.1.e50" "v0.3.1" false
expect_pass "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$CAND" --release

# Candidate-ID substitution.
cp -a "$CAND" "$TMP/manifest-sub"
jq --arg id "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    '.candidate.id=$id' "$CAND/release-candidate.json" \
    > "$TMP/manifest-sub/release-candidate.json"
expect_fail_with "candidate ID mismatch" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$TMP/manifest-sub" --release

# Artifact substitution.
cp -a "$CAND" "$TMP/artifact-sub"
printf 'x' >> "$TMP/artifact-sub/edgeos-vxlan_0.3.1+edgeos3.0.1.e50_all.deb"
expect_fail_with "artifact size mismatch" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$TMP/artifact-sub" --release

# Missing SBOM.
cp -a "$CAND" "$TMP/missing-sbom"
rm "$TMP/missing-sbom/sbom-edgeos-vxlan-kmod.spdx.json"
jq '.artifacts |= map(select(.name != "sbom-edgeos-vxlan-kmod.spdx.json"))' \
    "$CAND/release-candidate.json" > "$TMP/missing-sbom/release-candidate.json"
missing_id=$(candidate_id_from_manifest "$TMP/missing-sbom/release-candidate.json")
jq --arg id "$missing_id" '.candidate.id=$id' \
    "$TMP/missing-sbom/release-candidate.json" > "$TMP/missing-sbom/id.json"
mv "$TMP/missing-sbom/id.json" "$TMP/missing-sbom/release-candidate.json"
expect_fail_with "missing required artifact" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$TMP/missing-sbom" --release

# Missing attestation bundle (offline verifier).
expect_fail_with "required file not found" \
    "$ROOT/scripts/verify-attestations.sh" --candidate-dir "$CAND" \
    --bundle "$TMP/no-such-bundle.jsonl"

# Release-mode downgrade: nonRelease candidate must not verify as a release.
NONREL=$TMP/nonrelease
make_candidate "$NONREL" "0.3.1+edgeos3.0.1.e50" "v0.3.1" true
expect_fail_with "release candidate is marked nonRelease" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$NONREL" --release

# Wrong workflow ref must fail release mode.
WRONGREF=$TMP/wrong-ref
cp -a "$CAND" "$WRONGREF"
jq '.source.trustedWorkflow.ref="refs/heads/feature"' \
    "$CAND/release-candidate.json" > "$WRONGREF/release-candidate.json"
id=$(candidate_id_from_manifest "$WRONGREF/release-candidate.json")
jq --arg id "$id" '.candidate.id=$id' "$WRONGREF/release-candidate.json" > "$TMP/x"
mv "$TMP/x" "$WRONGREF/release-candidate.json"
expect_fail_with "workflow ref is not refs/heads/main" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$WRONGREF" --release

# Historical version reuse: production candidate at the published version.
REUSE=$TMP/reuse
make_candidate "$REUSE" "0.3.0+edgeos3.0.1.e50" "v0.3.0" false
expect_fail_with "not newer than published" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$REUSE" --production

# Canonical release with missing manifest must not fall back to legacy.
EMPTY_ASSETS=$TMP/empty-assets
EMPTY_SOURCE=$TMP/empty-source
mkdir -p "$EMPTY_ASSETS" "$EMPTY_SOURCE"
printf 'VERSION="0.3.1"\nPKG_VERSION="0.3.1+edgeos3.0.1.e50"\n' > "$EMPTY_SOURCE/install.sh"
expect_fail_with "missing release-candidate.json" \
    "$ROOT/scripts/verify-release.sh" --asset-dir "$EMPTY_ASSETS" \
    --source-dir "$EMPTY_SOURCE" --tag v0.3.1

# Publication gates: unauthorized and no-admin-token.
expect_fail_with "must run in GitHub Actions" \
    env -u GITHUB_ACTIONS "$ROOT/scripts/check-release-gates.sh" --tag v0.3.1 --confirm PUBLISH
expect_fail_with "administrative immutable-release tokens are not accepted" \
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main \
        RELEASE_ENVIRONMENT=release-publication RELEASE_PUBLICATION_ENABLED=true \
        IMMUTABLE_RELEASES_CONFIRMED=true IMMUTABLE_RELEASES_ADMIN_TOKEN=x \
        "$ROOT/scripts/check-release-gates.sh" --tag v0.3.1 --confirm PUBLISH

echo "unit-release-contracts: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
