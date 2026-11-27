#!/bin/sh
# Shared helpers for the trusted release lifecycle.
#
# This file is sourced by release scripts. It deliberately performs no work on
# its own and does not enable shell options; callers set their own strict mode.
#
# Runtime: host/CI shell. Requires jq, sha256sum, awk and sed. The controlled
# build image is not required to contain these tools.

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

note()
{
    echo "NOTE: $*" >&2
}

require_cmd()
{
    for _cmd in "$@"; do
        command -v "$_cmd" >/dev/null 2>&1 ||
            fail "required command not found: $_cmd"
    done
}

require_file()
{
    [ -f "$1" ] || fail "required file not found: $1"
}

require_dir()
{
    [ -d "$1" ] || fail "required directory not found: $1"
}

is_sha256()
{
    printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'
}

is_digest()
{
    printf '%s' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'
}

is_commit()
{
    case "$1" in
        *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

is_candidate_id()
{
    printf '%s' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'
}

is_release_tag()
{
    [ "$(printf '%s\n' "$1" | wc -l)" -eq 1 ] || return 1
    printf '%s\n' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
}

require_single_line()
{
    [ "$(printf '%s\n' "$1" | wc -l)" -eq 1 ] ||
        fail "$2 must be a single line"
}

require_sha256_field()
{
    is_sha256 "$2" || fail "$1 is not a lowercase SHA-256: $2"
}

require_digest_field()
{
    is_digest "$2" || fail "$1 is not a sha256:<hex> digest: $2"
}

require_commit_field()
{
    is_commit "$2" || fail "$1 is not a 40/64-character lowercase Git commit: $2"
}

require_candidate_id_field()
{
    is_candidate_id "$2" || fail "$1 is not a candidate ID: $2"
}

require_env()
{
    _value=$(printenv "$1" 2>/dev/null || true)
    [ -n "$_value" ] || fail "required environment variable is not set: $1"
}

sha256_file()
{
    sha256sum "$1" | awk '{print $1}'
}

manifest_get()
{
    jq -er "$2" "$1"
}

manifest_get_optional()
{
    jq -r "$2" "$1"
}

manifest_sha256()
{
    sha256_file "$1"
}

canonical_json()
{
    jq -cS .
}

canonical_identity()
{
    jq -cS '{
        schemaVersion: .schemaVersion,
        candidate: {
            status: .candidate.status,
            nonRelease: .candidate.nonRelease
        },
        project: .project,
        source: .source,
        buildEnvironment: .buildEnvironment,
        build: .build,
        artifacts: (.artifacts | sort_by(.name)),
        qualification: .qualification,
        limitations: .limitations
    }' "$1"
}

candidate_id_from_manifest()
{
    canonical_identity "$1" | sha256sum | awk '{print "sha256:" $1}'
}

check_candidate_id()
{
    _expected=$(manifest_get "$1" '.candidate.id')
    _actual=$(candidate_id_from_manifest "$1")
    [ "$_expected" = "$_actual" ] ||
        fail "candidate ID mismatch: manifest has $_expected, identity computes $_actual"
}

check_manifest_sha256()
{
    _expected=$2
    is_sha256 "$_expected" || fail "expected manifest hash is not a SHA-256: $_expected"
    _actual=$(manifest_sha256 "$1")
    [ "$_actual" = "$_expected" ] ||
        fail "manifest SHA-256 mismatch: $_actual != $_expected"
}

validate_artifact_name()
{
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*$' ||
        fail "invalid artifact name: $1"
}

validate_relative_path()
{
    case "$1" in
        ''|/*|*../*|..|*/..)
            fail "unsafe relative path: $1"
            ;;
    esac
}

# Compare a tag's Debian version with a policy threshold. Prints 0 when the
# tag version is greater than or equal to the threshold, 1 otherwise.
tag_version_at_least()
{
    _tag=${1#v}
    _threshold=${2#v}
    dpkg --compare-versions "$_tag" ge "$_threshold"
}

json_escape()
{
    printf '%s' "$1" | jq -Rs .
}

# Resolve a loaded Docker image to an immutable execution reference.
# Prefer a RepoDigest matching the OCI manifest. Some Docker stores expose no
# RepoDigest after loading a Docker archive; in that case accept the local tag
# only when its image ID equals the qualified config/manifest digest. Callers
# must additionally verify the config JSON hash.
resolve_loaded_image_ref()
{
    _image=$1
    _manifest=$2
    _config=$3
    _repo_ref=$(docker image inspect "$_image" \
        --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null |
        awk -v d="$_manifest" 'index($0, d) { print; exit }')
    if [ -n "$_repo_ref" ]; then
        printf '%s\n' "$_repo_ref"
        return 0
    fi
    _image_id=$(docker image inspect "$_image" --format '{{.Id}}' 2>/dev/null) ||
        return 1
    if [ "$_image_id" = "$_manifest" ] || [ "$_image_id" = "$_config" ]; then
        printf '%s\n' "$_image"
        return 0
    fi
    return 1
}
