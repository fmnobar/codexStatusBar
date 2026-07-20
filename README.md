# Codex Status Bar

Small macOS menu bar app that shows the selected Codex usage percentage in the status bar, the 5-hour and 7-day limits in a click popover, and lightweight local usage history over time. Detailed local analytics are an explicit opt-in.

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

- Lightweight collection is the default. It keeps rate limits, reset information, account-token status, current-day local token totals, and a seven-day daily token trend current. **Detailed Analytics** in **Settings > Data** opts into model, project, session, thread, and performance breakdowns.
- Operational history, optional detailed telemetry, source-health snapshots, and app-server diagnostics are stored locally under `~/Library/Application Support/CodexStatusBar`. Historical token archives are separate read-only SQLite files created only at a location the user selects.
- Capture is metadata-only: the app excludes prompts, messages, summaries, tool payloads, credentials, account identifiers, and arbitrary raw protocol payloads.
- Retention is fixed: rate-limit raw samples are kept for 7 days; detailed token and performance samples for 72 hours; hourly summaries for 90 days; and daily summaries for 365 days. The operational store targets 100 MiB in Lightweight mode and 250 MiB in Detailed Analytics, with hard maximums of 250 MiB and 500 MiB respectively.
- **Clear Analytics Data** removes optional dimensions and detailed telemetry while preserving rate-limit History, lightweight token totals, preferences, status state, backups, and archives. A full operational reset still uses the uninstall instructions above.
- Operational backups use SQLite-consistent copies and can restore v2 or v3 data through an offline, retained, budgeted, validated candidate. Historical archives are a distinct format and cannot be restored into live collection. Backups, archives, and dashboard CSV exports can include approved project paths or aliases and should be reviewed before sharing.
- Contributors can run `python3 scripts/measure_storage_fixture.py` for the frozen synthetic 10,000-turn normalization gate. It measures post-checkpoint v2/v3 dimension and total physical bytes without reading the live application database.
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
- The menu bar label can show `5h`, `7d`, or `Tightest`.
- The popover shows `5h`, `7d`, and `Tightest`, along with reset times, freshness state, and app version.
- The History window charts locally sampled usage by rolling day, week, month, and year ranges. It can be opened directly from the popover or expanded inline.
- History can include per-model series when Codex exposes model-specific rate-limit buckets.
- Settings leads with the Lightweight/Detailed Analytics choice, operational storage and maintenance status, fixed retention, backups, historical archives, and optional advanced diagnostics. Install/update visibility, live release checks, guided update installs, and release notes remain available.
- The popover includes always-visible routes to full History and Settings, inline controls, and a `Launch at login` toggle.
- Right click intentionally contains only Quit; primary actions remain in the left-click popover.
- Left click opens the popover. Clicking outside closes it.
