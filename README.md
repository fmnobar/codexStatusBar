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
By default it deletes its temporary `.build/DerivedData` output after a successful install. During development, keep build output with:

```bash
CLEAN_AFTER_INSTALL=0 ./install.sh
```

## Compatibility

This app depends on private and experimental Codex interfaces:

- local Codex app-server methods and notifications
- the ChatGPT backend usage endpoint used for current limit parity

That keeps the app simple, but a future Codex update can break compatibility until this repo is updated.

## Update

The Updates settings tab can check GitHub Releases for the latest published version. When a signed release zip is available, the app can download, verify, install, and relaunch from Settings.

Manual source installs still work:

```bash
git pull
./install.sh
```

Release maintainers should follow [RELEASING.md](RELEASING.md) to publish signed and notarized GitHub Release assets with the local release scripts. The GitHub Actions release workflow is currently disabled.

## Uninstall

Turn off **Launch at login** in the popover first, then run:

```bash
./uninstall.sh
```

The uninstall script removes the installed app but intentionally preserves local history and preferences. For a complete data reset after uninstalling:

```bash
rm -rf "$HOME/Library/Application Support/CodexStatusBar"
defaults delete com.farzad.codexstatusbar 2>/dev/null || true
```

## Privacy and local data

- Usage history, performance telemetry, source-health snapshots, and app-server diagnostics are stored locally under `~/Library/Application Support/CodexStatusBar`.
- Capture is metadata-only: the app excludes prompts, messages, summaries, tool payloads, credentials, account identifiers, and arbitrary raw protocol payloads.
- Raw-history retention can be set to 7, 14, 30, or 90 days in **Settings > Data**; the default is 14 days. Local history can also be cleared there. Backups and dashboard CSV exports can include project paths or aliases and should be reviewed before sharing.
- The app talks to the local Codex app-server, the Codex account-usage service for current limits, and GitHub Releases for update checks. It does not operate a separate analytics service.

## Development verification

Run the canonical local gate before submitting a change:

```bash
scripts/verify.sh
```

The gate checks scripts and project structure, builds and analyzes the app, and runs the complete test suite. Release publication remains a separate, explicitly enabled workflow.

## Notes

- The app launches and owns its local `codex app-server` transport. It never attaches to a pre-existing loopback listener.
- The menu bar label can show `5h`, `7d`, or `Tightest`.
- The popover shows `5h`, `7d`, and `Tightest`, along with reset times, freshness state, and app version.
- The History window charts locally sampled usage by rolling day, week, month, and year ranges. It can be opened directly from the popover or expanded inline.
- History can include per-model series when Codex exposes model-specific rate-limit buckets.
- Settings includes local history data management plus install/update visibility, live release checks, guided update installs, and release notes.
- The popover includes always-visible routes to full History and Settings, inline controls, and a `Launch at login` toggle.
- Right click intentionally contains only Quit; primary actions remain in the left-click popover.
- Left click opens the popover. Clicking outside closes it.
