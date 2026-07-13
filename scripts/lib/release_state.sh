#!/usr/bin/env bash

# Safety checks shared by the resumable GitHub release workflow and its
# executable fixture tests. Callers should enable `set -euo pipefail`.

release_assert_existing_tag_matches_head() {
  local version="$1"
  local tag="v$version"
  local tagged_commit
  local head_commit

  if ! tagged_commit="$(git rev-parse --verify "refs/tags/$tag^{commit}" 2>/dev/null)"; then
    return 0
  fi
  head_commit="$(git rev-parse HEAD)"
  if [[ "$tagged_commit" != "$head_commit" ]]; then
    echo "::error::Existing tag $tag does not point to the prepared release commit." >&2
    return 1
  fi
}

release_assert_resumable_github_release() {
  local version="$1"
  local tag="v$version"
  local error_file
  local is_draft

  error_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/codex-release-view.XXXXXX")"
  if ! is_draft="$(gh release view "$tag" --json isDraft --jq '.isDraft' 2>"$error_file")"; then
    if grep -Eqi 'release not found|HTTP 404|not found' "$error_file"; then
      rm -f -- "$error_file"
      return 0
    fi
    cat "$error_file" >&2
    rm -f -- "$error_file"
    echo "::error::Could not determine whether GitHub Release $tag already exists." >&2
    return 1
  fi
  rm -f -- "$error_file"

  if [[ "$is_draft" != "true" ]]; then
    echo "::error::Published GitHub Release $tag already exists." >&2
    return 1
  fi
  echo "Draft GitHub Release $tag already exists; the workflow will resume it."
}
