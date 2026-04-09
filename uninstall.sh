#!/usr/bin/env bash

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP_PATH="$INSTALL_DIR/CodexStatusBar.app"

pkill -x "CodexStatusBar" >/dev/null 2>&1 || true
pkill -x "CodexUsageMenuBar" >/dev/null 2>&1 || true

if [[ -d "$INSTALLED_APP_PATH" ]]; then
  rm -rf "$INSTALLED_APP_PATH"
  echo "Removed $INSTALLED_APP_PATH"
else
  echo "Codex Status Bar is not installed in $INSTALL_DIR."
fi
