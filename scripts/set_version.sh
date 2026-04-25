#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: scripts/set_version.sh <version> <build>"
  echo
  echo "  version: semantic version in X.Y.Z format"
  echo "  build:   positive integer"
}

fail() {
  echo "set_version.sh: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="${PROJECT_FILE:-$REPO_ROOT/CodexUsageMenuBar.xcodeproj/project.pbxproj}"

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

if [[ ! -f "$PROJECT_FILE" ]]; then
  fail "Project file not found: $PROJECT_FILE"
fi

marketing_count="$(grep -E '^[[:space:]]*MARKETING_VERSION = ' "$PROJECT_FILE" | wc -l | tr -d ' ')"
build_count="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | wc -l | tr -d ' ')"

if [[ "$marketing_count" -lt 2 ]]; then
  fail "Expected MARKETING_VERSION in Debug and Release build settings."
fi

if [[ "$build_count" -lt 2 ]]; then
  fail "Expected CURRENT_PROJECT_VERSION in Debug and Release build settings."
fi

RELEASE_VERSION="$VERSION" RELEASE_BUILD="$BUILD" /usr/bin/perl -0pi -e '
  s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $ENV{RELEASE_VERSION};/g;
  s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $ENV{RELEASE_BUILD};/g;
' "$PROJECT_FILE"

updated_marketing_count="$(grep -F "MARKETING_VERSION = $VERSION;" "$PROJECT_FILE" | wc -l | tr -d ' ')"
updated_build_count="$(grep -F "CURRENT_PROJECT_VERSION = $BUILD;" "$PROJECT_FILE" | wc -l | tr -d ' ')"

if [[ "$updated_marketing_count" != "$marketing_count" ]]; then
  fail "Version update did not touch every MARKETING_VERSION entry."
fi

if [[ "$updated_build_count" != "$build_count" ]]; then
  fail "Build update did not touch every CURRENT_PROJECT_VERSION entry."
fi

echo "Updated project version to $VERSION ($BUILD)."
