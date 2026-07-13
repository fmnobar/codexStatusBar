#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/safe_paths.sh"
source "$SCRIPT_DIR/lib/build_warnings.sh"
VERIFY_ROOT="${VERIFY_DERIVED_DATA_PATH:-$REPO_ROOT/.build/verify-$$}"
VERIFY_ALLOWED_ROOT="${VERIFY_ALLOWED_ROOT:-$REPO_ROOT/.build}"
RESULT_BUNDLE_PATH="${VERIFY_RESULT_BUNDLE_PATH:-$VERIFY_ROOT/TestResults.xcresult}"
LOG_PATH="${VERIFY_LOG_PATH:-$VERIFY_ROOT/verify.log}"
COVERAGE_REPORT_PATH="${VERIFY_COVERAGE_REPORT_PATH:-$VERIFY_ROOT/coverage.txt}"
FAIL_ON_WARNINGS="${FAIL_ON_WARNINGS:-1}"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
VERIFY_SENTINEL=".codex-status-bar-verification"
VERIFY_SUCCEEDED=0

safe_assert_strict_descendant "$VERIFY_ROOT" "$VERIFY_ALLOWED_ROOT"
safe_assert_strict_descendant "$RESULT_BUNDLE_PATH" "$VERIFY_ROOT"
safe_assert_strict_descendant "$LOG_PATH" "$VERIFY_ROOT"
safe_assert_strict_descendant "$COVERAGE_REPORT_PATH" "$VERIFY_ROOT"
safe_prepare_owned_directory "$VERIFY_ROOT" "$VERIFY_ALLOWED_ROOT" "$VERIFY_SENTINEL"
: > "$LOG_PATH"

cleanup() {
  local exit_status=$?
  if [[ -d "$RESULT_BUNDLE_PATH" && ! -f "$COVERAGE_REPORT_PATH" ]]; then
    xcrun xccov view --report --only-targets "$RESULT_BUNDLE_PATH" > "$COVERAGE_REPORT_PATH" 2>/dev/null || true
  fi
  if [[ "$exit_status" == "0" && "$VERIFY_SUCCEEDED" == "1" && "${CI:-false}" != "true" ]]; then
    safe_remove_owned_directory "$VERIFY_ROOT" "$VERIFY_ALLOWED_ROOT" "$VERIFY_SENTINEL"
  elif [[ "$exit_status" != "0" ]]; then
    echo "Verification evidence preserved at: $VERIFY_ROOT" >&2
  fi
  return "$exit_status"
}
trap cleanup EXIT

run_xcodebuild() {
  echo "Running: xcodebuild $*" | tee -a "$LOG_PATH"
  xcodebuild "$@" 2>&1 | tee -a "$LOG_PATH"
}

cd "$REPO_ROOT"

if [[ "${VERIFY_INJECT_FAILURE_AFTER_SETUP:-0}" == "1" ]]; then
  echo "Injected verification failure after evidence setup." | tee -a "$LOG_PATH" >&2
  exit 97
fi

shell_scripts=(install.sh uninstall.sh)
while IFS= read -r script; do
  shell_scripts+=("$script")
done < <(find scripts -type f -name '*.sh' | sort)
bash -n "${shell_scripts[@]}"

git diff --check
plutil -lint CodexUsageMenuBar.xcodeproj/project.pbxproj >/dev/null
xcodebuild -list -project CodexUsageMenuBar.xcodeproj >/dev/null
"$SCRIPT_DIR/test_release_scripts.sh"

run_xcodebuild \
  test \
  -project CodexUsageMenuBar.xcodeproj \
  -scheme CodexUsageMenuBar \
  -destination "platform=macOS,arch=$BUILD_ARCH" \
  -derivedDataPath "$VERIFY_ROOT" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  -enableCodeCoverage YES \
  CODE_SIGNING_ALLOWED=NO

xcrun xccov view --report --only-targets "$RESULT_BUNDLE_PATH" > "$COVERAGE_REPORT_PATH"

run_xcodebuild \
  analyze \
  -project CodexUsageMenuBar.xcodeproj \
  -scheme CodexUsageMenuBar \
  -configuration Debug \
  -destination "platform=macOS,arch=$BUILD_ARCH" \
  -derivedDataPath "$VERIFY_ROOT" \
  CODE_SIGNING_ALLOWED=NO

run_xcodebuild \
  build \
  -project CodexUsageMenuBar.xcodeproj \
  -scheme CodexUsageMenuBar \
  -configuration Release \
  -destination "platform=macOS,arch=$BUILD_ARCH" \
  -derivedDataPath "$VERIFY_ROOT" \
  CODE_SIGNING_ALLOWED=NO

VERIFIED_APP="$VERIFY_ROOT/Build/Products/Release/CodexStatusBar.app"
[[ -d "$VERIFIED_APP" ]] || {
  echo "Release verification build did not produce CodexStatusBar.app." >&2
  exit 1
}

"$SCRIPT_DIR/finalize_app_bundle.sh" \
  --app "$VERIFIED_APP" \
  --provenance source-checkout \
  --source-root "$REPO_ROOT" \
  --installed-path "$HOME/Applications/CodexStatusBar.app"

"$SCRIPT_DIR/validate_app_bundle.sh" \
  --app "$VERIFIED_APP" \
  --arch "$BUILD_ARCH" \
  --provenance source-checkout \
  --commit "$(git rev-parse HEAD)"

filter_actionable_build_warnings "$LOG_PATH" "$VERIFY_ROOT/warnings.txt"
if [[ "$FAIL_ON_WARNINGS" == "1" && -s "$VERIFY_ROOT/warnings.txt" ]]; then
  echo "Verification found build warnings:" >&2
  cat "$VERIFY_ROOT/warnings.txt" >&2
  exit 1
fi

VERIFY_SUCCEEDED=1
echo "Verification passed."
echo "  log: $LOG_PATH"
echo "  tests: $RESULT_BUNDLE_PATH"
echo "  coverage: $COVERAGE_REPORT_PATH"
