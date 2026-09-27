# Codex Status Bar

Small macOS menu bar app that shows Codex seven-day usage as a circular indicator in the status bar, with optional percentage and reset information and available usage resets in a click popover.

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

The uninstall script removes the installed app but intentionally preserves the operational history database and preferences. User-selected historical archives live outside the app's data directory and must be removed separately. For a complete operational-data reset after uninstalling:

```bash
rm -rf "$HOME/Library/Application Support/CodexStatusBar"
defaults delete com.farzad.codexstatusbar 2>/dev/null || true
```

## Privacy and local data

- The app displays current limits and reset information. It no longer collects usage history, daily token totals, model/project breakdowns, or performance analytics, and does not open an analytics database at startup.
- Preferences and the small usage-reset cache remain local. Previously stored databases, backups, and user-created archives are preserved without being opened or migrated.
- Retired analytics source and tests are excluded from the pushed source tree and build targets; the original cleanup retained a verified local recovery copy.
- The app talks to the local Codex app-server, the Codex account-usage service for current limits, and GitHub Releases for update checks. It does not operate a separate analytics service.

## Development verification

Run the canonical local gate before submitting a change:

```bash
scripts/verify.sh
```

The gate checks scripts and project structure, builds and analyzes the app, and runs the complete test suite. Release publication remains a separate, explicitly enabled workflow.

## License

Codex Status Bar is available under the [MIT License](LICENSE).

## Notes

- The app launches and owns its local `codex app-server` transport. It never attaches to a pre-existing loopback listener.
- When seven-day usage is available, the menu bar shows a circular remaining-usage indicator. The percentage, reset date, and reset time are independent display options; the percentage is on by default. When the percentage is hidden, hovering over the circle shows the current percentage.
- The compact popover has a read-only seven-day summary, available usage resets, freshness state, and app version.
- Settings has General and Updates tabs. General includes reset date/time display and launch at login. Updates retains live release checks and guided update installs.
- The popover always shows Remaining %, Reset date, and Reset time controls, a menu-bar preview, and `Launch at login`. Available resets appear directly beside an icon-only refresh button that rotates while refreshing.
- Right click intentionally contains only Quit; primary actions remain in the left-click popover.
- Left click opens the popover. Clicking outside closes it.
