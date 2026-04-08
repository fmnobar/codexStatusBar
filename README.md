# Codex Status Bar

Small macOS menu bar app that shows the remaining Codex 7-day usage percentage in the status bar and the 5-hour and 7-day limits in a click popover.

## Install

- macOS 14+
- Xcode 17+
- Codex installed locally
- No third-party package manager or extra build tool required

```bash
git clone https://github.com/fmnobar/codexStatusBar.git
cd codexStatusBar
./install.sh
```

The installer builds the app locally, installs it to `~/Applications/CodexStatusBar.app`, and launches it.

## Update

```bash
git pull
./install.sh
```

## Uninstall

```bash
./uninstall.sh
```

## Notes

- The app launches or reuses a local `codex app-server`.
- The menu bar label shows the selected 5-hour or 7-day remaining percent.
- The popover shows the 5-hour and 7-day remaining limits and reset times.
- Left click opens the popover. Right click shows `Quit`.
