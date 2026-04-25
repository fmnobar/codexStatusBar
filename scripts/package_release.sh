#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: scripts/package_release.sh [--dry-run]"
}

fail() {
  echo "package_release.sh: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="${PROJECT_FILE:-$REPO_ROOT/CodexUsageMenuBar.xcodeproj/project.pbxproj}"
PROJECT_PATH="$REPO_ROOT/CodexUsageMenuBar.xcodeproj"
SCHEME_NAME="CodexUsageMenuBar"
APP_NAME="CodexStatusBar.app"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
RELEASE_ROOT="${RELEASE_ROOT:-$REPO_ROOT/.build/release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$RELEASE_ROOT/DerivedData}"
STAGED_APP_PATH="$RELEASE_ROOT/$APP_NAME"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
DRY_RUN=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This release script only supports macOS."
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  fail "xcodebuild is required. Install Xcode and run 'xcode-select --switch /Applications/Xcode.app'."
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  fail "Project file not found: $PROJECT_FILE"
fi

read_unique_build_setting() {
  local key="$1"
  local values
  values="$(
    grep -E "^[[:space:]]*$key = " "$PROJECT_FILE" \
      | sed -E "s/^[[:space:]]*$key = ([^;]+);/\\1/" \
      | sort -u
  )"

  local count
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$count" != "1" ]]; then
    fail "Expected exactly one unique $key value in app build settings."
  fi

  printf '%s\n' "$values" | sed '/^$/d'
}

VERSION="$(read_unique_build_setting MARKETING_VERSION)"
BUILD="$(read_unique_build_setting CURRENT_PROJECT_VERSION)"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "MARKETING_VERSION must use X.Y.Z format before packaging, got '$VERSION'."
fi

if [[ ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
  fail "CURRENT_PROJECT_VERSION must be a positive integer before packaging, got '$BUILD'."
fi

ARTIFACT_PATH="$DIST_DIR/CodexStatusBar-v$VERSION-build$BUILD.zip"

echo "Release version: $VERSION ($BUILD)"
echo "Artifact path: $ARTIFACT_PATH"
echo "Signing: unsigned; not Developer ID signed or notarized."

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete. No build or zip was created."
  exit 0
fi

rm -rf "$RELEASE_ROOT"
mkdir -p "$RELEASE_ROOT" "$DIST_DIR"

echo "Building Release app..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "platform=macOS,arch=$BUILD_ARCH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  fail "Build succeeded, but the app bundle was not found at $BUILT_APP_PATH"
fi

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP_PATH/Contents/Info.plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP_PATH/Contents/Info.plist")"

if [[ "$actual_version" != "$VERSION" || "$actual_build" != "$BUILD" ]]; then
  fail "Built app Info.plist has version $actual_version ($actual_build), expected $VERSION ($BUILD)."
fi

ditto "$BUILT_APP_PATH" "$STAGED_APP_PATH"
rm -f "$ARTIFACT_PATH"

echo "Creating zip..."
(
  cd "$RELEASE_ROOT"
  ditto -c -k --keepParent "$APP_NAME" "$ARTIFACT_PATH"
)

if [[ ! -f "$ARTIFACT_PATH" ]]; then
  fail "Expected zip was not created: $ARTIFACT_PATH"
fi

echo
echo "Created release artifact:"
echo "  $ARTIFACT_PATH"
echo
echo "This artifact is not Developer ID signed or notarized."
