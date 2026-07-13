#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/safe_paths.sh"
source "$SCRIPT_DIR/lib/codex_resolver.sh"

fail() {
  echo "validate_app_bundle.sh: $*" >&2
  exit 1
}

APP_PATH=""
EXPECTED_VERSION=""
EXPECTED_BUILD=""
EXPECTED_ARCH=""
EXPECTED_PROVENANCE=""
EXPECTED_COMMIT=""
EXPECTED_TEAM=""
EXPECTED_SIGNER=""
SIGNED=0
NOTARIZED=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --version) EXPECTED_VERSION="${2:-}"; shift 2 ;;
    --build) EXPECTED_BUILD="${2:-}"; shift 2 ;;
    --arch) EXPECTED_ARCH="${2:-}"; shift 2 ;;
    --provenance) EXPECTED_PROVENANCE="${2:-}"; shift 2 ;;
    --commit) EXPECTED_COMMIT="${2:-}"; shift 2 ;;
    --team) EXPECTED_TEAM="${2:-}"; shift 2 ;;
    --signer) EXPECTED_SIGNER="${2:-}"; shift 2 ;;
    --signed) SIGNED=1; shift ;;
    --notarized) NOTARIZED=1; shift ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -d "$APP_PATH" ]] || fail "App bundle not found: $APP_PATH"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
FINGERPRINT_PATH="$APP_PATH/Contents/Resources/BuildFingerprint.json"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist not found."
[[ -f "$FINGERPRINT_PATH" ]] || fail "BuildFingerprint.json not found."

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
executable_path="$APP_PATH/Contents/MacOS/$executable_name"

[[ "$bundle_identifier" == "com.farzad.codexstatusbar" ]] || fail "Unexpected bundle identifier: $bundle_identifier"
[[ -x "$executable_path" ]] || fail "Executable not found: $executable_path"
[[ -z "$EXPECTED_VERSION" || "$actual_version" == "$EXPECTED_VERSION" ]] || fail "Version is $actual_version, expected $EXPECTED_VERSION."
[[ -z "$EXPECTED_BUILD" || "$actual_build" == "$EXPECTED_BUILD" ]] || fail "Build is $actual_build, expected $EXPECTED_BUILD."

if [[ -n "$EXPECTED_ARCH" ]]; then
  architectures="$(/usr/bin/lipo -archs "$executable_path")"
  case " $architectures " in
    *" $EXPECTED_ARCH "*) ;;
    *) fail "Executable architectures '$architectures' do not contain '$EXPECTED_ARCH'." ;;
  esac
else
  architectures="$(/usr/bin/lipo -archs "$executable_path")"
fi

/usr/bin/python3 -m json.tool "$FINGERPRINT_PATH" >/dev/null
schema_version="$(plutil -extract schemaVersion raw "$FINGERPRINT_PATH")"
provenance_kind="$(plutil -extract provenanceKind raw "$FINGERPRINT_PATH")"
fingerprint_version="$(plutil -extract appVersion raw "$FINGERPRINT_PATH")"
fingerprint_build="$(plutil -extract appBuild raw "$FINGERPRINT_PATH")"
fingerprint_architectures="$(plutil -extract architectures raw "$FINGERPRINT_PATH")"
fingerprint_commit="$(plutil -extract gitCommit raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
fingerprint_build_time="$(plutil -extract buildTime raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
[[ "$schema_version" == "2" ]] || fail "Unsupported fingerprint schema: $schema_version"
[[ "$provenance_kind" == "source-checkout" || "$provenance_kind" == "public-release" ]] || fail "Unsupported fingerprint provenance: $provenance_kind"
[[ -z "$EXPECTED_PROVENANCE" || "$provenance_kind" == "$EXPECTED_PROVENANCE" ]] || fail "Fingerprint provenance is '$provenance_kind', expected '$EXPECTED_PROVENANCE'."
[[ "$fingerprint_version" == "$actual_version" && "$fingerprint_build" == "$actual_build" ]] || fail "Fingerprint version/build does not match Info.plist."
[[ "$fingerprint_architectures" == "${architectures// /,}" ]] || fail "Fingerprint architectures do not match the executable."
[[ "$fingerprint_commit" =~ ^[0-9a-fA-F]{40,64}$ ]] || fail "Fingerprint git commit is missing or malformed."
[[ -z "$EXPECTED_COMMIT" || "$fingerprint_commit" == "$EXPECTED_COMMIT" ]] || fail "Fingerprint commit is '$fingerprint_commit', expected '$EXPECTED_COMMIT'."
[[ "$fingerprint_build_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "Fingerprint build time is missing or malformed."

if [[ "$provenance_kind" == "public-release" ]]; then
  source_root="$(plutil -extract sourceRoot raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  installed_path="$(plutil -extract installedBundlePath raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  branch="$(plutil -extract gitBranch raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  dirty_state="$(plutil -extract isDirty raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  executable_hash="$(plutil -extract executableSHA256 raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  [[ -z "$source_root" || "$source_root" == "null" ]] || fail "Public fingerprint exposes a source path."
  [[ -z "$installed_path" || "$installed_path" == "null" ]] || fail "Public fingerprint exposes an install path."
  [[ -z "$branch" || "$branch" == "null" ]] || fail "Public fingerprint exposes a local branch."
  [[ -z "$dirty_state" || "$dirty_state" == "null" ]] || fail "Public fingerprint exposes local dirty state."
  [[ -z "$executable_hash" || "$executable_hash" == "null" ]] || fail "Public fingerprint contains a pre-signing executable hash."
else
  source_root="$(plutil -extract sourceRoot raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  installed_path="$(plutil -extract installedBundlePath raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  dirty_state="$(plutil -extract isDirty raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  executable_hash="$(plutil -extract executableSHA256 raw "$FINGERPRINT_PATH" 2>/dev/null || true)"
  [[ -n "$source_root" && "$source_root" != "null" ]] || fail "Source fingerprint is missing its source root."
  [[ -n "$installed_path" && "$installed_path" != "null" ]] || fail "Source fingerprint is missing its installed bundle path."
  [[ "$dirty_state" == "true" || "$dirty_state" == "false" ]] || fail "Source fingerprint dirty state is missing or malformed."
  actual_executable_hash="$(shasum -a 256 "$executable_path" | awk '{print $1}')"
  [[ "$executable_hash" == "$actual_executable_hash" ]] || fail "Source fingerprint executable hash does not match the app executable."
fi

icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$icon_name" == "AppIcon" ]] || fail "CFBundleIconName is not AppIcon."
[[ -f "$APP_PATH/Contents/Resources/Assets.car" ]] || fail "Compiled asset catalog is missing."
[[ -s "$APP_PATH/Contents/Resources/AppIcon.icns" ]] || fail "Compiled AppIcon.icns is missing."
[[ -s "$APP_PATH/Contents/Resources/CodexExecutableCandidates.txt" ]] || fail "Canonical Codex candidate manifest is missing from app resources."
codex_validate_candidate_manifest "$REPO_ROOT/Resources/CodexExecutableCandidates.txt" \
  || fail "Repository Codex candidate manifest is invalid."
cmp -s \
  "$REPO_ROOT/Resources/CodexExecutableCandidates.txt" \
  "$APP_PATH/Contents/Resources/CodexExecutableCandidates.txt" \
  || fail "Bundled Codex candidate manifest does not match the repository contract."

if [[ "$NOTARIZED" == "1" && "$SIGNED" != "1" ]]; then
  fail "--notarized requires --signed and an expected team."
fi

if [[ "$SIGNED" == "1" ]]; then
  [[ -n "$EXPECTED_TEAM" ]] || fail "--team is required with --signed."
  [[ -n "$EXPECTED_SIGNER" ]] || fail "--signer is required with --signed."
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  signature_details="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
  actual_team="$(printf '%s\n' "$signature_details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  actual_signer="$(printf '%s\n' "$signature_details" | awk -F= '/^Authority=/{print substr($0, index($0, "=") + 1); exit}')"
  [[ "$actual_team" == "$EXPECTED_TEAM" ]] || fail "Signed bundle team is '$actual_team', expected '$EXPECTED_TEAM'."
  [[ "$actual_signer" == "$EXPECTED_SIGNER" ]] || fail "Signed bundle signer is '$actual_signer', expected '$EXPECTED_SIGNER'."
  designated_requirement="$(codesign --display --requirements - "$APP_PATH" 2>&1)"
  [[ "$designated_requirement" == *"certificate leaf[subject.OU] = \"$EXPECTED_TEAM\""* ]] || fail "Designated requirement is not pinned to team '$EXPECTED_TEAM'."
fi

if [[ "$NOTARIZED" == "1" ]]; then
  xcrun stapler validate "$APP_PATH"
  spctl -a -vv --type execute "$APP_PATH"
fi

echo "Validated app bundle: $APP_PATH"
