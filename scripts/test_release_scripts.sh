#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/safe_paths.sh"

fail() {
  echo "test_release_scripts.sh: $*" >&2
  exit 1
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "Expected command to fail: $*"
  fi
}

TEMP_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/CodexStatusBarScriptTests.XXXXXX")"
TEMP_SENTINEL=".codex-status-bar-script-tests"
: > "$TEMP_PARENT/$TEMP_SENTINEL"
UNINSTALL_CANARY_PID=""
UNINSTALL_TARGET_PID=""
cleanup() {
  [[ -z "$UNINSTALL_CANARY_PID" ]] || kill "$UNINSTALL_CANARY_PID" >/dev/null 2>&1 || true
  [[ -z "$UNINSTALL_TARGET_PID" ]] || kill "$UNINSTALL_TARGET_PID" >/dev/null 2>&1 || true
  safe_remove_owned_directory "$TEMP_PARENT" "$(dirname "$TEMP_PARENT")" "$TEMP_SENTINEL"
}
trap cleanup EXIT

MANAGED_ROOT="$TEMP_PARENT/managed"
mkdir -p "$MANAGED_ROOT"

expect_failure safe_assert_strict_descendant / "$MANAGED_ROOT"
expect_failure safe_assert_strict_descendant "$HOME" "$MANAGED_ROOT"
expect_failure safe_assert_strict_descendant "$REPO_ROOT" "$REPO_ROOT/.build"
expect_failure safe_assert_strict_descendant "$TEMP_PARENT/outside" "$MANAGED_ROOT"

OWNED="$MANAGED_ROOT/owned"
safe_prepare_owned_directory "$OWNED" "$MANAGED_ROOT" .owned
[[ -f "$OWNED/.owned" ]] || fail "Owned-directory sentinel was not created."
safe_remove_owned_directory "$OWNED" "$MANAGED_ROOT" .owned
[[ ! -e "$OWNED" ]] || fail "Owned directory was not removed."

UNOWNED="$MANAGED_ROOT/unowned"
mkdir -p "$UNOWNED"
expect_failure safe_remove_owned_directory "$UNOWNED" "$MANAGED_ROOT" .owned

SYMLINK="$MANAGED_ROOT/symlink"
ln -s "$UNOWNED" "$SYMLINK"
expect_failure safe_remove_owned_directory "$SYMLINK" "$MANAGED_ROOT" .owned
SYMLINKED_ROOT="$TEMP_PARENT/symlinked-root"
ln -s "$MANAGED_ROOT" "$SYMLINKED_ROOT"
expect_failure safe_assert_strict_descendant "$SYMLINKED_ROOT/child" "$SYMLINKED_ROOT"

MANAGED_CHILD_PARENT="$TEMP_PARENT/install-parent"
mkdir -p "$MANAGED_CHILD_PARENT/.CodexStatusBar.install.123"
: > "$MANAGED_CHILD_PARENT/.CodexStatusBar.install.123/payload"
safe_remove_managed_child \
  "$MANAGED_CHILD_PARENT/.CodexStatusBar.install.123" \
  "$MANAGED_CHILD_PARENT" \
  '.CodexStatusBar.*.*'
[[ ! -e "$MANAGED_CHILD_PARENT/.CodexStatusBar.install.123" ]] \
  || fail "Managed install sibling was not removed."
ln -s "$UNOWNED" "$MANAGED_CHILD_PARENT/.CodexStatusBar.install.456"
expect_failure safe_remove_managed_child \
  "$MANAGED_CHILD_PARENT/.CodexStatusBar.install.456" \
  "$MANAGED_CHILD_PARENT" \
  '.CodexStatusBar.*.*'
expect_failure safe_remove_managed_child \
  "$TEMP_PARENT/.CodexStatusBar.install.789" \
  "$MANAGED_CHILD_PARENT" \
  '.CodexStatusBar.*.*'
expect_failure safe_remove_managed_child \
  "$MANAGED_CHILD_PARENT/unexpected-name" \
  "$MANAGED_CHILD_PARENT" \
  '.CodexStatusBar.*.*'
SYMLINKED_CHILD_PARENT="$TEMP_PARENT/symlinked-install-parent"
ln -s "$MANAGED_CHILD_PARENT" "$SYMLINKED_CHILD_PARENT"
expect_failure safe_remove_managed_child \
  "$SYMLINKED_CHILD_PARENT/.CodexStatusBar.install.999" \
  "$SYMLINKED_CHILD_PARENT" \
  '.CodexStatusBar.*.*'

expect_failure env RELEASE_ROOT=/ "$SCRIPT_DIR/package_release.sh" --dry-run
expect_failure env RELEASE_ROOT="$HOME" "$SCRIPT_DIR/package_release.sh" --dry-run
expect_failure env RELEASE_ROOT="$REPO_ROOT" "$SCRIPT_DIR/package_release.sh" --dry-run
expect_failure env RELEASE_ROOT="$TEMP_PARENT/outside" "$SCRIPT_DIR/package_release.sh" --dry-run
env RELEASE_ROOT="$REPO_ROOT/.build/release-dry-run-test" "$SCRIPT_DIR/package_release.sh" --dry-run >/dev/null

make_codex_fixture() {
  local executable="$1"
  local version_output="$2"
  local capability_output="$3"

  mkdir -p "$(dirname "$executable")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    "  printf '%s\\n' '$version_output'" \
    '  exit 0' \
    'fi' \
    'if [[ "${1:-}" == "app-server" && "${2:-}" == "--help" ]]; then' \
    "  printf '%s\\n' '$capability_output'" \
    '  exit 0' \
    'fi' \
    'exit 2' \
    > "$executable"
  chmod +x "$executable"
}

source "$SCRIPT_DIR/lib/codex_resolver.sh"
codex_validate_candidate_manifest
fixed_candidate_contract="$(codex_fixed_candidate_paths)"
expected_fixed_candidate_contract="$(printf '%s\n' \
  '/Applications/ChatGPT.app/Contents/Resources/codex' \
  '/Applications/Codex.app/Contents/Resources/codex' \
  '/opt/homebrew/bin/codex' \
  '/usr/local/bin/codex')"
[[ "$fixed_candidate_contract" == "$expected_fixed_candidate_contract" ]] \
  || fail "Canonical Codex candidate manifest order changed unexpectedly."
INVALID_CANDIDATE_MANIFEST="$TEMP_PARENT/invalid-candidates.txt"
printf '%s\n' '/usr/local/bin/codex' '/usr/local/bin/codex' > "$INVALID_CANDIDATE_MANIFEST"
expect_failure codex_validate_candidate_manifest "$INVALID_CANDIDATE_MANIFEST"
SPACED_CANDIDATE_MANIFEST="$TEMP_PARENT/spaced-candidates.txt"
printf '%s\n' '  # indented comment' '  /Applications/Codex Preview.app/Contents/Resources/codex  ' \
  > "$SPACED_CANDIDATE_MANIFEST"
codex_validate_candidate_manifest "$SPACED_CANDIDATE_MANIFEST" \
  || fail "Shell manifest parsing must match the app's trim/comment/path rules."

FAKE_APPLICATIONS="$TEMP_PARENT/Applications"
FAKE_PATH_BIN="$TEMP_PARENT/path-bin"
mkdir -p "$FAKE_APPLICATIONS" "$FAKE_PATH_BIN"
make_codex_fixture \
  "$FAKE_APPLICATIONS/ChatGPT.app/Contents/Resources/codex" \
  "not-a-version" \
  "--stdio"
make_codex_fixture \
  "$FAKE_APPLICATIONS/Codex.app/Contents/Resources/codex" \
  "codex-cli 0.143.0" \
  "no supported transport"
make_codex_fixture \
  "$FAKE_APPLICATIONS/Codex10.app/Contents/Resources/codex" \
  "codex-cli 0.144.0" \
  "--listen <URL> ws://IP:PORT"
make_codex_fixture \
  "$FAKE_APPLICATIONS/Codex2.app/Contents/Resources/codex" \
  "codex-cli 0.145.0" \
  "--listen <URL> stdio://"
make_codex_fixture \
  "$TEMP_PARENT/symlink-source.app/Contents/Resources/codex" \
  "codex-cli 0.146.0-alpha.1" \
  "--stdio"
ln -s "$TEMP_PARENT/symlink-source.app" "$FAKE_APPLICATIONS/Codex05.app"
make_codex_fixture "$FAKE_PATH_BIN/codex" "codex-cli 9.9.9" "--stdio"

STUBBORN_CODEX="$TEMP_PARENT/stubborn-codex"
STUBBORN_PID_FILE="$TEMP_PARENT/stubborn-codex.pid"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'trap "" TERM' \
  'printf "%s\n" "$$" > "$CODEX_STUBBORN_PID_FILE"' \
  'while :; do :; done' \
  > "$STUBBORN_CODEX"
chmod +x "$STUBBORN_CODEX"
export CODEX_STUBBORN_PID_FILE="$STUBBORN_PID_FILE"
export CODEX_PROBE_WAIT_ATTEMPTS=20
export CODEX_PROBE_WAIT_INTERVAL=0.01
export CODEX_PROBE_TERMINATION_GRACE_ATTEMPTS=1
export CODEX_PROBE_TERMINATION_INTERVAL=0.01
SECONDS=0
expect_failure codex_validate_candidate "$STUBBORN_CODEX"
[[ "$SECONDS" -lt 3 ]] || fail "Stubborn Codex probe exceeded its bounded termination window."
STUBBORN_PID="$(cat "$STUBBORN_PID_FILE")"
if kill -0 "$STUBBORN_PID" >/dev/null 2>&1; then
  fail "Stubborn Codex probe process survived timeout escalation: $STUBBORN_PID"
fi
unset \
  CODEX_STUBBORN_PID_FILE \
  CODEX_PROBE_WAIT_ATTEMPTS \
  CODEX_PROBE_WAIT_INTERVAL \
  CODEX_PROBE_TERMINATION_GRACE_ATTEMPTS \
  CODEX_PROBE_TERMINATION_INTERVAL

OVERSIZED_CODEX="$TEMP_PARENT/oversized-codex"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 1.2.3"; exit 0; fi' \
  'if [[ "${1:-}" == "app-server" && "${2:-}" == "--help" ]]; then' \
  '  /bin/dd if=/dev/zero bs=262145 count=1 2>/dev/null' \
  '  printf "%s\n" "--stdio"' \
  '  exit 0' \
  'fi' \
  'exit 2' \
  > "$OVERSIZED_CODEX"
chmod +x "$OVERSIZED_CODEX"
expect_failure codex_validate_candidate "$OVERSIZED_CODEX"

expect_failure codex_validate_candidate "$FAKE_APPLICATIONS/ChatGPT.app/Contents/Resources/codex"
expect_failure codex_validate_candidate "$FAKE_APPLICATIONS/Codex.app/Contents/Resources/codex"

discovered_order="$({
  CODEX_APPLICATIONS_DIR="$FAKE_APPLICATIONS" \
  CODEX_HOMEBREW_CANDIDATE="$TEMP_PARENT/missing-homebrew" \
  CODEX_USR_LOCAL_CANDIDATE="$TEMP_PARENT/missing-usr-local" \
  CODEX_PATH_VALUE="" \
    codex_candidate_paths
} | grep -E '/Codex(05|10|2)\.app/Contents/Resources/codex$')"
expected_discovered_order="$(printf '%s\n' \
  "$FAKE_APPLICATIONS/Codex05.app/Contents/Resources/codex" \
  "$FAKE_APPLICATIONS/Codex10.app/Contents/Resources/codex" \
  "$FAKE_APPLICATIONS/Codex2.app/Contents/Resources/codex")"
[[ "$discovered_order" == "$expected_discovered_order" ]] \
  || fail "Discovered Codex app order/symlink policy drifted from the canonical contract."

resolved_codex="$({
  CODEX_APPLICATIONS_DIR="$FAKE_APPLICATIONS" \
  CODEX_HOMEBREW_CANDIDATE="$TEMP_PARENT/missing-homebrew" \
  CODEX_USR_LOCAL_CANDIDATE="$TEMP_PARENT/missing-usr-local" \
  CODEX_PATH_VALUE="$FAKE_PATH_BIN" \
    codex_resolve_executable
})"
[[ "$resolved_codex" == "$FAKE_APPLICATIONS/Codex05.app/Contents/Resources/codex" ]] \
  || fail "Resolver did not skip malformed/unsupported candidates or include the canonical symlink candidate."

UNINSTALL_ROOT="$TEMP_PARENT/uninstall-fixture"
UNINSTALL_INSTALL_DIR="$UNINSTALL_ROOT/Applications"
UNINSTALL_APP="$UNINSTALL_INSTALL_DIR/CodexStatusBar.app"
UNINSTALL_EXECUTABLE="$UNINSTALL_APP/Contents/MacOS/CodexStatusBar"
UNINSTALL_CANARY="$UNINSTALL_ROOT/canary/CodexStatusBar"
mkdir -p "$(dirname "$UNINSTALL_EXECUTABLE")" "$(dirname "$UNINSTALL_CANARY")"
UNINSTALL_PROCESS_SOURCE="$UNINSTALL_ROOT/process.c"
printf '%s\n' \
  '#include <unistd.h>' \
  'int main(void) { for (;;) { pause(); } }' \
  > "$UNINSTALL_PROCESS_SOURCE"
/usr/bin/clang "$UNINSTALL_PROCESS_SOURCE" -o "$UNINSTALL_EXECUTABLE"
/usr/bin/clang "$UNINSTALL_PROCESS_SOURCE" -o "$UNINSTALL_CANARY"
chmod +x "$UNINSTALL_EXECUTABLE" "$UNINSTALL_CANARY"
write_uninstall_info_plist() {
  local bundle_identifier="$1"
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    "<key>CFBundleIdentifier</key><string>$bundle_identifier</string>" \
    '<key>CFBundleExecutable</key><string>CodexStatusBar</string>' \
    '</dict></plist>' \
    > "$UNINSTALL_APP/Contents/Info.plist"
}
write_uninstall_info_plist "example.foreign.app"
"$UNINSTALL_CANARY" &
UNINSTALL_CANARY_PID=$!
expect_failure env INSTALL_DIR="$UNINSTALL_INSTALL_DIR" "$REPO_ROOT/uninstall.sh"
kill -0 "$UNINSTALL_CANARY_PID" >/dev/null 2>&1 \
  || fail "Uninstall terminated a canary process before validating the target bundle."
[[ -d "$UNINSTALL_APP" ]] || fail "Uninstall removed a foreign bundle."

write_uninstall_info_plist "com.farzad.codexstatusbar"
"$UNINSTALL_EXECUTABLE" &
UNINSTALL_TARGET_PID=$!
env \
  INSTALL_DIR="$UNINSTALL_INSTALL_DIR" \
  PROCESS_WAIT_ATTEMPTS=20 \
  PROCESS_WAIT_INTERVAL=0.01 \
  "$REPO_ROOT/uninstall.sh" >/dev/null
[[ ! -e "$UNINSTALL_APP" ]] || fail "Uninstall did not remove the validated app bundle."
if kill -0 "$UNINSTALL_TARGET_PID" >/dev/null 2>&1; then
  fail "Uninstall did not terminate the validated target executable."
fi
wait "$UNINSTALL_TARGET_PID" >/dev/null 2>&1 || true
UNINSTALL_TARGET_PID=""
kill -0 "$UNINSTALL_CANARY_PID" >/dev/null 2>&1 \
  || fail "Uninstall terminated a same-name process outside the validated target path."
kill "$UNINSTALL_CANARY_PID" >/dev/null 2>&1 || true
wait "$UNINSTALL_CANARY_PID" >/dev/null 2>&1 || true
UNINSTALL_CANARY_PID=""

INSTALL_FIXTURE_REPO="$TEMP_PARENT/install-fixture-repo"
INSTALL_FIXTURE_TOOLS="$TEMP_PARENT/install-fixture-tools"
INSTALL_FIXTURE_TARGET="$TEMP_PARENT/install-fixture-target"
INSTALL_FIXTURE_DERIVED="$TEMP_PARENT/install-fixture-derived"
INSTALL_FIXTURE_OPEN_MARKER="$TEMP_PARENT/install-fixture-opened.txt"
INSTALL_FIXTURE_CODEX="$TEMP_PARENT/install-fixture-codex"
INSTALL_FIXTURE_MANIFEST="$TEMP_PARENT/install-fixture-candidates.txt"
mkdir -p \
  "$INSTALL_FIXTURE_REPO/scripts/lib" \
  "$INSTALL_FIXTURE_REPO/CodexUsageMenuBar.xcodeproj" \
  "$INSTALL_FIXTURE_TOOLS" \
  "$INSTALL_FIXTURE_TARGET"
cp "$REPO_ROOT/install.sh" "$INSTALL_FIXTURE_REPO/install.sh"
cp "$SCRIPT_DIR/lib/safe_paths.sh" "$SCRIPT_DIR/lib/codex_resolver.sh" "$INSTALL_FIXTURE_REPO/scripts/lib/"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 1.2.3"; exit 0; fi' \
  'if [[ "${1:-}" == "app-server" && "${2:-}" == "--help" ]]; then echo "--stdio"; exit 0; fi' \
  'exit 2' \
  > "$INSTALL_FIXTURE_CODEX"
chmod +x "$INSTALL_FIXTURE_CODEX"
printf '%s\n' "$INSTALL_FIXTURE_CODEX" > "$INSTALL_FIXTURE_MANIFEST"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'derived=""' \
  'while [[ "$#" -gt 0 ]]; do' \
  '  if [[ "$1" == "-derivedDataPath" ]]; then derived="$2"; shift 2; else shift; fi' \
  'done' \
  '[[ -n "$derived" ]]' \
  'app="$derived/Build/Products/Release/CodexStatusBar.app"' \
  '/bin/rm -rf -- "$app"' \
  'mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"' \
  'printf "#!/usr/bin/env bash\\nexit 0\\n" > "$app/Contents/MacOS/CodexStatusBar"' \
  'chmod +x "$app/Contents/MacOS/CodexStatusBar"' \
  'printf "%s" "${CODEX_TEST_BUILD_MARKER:-build}" > "$app/build-marker.txt"' \
  > "$INSTALL_FIXTURE_TOOLS/xcodebuild"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'app=""' \
  'while [[ "$#" -gt 0 ]]; do if [[ "$1" == "--app" ]]; then app="$2"; shift 2; else shift; fi; done' \
  'mkdir -p "$app/Contents/Resources"' \
  'printf "{}\\n" > "$app/Contents/Resources/BuildFingerprint.json"' \
  > "$INSTALL_FIXTURE_REPO/scripts/finalize_app_bundle.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'app=""' \
  'while [[ "$#" -gt 0 ]]; do if [[ "$1" == "--app" ]]; then app="$2"; shift 2; else shift; fi; done' \
  '[[ -x "$app/Contents/MacOS/CodexStatusBar" ]]' \
  '[[ -f "$app/Contents/Resources/BuildFingerprint.json" ]]' \
  'if [[ -n "${CODEX_TEST_FAIL_VALIDATION_SUBSTRING:-}" && "$app" == *"$CODEX_TEST_FAIL_VALIDATION_SUBSTRING"* ]]; then' \
  '  echo "injected staged validation failure" >&2' \
  '  exit 85' \
  'fi' \
  > "$INSTALL_FIXTURE_REPO/scripts/validate_app_bundle.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exec /usr/bin/ditto "$@"' > "$INSTALL_FIXTURE_TOOLS/ditto"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${CODEX_TEST_FAIL_INSTALL_SWAP:-0}" == "1" && "$1" == *"/.CodexStatusBar.install."* && "$2" == */CodexStatusBar.app ]]; then' \
  '  echo "injected install swap failure" >&2' \
  '  exit 86' \
  'fi' \
  'exec /bin/mv "$@"' \
  > "$INSTALL_FIXTURE_TOOLS/mv"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s" "$1" > "$CODEX_TEST_INSTALL_OPEN_MARKER"' \
  > "$INSTALL_FIXTURE_TOOLS/open"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ -f "$CODEX_TEST_INSTALL_OPEN_MARKER" && "${!#}" == "CodexStatusBar" ]]; then echo 5151; exit 0; fi' \
  'exit 1' \
  > "$INSTALL_FIXTURE_TOOLS/pgrep"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$CODEX_TEST_INSTALL_EXECUTABLE"' \
  > "$INSTALL_FIXTURE_TOOLS/ps"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '/bin/rm -f -- "$CODEX_TEST_INSTALL_OPEN_MARKER"' \
  'exit 0' \
  > "$INSTALL_FIXTURE_TOOLS/pkill"
chmod +x \
  "$INSTALL_FIXTURE_REPO/install.sh" \
  "$INSTALL_FIXTURE_REPO/scripts/"*.sh \
  "$INSTALL_FIXTURE_TOOLS/"*

run_install_fixture() {
  env \
    PATH="$INSTALL_FIXTURE_TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
    INSTALL_DIR="$INSTALL_FIXTURE_TARGET" \
    DERIVED_DATA_PATH="$INSTALL_FIXTURE_DERIVED" \
    CLEAN_AFTER_INSTALL=0 \
    OPEN_AFTER_INSTALL=1 \
    VERIFY_OPEN_AFTER_INSTALL=1 \
    PROCESS_WAIT_ATTEMPTS=5 \
    PROCESS_WAIT_INTERVAL=0.01 \
    CODEX_CANDIDATE_MANIFEST="$INSTALL_FIXTURE_MANIFEST" \
    CODEX_APPLICATIONS_DIR="$TEMP_PARENT/no-applications" \
    CODEX_HOMEBREW_CANDIDATE="$TEMP_PARENT/no-homebrew" \
    CODEX_USR_LOCAL_CANDIDATE="$TEMP_PARENT/no-usr-local" \
    CODEX_PATH_VALUE="" \
    CODEX_TEST_INSTALL_OPEN_MARKER="$INSTALL_FIXTURE_OPEN_MARKER" \
    CODEX_TEST_INSTALL_EXECUTABLE="$INSTALL_FIXTURE_TARGET/CodexStatusBar.app/Contents/MacOS/CodexStatusBar" \
    "$@" \
    "$INSTALL_FIXTURE_REPO/install.sh" >/dev/null
}

run_install_fixture env CODEX_TEST_BUILD_MARKER=first
[[ "$(<"$INSTALL_FIXTURE_TARGET/CodexStatusBar.app/build-marker.txt")" == "first" ]] \
  || fail "First-install fixture did not install the built bundle."
[[ "$(<"$INSTALL_FIXTURE_OPEN_MARKER")" == "$INSTALL_FIXTURE_TARGET/CodexStatusBar.app" ]] \
  || fail "First-install fixture did not relaunch the installed target."

run_install_fixture env CODEX_TEST_BUILD_MARKER=upgrade
[[ "$(<"$INSTALL_FIXTURE_TARGET/CodexStatusBar.app/build-marker.txt")" == "upgrade" ]] \
  || fail "Upgrade fixture did not replace the installed bundle."

expect_failure run_install_fixture env \
  CODEX_TEST_BUILD_MARKER=invalid \
  CODEX_TEST_FAIL_VALIDATION_SUBSTRING=.CodexStatusBar.install.
[[ "$(<"$INSTALL_FIXTURE_TARGET/CodexStatusBar.app/build-marker.txt")" == "upgrade" ]] \
  || fail "Staged-validation failure did not preserve the previous install."

expect_failure run_install_fixture env \
  CODEX_TEST_BUILD_MARKER=swap-failure \
  CODEX_TEST_FAIL_INSTALL_SWAP=1
[[ "$(<"$INSTALL_FIXTURE_TARGET/CodexStatusBar.app/build-marker.txt")" == "upgrade" ]] \
  || fail "Swap failure did not roll back to the previous install."
if find "$INSTALL_FIXTURE_TARGET" -maxdepth 1 -name '.CodexStatusBar.*.*' -print | grep -q .; then
  fail "Install fixtures left a transactional sibling behind."
fi

FIXTURE_REPO="$TEMP_PARENT/release-prep-fixture"
FIXTURE_REMOTE="$TEMP_PARENT/release-prep-remote.git"
mkdir -p "$FIXTURE_REPO/scripts" "$FIXTURE_REPO/CodexUsageMenuBar.xcodeproj"
cp "$SCRIPT_DIR/prepare_release.sh" "$SCRIPT_DIR/set_version.sh" "$FIXTURE_REPO/scripts/"
printf '%s\n' \
  'MARKETING_VERSION = 1.0.0;' \
  'CURRENT_PROJECT_VERSION = 1;' \
  'MARKETING_VERSION = 1.0.0;' \
  'CURRENT_PROJECT_VERSION = 1;' \
  > "$FIXTURE_REPO/CodexUsageMenuBar.xcodeproj/project.pbxproj"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$FIXTURE_REPO/scripts/package_release.sh"
printf '%s\n' '#!/bin/bash' 'exit 17' > "$FIXTURE_REPO/scripts/verify.sh"
chmod +x "$FIXTURE_REPO/scripts/"*.sh
git -C "$FIXTURE_REPO" init -b main >/dev/null
git -C "$FIXTURE_REPO" config user.name "Release Script Test"
git -C "$FIXTURE_REPO" config user.email "release-script-test@example.invalid"
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -m initial >/dev/null
git init --bare "$FIXTURE_REMOTE" >/dev/null
git -C "$FIXTURE_REPO" remote add origin "$FIXTURE_REMOTE"
git -C "$FIXTURE_REPO" push -u origin main >/dev/null
FIXTURE_ORIGINAL_HEAD="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

expect_failure "$FIXTURE_REPO/scripts/prepare_release.sh" 2.0.0 2
if ! git -C "$FIXTURE_REPO" diff --quiet -- CodexUsageMenuBar.xcodeproj/project.pbxproj; then
  fail "prepare_release.sh did not roll back version edits after verification failure."
fi
[[ "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" == "$FIXTURE_ORIGINAL_HEAD" ]] \
  || fail "Verification failure unexpectedly changed the release fixture HEAD."

PACKAGE_OBSERVATION="$TEMP_PARENT/package-head.txt"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "--dry-run" ]]; then exit 0; fi' \
  '[[ -z "$(git status --porcelain)" ]] || exit 31' \
  'git rev-parse HEAD > "$RELEASE_TEST_OBSERVATION"' \
  'exit 17' \
  > "$FIXTURE_REPO/scripts/package_release.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$FIXTURE_REPO/scripts/verify.sh"
chmod +x "$FIXTURE_REPO/scripts/package_release.sh" "$FIXTURE_REPO/scripts/verify.sh"
git -C "$FIXTURE_REPO" add scripts/package_release.sh scripts/verify.sh
git -C "$FIXTURE_REPO" commit -m "configure package failure fixture" >/dev/null
git -C "$FIXTURE_REPO" push origin main >/dev/null
FIXTURE_ORIGINAL_HEAD="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

expect_failure env RELEASE_TEST_OBSERVATION="$PACKAGE_OBSERVATION" \
  "$FIXTURE_REPO/scripts/prepare_release.sh" 2.0.0 2
[[ "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" == "$FIXTURE_ORIGINAL_HEAD" ]] \
  || fail "Packaging failure did not remove the unpushed version commit."
git -C "$FIXTURE_REPO" diff --quiet -- CodexUsageMenuBar.xcodeproj/project.pbxproj \
  || fail "Packaging failure did not restore version metadata."
OBSERVED_PACKAGE_HEAD="$(cat "$PACKAGE_OBSERVATION")"
[[ "$OBSERVED_PACKAGE_HEAD" != "$FIXTURE_ORIGINAL_HEAD" ]] \
  || fail "Packaging ran before the new version commit was created."
git -C "$FIXTURE_REPO" show "$OBSERVED_PACKAGE_HEAD:CodexUsageMenuBar.xcodeproj/project.pbxproj" \
  | grep -q 'MARKETING_VERSION = 2.0.0;' \
  || fail "Packaged commit did not contain the requested version metadata."

printf '%s\n' ahead > "$FIXTURE_REPO/ahead.txt"
git -C "$FIXTURE_REPO" add ahead.txt
git -C "$FIXTURE_REPO" commit -m ahead >/dev/null
expect_failure "$FIXTURE_REPO/scripts/prepare_release.sh" 2.0.0 2

printf '%s\n' '#!/bin/bash' 'exit 0' > "$FIXTURE_REPO/scripts/package_release.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$FIXTURE_REPO/scripts/verify.sh"
chmod +x "$FIXTURE_REPO/scripts/package_release.sh" "$FIXTURE_REPO/scripts/verify.sh"
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -m "configure successful release fixture" >/dev/null
git -C "$FIXTURE_REPO" push origin main >/dev/null
"$FIXTURE_REPO/scripts/prepare_release.sh" 3.0.0 3 >/dev/null
FIRST_SUCCESSFUL_RELEASE_HEAD="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
git -C "$FIXTURE_REPO" push origin main >/dev/null
"$FIXTURE_REPO/scripts/prepare_release.sh" 3.0.0 3 >/dev/null
[[ "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" == "$FIRST_SUCCESSFUL_RELEASE_HEAD" ]] \
  || fail "Rerunning release preparation for matching metadata created another commit."
git -C "$FIXTURE_REPO" diff --quiet \
  || fail "Idempotent release preparation left tracked changes behind."

PROVENANCE_REPO="$TEMP_PARENT/provenance-fixture"
PROVENANCE_APP="$PROVENANCE_REPO/CodexStatusBar.app"
mkdir -p \
  "$PROVENANCE_REPO/scripts" \
  "$PROVENANCE_REPO/scripts/lib" \
  "$PROVENANCE_REPO/Resources" \
  "$PROVENANCE_APP/Contents/MacOS" \
  "$PROVENANCE_APP/Contents/Resources"
cp \
  "$SCRIPT_DIR/finalize_app_bundle.sh" \
  "$SCRIPT_DIR/validate_app_bundle.sh" \
  "$SCRIPT_DIR/validate_release_artifact.sh" \
  "$PROVENANCE_REPO/scripts/"
cp "$SCRIPT_DIR/lib/safe_paths.sh" "$SCRIPT_DIR/lib/codex_resolver.sh" "$PROVENANCE_REPO/scripts/lib/"
cp "$REPO_ROOT/Resources/CodexExecutableCandidates.txt" "$PROVENANCE_REPO/Resources/"
cp /usr/bin/true "$PROVENANCE_APP/Contents/MacOS/CodexStatusBar"
printf '%s\n' compiled-assets > "$PROVENANCE_APP/Contents/Resources/Assets.car"
printf '%s\n' compiled-icon > "$PROVENANCE_APP/Contents/Resources/AppIcon.icns"
cp "$REPO_ROOT/Resources/CodexExecutableCandidates.txt" "$PROVENANCE_APP/Contents/Resources/"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  '<key>CFBundleIdentifier</key><string>com.farzad.codexstatusbar</string>' \
  '<key>CFBundleExecutable</key><string>CodexStatusBar</string>' \
  '<key>CFBundleShortVersionString</key><string>1.2.3</string>' \
  '<key>CFBundleVersion</key><string>7</string>' \
  '<key>CFBundleIconName</key><string>AppIcon</string>' \
  '</dict></plist>' \
  > "$PROVENANCE_APP/Contents/Info.plist"
printf '%s\n' clean > "$PROVENANCE_REPO/tracked.txt"
git -C "$PROVENANCE_REPO" init -b main >/dev/null
git -C "$PROVENANCE_REPO" config user.name "Release Script Test"
git -C "$PROVENANCE_REPO" config user.email "release-script-test@example.invalid"
git -C "$PROVENANCE_REPO" add .
git -C "$PROVENANCE_REPO" commit -m initial >/dev/null
printf '%s\n' dirty >> "$PROVENANCE_REPO/tracked.txt"
expect_failure "$PROVENANCE_REPO/scripts/finalize_app_bundle.sh" \
  --app "$PROVENANCE_APP" \
  --provenance public-release \
  --omit-executable-hash
git -C "$PROVENANCE_REPO" restore -- tracked.txt
"$PROVENANCE_REPO/scripts/finalize_app_bundle.sh" \
  --app "$PROVENANCE_APP" \
  --provenance public-release \
  --omit-executable-hash \
  >/dev/null
[[ "$(plutil -extract gitCommit raw "$PROVENANCE_APP/Contents/Resources/BuildFingerprint.json")" == "$(git -C "$PROVENANCE_REPO" rev-parse HEAD)" ]] \
  || fail "Public fingerprint did not identify the exact clean fixture commit."
for private_key in sourceRoot gitBranch isDirty installedBundlePath executableSHA256; do
  if plutil -extract "$private_key" raw "$PROVENANCE_APP/Contents/Resources/BuildFingerprint.json" >/dev/null 2>&1; then
    fail "Public fingerprint must omit local-only field '$private_key'."
  fi
done
PROVENANCE_COMMIT="$(git -C "$PROVENANCE_REPO" rev-parse HEAD)"
PROVENANCE_ARCH="$(/usr/bin/lipo -archs "$PROVENANCE_APP/Contents/MacOS/CodexStatusBar" | awk '{print $1}')"
"$PROVENANCE_REPO/scripts/validate_app_bundle.sh" \
  --app "$PROVENANCE_APP" \
  --version 1.2.3 \
  --build 7 \
  --arch "$PROVENANCE_ARCH" \
  --provenance public-release \
  --commit "$PROVENANCE_COMMIT" \
  >/dev/null
expect_failure "$PROVENANCE_REPO/scripts/validate_app_bundle.sh" --app "$PROVENANCE_APP" --version 9.9.9
expect_failure "$PROVENANCE_REPO/scripts/validate_app_bundle.sh" --app "$PROVENANCE_APP" --build 999
expect_failure "$PROVENANCE_REPO/scripts/validate_app_bundle.sh" --app "$PROVENANCE_APP" --arch not-a-real-arch
expect_failure "$PROVENANCE_REPO/scripts/validate_app_bundle.sh" --app "$PROVENANCE_APP" --provenance source-checkout
expect_failure "$PROVENANCE_REPO/scripts/validate_app_bundle.sh" \
  --app "$PROVENANCE_APP" \
  --commit 0000000000000000000000000000000000000000

SIGNATURE_TOOLS="$TEMP_PARENT/signature-tools"
mkdir -p "$SIGNATURE_TOOLS"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "--verify" ]]; then exit "${RELEASE_TEST_CODESIGN_VERIFY_STATUS:-0}"; fi' \
  'if [[ " $* " == *" --requirements "* ]]; then' \
  '  printf "designated => anchor apple generic and certificate leaf[subject.OU] = \"%s\"\n" "${RELEASE_TEST_REQUIREMENT_TEAM:-ABCDE12345}" >&2' \
  '  exit 0' \
  'fi' \
  'if [[ " $* " == *" --display "* ]]; then' \
  '  printf "TeamIdentifier=%s\nAuthority=%s\n" "${RELEASE_TEST_TEAM:-ABCDE12345}" "${RELEASE_TEST_SIGNER:-Developer ID Application: Example (ABCDE12345)}" >&2' \
  '  exit 0' \
  'fi' \
  'exit 2' \
  > "$SIGNATURE_TOOLS/codesign"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "${1:-}" == "stapler" && "${2:-}" == "validate" ]] || exit 2' \
  'exit "${RELEASE_TEST_STAPLER_STATUS:-0}"' \
  > "$SIGNATURE_TOOLS/xcrun"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit "${RELEASE_TEST_SPCTL_STATUS:-0}"' \
  > "$SIGNATURE_TOOLS/spctl"
chmod +x "$SIGNATURE_TOOLS/"*

SIGNED_VALIDATOR=(
  "$PROVENANCE_REPO/scripts/validate_app_bundle.sh"
  --app "$PROVENANCE_APP"
  --signed
  --team ABCDE12345
  --signer 'Developer ID Application: Example (ABCDE12345)'
)
env PATH="$SIGNATURE_TOOLS:$PATH" "${SIGNED_VALIDATOR[@]}" >/dev/null
expect_failure env PATH="$SIGNATURE_TOOLS:$PATH" RELEASE_TEST_CODESIGN_VERIFY_STATUS=41 \
  "${SIGNED_VALIDATOR[@]}"
expect_failure env PATH="$SIGNATURE_TOOLS:$PATH" RELEASE_TEST_TEAM=WRONGTEAM \
  "${SIGNED_VALIDATOR[@]}"
expect_failure env PATH="$SIGNATURE_TOOLS:$PATH" RELEASE_TEST_SIGNER='Developer ID Application: Impostor (ABCDE12345)' \
  "${SIGNED_VALIDATOR[@]}"
expect_failure env PATH="$SIGNATURE_TOOLS:$PATH" RELEASE_TEST_REQUIREMENT_TEAM=WRONGTEAM \
  "${SIGNED_VALIDATOR[@]}"
env PATH="$SIGNATURE_TOOLS:$PATH" "${SIGNED_VALIDATOR[@]}" --notarized >/dev/null
expect_failure env PATH="$SIGNATURE_TOOLS:$PATH" RELEASE_TEST_STAPLER_STATUS=42 \
  "${SIGNED_VALIDATOR[@]}" --notarized
expect_failure env PATH="$SIGNATURE_TOOLS:$PATH" RELEASE_TEST_SPCTL_STATUS=43 \
  "${SIGNED_VALIDATOR[@]}" --notarized

PUBLIC_FINGERPRINT_BACKUP="$TEMP_PARENT/public-fingerprint.json"
cp "$PROVENANCE_APP/Contents/Resources/BuildFingerprint.json" "$PUBLIC_FINGERPRINT_BACKUP"
plutil -insert sourceRoot -string /private/source/path "$PROVENANCE_APP/Contents/Resources/BuildFingerprint.json"
expect_failure "$PROVENANCE_REPO/scripts/validate_app_bundle.sh" \
  --app "$PROVENANCE_APP" \
  --provenance public-release
cp "$PUBLIC_FINGERPRINT_BACKUP" "$PROVENANCE_APP/Contents/Resources/BuildFingerprint.json"

PROVENANCE_ZIP="$TEMP_PARENT/CodexStatusBar-v1.2.3-build7.zip"
(
  cd "$PROVENANCE_REPO"
  ditto -c -k --keepParent CodexStatusBar.app "$PROVENANCE_ZIP"
)
"$PROVENANCE_REPO/scripts/validate_release_artifact.sh" \
  --artifact "$PROVENANCE_ZIP" \
  --version 1.2.3 \
  --build 7 \
  --arch "$PROVENANCE_ARCH" \
  --provenance public-release \
  --commit "$PROVENANCE_COMMIT" \
  >/dev/null

SOURCE_INSTALL_PATH="$PROVENANCE_REPO/Installed/CodexStatusBar.app"
"$PROVENANCE_REPO/scripts/finalize_app_bundle.sh" \
  --app "$PROVENANCE_APP" \
  --provenance source-checkout \
  --source-root "$PROVENANCE_REPO" \
  --installed-path "$SOURCE_INSTALL_PATH" \
  >/dev/null
[[ "$(plutil -extract sourceRoot raw "$PROVENANCE_APP/Contents/Resources/BuildFingerprint.json")" == "$PROVENANCE_REPO" ]] \
  || fail "Source fingerprint did not retain its source root."
[[ "$(plutil -extract installedBundlePath raw "$PROVENANCE_APP/Contents/Resources/BuildFingerprint.json")" == "$SOURCE_INSTALL_PATH" ]] \
  || fail "Source fingerprint did not retain its installed bundle path."
source_executable_hash="$(shasum -a 256 "$PROVENANCE_APP/Contents/MacOS/CodexStatusBar" | awk '{print $1}')"
[[ "$(plutil -extract executableSHA256 raw "$PROVENANCE_APP/Contents/Resources/BuildFingerprint.json")" == "$source_executable_hash" ]] \
  || fail "Source fingerprint executable hash did not match its app executable."
"$PROVENANCE_REPO/scripts/validate_app_bundle.sh" \
  --app "$PROVENANCE_APP" \
  --version 1.2.3 \
  --build 7 \
  --arch "$PROVENANCE_ARCH" \
  --provenance source-checkout \
  --commit "$PROVENANCE_COMMIT" \
  >/dev/null
PROVENANCE_EXECUTABLE_BACKUP="$TEMP_PARENT/provenance-executable"
cp "$PROVENANCE_APP/Contents/MacOS/CodexStatusBar" "$PROVENANCE_EXECUTABLE_BACKUP"
printf '%s\n' mutation >> "$PROVENANCE_APP/Contents/MacOS/CodexStatusBar"
expect_failure "$PROVENANCE_REPO/scripts/validate_app_bundle.sh" \
  --app "$PROVENANCE_APP" \
  --provenance source-checkout
cp "$PROVENANCE_EXECUTABLE_BACKUP" "$PROVENANCE_APP/Contents/MacOS/CodexStatusBar"
chmod +x "$PROVENANCE_APP/Contents/MacOS/CodexStatusBar"

RELEASE_WORKFLOW="$REPO_ROOT/.github/workflows/release.yml.disabled"
/usr/bin/ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path) }' \
  "$REPO_ROOT/.github/workflows/ci.yml" \
  "$RELEASE_WORKFLOW"
source "$SCRIPT_DIR/lib/release_state.sh"
TAG_STATE_REPO="$TEMP_PARENT/tag-state-repo"
mkdir -p "$TAG_STATE_REPO"
git -C "$TAG_STATE_REPO" init -b main >/dev/null
git -C "$TAG_STATE_REPO" config user.name "Release State Test"
git -C "$TAG_STATE_REPO" config user.email "release-state-test@example.invalid"
printf '%s\n' first > "$TAG_STATE_REPO/state.txt"
git -C "$TAG_STATE_REPO" add state.txt
git -C "$TAG_STATE_REPO" commit -m first >/dev/null
git -C "$TAG_STATE_REPO" tag -a v1.2.3 -m v1.2.3
printf '%s\n' second >> "$TAG_STATE_REPO/state.txt"
git -C "$TAG_STATE_REPO" add state.txt
git -C "$TAG_STATE_REPO" commit -m second >/dev/null
(
  cd "$TAG_STATE_REPO"
  expect_failure release_assert_existing_tag_matches_head 1.2.3
  git tag -a v2.0.0 -m v2.0.0
  release_assert_existing_tag_matches_head 2.0.0
  release_assert_existing_tag_matches_head 9.9.9
)

RELEASE_STATE_TOOLS="$TEMP_PARENT/release-state-tools"
mkdir -p "$RELEASE_STATE_TOOLS"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "${RELEASE_TEST_GH_STATE:-missing}" in' \
  '  missing) echo "release not found" >&2; exit 1 ;;' \
  '  draft) echo true; exit 0 ;;' \
  '  published) echo false; exit 0 ;;' \
  '  error) echo "authentication failed" >&2; exit 1 ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  > "$RELEASE_STATE_TOOLS/gh"
chmod +x "$RELEASE_STATE_TOOLS/gh"
run_release_state_fixture() {
  PATH="$RELEASE_STATE_TOOLS:$PATH" \
    RELEASE_TEST_GH_STATE="$1" \
    release_assert_resumable_github_release 1.2.3
}
run_release_state_fixture missing
run_release_state_fixture draft >/dev/null
expect_failure run_release_state_fixture published
expect_failure run_release_state_fixture error

VERIFY_SCRIPT="$REPO_ROOT/scripts/verify.sh"
source "$SCRIPT_DIR/lib/build_warnings.sh"
WARNING_FIXTURE_LOG="$TEMP_PARENT/warning-fixture.log"
WARNING_FIXTURE_OUTPUT="$TEMP_PARENT/warning-fixture-output.txt"
printf '%s\n' \
  'a.swift:1: warning: Metadata extraction skipped. No AppIntents.framework dependency found.' \
  'b.swift:2: warning: Metadata extraction skipped. No AppIntents.framework dependency found. extra context' \
  'c.swift:3: warning: Actionable warning' \
  'd.swift:4: warning: Nested warning: Metadata extraction skipped. No AppIntents.framework dependency found.' \
  > "$WARNING_FIXTURE_LOG"
filter_actionable_build_warnings "$WARNING_FIXTURE_LOG" "$WARNING_FIXTURE_OUTPUT"
[[ "$(wc -l < "$WARNING_FIXTURE_OUTPUT" | tr -d '[:space:]')" == "3" ]] \
  || fail "Warning filter must suppress only the exact documented warning line."
grep -Fq 'extra context' "$WARNING_FIXTURE_OUTPUT" \
  || fail "Warning filter incorrectly suppressed a warning containing the allowed phrase."
grep -Fq 'Actionable warning' "$WARNING_FIXTURE_OUTPUT" \
  || fail "Warning filter discarded an actionable warning."
grep -Fq 'Nested warning' "$WARNING_FIXTURE_OUTPUT" \
  || fail "Warning filter suppressed a line whose trailing text matched the allowed warning."

VERIFY_EVIDENCE_ROOT="$TEMP_PARENT/verify-evidence"
VERIFY_EVIDENCE_LOG="$VERIFY_EVIDENCE_ROOT/verify.log"
expect_failure env \
  CI=false \
  VERIFY_ALLOWED_ROOT="$TEMP_PARENT" \
  VERIFY_DERIVED_DATA_PATH="$VERIFY_EVIDENCE_ROOT" \
  VERIFY_RESULT_BUNDLE_PATH="$VERIFY_EVIDENCE_ROOT/TestResults.xcresult" \
  VERIFY_LOG_PATH="$VERIFY_EVIDENCE_LOG" \
  VERIFY_COVERAGE_REPORT_PATH="$VERIFY_EVIDENCE_ROOT/coverage.txt" \
  VERIFY_INJECT_FAILURE_AFTER_SETUP=1 \
  "$VERIFY_SCRIPT"
[[ -f "$VERIFY_EVIDENCE_ROOT/.codex-status-bar-verification" ]] \
  || fail "Failed verification did not preserve its ownership sentinel."
grep -Fq 'Injected verification failure after evidence setup.' "$VERIFY_EVIDENCE_LOG" \
  || fail "Failed verification did not preserve its diagnostic log."

grep -Fq -- '"$SCRIPT_DIR/finalize_app_bundle.sh"' "$VERIFY_SCRIPT" \
  || fail "Canonical verification must finalize its Release app through the shared contract."
grep -Fq -- '"$SCRIPT_DIR/validate_app_bundle.sh"' "$VERIFY_SCRIPT" \
  || fail "Canonical verification must validate its finalized Release app through the shared contract."
finalizer_line="$(grep -nF '"$SCRIPT_DIR/finalize_app_bundle.sh"' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)"
validator_line="$(grep -nF '"$SCRIPT_DIR/validate_app_bundle.sh"' "$VERIFY_SCRIPT" | head -1 | cut -d: -f1)"
if [[ -z "$finalizer_line" || -z "$validator_line" || "$finalizer_line" -ge "$validator_line" ]]; then
  fail "Canonical verification must finalize the Release app before validating it."
fi
if ! grep -q -- '--draft' "$RELEASE_WORKFLOW"; then
  fail "Disabled release workflow must create a draft before publishing."
fi
draft_line="$(awk '/--draft([[:space:]]|$)/ { print NR; exit }' "$RELEASE_WORKFLOW")"
publish_line="$(awk '/--draft=false/ { print NR; exit }' "$RELEASE_WORKFLOW")"
if [[ -z "$draft_line" || -z "$publish_line" || "$draft_line" -ge "$publish_line" ]]; then
  fail "Disabled release workflow must create the draft before its final publication step."
fi
grep -q -- 'CHECKSUM_PATH' "$RELEASE_WORKFLOW" \
  || fail "Disabled release workflow must upload the checksum with the app artifact."
grep -Fq -- '--commit "$(git rev-parse HEAD)"' "$RELEASE_WORKFLOW" \
  || fail "Disabled release workflow must validate the artifact against the exact packaged commit."
grep -Fq -- '--signer "$DEVELOPER_ID_APPLICATION"' "$RELEASE_WORKFLOW" \
  || fail "Disabled release workflow must validate the exact Developer ID signer."
grep -Fq -- 'Version metadata was not committed before public packaging.' "$RELEASE_WORKFLOW" \
  || fail "Disabled release workflow must reject post-package version commits."
grep -Fq -- 'release_assert_existing_tag_matches_head "$VERSION"' "$RELEASE_WORKFLOW" \
  || fail "Disabled release workflow must execute the conflicting-tag guard."
grep -Fq -- 'release_assert_resumable_github_release "$VERSION"' "$RELEASE_WORKFLOW" \
  || fail "Disabled release workflow must execute the draft-resume guard."
if [[ -e "$REPO_ROOT/.github/workflows/release.yml" ]]; then
  fail "Publishing release workflow must remain disabled."
fi

CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
for evidence_path in verify.log warnings.txt coverage.txt TestResults.xcresult; do
  grep -Fq "$evidence_path" "$CI_WORKFLOW" \
    || fail "CI failure artifact selection is missing $evidence_path."
done
grep -Fq 'if: failure()' "$CI_WORKFLOW" \
  || fail "CI must upload verification evidence only after failure."
grep -Fq 'retention-days: 14' "$CI_WORKFLOW" \
  || fail "CI verification evidence must use the documented 14-day retention."

echo "Release/install script safeguards passed."
