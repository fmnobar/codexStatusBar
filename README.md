# Codex Status Bar

Small macOS menu bar app that shows the selected Codex usage percentage in the status bar, the 5-hour and 7-day limits in a click popover, and local usage history over time.

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
- The popover shows `5h`, `7d`, and `Tightest`, along with reset times, freshness state, and app version.
- The History window charts locally sampled usage by rolling day, week, month, and year ranges.
- History can include per-model series when Codex exposes model-specific rate-limit buckets.
- Settings includes local history data management plus install/update visibility and release notes.
- The popover also includes `Settings` and a `Launch at login` toggle.
- Right click includes quick actions for refresh, history, settings, opening Codex, and quit.
- Left click opens the popover. Clicking outside closes it.
