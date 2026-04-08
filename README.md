# Codex Status Bar

Small macOS menu bar app that shows the remaining Codex 7-day usage percentage in the status bar and the 5-hour and 7-day limits in a click popover.

## Install

- macOS 14+
- Xcode 17+
- Codex installed locally

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

## Development

The repo includes a checked-in Xcode project, so end users do not need `xcodegen`.

If you change `project.yml`, regenerate the project with:

```bash
xcodegen generate
```

## Notes

- The app launches or reuses a local `codex app-server`.
- The menu bar label shows the 7-day remaining percent.
- The popover shows the 5-hour and 7-day remaining limits and reset times.
