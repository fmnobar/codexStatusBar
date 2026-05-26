# Backlog

## Delivery Rule

- After every app or source update, run `./install.sh` and verify the installed app is relaunched from `/Users/farzadmahmoodinobar/Applications/CodexStatusBar.app` before calling the work complete.

## Remaining Work

| Priority | Item | Why | Planning |
| --- | --- | --- | --- |
| 1 | Return pre-aggregated Performance Dashboard presentation rows | Performance Dashboard month pulls about 80k rows and year pulls about 105k rows, then rebuilds chart/table presentation in Swift. | Needs planning to preserve CSV, sorting, and selection semantics. |
| 2 | Add dashboard snapshot and presentation caching | Repeated dashboard mode/breakdown/period toggles should reuse stable results until capture/import data changes. | Needs planning around invalidation and stale-result behavior. |
| 3 | Add built-in dashboard/menu performance instrumentation | External UI automation could not reliably open the menu popover in this session, so the app should record open-to-first-render and toggle timings internally. | Ready to plan; best as diagnostics-only first. |
| 4 | Add indexed event timestamp for session task timing queries | Timing queries use `COALESCE(started_at, completed_at, recorded_at)` in `WHERE`/`ORDER BY`, which prevents simple index use and will age poorly. | Needs a migration/index plan. |

### Return Pre-Aggregated Performance Dashboard Presentation Rows

- Problem:
  - The store returns raw timing, reliability, and token samples, then `PerformanceDashboardViewModel` rebuilds charts and tables in Swift when mode or breakdown changes.
  - Breakdown toggles avoid SQLite reloads, but they can still do large main-actor presentation work.
- Implementation options:
  - Add read-only store queries that return bucketed chart points and table rows for the selected mode, period, and breakdown dimension.
  - Keep raw sample APIs only where tests or export paths still need them.
  - For Performance mode, return duration bucket rows and reliability bucket rows directly.
  - For Efficiency mode, return token-rate bucket rows and efficiency breakdown rows directly.
- Planning notes:
  - Needs a plan before implementation because it touches dashboard presentation contracts, row selection, sorting, and CSV export.
  - Be explicit about which aggregations happen in SQLite and which remain in Swift.
- Verification:
  - Add store/view-model parity tests against current raw-sample behavior.
  - Add tests for all breakdown dimensions: model, project, effort, source, transport, and wire API where applicable.
  - Run full verification and relaunch latest installed app with `./install.sh`.

### Add Dashboard Snapshot And Presentation Caching

- Problem:
  - Period changes should reload, but repeated toggles between recently viewed mode/breakdown combinations should not recompute the same data repeatedly.
- Implementation options:
  - Cache snapshots by period range and mode.
  - Cache presentation results by period, mode, breakdown dimension, sort state, and selected rows when practical.
  - Invalidate on history-change notifications, local token capture, OTEL capture, session timing capture, imports, clear-history, and project alias updates.
- Planning notes:
  - Needs a short plan because stale data would be worse than slow data.
  - Keep existing reload-generation cancellation behavior.
- Verification:
  - Add tests for cache hit/miss behavior and invalidation after data-change notifications.
  - Add tests that stale async results are still ignored.
  - Run full verification and relaunch latest installed app with `./install.sh`.

### Add Built-In Dashboard/Menu Performance Instrumentation

- Problem:
  - External Accessibility automation could query the menu-bar item, but automated clicks did not reliably open the popover in the current session.
  - The app should measure its own user-visible timings so future audits have first-render data instead of only query timings.
- Implementation notes:
  - Add lightweight internal timing around:
    - app launch to first real menu-bar title
    - menu popover open to first rendered content
    - History expand/reload
    - Token Dashboard open/reload
    - Performance Dashboard open/reload
    - Performance/Efficiency mode switches
    - dashboard breakdown and period changes
  - Store only local timing metrics, not payloads or sensitive data.
  - Surface a compact diagnostics readout in Settings Data or a diagnostics export.
- Verification:
  - Add tests for timing event recording and bounded retention.
  - Run full verification and relaunch latest installed app with `./install.sh`.

### Add Indexed Event Timestamp For Session Task Timing Queries

- Problem:
  - Session timing queries filter and sort on `COALESCE(started_at, completed_at, recorded_at)`, which currently scans `codex_session_task_timing_events`.
  - The table is small today, but this will degrade as task timing history grows.
- Implementation options:
  - Add a stored `event_timestamp` column populated during import and migration.
  - Add an index on `event_timestamp`.
  - Update timing queries and bounds queries to use that column directly.
- Planning notes:
  - Needs a migration plan and compatibility tests for existing databases with partial timing rows.
- Verification:
  - Add migration tests for rows with started, completed, and recorded-only timestamps.
  - Add query-plan tests proving the timing dashboard query uses the new timestamp index.
  - Run full verification and relaunch latest installed app with `./install.sh`.

## Conditional Watchlist

- Review live token payload audit sample
  - A bounded probe on May 19, 2026 generated local Codex token activity and was captured through the log-based token importer, but app-server diagnostics still showed `0` `thread/tokenUsage/updated` notifications and no `live-token-payload-audit.json`.
  - Keep this blocked until Settings Data or `~/Library/Application Support/CodexStatusBar/live-token-payload-audit.json` shows a real sanitized payload.
  - If a future sample appears with useful fields, plan `Record live token context fields directly`; otherwise keep local log/session capture as the evidence-backed live token source.

## Done

- Pre-aggregate Token Dashboard attribution coverage
  - Replaced repeated attribution coverage scans with one shared, period-bounded `period_samples` query for core and generic dimensions.
  - Preserved existing observed-token semantics, CSV coverage rows, sorting, and low-signal `source_kind=codex-log` handling.
  - Added correctness coverage for missing attribution, meaningful dimensions, duplicate dimension rows, and no-token periods.
  - Added query-plan and conservative timing regression checks for the consolidated coverage path.

- Split Performance Dashboard snapshots by selected mode
  - Made Performance Dashboard snapshots mode-aware so the default `Performance` view no longer loads Efficiency token samples or model capabilities.
  - Added lazy Efficiency loading when the user switches to `Efficiency`, while preserving cached Performance data for fast switching back.
  - Added mode-specific dashboard bounds so Performance navigation no longer scans token history just to open the default view.
  - Added worker and view-model tests for mode-specific payloads, lazy Efficiency loading, and cached mode switching.

- Polish Performance Dashboard layout and tables
  - Reworked the Performance Dashboard shell so header controls, summary tiles, charts, and tables stay visible at launch.
  - Gave Performance and Efficiency the same stable dashboard geometry while keeping Performance as the default.
  - Replaced free-expanding metric grids with fixed-column, internally scrollable tables so row labels and numeric columns remain readable.
  - Added bounded chart panel sizing to prevent chart clipping at the default window size.

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

- Capture safe OTEL turn performance telemetry
  - Added incremental metadata-only capture from `~/.codex/logs_2.sqlite` for safe OTEL/log/API targets.
  - Stored event name/kind, timestamp, duration, success/error summary, local thread/turn identifiers, model, effort, project, source, transport, wire API, API path, app version, terminal type, and originator where explicitly present.
  - Added SQLite event/cursor tables and Settings Data diagnostics without changing token totals, History charts, menu-bar text, or dashboard semantics.
  - Kept extraction allowlist-only and excluded `user.email`, `user.account_id`, prompt/message/tool payloads, raw request bodies, auth values, and arbitrary unknown fields.

- Capture session task timing metadata
  - Added recent active-session JSONL capture for safe `task_started` and `task_complete` metadata.
  - Stored session/turn ids, start and completion times, duration, time-to-first-token, model context window, collaboration mode kind, model, effort, project, source, and allowlisted dimensions.
  - Added SQLite timing event/import-state tables plus Settings Data diagnostics, backup/import, and clear-history support without changing token totals or dashboard semantics.
  - Kept parsing metadata-only and excluded message text, prompts, summaries, instructions, tool payloads, auth fields, and arbitrary unknown fields.

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

- Make live token payload audit capture observable
  - Added app-server capture diagnostics for connection state, inbound JSON-RPC method names, rate-limit and token notification counts, audit sanitization, audit persistence, and last errors.
  - Made audit persistence report success or failure without blocking token notification handling.
  - Surfaced the diagnostic state in Data settings with a separate clear action while keeping raw payload values out of diagnostics.

- Join live token events with latest safe turn context
  - Added app-owned local token capture from bounded Codex log events so token totals do not depend on cross-process app-server token notifications.
  - Added cursor/health state for local token capture and surfaced metadata-only diagnostics in Data settings.
  - Reused existing safe log/session context extraction and token import dedupe/repair paths so live capture can update token totals without inferring hidden modes or storing prompt/tool/auth content.

- Import Codex thread catalog metadata from `state_5.sqlite`
  - Added metadata-only capture from `~/.codex/state_5.sqlite` for `threads`, `thread_spawn_edges`, and `thread_dynamic_tools`.
  - Stored safe thread catalog fields such as rollout path pointer, created/updated timestamps, source, model provider, cwd/project, sandbox/approval type, tokens used, archive state, git SHA/branch/origin, CLI version, agent nickname/role/path, memory mode, model, reasoning effort, and thread source.
  - Stored spawn edge identities and dynamic tool name/namespace/defer-loading identity only.
  - Excluded thread title, first user message, preview, dynamic tool descriptions, input schemas, prompts, and content-bearing fields.
  - Added SQLite catalog/capture-state tables, backup/import, clear-history handling, launch capture, and Data settings diagnostics.

- Catalog Codex model capabilities
  - Added metadata-only capture from `~/.codex/models_cache.json`.
  - Stored safe model capability fields such as slug/display name, visibility, API support, priority, context windows, default/supported reasoning levels, reasoning summary and verbosity support, input modalities, supported tool identities, speed tiers, service tiers, and truncation policy.
  - Excluded instruction templates, model messages, availability NUX, migration markdown, descriptions, and arbitrary unknown text.
  - Added SQLite capability/capture-state tables, backup/import, clear-history handling, launch capture, and Data settings diagnostics without changing token totals, History charts, or model-selection behavior.

- Add turn performance and reliability analytics
  - Added a separate Performance Dashboard window from the left-click popover.
  - Used captured session task timing and OTEL performance rows to show turn count, median/p95 duration, median first token, event counts, failure rate, transport, and wire API behavior.
  - Added model, effort, project, source, transport, and wire API breakdowns plus CSV export without changing token totals, History charts, or telemetry schema.

- Add model/project efficiency insights
  - Added an Efficiency view inside the existing Performance Dashboard while keeping Performance as the default view.
  - Combined captured token categories, turn timing, reliability events, and model capability context windows into tokens/min, output/min, cache share, reasoning share, failure rate, and context pressure.
  - Added model, project, effort, and source breakdown rows with row selection, summary tiles, bucketed charting, and CSV export without changing telemetry capture, token totals, or History charts.

## Next Candidates

No next candidates. Do a product/backlog review before planning more implementation work.
