#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "validate_release_artifact.sh: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/safe_paths.sh"

ARTIFACT_PATH=""
APP_ARGS=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --artifact)
      ARTIFACT_PATH="${2:-}"
      shift 2
      ;;
    *)
      APP_ARGS+=("$1")
      if [[ "$1" == "--version" || "$1" == "--build" || "$1" == "--arch" || "$1" == "--provenance" || "$1" == "--commit" || "$1" == "--team" || "$1" == "--signer" ]]; then
        APP_ARGS+=("${2:-}")
        shift 2
      else
        shift
      fi
      ;;
  esac
done

[[ -f "$ARTIFACT_PATH" ]] || fail "Artifact not found: $ARTIFACT_PATH"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/CodexStatusBarArtifactValidation.XXXXXX")"
SENTINEL=".codex-status-bar-artifact-validation"
: > "$TEMP_ROOT/$SENTINEL"
cleanup() {
  safe_remove_owned_directory "$TEMP_ROOT" "$(dirname "$TEMP_ROOT")" "$SENTINEL"
}
trap cleanup EXIT

ditto -x -k "$ARTIFACT_PATH" "$TEMP_ROOT"
APP_PATH="$TEMP_ROOT/CodexStatusBar.app"
[[ -d "$APP_PATH" ]] || fail "Archive does not contain CodexStatusBar.app at its root."
"$SCRIPT_DIR/validate_app_bundle.sh" --app "$APP_PATH" "${APP_ARGS[@]}"

roundtrip_zip="$TEMP_ROOT/roundtrip.zip"
(
  cd "$TEMP_ROOT"
  ditto -c -k --keepParent CodexStatusBar.app "$roundtrip_zip"
)
ditto -x -k "$roundtrip_zip" "$TEMP_ROOT/roundtrip"
ROUNDTRIP_APP_PATH="$TEMP_ROOT/roundtrip/CodexStatusBar.app"
[[ -x "$ROUNDTRIP_APP_PATH/Contents/MacOS/CodexStatusBar" ]] || fail "Zip round-trip lost the executable."
"$SCRIPT_DIR/validate_app_bundle.sh" --app "$ROUNDTRIP_APP_PATH" "${APP_ARGS[@]}"

echo "Validated release artifact and zip round-trip: $ARTIFACT_PATH"
