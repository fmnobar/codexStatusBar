#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: scripts/finalize_app_bundle.sh --app <path> --provenance <source-checkout|public-release> [options]"
  echo
  echo "  --source-root <path>       Included only for source-checkout builds."
  echo "  --installed-path <path>    Included only for source-checkout builds."
  echo "  --omit-executable-hash     Required before a public bundle is re-signed."
}

fail() {
  echo "finalize_app_bundle.sh: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
APP_PATH=""
PROVENANCE=""
SOURCE_ROOT=""
INSTALLED_PATH=""
INCLUDE_EXECUTABLE_HASH=1

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --provenance)
      PROVENANCE="${2:-}"
      shift 2
      ;;
    --source-root)
      SOURCE_ROOT="${2:-}"
      shift 2
      ;;
    --installed-path)
      INSTALLED_PATH="${2:-}"
      shift 2
      ;;
    --omit-executable-hash)
      INCLUDE_EXECUTABLE_HASH=0
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

[[ -d "$APP_PATH" ]] || fail "App bundle not found: $APP_PATH"
case "$PROVENANCE" in
  source-checkout|public-release)
    ;;
  *)
    fail "--provenance must be source-checkout or public-release."
    ;;
esac

if [[ "$PROVENANCE" == "source-checkout" ]]; then
  [[ -n "$SOURCE_ROOT" ]] || fail "--source-root is required for source-checkout provenance."
  [[ -n "$INSTALLED_PATH" ]] || fail "--installed-path is required for source-checkout provenance."
else
  [[ -z "$SOURCE_ROOT" && -z "$INSTALLED_PATH" ]] || fail "Public provenance must not embed local paths."
  [[ "$INCLUDE_EXECUTABLE_HASH" == "0" ]] || fail "Public provenance must omit the pre-signing executable hash."
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist not found: $INFO_PLIST"

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
[[ -x "$EXECUTABLE_PATH" ]] || fail "App executable not found: $EXECUTABLE_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
ARCHITECTURES="$(/usr/bin/lipo -archs "$EXECUTABLE_PATH" | tr ' ' ',')"
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
BUILD_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DIRTY=null

if [[ "$PROVENANCE" == "source-checkout" ]] && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
    DIRTY=true
  else
    DIRTY=false
  fi
fi

if [[ "$PROVENANCE" == "public-release" ]]; then
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "Public provenance requires a git checkout."
  [[ -n "$COMMIT" ]] || fail "Public provenance requires an exact source commit."
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] \
    || fail "Public provenance requires a clean source tree. Commit the exact packaged source first."
  BRANCH=""
fi

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "$value"
}

json_optional() {
  if [[ -n "$1" ]]; then
    json_string "$1"
  else
    printf 'null'
  fi
}

EXECUTABLE_HASH=""
if [[ "$INCLUDE_EXECUTABLE_HASH" == "1" ]]; then
  EXECUTABLE_HASH="$(shasum -a 256 "$EXECUTABLE_PATH" | awk '{print $1}')"
fi

FINGERPRINT_PATH="$APP_PATH/Contents/Resources/BuildFingerprint.json"
mkdir -p "$(dirname "$FINGERPRINT_PATH")"
{
  printf '{\n'
  printf '  "schemaVersion": 2,\n'
  printf '  "provenanceKind": %s,\n' "$(json_string "$PROVENANCE")"
  printf '  "appVersion": %s,\n' "$(json_string "$VERSION")"
  printf '  "appBuild": %s,\n' "$(json_string "$BUILD")"
  printf '  "architectures": %s,\n' "$(json_string "$ARCHITECTURES")"
  printf '  "gitCommit": %s,\n' "$(json_optional "$COMMIT")"
  printf '  "buildTime": %s' "$(json_string "$BUILD_TIME")"
  if [[ "$PROVENANCE" == "source-checkout" ]]; then
    printf ',\n'
    printf '  "sourceRoot": %s,\n' "$(json_string "$SOURCE_ROOT")"
    printf '  "gitBranch": %s,\n' "$(json_optional "$BRANCH")"
    printf '  "isDirty": %s,\n' "$DIRTY"
    printf '  "installedBundlePath": %s,\n' "$(json_string "$INSTALLED_PATH")"
    printf '  "executableSHA256": %s\n' "$(json_string "$EXECUTABLE_HASH")"
  else
    printf '\n'
  fi
  printf '}\n'
} > "$FINGERPRINT_PATH"

/usr/bin/python3 -m json.tool "$FINGERPRINT_PATH" >/dev/null
echo "Finalized $PROVENANCE provenance at $FINGERPRINT_PATH"
