#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/CodexUsageMenuBar.xcodeproj"
SCHEME_NAME="CodexUsageMenuBar"
DEFAULT_DERIVED_DATA_PATH="$SCRIPT_DIR/.build/DerivedData"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DEFAULT_DERIVED_DATA_PATH}"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/CodexStatusBar.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP_PATH="$INSTALL_DIR/CodexStatusBar.app"
APP_PROCESS_NAME="CodexStatusBar"
LEGACY_PROCESS_NAME="CodexUsageMenuBar"
BUILT_EXECUTABLE_PATH="$BUILT_APP_PATH/Contents/MacOS/$APP_PROCESS_NAME"
INSTALLED_EXECUTABLE_PATH="$INSTALLED_APP_PATH/Contents/MacOS/$APP_PROCESS_NAME"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-1}"
VERIFY_OPEN_AFTER_INSTALL="${VERIFY_OPEN_AFTER_INSTALL:-1}"
CLEAN_AFTER_INSTALL="${CLEAN_AFTER_INSTALL:-1}"
PROCESS_WAIT_ATTEMPTS="${PROCESS_WAIT_ATTEMPTS:-50}"
PROCESS_WAIT_INTERVAL="${PROCESS_WAIT_INTERVAL:-0.2}"

resolve_codex_path() {
  local candidate

  for candidate in \
    /Applications/Codex.app/Contents/Resources/codex \
    /opt/homebrew/bin/codex \
    /usr/local/bin/codex
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  while IFS= read -r bundle; do
    candidate="$bundle/Contents/Resources/codex"
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find /Applications -maxdepth 1 -type d -name 'Codex*.app' | sort)

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  return 1
}

cleanup_build_output() {
  if [[ "$CLEAN_AFTER_INSTALL" != "1" ]]; then
    return
  fi

  if [[ "$DERIVED_DATA_PATH" != "$DEFAULT_DERIVED_DATA_PATH" ]]; then
    echo
    echo "Skipping build cache cleanup because DERIVED_DATA_PATH was customized:"
    echo "  $DERIVED_DATA_PATH"
    echo "Remove that directory manually when you no longer need it."
    return
  fi

  rm -rf "$DERIVED_DATA_PATH"
  rmdir "$SCRIPT_DIR/.build" >/dev/null 2>&1 || true

  echo
  echo "Cleaned build cache:"
  echo "  $DERIVED_DATA_PATH"
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
      exit 1
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
  exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer only supports macOS."
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required. Install Xcode and run 'xcode-select --switch /Applications/Xcode.app'."
  exit 1
fi

if ! resolve_codex_path >/dev/null; then
  echo "Codex was not found. Install Codex before using Codex Status Bar."
  exit 1
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

mkdir -p "$INSTALL_DIR"

terminate_running_app

rm -rf "$INSTALLED_APP_PATH"
ditto "$BUILT_APP_PATH" "$INSTALLED_APP_PATH"

if [[ ! -x "$INSTALLED_EXECUTABLE_PATH" ]]; then
  echo "Install failed because the copied app executable was not found at:"
  echo "  $INSTALLED_EXECUTABLE_PATH"
  exit 1
fi

if ! cmp -s "$BUILT_EXECUTABLE_PATH" "$INSTALLED_EXECUTABLE_PATH"; then
  echo "Install failed because the installed executable does not match the just-built executable."
  exit 1
fi

cleanup_build_output

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  open "$INSTALLED_APP_PATH"
  if [[ "$VERIFY_OPEN_AFTER_INSTALL" == "1" ]]; then
    verify_installed_app_is_running
  fi
fi

echo
echo "Installed to:"
echo "  $INSTALLED_APP_PATH"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  echo
  echo "The app should now appear in your menu bar."
fi
