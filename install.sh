#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/CodexUsageMenuBar.xcodeproj"
SCHEME_NAME="CodexUsageMenuBar"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$SCRIPT_DIR/.build/DerivedData}"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/CodexStatusBar.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP_PATH="$INSTALL_DIR/CodexStatusBar.app"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-1}"

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

mkdir -p "$INSTALL_DIR"

pkill -x "CodexStatusBar" >/dev/null 2>&1 || true
pkill -x "CodexUsageMenuBar" >/dev/null 2>&1 || true

rm -rf "$INSTALLED_APP_PATH"
ditto "$BUILT_APP_PATH" "$INSTALLED_APP_PATH"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  open "$INSTALLED_APP_PATH"
fi

echo
echo "Installed to:"
echo "  $INSTALLED_APP_PATH"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  echo
  echo "The app should now appear in your menu bar."
fi
