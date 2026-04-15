# Codex Status Bar

Small macOS menu bar app that shows the selected Codex usage percentage in the status bar and the 5-hour and 7-day limits in a click popover.

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

## Compatibility

This app depends on private and experimental Codex interfaces:

- local Codex app-server methods and notifications
- the ChatGPT backend usage endpoint used for current limit parity

That keeps the app simple, but a future Codex update can break compatibility until this repo is updated.

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
- The menu bar label can show `5h`, `7d`, or `Tightest`.
- The popover shows `5h`, `7d`, and `Tightest`, along with reset times and freshness state.
- The popover also includes a `Launch at login` toggle.
- Right click includes quick actions for refresh, opening Codex, and quit.
- Left click opens the popover. Clicking outside closes it.
