#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: scripts/prepare_release.sh <version> <build>"
}

fail() {
  echo "prepare_release.sh: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-}"
BUILD="${2:-}"

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

if [[ ! -d "$REPO_ROOT/.git" ]]; then
  fail "Run from a git checkout."
fi

cd "$REPO_ROOT"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "main" ]]; then
  fail "Release prep must start from main; current branch is '$current_branch'."
fi

if [[ -n "$(git status --porcelain)" ]]; then
  fail "Release prep must start from a clean working tree."
fi

"$SCRIPT_DIR/set_version.sh" "$VERSION" "$BUILD"

bash -n "$SCRIPT_DIR/set_version.sh" "$SCRIPT_DIR/package_release.sh" "$SCRIPT_DIR/prepare_release.sh"
git diff --check
xcodebuild test -project CodexUsageMenuBar.xcodeproj -scheme CodexUsageMenuBar -destination 'platform=macOS'
"$SCRIPT_DIR/package_release.sh"

echo
echo "Release prep complete for v$VERSION build $BUILD."
echo "Review changes, commit them, tag v$VERSION, push main and the tag, then create the GitHub Release."
