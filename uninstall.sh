#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/safe_paths.sh"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP_PATH="$INSTALL_DIR/CodexStatusBar.app"
INSTALLED_EXECUTABLE_PATH="$INSTALLED_APP_PATH/Contents/MacOS/CodexStatusBar"
PROCESS_WAIT_ATTEMPTS="${PROCESS_WAIT_ATTEMPTS:-50}"
PROCESS_WAIT_INTERVAL="${PROCESS_WAIT_INTERVAL:-0.2}"

if [[ -L "$INSTALL_DIR" || ( -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ) ]]; then
  echo "Refusing a symlinked or non-directory install root: $INSTALL_DIR" >&2
  exit 1
fi

process_command_for_pid() {
  ps -p "$1" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//'
}

target_process_identifiers() {
  local command
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(process_command_for_pid "$pid")"
    if [[ "$command" == "$INSTALLED_EXECUTABLE_PATH" ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -x CodexStatusBar 2>/dev/null || true)
}

terminate_validated_target() {
  local attempt
  local pid
  local -a process_identifiers=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && process_identifiers+=("$pid")
  done < <(target_process_identifiers)

  (( ${#process_identifiers[@]} > 0 )) || return 0
  kill -TERM "${process_identifiers[@]}" >/dev/null 2>&1 || true
  for ((attempt = 0; attempt < PROCESS_WAIT_ATTEMPTS; attempt += 1)); do
    if ! target_process_identifiers | grep -q .; then
      return 0
    fi
    sleep "$PROCESS_WAIT_INTERVAL"
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -KILL "$pid" >/dev/null 2>&1 || true
  done < <(target_process_identifiers)
  for ((attempt = 0; attempt < PROCESS_WAIT_ATTEMPTS; attempt += 1)); do
    if ! target_process_identifiers | grep -q .; then
      return 0
    fi
    sleep "$PROCESS_WAIT_INTERVAL"
  done
  echo "Could not stop the validated installed app executable: $INSTALLED_EXECUTABLE_PATH" >&2
  return 1
}

if [[ -d "$INSTALLED_APP_PATH" ]]; then
  if [[ -L "$INSTALLED_APP_PATH" ]]; then
    echo "Refusing to recursively remove a symlinked app path: $INSTALLED_APP_PATH" >&2
    exit 1
  fi

  INFO_PLIST="$INSTALLED_APP_PATH/Contents/Info.plist"
  BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
  if [[ "$BUNDLE_IDENTIFIER" != "com.farzad.codexstatusbar" ]]; then
    echo "Refusing to remove an app with unexpected bundle identifier '$BUNDLE_IDENTIFIER'." >&2
    exit 1
  fi

  [[ -x "$INSTALLED_EXECUTABLE_PATH" ]] || {
    echo "Refusing to remove an app without the expected executable: $INSTALLED_EXECUTABLE_PATH" >&2
    exit 1
  }

  terminate_validated_target

  safe_remove_managed_child "$INSTALLED_APP_PATH" "$INSTALL_DIR" 'CodexStatusBar.app'
  echo "Removed $INSTALLED_APP_PATH"
else
  echo "Codex Status Bar is not installed in $INSTALL_DIR."
fi
