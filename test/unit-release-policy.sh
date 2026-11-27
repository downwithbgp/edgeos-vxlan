#!/bin/bash
# Regression tests for the release policy surface.
#
# release/release-policy.json is a security contract. Every key in it must be
# consumed by code, because a key nothing reads still reads like a control to
# anyone auditing the repository. These tests fail when a decorative or
# unimplemented control is introduced, and they pin the removal of the controls
# that previously implied guarantees they did not provide.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
POLICY=$ROOT/release/release-policy.json
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad()
{
    FAIL=$((FAIL + 1))
    echo "FAIL: $*" >&2
}

# The complete implemented surface. A new key must be added here *and* have a
# consumer below, so it cannot be introduced silently.
EXPECTED_SURFACE="attestation.provenancePredicate
attestation.sbomPredicate
attestation.workflowPath
image.registry
image.repository
project.name
project.repository
project.repositoryId
publication.confirmValue
publication.enableVariable
publication.environment
publication.immutableConfirmedVariable
release.baselinePublishedVersion
release.canonicalFrom
release.immutableFrom
release.requiredAssets[]
schemaVersion"

# --- structure ---------------------------------------------------------------
[ "$(jq -r '.schemaVersion' "$POLICY")" = "1" ] && ok || bad "policy schemaVersion is not 1"

actual=$(jq -r '
    [paths(scalars) | map(if type == "number" then "[]" else . end) | join(".")]
    | map(gsub("\\.\\[\\]"; "[]"))
    | unique | sort | .[]
' "$POLICY")
if [ "$actual" = "$EXPECTED_SURFACE" ]; then
    ok
else
    bad "policy surface changed; update EXPECTED_SURFACE only with a consumer"
    diff <(printf '%s\n' "$EXPECTED_SURFACE") <(printf '%s\n' "$actual") >&2 || true
fi

# --- removed decorative controls must stay removed ---------------------------
for path in 'publication.signedTagsVariable' 'pinCommit' 'packagingInputs' \
            'project.integrationPackage' 'project.kernelPackage' \
            'project.versionSuffix' 'image.publicationEnvironment' \
            'image.publicationVariable' 'image.artifactRetentionDays'; do
    if jq -e ".$path" "$POLICY" >/dev/null 2>&1; then
        bad "decorative policy control reintroduced: $path"
    else
        ok
    fi
done

# --- no policy key may imply tag-signature enforcement -----------------------
if jq -r '[paths | map(tostring) | join(".")] | .[]' "$POLICY" |
    grep -Eqi 'sign|gpg|pgp'; then
    bad "policy implies tag-signature enforcement, which this lifecycle does not perform"
else
    ok
fi

# --- every policy key must be read by the trusted tooling -------------------
unread=""
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! grep -rqF ".$path" "$ROOT/scripts" "$ROOT/.github"; then
        unread="${unread}${unread:+, }$path"
    fi
done <<EOF
$EXPECTED_SURFACE
EOF
[ -z "$unread" ] && ok || bad "policy keys no script reads: $unread"

# --- authorization gates must read their names from policy -------------------
# The gate must not hardcode the environment or variable names it enforces,
# otherwise the policy value is decorative and the two can drift.
for path in publication.environment publication.enableVariable \
            publication.immutableConfirmedVariable publication.confirmValue; do
    if grep -qF ".$path" "$ROOT/scripts/check-release-gates.sh"; then
        ok
    else
        bad "check-release-gates.sh does not read .$path from policy"
    fi
done

# --- attestation expectations must come from policy -------------------------
for path in attestation.provenancePredicate attestation.sbomPredicate \
            attestation.workflowPath; do
    if grep -qF ".$path" "$ROOT/scripts/verify-attestations.sh"; then
        ok
    else
        bad "verify-attestations.sh does not read .$path from policy"
    fi
done

# --- the historical baseline must not be the only version gate --------------
# baselinePublishedVersion classifies legacy releases; publication eligibility
# must consult the newest published release instead.
if grep -qF '.release.baselinePublishedVersion' "$ROOT/scripts/build-release-candidate.sh" &&
    ! grep -qF "jq -r '.release.baselinePublishedVersion'" "$ROOT/scripts/promote-release.sh" &&
    grep -qF 'check-version-eligibility.sh' "$ROOT/scripts/promote-release.sh"; then
    ok
else
    bad "publication eligibility must resolve the newest published version, not the static baseline"
fi

echo "unit-release-policy: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
