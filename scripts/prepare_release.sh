#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: scripts/prepare_release.sh <version> <build> [--signed] [--notarize]"
  echo
  echo "  --signed     Package with Developer ID signing."
  echo "  --notarize   Submit, staple, and validate before creating the release zip."
}

fail() {
  echo "prepare_release.sh: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-}"
BUILD="${2:-}"
PACKAGE_ARGS=()
VERSION_EDIT_STARTED=0
VERSION_COMMIT_CREATED=0
RELEASE_PREP_SUCCEEDED=0
ORIGINAL_HEAD=""
VERSION_COMMIT=""
CURRENT_BRANCH_REF=""

rollback_version_edit() {
  local exit_status="$1"
  local rollback_failed=0
  local current_head
  trap - EXIT
  if [[ "$RELEASE_PREP_SUCCEEDED" != "1" && "$VERSION_EDIT_STARTED" == "1" ]]; then
    if [[ "$VERSION_COMMIT_CREATED" == "1" ]]; then
      current_head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
      if [[ "$current_head" != "$VERSION_COMMIT" ]] \
        || ! git -C "$REPO_ROOT" diff --quiet \
        || ! git -C "$REPO_ROOT" diff --cached --quiet; then
        echo "Release prep failed after the version commit, but HEAD or tracked files changed unexpectedly." >&2
        echo "The version commit was retained for manual recovery: $VERSION_COMMIT" >&2
        rollback_failed=1
      else
        echo "Release prep failed; removing the unpushed version commit and restoring metadata." >&2
        if ! git -C "$REPO_ROOT" update-ref "$CURRENT_BRANCH_REF" "$ORIGINAL_HEAD" "$VERSION_COMMIT"; then
          echo "Could not restore $CURRENT_BRANCH_REF to $ORIGINAL_HEAD; version commit retained." >&2
          rollback_failed=1
        elif ! git -C "$REPO_ROOT" restore \
          --source="$ORIGINAL_HEAD" \
          --staged \
          --worktree \
          -- CodexUsageMenuBar.xcodeproj/project.pbxproj; then
          echo "Branch ref was restored, but project metadata needs manual recovery." >&2
          rollback_failed=1
        fi
      fi
    else
      echo "Release prep failed; restoring project version metadata." >&2
      if ! git -C "$REPO_ROOT" restore \
        --source="$ORIGINAL_HEAD" \
        --staged \
        --worktree \
        -- CodexUsageMenuBar.xcodeproj/project.pbxproj; then
        echo "Could not restore project version metadata." >&2
        rollback_failed=1
      fi
    fi
  fi
  [[ "$rollback_failed" == "0" ]] || exit 1
  exit "$exit_status"
}

trap 'rollback_version_edit $?' EXIT

run_package_release() {
  if (( ${#PACKAGE_ARGS[@]} > 0 )); then
    "$SCRIPT_DIR/package_release.sh" "$@" "${PACKAGE_ARGS[@]}"
  else
    "$SCRIPT_DIR/package_release.sh" "$@"
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This release script only supports macOS."
fi

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  usage >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "Version must use X.Y.Z format, got '$VERSION'."
fi

if [[ ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
  fail "Build must be a positive integer, got '$BUILD'."
fi

shift 2

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --signed|--notarize)
      PACKAGE_ARGS+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ ! -d "$REPO_ROOT/.git" ]]; then
  fail "Run from a git checkout."
fi

cd "$REPO_ROOT"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "main" ]]; then
  fail "Release prep must start from main; current branch is '$current_branch'."
fi
CURRENT_BRANCH_REF="$(git symbolic-ref -q HEAD)"
[[ -n "$CURRENT_BRANCH_REF" ]] || fail "Release prep requires a non-detached main branch."

if [[ -n "$(git status --porcelain)" ]]; then
  fail "Release prep must start from a clean working tree."
fi

echo "Refreshing origin/main parity..."
git fetch --prune origin
if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  fail "origin/main is unavailable after fetch."
fi

read -r ahead behind < <(git rev-list --left-right --count HEAD...origin/main)
if [[ "$ahead" != "0" || "$behind" != "0" ]]; then
  fail "Local main must exactly match origin/main (ahead $ahead, behind $behind)."
fi
ORIGINAL_HEAD="$(git rev-parse HEAD)"

run_package_release --dry-run
VERSION_EDIT_STARTED=1
"$SCRIPT_DIR/set_version.sh" "$VERSION" "$BUILD"

if ! VERIFY_DERIVED_DATA_PATH="${VERIFY_DERIVED_DATA_PATH:-$REPO_ROOT/.build/verify-release-$$}" \
  "$SCRIPT_DIR/verify.sh"; then
  fail "Canonical verification failed."
fi

git add CodexUsageMenuBar.xcodeproj/project.pbxproj
if git diff --cached --quiet; then
  echo "Version metadata already matches v$VERSION build $BUILD; using existing commit $(git rev-parse --short HEAD)."
else
  git commit -m "Bump version to $VERSION"
  VERSION_COMMIT="$(git rev-parse HEAD)"
  VERSION_COMMIT_CREATED=1
  echo "Created version commit $VERSION_COMMIT before public packaging."
fi

if [[ -n "$(git status --porcelain)" ]]; then
  fail "Release source tree is not clean after creating the version commit."
fi
if ! run_package_release; then
  fail "Release packaging failed."
fi

RELEASE_PREP_SUCCEEDED=1

echo
echo "Release prep complete for v$VERSION build $BUILD."
if [[ "$VERSION_COMMIT_CREATED" == "1" ]]; then
  echo "Review version commit $VERSION_COMMIT, tag v$VERSION, then push main and the tag."
else
  echo "Review the existing version commit, tag v$VERSION, then push main and the tag."
fi
