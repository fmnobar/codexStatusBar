#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/safe_paths.sh"
source "$SCRIPT_DIR/scripts/lib/codex_resolver.sh"
PROJECT_PATH="$SCRIPT_DIR/CodexUsageMenuBar.xcodeproj"
SCHEME_NAME="CodexUsageMenuBar"
DEFAULT_DERIVED_DATA_PATH="$SCRIPT_DIR/.build/DerivedData"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DEFAULT_DERIVED_DATA_PATH}"
DERIVED_DATA_IS_MANAGED=0
BUILD_SENTINEL=".codex-status-bar-derived-data"
if [[ "$DERIVED_DATA_PATH" == "$DEFAULT_DERIVED_DATA_PATH" ]]; then
  DERIVED_DATA_IS_MANAGED=1
  if [[ -d "$DERIVED_DATA_PATH" && ! -f "$DERIVED_DATA_PATH/$BUILD_SENTINEL" ]]; then
    DERIVED_DATA_PATH="$SCRIPT_DIR/.build/DerivedData.install.$$"
    echo "Preserving legacy build output without an ownership sentinel: $DEFAULT_DERIVED_DATA_PATH"
    echo "Using isolated build output instead: $DERIVED_DATA_PATH"
  fi
fi
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/CodexStatusBar.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP_PATH="$INSTALL_DIR/CodexStatusBar.app"
APP_PROCESS_NAME="CodexStatusBar"
LEGACY_PROCESS_NAME="CodexUsageMenuBar"
BUILT_EXECUTABLE_PATH="$BUILT_APP_PATH/Contents/MacOS/$APP_PROCESS_NAME"
INSTALLED_EXECUTABLE_PATH="$INSTALLED_APP_PATH/Contents/MacOS/$APP_PROCESS_NAME"
BUILT_FINGERPRINT_PATH="$BUILT_APP_PATH/Contents/Resources/BuildFingerprint.json"
INSTALLED_FINGERPRINT_PATH="$INSTALLED_APP_PATH/Contents/Resources/BuildFingerprint.json"
INSTALL_STAGE_PATH="$INSTALL_DIR/.CodexStatusBar.install.$$"
INSTALL_BACKUP_PATH="$INSTALL_DIR/.CodexStatusBar.backup.$$"
INSTALL_FAILED_PATH="$INSTALL_DIR/.CodexStatusBar.failed.$$"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-1}"
VERIFY_OPEN_AFTER_INSTALL="${VERIFY_OPEN_AFTER_INSTALL:-1}"
CLEAN_AFTER_INSTALL="${CLEAN_AFTER_INSTALL:-1}"
PROCESS_WAIT_ATTEMPTS="${PROCESS_WAIT_ATTEMPTS:-50}"
PROCESS_WAIT_INTERVAL="${PROCESS_WAIT_INTERVAL:-0.2}"
cleanup_build_output() {
  if [[ "$CLEAN_AFTER_INSTALL" != "1" ]]; then
    return
  fi

  if [[ "$DERIVED_DATA_IS_MANAGED" != "1" ]]; then
    echo
    echo "Skipping build cache cleanup because DERIVED_DATA_PATH was customized:"
    echo "  $DERIVED_DATA_PATH"
    echo "Remove that directory manually when you no longer need it."
    return
  fi

  safe_remove_owned_directory "$DERIVED_DATA_PATH" "$SCRIPT_DIR/.build" "$BUILD_SENTINEL"
  rmdir "$SCRIPT_DIR/.build" >/dev/null 2>&1 || true

  echo
  echo "Cleaned build cache:"
  echo "  $DERIVED_DATA_PATH"
}

prepare_install_directory() {
  if [[ -L "$INSTALL_DIR" || ( -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ) ]]; then
    echo "Refusing a symlinked or non-directory install root: $INSTALL_DIR" >&2
    return 1
  fi
  mkdir -p "$INSTALL_DIR"
  [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] || {
    echo "Could not create a safe install root: $INSTALL_DIR" >&2
    return 1
  }
}

remove_install_sibling() {
  safe_remove_managed_child "$1" "$INSTALL_DIR" '.CodexStatusBar.*.*'
}

verify_staged_app() {
  local staged_app="$1"
  local staged_executable="$staged_app/Contents/MacOS/$APP_PROCESS_NAME"
  local staged_fingerprint="$staged_app/Contents/Resources/BuildFingerprint.json"

  [[ -x "$staged_executable" ]] || {
    echo "Staged app executable was not found: $staged_executable" >&2
    return 1
  }
  cmp -s "$BUILT_EXECUTABLE_PATH" "$staged_executable" || {
    echo "Staged executable does not match the just-built executable." >&2
    return 1
  }
  [[ -f "$staged_fingerprint" ]] || {
    echo "Staged build fingerprint was not found: $staged_fingerprint" >&2
    return 1
  }
  "$SCRIPT_DIR/scripts/validate_app_bundle.sh" \
    --app "$staged_app" \
    --provenance source-checkout \
    --arch "$BUILD_ARCH"
}

restore_previous_install() {
  local had_backup="$1"
  local restore_failed=0

  pkill -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true

  if [[ -e "$INSTALLED_APP_PATH" ]]; then
    if ! mv "$INSTALLED_APP_PATH" "$INSTALL_FAILED_PATH"; then
      echo "Could not move the failed new app aside; backup remains at: $INSTALL_BACKUP_PATH" >&2
      restore_failed=1
    fi
  fi

  if [[ "$had_backup" == "1" && -e "$INSTALL_BACKUP_PATH" ]]; then
    if [[ -e "$INSTALLED_APP_PATH" ]]; then
      echo "Could not restore the previous app because the target path is still occupied." >&2
      restore_failed=1
    elif ! mv "$INSTALL_BACKUP_PATH" "$INSTALLED_APP_PATH"; then
      echo "Could not restore the previous app; backup remains at: $INSTALL_BACKUP_PATH" >&2
      restore_failed=1
    else
      open "$INSTALLED_APP_PATH" >/dev/null 2>&1 || true
    fi
  fi

  remove_install_sibling "$INSTALL_STAGE_PATH" || true
  if [[ "$restore_failed" == "0" ]]; then
    remove_install_sibling "$INSTALL_FAILED_PATH" || true
  fi
  return "$restore_failed"
}

install_transactionally() {
  local had_backup=0

  remove_install_sibling "$INSTALL_STAGE_PATH"
  remove_install_sibling "$INSTALL_BACKUP_PATH"
  remove_install_sibling "$INSTALL_FAILED_PATH"

  ditto "$BUILT_APP_PATH" "$INSTALL_STAGE_PATH"
  if ! verify_staged_app "$INSTALL_STAGE_PATH"; then
    remove_install_sibling "$INSTALL_STAGE_PATH" || true
    return 1
  fi

  if ! terminate_running_app; then
    remove_install_sibling "$INSTALL_STAGE_PATH" || true
    return 1
  fi

  if [[ -e "$INSTALLED_APP_PATH" ]]; then
    if [[ -L "$INSTALLED_APP_PATH" || ! -d "$INSTALLED_APP_PATH" ]]; then
      echo "Refusing to replace a non-directory or symlinked installed app: $INSTALLED_APP_PATH" >&2
      remove_install_sibling "$INSTALL_STAGE_PATH" || true
      return 1
    fi
    mv "$INSTALLED_APP_PATH" "$INSTALL_BACKUP_PATH"
    had_backup=1
  fi

  if ! mv "$INSTALL_STAGE_PATH" "$INSTALLED_APP_PATH"; then
    restore_previous_install "$had_backup"
    return 1
  fi

  if ! verify_staged_app "$INSTALLED_APP_PATH"; then
    restore_previous_install "$had_backup"
    return 1
  fi

  if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
    if ! open "$INSTALLED_APP_PATH"; then
      restore_previous_install "$had_backup"
      return 1
    fi
    if [[ "$VERIFY_OPEN_AFTER_INSTALL" == "1" ]] && ! verify_installed_app_is_running; then
      restore_previous_install "$had_backup"
      return 1
    fi
  fi

  remove_install_sibling "$INSTALL_BACKUP_PATH"
}

wait_for_process_name_to_exit() {
  local process_name="$1"
  local attempt

  for ((attempt = 0; attempt < PROCESS_WAIT_ATTEMPTS; attempt += 1)); do
    if ! pgrep -x "$process_name" >/dev/null 2>&1; then
      return 0
    fi

    sleep "$PROCESS_WAIT_INTERVAL"
  done

  return 1
}

terminate_running_app() {
  local process_name

  echo "Stopping any running Codex Status Bar app..."
  for process_name in "$APP_PROCESS_NAME" "$LEGACY_PROCESS_NAME"; do
    pkill -x "$process_name" >/dev/null 2>&1 || true
  done

  for process_name in "$APP_PROCESS_NAME" "$LEGACY_PROCESS_NAME"; do
    if wait_for_process_name_to_exit "$process_name"; then
      continue
    fi

    echo "Process '$process_name' did not exit after TERM; force quitting it..."
    pkill -9 -x "$process_name" >/dev/null 2>&1 || true
    if ! wait_for_process_name_to_exit "$process_name"; then
      echo "Could not stop the existing '$process_name' process."
      return 1
    fi
  done
}

process_command_for_pid() {
  local pid="$1"
  ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//'
}

running_installed_app_pid() {
  local command
  local pid

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(process_command_for_pid "$pid")"
    if [[ "$command" == "$INSTALLED_EXECUTABLE_PATH" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(pgrep -x "$APP_PROCESS_NAME" 2>/dev/null || true)

  return 1
}

print_running_app_processes() {
  local command
  local pid

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(process_command_for_pid "$pid")"
    echo "  pid $pid -> ${command:-unknown}"
  done < <(pgrep -x "$APP_PROCESS_NAME" 2>/dev/null || true)
}

verify_installed_app_is_running() {
  local attempt
  local pid

  for ((attempt = 0; attempt < PROCESS_WAIT_ATTEMPTS; attempt += 1)); do
    if pid="$(running_installed_app_pid)"; then
      echo
      echo "Verified relaunched app:"
      echo "  pid $pid -> $INSTALLED_EXECUTABLE_PATH"
      return 0
    fi

    sleep "$PROCESS_WAIT_INTERVAL"
  done

  echo "Installed app was copied, but the freshly installed app is not running from:"
  echo "  $INSTALLED_EXECUTABLE_PATH"
  echo "Running CodexStatusBar processes:"
  print_running_app_processes
  return 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer only supports macOS."
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required. Install Xcode and run 'xcode-select --switch /Applications/Xcode.app'."
  exit 1
fi

prepare_install_directory

if ! RESOLVED_CODEX_PATH="$(codex_resolve_executable)"; then
  echo "Codex was not found. Install Codex before using Codex Status Bar."
  exit 1
fi

echo "Using Codex executable: $RESOLVED_CODEX_PATH"

if [[ "$DERIVED_DATA_IS_MANAGED" == "1" ]]; then
  safe_prepare_owned_directory "$DERIVED_DATA_PATH" "$SCRIPT_DIR/.build" "$BUILD_SENTINEL"
fi

echo "Building Codex Status Bar..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "platform=macOS,arch=$BUILD_ARCH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  echo "Build succeeded, but the app bundle was not found at:"
  echo "  $BUILT_APP_PATH"
  exit 1
fi

if [[ ! -x "$BUILT_EXECUTABLE_PATH" ]]; then
  echo "Build succeeded, but the app executable was not found at:"
  echo "  $BUILT_EXECUTABLE_PATH"
  exit 1
fi

"$SCRIPT_DIR/scripts/finalize_app_bundle.sh" \
  --app "$BUILT_APP_PATH" \
  --provenance source-checkout \
  --source-root "$SCRIPT_DIR" \
  --installed-path "$INSTALLED_APP_PATH"

if ! install_transactionally; then
  echo "Install failed; the previous app was restored when one existed." >&2
  exit 1
fi

cleanup_build_output

echo
echo "Installed to:"
echo "  $INSTALLED_APP_PATH"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  echo
  echo "The app should now appear in your menu bar."
fi
