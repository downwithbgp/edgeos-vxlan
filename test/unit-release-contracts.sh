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
    {
        add_file "$dir" "edgeos-vxlan_${version}_all.deb" package "integration"
        add_file "$dir" "edgeos-vxlan-kmod_${version}_mipsel.deb" package "kmod"
        add_file "$dir" "edgeos-vxlan_${version}_mipsel.buildinfo" debian-metadata "buildinfo"
        add_file "$dir" "edgeos-vxlan_${version}_mipsel.changes" debian-metadata "changes"
        add_file "$dir" "sbom-edgeos-vxlan.spdx.json" sbom "{}"
        add_file "$dir" "sbom-edgeos-vxlan-kmod.spdx.json" sbom "{}"
        add_file "$dir" "build-environment-qualification.json" environment-qualification "{}"
    } >> "$tsv"
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

# Unexpected top-level entry (transient build state) must be rejected.
cp -a "$CAND" "$TMP/unexpected-file"
mkdir -p "$TMP/unexpected-file/.work"
expect_fail_with "unexpected candidate file: .work" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$TMP/unexpected-file" --release

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

# SBOM predicate binding. The attested predicate must be exactly the shipped
# SBOM and must be bound to the package subject digest.
make_sbom_bundle()
{
    local bundle=$1 package=$2 sbom=$3
    python3 - "$bundle" "$package" "$sbom" <<'PY'
import base64, json, sys
from hashlib import sha256
from pathlib import Path

bundle_path, package_path, sbom_path = (Path(arg) for arg in sys.argv[1:4])
digest = sha256(package_path.read_bytes()).hexdigest()
predicate = json.loads(sbom_path.read_text(encoding="utf-8"))
statement = {
    "_type": "https://in-toto.io/Statement/v1",
    "subject": [{"name": package_path.name, "digest": {"sha256": digest}}],
    "predicateType": "https://spdx.dev/Document/v2.3",
    "predicate": predicate,
}
envelope = {
    "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
    "dsseEnvelope": {
        "payloadType": "application/vnd.in-toto+json",
        "payload": base64.b64encode(json.dumps(statement).encode()).decode(),
        "signatures": [],
    },
}
bundle_path.write_text(json.dumps(envelope) + "\n", encoding="utf-8")
PY
}

SBOM_PKG=$CAND/edgeos-vxlan_0.3.1+edgeos3.0.1.e50_all.deb
SBOM_FILE=$CAND/sbom-edgeos-vxlan.spdx.json
make_sbom_bundle "$TMP/bundle-int.jsonl" "$SBOM_PKG" "$SBOM_FILE"
expect_pass "$ROOT/scripts/verify-sbom-predicate.sh" \
    --bundle "$TMP/bundle-int.jsonl" --package "$SBOM_PKG" --sbom "$SBOM_FILE"

# A modified SBOM must not satisfy the attested predicate.
cp "$SBOM_FILE" "$TMP/tampered.spdx.json"
jq '.name="tampered"' "$SBOM_FILE" > "$TMP/tampered.spdx.json"
expect_fail_with "does not match" \
    "$ROOT/scripts/verify-sbom-predicate.sh" \
    --bundle "$TMP/bundle-int.jsonl" --package "$SBOM_PKG" \
    --sbom "$TMP/tampered.spdx.json"

# The predicate must be bound to the package subject digest. A file with the
# same name but different bytes must not satisfy it (a byte-identical copy
# under another name would only exercise the name check).
mkdir -p "$TMP/same-name"
cp "$SBOM_PKG" "$TMP/same-name/$(basename "$SBOM_PKG")"
printf 'appended\n' >> "$TMP/same-name/$(basename "$SBOM_PKG")"
expect_fail_with "expected exactly one" \
    "$ROOT/scripts/verify-sbom-predicate.sh" \
    --bundle "$TMP/bundle-int.jsonl" \
    --package "$TMP/same-name/$(basename "$SBOM_PKG")" --sbom "$SBOM_FILE"

# A different name with identical bytes must also fail: the subject name is
# part of the binding.
cp "$SBOM_PKG" "$TMP/other.deb"
expect_fail_with "expected exactly one" \
    "$ROOT/scripts/verify-sbom-predicate.sh" \
    --bundle "$TMP/bundle-int.jsonl" --package "$TMP/other.deb" --sbom "$SBOM_FILE"

# The unversioned SPDX predicate type is not what GitHub emits.
expect_fail_with "unsupported SBOM predicate type" \
    "$ROOT/scripts/verify-sbom-predicate.sh" \
    --bundle "$TMP/bundle-int.jsonl" --package "$SBOM_PKG" --sbom "$SBOM_FILE" \
    --predicate-type https://spdx.dev/Document

# The policy must pin the versioned predicate type GitHub actually emits.
[ "$(jq -r '.attestation.sbomPredicate' "$ROOT/release/release-policy.json")" = \
  "https://spdx.dev/Document/v2.3" ] && ok || bad "policy SBOM predicate is not versioned"

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

# --- adversarial matrix: qualification evidence, digests, duplication --------

# One failed qualification check must reject the whole candidate.
QUALFAIL=$TMP/qual-fail
cp -a "$CAND" "$QUALFAIL"
jq '.qualification.checks[0].status="failed"' "$CAND/release-candidate.json" \
    > "$QUALFAIL/release-candidate.json"
qid=$(candidate_id_from_manifest "$QUALFAIL/release-candidate.json")
jq --arg id "$qid" '.candidate.id=$id' "$QUALFAIL/release-candidate.json" > "$TMP/q1"
mv "$TMP/q1" "$QUALFAIL/release-candidate.json"
expect_fail_with "qualification checks did not pass" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$QUALFAIL" --release

# A candidate whose qualification status is not passed is rejected.
# "failed" is schema-valid, so this exercises the semantic layer.
STATUSFAIL=$TMP/status-fail
cp -a "$CAND" "$STATUSFAIL"
jq '.qualification.status="failed"' "$CAND/release-candidate.json" \
    > "$STATUSFAIL/release-candidate.json"
sid=$(candidate_id_from_manifest "$STATUSFAIL/release-candidate.json")
jq --arg id "$sid" '.candidate.id=$id' "$STATUSFAIL/release-candidate.json" > "$TMP/s1"
mv "$TMP/s1" "$STATUSFAIL/release-candidate.json"
expect_fail_with "qualification status is not passed" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$STATUSFAIL" --release

# A malformed (non-digest) manifest digest is rejected by the schema, before
# the semantic layer is reached. Digests are therefore never merely stringy.
BADDIGEST=$TMP/bad-digest
cp -a "$CAND" "$BADDIGEST"
jq '.buildEnvironment.manifestDigest="not-a-digest"' "$CAND/release-candidate.json" \
    > "$BADDIGEST/release-candidate.json"
did=$(candidate_id_from_manifest "$BADDIGEST/release-candidate.json")
jq --arg id "$did" '.candidate.id=$id' "$BADDIGEST/release-candidate.json" > "$TMP/d1"
mv "$TMP/d1" "$BADDIGEST/release-candidate.json"
expect_fail_with "buildEnvironment/manifestDigest" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$BADDIGEST" --release

# Duplicate artifact names are rejected.
DUP=$TMP/duplicate
cp -a "$CAND" "$DUP"
jq '.artifacts += [.artifacts[0]]' "$CAND/release-candidate.json" \
    > "$DUP/release-candidate.json"
dupid=$(candidate_id_from_manifest "$DUP/release-candidate.json")
jq --arg id "$dupid" '.candidate.id=$id' "$DUP/release-candidate.json" > "$TMP/du1"
mv "$TMP/du1" "$DUP/release-candidate.json"
expect_fail_with "duplicate artifact names" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$DUP" --release

# An unexpected artifact role is rejected by the schema layer.
BADROLE=$TMP/bad-role
cp -a "$CAND" "$BADROLE"
jq '.artifacts[0].role="executable"' "$CAND/release-candidate.json" \
    > "$BADROLE/release-candidate.json"
rid=$(candidate_id_from_manifest "$BADROLE/release-candidate.json")
jq --arg id "$rid" '.candidate.id=$id' "$BADROLE/release-candidate.json" > "$TMP/r1"
mv "$TMP/r1" "$BADROLE/release-candidate.json"
expect_fail_with "artifacts/0/role" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$BADROLE" --release

# --- adversarial matrix: publication authorization ----------------------------

# Publication must come from main.
expect_fail_with "must run from refs/heads/main" \
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch \
        GITHUB_REF=refs/heads/feature RELEASE_ENVIRONMENT=release-publication \
        RELEASE_PUBLICATION_ENABLED=true IMMUTABLE_RELEASES_CONFIRMED=true \
        "$ROOT/scripts/check-release-gates.sh" --tag v0.3.1 --confirm PUBLISH

# Publication must run in the protected environment.
expect_fail_with "publication environment is not" \
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch \
        GITHUB_REF=refs/heads/main RELEASE_ENVIRONMENT=other \
        RELEASE_PUBLICATION_ENABLED=true IMMUTABLE_RELEASES_CONFIRMED=true \
        "$ROOT/scripts/check-release-gates.sh" --tag v0.3.1 --confirm PUBLISH

# Publication requires the enable variable.
expect_fail_with "is not true" \
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch \
        GITHUB_REF=refs/heads/main RELEASE_ENVIRONMENT=release-publication \
        RELEASE_PUBLICATION_ENABLED=false IMMUTABLE_RELEASES_CONFIRMED=true \
        "$ROOT/scripts/check-release-gates.sh" --tag v0.3.1 --confirm PUBLISH

# Immutable confirmation is required.
expect_fail_with "immutable" \
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch \
        GITHUB_REF=refs/heads/main RELEASE_ENVIRONMENT=release-publication \
        RELEASE_PUBLICATION_ENABLED=true \
        "$ROOT/scripts/check-release-gates.sh" --tag v0.3.1 --confirm PUBLISH

# The exact confirmation string is required.
expect_fail_with "confirmation value does not match" \
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch \
        GITHUB_REF=refs/heads/main RELEASE_ENVIRONMENT=release-publication \
        RELEASE_PUBLICATION_ENABLED=true IMMUTABLE_RELEASES_CONFIRMED=true \
        "$ROOT/scripts/check-release-gates.sh" --tag v0.3.1 --confirm publish

# A full set of correct gates passes (the only accepted combination).
expect_pass env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main RELEASE_ENVIRONMENT=release-publication \
    RELEASE_PUBLICATION_ENABLED=true IMMUTABLE_RELEASES_CONFIRMED=true \
    "$ROOT/scripts/check-release-gates.sh" --tag v0.3.1 --confirm PUBLISH

# --- adversarial matrix: attestation identity ---------------------------------

# Exercises the real verifier against a mocked GitHub CLI. Signature crypto is
# covered by the live acceptance run; these cases pin the identity semantics.
FAKE_ATTEST_GH=$TMP/fake-attest-gh
cat > "$FAKE_ATTEST_GH" <<'EOF'
#!/bin/sh
set -eu
[ "${FAKE_ATTEST_FAIL:-}" = "yes" ] && { echo "no attestations found" >&2; exit 1; }
cat "$FAKE_ATTEST_OUTPUT"
EOF
chmod +x "$FAKE_ATTEST_GH"
BUNDLE_FILE=$TMP/bundle-identity.jsonl
: > "$BUNDLE_FILE"

verify_with_identity()
{
    GH_BIN=$FAKE_ATTEST_GH FAKE_ATTEST_OUTPUT=$1 \
        "$ROOT/scripts/verify-attestations.sh" \
        --candidate-dir "$CAND" --bundle "$BUNDLE_FILE" --no-sbom
}

# Wrong repository identifier in the signing certificate.
jq -n '[{verificationResult:{signature:{certificate:{sourceRepositoryIdentifier: 999}}}}]' \
    > "$TMP/id-wrong.json"
expect_fail_with "attestation repository ID 999 != expected" \
    verify_with_identity "$TMP/id-wrong.json"

# Missing repository identifier.
jq -n '[{verificationResult:{signature:{certificate:{}}}}]' > "$TMP/id-missing.json"
expect_fail_with "exposes no repository identifier" \
    verify_with_identity "$TMP/id-missing.json"

# Multiple repository identifiers are ambiguous.
jq -n '[{verificationResult:{signature:{certificate:{sourceRepositoryIdentifier: 1}}}},
        {verificationResult:{signature:{certificate:{sourceRepositoryIdentifier: 2}}}}]' \
    > "$TMP/id-multiple.json"
expect_fail_with "multiple repository identifiers" \
    verify_with_identity "$TMP/id-multiple.json"

# A failed gh verification must not be treated as success.
expect_fail_with "attestation verification failed" \
    env GH_BIN="$FAKE_ATTEST_GH" FAKE_ATTEST_FAIL=yes \
        FAKE_ATTEST_OUTPUT="$TMP/id-wrong.json" \
        "$ROOT/scripts/verify-attestations.sh" \
        --candidate-dir "$CAND" --bundle "$BUNDLE_FILE" --no-sbom

# The genuine repository identifier is accepted.
jq -n '[{verificationResult:{signature:{certificate:{sourceRepositoryIdentifier: 1357738281}}}}]' \
    > "$TMP/id-good.json"
expect_pass verify_with_identity "$TMP/id-good.json"

# --- adversarial matrix: malformed evidence -----------------------------------

# A malformed attestation bundle is rejected, not ignored.
printf 'not-json\n' > "$TMP/bundle-bad.jsonl"
expect_fail_with "cannot parse the attestation bundle" \
    "$ROOT/scripts/verify-sbom-predicate.sh" \
    --bundle "$TMP/bundle-bad.jsonl" --package "$SBOM_PKG" --sbom "$SBOM_FILE"

# A malformed SBOM is rejected, not silently compared.
printf 'not json\n' > "$TMP/bad.spdx.json"
expect_fail_with "cannot parse the expected SBOM" \
    "$ROOT/scripts/verify-sbom-predicate.sh" \
    --bundle "$TMP/bundle-int.jsonl" --package "$SBOM_PKG" \
    --sbom "$TMP/bad.spdx.json"

# --- adversarial matrix: concurrent candidates --------------------------------

# Two candidates for the same version must not share an identity when their
# content differs, and the release workflow must serialize them per tag.
CONC_A=$TMP/concurrent-a
make_candidate "$CONC_A" "0.3.1+edgeos3.0.1.e50" "v0.3.1" false
CONC_B=$TMP/concurrent-b
cp -a "$CONC_A" "$CONC_B"
printf 'different payload\n' > "$CONC_B/edgeos-vxlan_0.3.1+edgeos3.0.1.e50_all.deb"
b_entries=$(jq -r '.artifacts[] | [.name, .role] | @tsv' "$CONC_A/release-candidate.json" |
    while IFS=$'\t' read -r name role; do
        jq -n --arg name "$name" --arg role "$role" \
            --argjson size "$(stat -c '%s' "$CONC_B/$name")" \
            --arg sha256 "$(sha256_file "$CONC_B/$name")" \
            '{name:$name,role:$role,size:$size,sha256:$sha256}'
    done | jq -s .)
jq --argjson a "$b_entries" '.artifacts=$a' "$CONC_B/release-candidate.json" \
    > "$TMP/cb.json"
mv "$TMP/cb.json" "$CONC_B/release-candidate.json"
b_id=$(candidate_id_from_manifest "$CONC_B/release-candidate.json")
jq --arg id "$b_id" '.candidate.id=$id' "$CONC_B/release-candidate.json" > "$TMP/cb2.json"
mv "$TMP/cb2.json" "$CONC_B/release-candidate.json"
a_id=$(jq -r '.candidate.id' "$CONC_A/release-candidate.json")
[ "$a_id" != "$b_id" ] && ok || bad "concurrent candidates shared an identity"
# A stale ID from the other concurrent candidate cannot pass validation.
CONC_STALE=$TMP/concurrent-stale
cp -a "$CONC_A" "$CONC_STALE"
jq --arg id "$b_id" '.candidate.id=$id' "$CONC_A/release-candidate.json" \
    > "$CONC_STALE/release-candidate.json"
expect_fail_with "candidate ID mismatch" \
    "$ROOT/scripts/validate-candidate.sh" --candidate-dir "$CONC_STALE" --release
# The workflow must serialize publication per tag and never cancel a run.
grep -qF "group: trusted-release-\${{ github.ref }}-\${{ inputs.release_tag ||" \
    "$ROOT/.github/workflows/release.yml" &&
    grep -qF 'cancel-in-progress: false' "$ROOT/.github/workflows/release.yml" &&
    ok || bad "release workflow does not serialize concurrent candidates"

echo "unit-release-contracts: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]