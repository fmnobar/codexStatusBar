# Backlog

## Done

- Usage history by time and model
  - Added local SQLite history recording for sampled usage percentages.
  - Added rolling day, week, month, and year chart views.
  - Added aggregate and per-model series when model buckets are available.
  - Added CSV export and clear-history controls.

- Validate model bucket behavior against live Codex data
  - Added hidden Option-context-menu diagnostics export.
  - Added sanitized app-server bucket JSON with aggregate/model comparison summaries.
  - Added classification for comparable, independent, and inconclusive bucket shapes.

- Review exported diagnostics and decide History chart semantics
  - Added multi-capture diagnostics review for comparable, independent, and inconclusive evidence.
  - Kept the History chart in neutral independent-signal mode until real captures prove contributor semantics.
  - Added internal contributor rendering support for evidence-backed comparable buckets.

- Improve History chart polish and interaction
  - Added nearest-timestamp hover inspection with per-bucket usage details.
  - Replaced the horizontal series toggle strip with a searchable model selector.
  - Added specific empty states for no history, no selected-range data, and hidden series.

- Add data-management preferences
  - Added a native Data settings pane for history database location, size, reveal, backup, restore, and clear actions.
  - Added raw-sample retention presets while keeping hourly and daily rollups indefinitely.
  - Added SQLite backup export/import with validation and history-change notifications.

- Add install/update visibility
  - Added local version/build visibility in the popover.
  - Added an Updates settings tab with app metadata, install/update commands, project link, and release notes.

- Add live update checking
  - Added GitHub latest-release checks without changing the manual install flow.
  - Added up-to-date, update-available, no-release, inconclusive, checking, and failure states to the Updates settings tab.

- Add release packaging and versioning workflow
  - Added local scripts to set semantic app versions, validate releases, and package unsigned zip assets.
  - Added release instructions for tags, GitHub Releases, and manual artifact validation.

- Add signed/notarized distribution
  - Added optional Developer ID signing and notarization to local release packaging.
  - Kept unsigned local packaging available while documenting the recommended signed public release path.

- Make History charts easier to read
  - Replaced sampled line charts with bucketed bar charts for hourly, daily, and monthly views.
  - Added a default Capacity left metric with a Usage toggle for peak consumption.
  - Added peak rollups, bucket hover details, and chart-shaped CSV export.

- Add calendar-period History navigation and axis labels
  - Changed History charts from rolling ranges to explicit local day, week, month, and year periods.
  - Added bounded previous/next period navigation for both inline and full History charts.
  - Simplified x-axis labels to hours, weekdays, day numbers, and month names by selected range.

- Add GitHub Actions release automation
  - Added a manual release workflow for signed, notarized GitHub Release assets.
  - Kept local release scripts as the source of truth while adding CI keychain and notary support.
  - Documented required repository secrets and protected-branch behavior.

- Add in-app update download/install flow
  - Added release asset decoding for signed GitHub Release zip downloads.
  - Added download staging, checksum/trust verification, and guided no-admin app replacement.
  - Added Settings UI states for downloading, verifying, ready-to-install, install fallback, and errors.

- Add History chart period polish
  - Added a compact jump-to-current control and clearer disabled navigation hints.
  - Added period-aware CSV filenames while keeping the current calendar-period model and local-only storage behavior.

- Add token usage telemetry capture
  - Added app-server `thread/tokenUsage/updated` notification decoding.
  - Persisted live token telemetry with input, cached input, output, reasoning output, total, last-turn, cumulative, context-window, thread, turn, timestamp, and nullable model fields.
  - Added deduped observed-token deltas so repeated streaming updates do not inflate daily totals.

- Add menu-bar token display option
  - Added a persisted `Tokens` menu-bar display option, default off.
  - Appends today's captured token total to the existing capacity text when enabled.
  - Shows `-- tok` when selected before token telemetry has been captured.

- Add token history charts
  - Added token-volume History charts for the existing day, week, month, and year periods.
  - Added total, input, cached input, output, and reasoning token categories with local SQLite queries and CSV export.
  - Kept token volume separate from rate-limit capacity and usage charts.

- Backfill token history from local Codex sessions
  - Added an opt-in Data settings import for local Codex session token metadata.
  - Imported only token-count metadata from `~/.codex/sessions` and `~/.codex/archived_sessions`.
  - Kept the importer idempotent so repeated imports do not inflate token history.

- Align menu-bar context menu and history model controls with intended UX
  - Restricted the right-click status menu to `Quit` only.
  - Kept primary controls in the left-click popover.
  - Made History model selectors use all locally tracked series for the selected limit or token category.
  - Kept Spark visible but unchecked by default.

- Show menu-bar tokens as compact category parts
  - Replaced the single total-token suffix with a compact input, cache, output, and reasoning breakdown.
  - Kept the same menu-bar tone and spacing as the current capacity/token text, with a readable fallback when category data is unavailable.
  - Avoided turning the menu bar into a dashboard by keeping category labels concise.

- Capture token model attribution from all available sources
  - Added generic model-name normalization without hardcoding current model names.
  - Added live token notification decoding for optional model identifiers when app-server payloads provide them.
  - Added session-token backfill attribution from safe `turn_context` and token-count metadata.
  - Let repeated metadata imports repair previously model-less token rows without inflating totals.

- Make Codex session token backfill incremental and bounded
  - Made Data settings default to a bounded recent session import before offering all-history import.
  - Added local session-file metadata so unchanged JSONL files are skipped on repeat imports.
  - Streamed JSONL parsing line by line while preserving metadata-only token/model attribution.
  - Reported discovered, scanned, skipped, imported, duplicate, repaired, failed-line, and elapsed-time import counts.

- Add detailed token dashboard
  - Add a separate dashboard surface outside the compact menu popover for deeper token analysis.
  - Show totals and trends for all captured token categories, including input, cached input, output, reasoning output, and total tokens.
  - Reuse existing token history storage, calendar-period navigation, model series, and export behavior where practical.

- Polish detailed token dashboard readability
  - Removed redundant labels from the dashboard chrome, chart, table, export button, and token values.
  - Improved compact number formatting with billions, separators, and unit-free dashboard values.
  - Gave the model breakdown enough room for full category and model labels when the dashboard opens.

- Add installed-app freshness checks and stale-build notification
  - Added an install-time build fingerprint with source root, branch, commit, dirty state, build time, installed bundle path, and executable hash.
  - Added local freshness checks for newer source checkouts and newer installed bundles than the running process.
  - Added a compact stale-build warning in the popover plus Local Build status and relaunch/install guidance in Updates settings.

- Optimize History hover selection
  - Cache visible bucketed chart data during reload instead of rebuilding computed arrays during high-frequency pointer movement.
  - Pre-index hover data by bucket start so nearest-bucket lookup and detail rendering do not block the main thread.

## Next Candidates

- Pre-aggregate token History data in SQLite
  - Return period-bucketed token component totals directly from store queries for compact History.
  - Keep the model-level breakdown in the Token Dashboard while reducing the inline History row count.

- Move history database work off the main actor
  - Put `UsageHistoryStore` calls behind a database actor or serial worker queue.
  - Publish immutable view snapshots back to SwiftUI after SQLite reads, writes, and imports complete.

- Add targeted SQLite indexes and bounded series queries
  - Add indexes or summary tables for token component availability and period-scoped dashboard/history queries.
  - Avoid full-table scans for model/series lists once token history grows.

- Clean malformed token model labels
  - Add a one-time normalization pass for stored token model values with newlines or unrelated text.
  - Harden log/session import parsing so malformed model strings cannot become visible series.

- Split History store, History view, and store tests by responsibility
  - Split migrations, write paths, read queries, import/export, and dashboard queries into focused files.
  - Split large History UI and store test files so future feature work has smaller blast radius.

- Add performance regression coverage for History and token charts
  - Add measured tests or fixtures for History reload, token dashboard reload, and hover selection with realistic sample counts.
  - Add query-plan expectations for the SQLite hot paths.

- Add lightweight update notifications
  - Optionally check for updates during normal sessions and surface a visible popover/settings prompt.
  - Keep downloads and installs user-initiated.
