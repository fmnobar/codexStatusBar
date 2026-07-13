#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: scripts/package_release.sh [--signed] [--notarize] [--dry-run]"
  echo
  echo "  --signed     Build with Developer ID signing and hardened runtime."
  echo "  --notarize   Submit, staple, and validate the signed app before zipping."
  echo "  --dry-run    Validate inputs and print paths without building or writing artifacts."
}

fail() {
  echo "package_release.sh: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/safe_paths.sh"
PROJECT_FILE="${PROJECT_FILE:-$REPO_ROOT/CodexUsageMenuBar.xcodeproj/project.pbxproj}"
PROJECT_PATH="$REPO_ROOT/CodexUsageMenuBar.xcodeproj"
SCHEME_NAME="CodexUsageMenuBar"
APP_NAME="CodexStatusBar.app"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
DEFAULT_RELEASE_ROOT="$REPO_ROOT/.build/release"
RELEASE_ROOT="${RELEASE_ROOT:-$DEFAULT_RELEASE_ROOT}"
RELEASE_SENTINEL=".codex-status-bar-release-root"
if [[ "$RELEASE_ROOT" == "$DEFAULT_RELEASE_ROOT" && -d "$RELEASE_ROOT" && ! -f "$RELEASE_ROOT/$RELEASE_SENTINEL" ]]; then
  RELEASE_ROOT="$REPO_ROOT/.build/release.package.$$"
  echo "Preserving legacy release output without an ownership sentinel: $DEFAULT_RELEASE_ROOT"
  echo "Using isolated release output instead: $RELEASE_ROOT"
fi
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$RELEASE_ROOT/DerivedData}"
STAGED_APP_PATH="$RELEASE_ROOT/$APP_NAME"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
NOTARY_UPLOAD_PATH="$RELEASE_ROOT/CodexStatusBar-vnotary-upload.zip"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
DRY_RUN=0
SIGNED=0
NOTARIZE=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --signed)
      SIGNED=1
      shift
      ;;
    --notarize)
      NOTARIZE=1
      shift
      ;;
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

safe_assert_strict_descendant "$RELEASE_ROOT" "$REPO_ROOT/.build"

if [[ "$NOTARIZE" == "1" && "$SIGNED" != "1" ]]; then
  fail "--notarize requires --signed."
fi

if [[ "$SIGNED" == "1" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    fail "DEVELOPER_ID_APPLICATION is required with --signed."
  fi

  if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    fail "DEVELOPMENT_TEAM is required with --signed."
  fi
fi

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    fail "NOTARYTOOL_PROFILE is required with --notarize."
  fi

  if ! xcrun -f notarytool >/dev/null 2>&1; then
    fail "xcrun notarytool is required for notarization."
  fi

  if ! xcrun -f stapler >/dev/null 2>&1; then
    fail "xcrun stapler is required for notarization."
  fi

  if [[ -n "${NOTARY_KEYCHAIN:-}" && "$DRY_RUN" != "1" && ! -f "$NOTARY_KEYCHAIN" ]]; then
    fail "NOTARY_KEYCHAIN does not exist: $NOTARY_KEYCHAIN"
  fi
fi

if [[ "$SIGNED" == "1" && "$DRY_RUN" != "1" ]]; then
  if ! security find-identity -p codesigning -v | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null; then
    fail "Developer ID signing identity was not found: $DEVELOPER_ID_APPLICATION"
  fi
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

if [[ "$NOTARIZE" == "1" ]]; then
  SIGNING_STATUS="Developer ID signed, notarized, and stapled"
elif [[ "$SIGNED" == "1" ]]; then
  SIGNING_STATUS="Developer ID signed; not notarized"
else
  SIGNING_STATUS="unsigned; not Developer ID signed or notarized"
fi

echo "Release version: $VERSION ($BUILD)"
echo "Artifact path: $ARTIFACT_PATH"
echo "Signing: $SIGNING_STATUS."

if [[ "$SIGNED" == "1" ]]; then
  echo "Developer ID identity: $DEVELOPER_ID_APPLICATION"
  echo "Development team: $DEVELOPMENT_TEAM"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Notary profile: $NOTARYTOOL_PROFILE"
  if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    echo "Notary keychain: $NOTARY_KEYCHAIN"
  fi
  echo "Notary timeout: $NOTARY_TIMEOUT"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete. No build or zip was created."
  exit 0
fi

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Public packaging requires a git checkout."
fi
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  fail "Public packaging requires a clean source tree whose HEAD exactly identifies the artifact."
fi
SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

safe_reset_owned_directory "$RELEASE_ROOT" "$REPO_ROOT/.build" "$RELEASE_SENTINEL"
mkdir -p "$RELEASE_ROOT" "$DIST_DIR"

echo "Building Release app..."
build_args=(
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "platform=macOS,arch=$BUILD_ARCH" \
  -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ "$SIGNED" == "1" ]]; then
  build_args+=(
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    ENABLE_HARDENED_RUNTIME=YES
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
else
  build_args+=(CODE_SIGNING_ALLOWED=NO)
fi

build_args+=(build)

xcodebuild "${build_args[@]}"

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  fail "Build succeeded, but the app bundle was not found at $BUILT_APP_PATH"
fi

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP_PATH/Contents/Info.plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP_PATH/Contents/Info.plist")"

if [[ "$actual_version" != "$VERSION" || "$actual_build" != "$BUILD" ]]; then
  fail "Built app Info.plist has version $actual_version ($actual_build), expected $VERSION ($BUILD)."
fi

ditto "$BUILT_APP_PATH" "$STAGED_APP_PATH"

"$SCRIPT_DIR/finalize_app_bundle.sh" \
  --app "$STAGED_APP_PATH" \
  --provenance public-release \
  --omit-executable-hash

if [[ "$SIGNED" == "1" ]]; then
  echo "Re-signing finalized release bundle..."
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$STAGED_APP_PATH"

  echo "Verifying Developer ID signature..."
  "$SCRIPT_DIR/validate_app_bundle.sh" \
    --app "$STAGED_APP_PATH" \
    --version "$VERSION" \
    --build "$BUILD" \
    --arch "$BUILD_ARCH" \
    --provenance public-release \
    --commit "$SOURCE_COMMIT" \
    --signed \
    --team "$DEVELOPMENT_TEAM" \
    --signer "$DEVELOPER_ID_APPLICATION"
else
  "$SCRIPT_DIR/validate_app_bundle.sh" \
    --app "$STAGED_APP_PATH" \
    --version "$VERSION" \
    --build "$BUILD" \
    --arch "$BUILD_ARCH" \
    --provenance public-release \
    --commit "$SOURCE_COMMIT"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  rm -f "$NOTARY_UPLOAD_PATH"

  echo "Creating temporary notarization upload zip..."
  (
    cd "$RELEASE_ROOT"
    ditto -c -k --keepParent "$APP_NAME" "$NOTARY_UPLOAD_PATH"
  )

  echo "Submitting app for notarization..."
  notary_args=(
    "$NOTARY_UPLOAD_PATH"
    --keychain-profile "$NOTARYTOOL_PROFILE"
    --wait
    --timeout "$NOTARY_TIMEOUT"
  )

  if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    notary_args+=(--keychain "$NOTARY_KEYCHAIN")
  fi

  xcrun notarytool submit "${notary_args[@]}"

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$STAGED_APP_PATH"

  echo "Validating stapled ticket..."
  xcrun stapler validate "$STAGED_APP_PATH"

  echo "Verifying stapled app signature..."
  codesign --verify --deep --strict --verbose=2 "$STAGED_APP_PATH"
fi

rm -f "$ARTIFACT_PATH" "$ARTIFACT_PATH.sha256"

echo "Creating zip..."
(
  cd "$RELEASE_ROOT"
  ditto -c -k --keepParent "$APP_NAME" "$ARTIFACT_PATH"
)

if [[ ! -f "$ARTIFACT_PATH" ]]; then
  fail "Expected zip was not created: $ARTIFACT_PATH"
fi

validation_args=(
  --artifact "$ARTIFACT_PATH"
  --version "$VERSION"
  --build "$BUILD"
  --arch "$BUILD_ARCH"
  --provenance public-release
  --commit "$SOURCE_COMMIT"
)
if [[ "$SIGNED" == "1" ]]; then
  validation_args+=(--signed --team "$DEVELOPMENT_TEAM" --signer "$DEVELOPER_ID_APPLICATION")
fi
if [[ "$NOTARIZE" == "1" ]]; then
  validation_args+=(--notarized)
fi
"$SCRIPT_DIR/validate_release_artifact.sh" "${validation_args[@]}"

artifact_digest="$(shasum -a 256 "$ARTIFACT_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$artifact_digest" "$(basename "$ARTIFACT_PATH")" > "$ARTIFACT_PATH.sha256"

echo
echo "Created release artifact:"
echo "  $ARTIFACT_PATH"
echo "  $ARTIFACT_PATH.sha256"
echo
echo "Signing: $SIGNING_STATUS."
