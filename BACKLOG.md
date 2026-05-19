# Backlog

## Remaining Work

| Priority | Item | Scope |
| --- | --- | --- |
| 1 | Make live token payload audit capture observable | A real Codex CLI token-generating probe completed while the installed app was running, but no `live-token-payload-audit.json` was written; add diagnostics that show whether the app-server connection receives token notifications, whether audit sanitization runs, and why no bounded sample is persisted. |
| 2 | Review live token payload audit sample | After a live token notification is captured in Settings Data, review/export the sanitized sample and decide whether to record live context fields directly or join live events with safe turn context. |

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

- Pre-aggregate token History data in SQLite
  - Return period-bucketed token component totals directly from store queries for compact History.
  - Keep the model-level breakdown in the Token Dashboard while reducing the inline History row count.

- Move history database work off the main actor
  - Added an async serial database worker around the synchronous SQLite store.
  - Moved app-facing History, Token Dashboard, Data settings, recording, and token-total calls through the worker.
  - Added stale-result handling for async History and Token Dashboard reloads.

- Add targeted SQLite indexes and bounded series queries
  - Added targeted indexes for rate-limit and token history hot paths.
  - Added derived series catalogs for rate-limit and token model availability.
  - Moved available-series discovery to catalog reads while keeping chart data semantics unchanged.

- Clean malformed token model labels
  - Added a one-time cleanup pass for stored token model values with newlines, unsafe characters, or unrelated path/log text.
  - Hardened live token notifications, session imports, duplicate repairs, backup imports, and catalog writes through the shared model normalizer.
  - Rebuilt token series catalogs after cleanup so malformed duplicate model labels collapse without changing token totals.

- Split History store, History view, and store tests by responsibility
  - Split the oversized SQLite History store into focused setup, recording, migration, query, import metadata, data-management, and SQLite-support files.
  - Split the History UI into focused view, view-model, hover/indexing, and control-support files while preserving the same visible behavior.
  - Split the monolithic History test file into store usage, token storage, migrations, import/export/settings, view-model, window, and shared-support test files.

- Add performance regression coverage for History and token charts
  - Added a realistic file-backed SQLite fixture for usage and token history hot paths.
  - Added query-plan regression checks for bounded History, token History, Token Dashboard, and catalog series queries.
  - Added conservative reload and hover timing guards for History snapshots, Token Dashboard snapshots, and hover lookup.

- Add lightweight update notifications
  - Added shared app-session GitHub Release update checks outside the Settings window.
  - Added a non-blocking popover prompt for available updates with Updates and Later actions.
  - Reused the existing Updates settings download/install flow while keeping right-click menu behavior unchanged.

- Capture token context dimensions for project and effort
  - Added nullable token context fields for session id, project path/name, reasoning effort, and source.
  - Extended session/log backfill to read safe metadata from `session_meta` and `turn_context` without decoding prompt, message, or tool content.
  - Added re-import repair for missing context/model metadata plus project, effort, and source catalogs for future dashboard breakdowns.

- Add Token Dashboard breakdowns by model, effort, and project
  - Added a Token Dashboard breakdown selector for Model, Effort, and Project while keeping Model as the default.
  - Reused stored model, effort, and project catalogs so available breakdown rows stay stable without scanning raw token history.
  - Kept the stacked category chart style unchanged while filtering summaries, chart rows, table rows, and CSV export to the selected breakdown rows.

- Add editable project names for token analytics
  - Added local project aliases stored on the token project catalog while keeping project paths as the stable identifier.
  - Added project rename and reset controls in Data settings.
  - Updated Token Dashboard project breakdowns and CSV export to use aliases while preserving full project paths for audit/debugging.

- Track additional safe token slices as Codex exposes them
  - Added generic token dimension and dimension-catalog tables so future explicit metadata can be stored without schema churn.
  - Captured allowlisted session/app, runtime policy, subagent, and explicit usage-mode metadata from live notifications, session JSONL, and Codex logs.
  - Kept prompt, message, summary, instruction, tool, auth, and arbitrary unknown fields out of storage, with no `/fast` inference.

- Expose additional token slices in Token Dashboard
  - Added dashboard grouping, filtering, and CSV export for captured originator, source, runtime policy, subagent, memory, provider, and explicit usage-mode dimensions.
  - Kept Token Dashboard defaulted to Model while exposing the added dimensions through a scalable breakdown selector.
  - Preserved compact History, menu-bar tokens, and existing model/effort/project dashboard behavior.

- Backfill recent token context dimensions from Codex sessions
  - Bumped the session context import version so unchanged recent active session files imported under older context versions are re-read once.
  - Hardened session/live metadata decoding for current object-shaped permission profile and truncation policy fields while preserving string payload compatibility.
  - Repaired token context and safe dimension catalogs through the existing deterministic import keys without changing observed token totals.

- Stop showing low-signal importer provenance as token breakdowns
  - Treated `source_kind=codex-log` versus `Unattributed` as ingestion provenance rather than a useful user-facing slice.
  - Made generic token dashboard dimensions period-aware so empty or attribution-only slices do not appear for the selected period.
  - Hid `source_kind=codex-log` from user-facing breakdown rows while keeping it stored for diagnostics and importer repair.
  - Kept genuinely useful explicit source values, such as `vscode`, `cli`, or future app-provided sources, when they are actually present.

- Fix Codex log context extraction and backfill safe metadata
  - Added a safe log metadata extractor for exact span values, including dotted trace keys for `cwd`, model, reasoning effort, source, and runtime-policy fields.
  - Repaired log-derived token rows through the existing duplicate/model/context/dimension repair path without changing observed token totals.
  - Preserved importer provenance while preventing adjacent trace or request text from becoming visible metadata.

- Add token attribution coverage diagnostics
  - Added Token Dashboard diagnostics showing attributed, missing, percent, and distinct-value counts by token volume for model, project, effort, source, and meaningful safe dimensions.
  - Kept diagnostics read-only while preserving existing token totals, chart semantics, dashboard filtering, and menu-bar text.
  - Added coverage rows to Token Dashboard CSV export so missing metadata can be inspected outside the app.

- Audit live token notification context payloads
  - Added a sanitized audit path for live `thread/tokenUsage/updated` payload context fields.
  - Persisted the latest bounded audit sample under Application Support without changing token totals or token storage semantics.
  - Added Data settings status, export, and clear controls for the live payload audit.
  - Kept prompt, message, tool, auth, and arbitrary unknown values out of persisted diagnostics.

## Next Candidates

- Review live token payload audit sample
  - Use the new Data settings readout/export after a live token event arrives.
  - If useful fields are present, plan `Record live token context fields directly`.
  - If useful fields are absent, plan `Join live token events with latest safe turn context`.
