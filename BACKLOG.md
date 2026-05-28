# Backlog

## Delivery Rule

- After every app or source update, run `./install.sh` and verify the installed app is relaunched from `/Users/farzadmahmoodinobar/Applications/CodexStatusBar.app` before calling the work complete.

## Remaining Work

| Priority | Item | Why | Planning |
| --- | --- | --- | --- |
| 1 | Decouple dashboard reads from live capture/import work | Performance Dashboard reloads measured at 5.4s, 7.1s, and 9.8s; Token Dashboard first month reload measured at 2.7s; History reloads spiked to 2.1s-3.9s while dashboard work was in flight. Snapshot code still performs capture/import checks on the same database worker before serving dashboard reads, including a performance import on the Token Dashboard path. | Needs a separate planning prompt. |
| 2 | Add a dedicated read-only dashboard query worker or connection | Slow dashboard/capture work on the serial history database worker appears to delay unrelated History and Token Dashboard reads. A separate read path would reduce head-of-line blocking while preserving one writer/importer path. | Needs a separate planning prompt. |
| 3 | Fix performance diagnostics accuracy and retention | Diagnostics captured useful dashboard reload timings, but `menuPopoverOpenToContent` has cancelled outliers of 16s, 31s, 55s, and 129s, and 491/500 retained events were History reloads, evicting dashboard evidence quickly. | Can be planned as a small implementation item. |
| 4 | Cache or precompute Token Dashboard period snapshots | Token Dashboard open was fast, but the first month reload still took 2.7s for only 336 chart points and 7 rows; warm reload was about 0.63s. The UI can briefly show an empty state while data is loading. | Needs a separate planning prompt. |
| 5 | Optimize Performance Dashboard reliability-heavy SQL paths | The live database has about 179k turn-performance events. Month Performance reloads still took 5s-10s after prior timestamp indexing, suggesting reliability grouping/top-error aggregation and broad period joins remain expensive. | Needs a separate planning prompt after query-plan inspection. |
| 6 | Make dashboard loading and empty states explicit | Token Dashboard can show a no-data surface before the reload finishes, and Performance Month can appear empty when the selected period has sparse timing data. This is visually confusing even when the data path later succeeds. | Can be planned as a small UI item. |
| 7 | Make launch-time capture work budgeted and lazy | App launch to first menu-bar title was acceptable at roughly 0.9s-1.1s, but launch immediately schedules forced OTEL, session timing, thread catalog, and model capability captures on the shared database worker, which can slow the first dashboard interaction. | Fold into priority 1 unless it needs separate rollout. |

## Performance Recommendation Details

- Decouple dashboard reads from live capture/import work
  - Observed evidence: Performance Dashboard worker-backed reloads recorded 5.4s, 7.1s, and 9.8s. Token Dashboard first month reload recorded 2.7s. History reloads recorded 2.1s-3.9s near dashboard work even though normal History reloads are usually single-digit milliseconds.
  - Likely code path/root cause: `UsageHistoryDatabaseWorker.performanceDashboardSnapshot(for:)` runs turn-performance and session-task capture checks before querying dashboard data. `UsageHistoryDatabaseWorker.tokenDashboardSnapshot(for:)` also runs a turn-performance import even though Token Dashboard does not need OTEL data. Launch capture work is scheduled on the same database worker.
  - Proposed implementation shape: make dashboard snapshots read-only and capture-free; move capture refreshes into a bounded background coordinator and explicit Settings diagnostics refresh; keep capture health visible but never block dashboard snapshots on importer work. Remove the Token Dashboard dependency on turn-performance capture.
  - Verification plan: compare cold-ish and warm Token/Performance Dashboard opens before/after; assert Token Dashboard snapshot no longer calls OTEL capture; assert Performance snapshot can load from existing rows when capture source is slow/unavailable; verify token totals, charts, diagnostics, and capture health are unchanged.

- Add a dedicated read-only dashboard query worker or connection
  - Observed evidence: slow History reloads appeared at the same time as dashboard period/mode reloads, indicating serial database-worker head-of-line blocking.
  - Likely code path/root cause: all app-owned reads, writes, imports, and dashboard snapshots are routed through one `UsageHistoryDatabaseWorker` actor that owns one synchronous `UsageHistoryStore`.
  - Proposed implementation shape: add a read-only SQLite store/worker for bounded snapshot queries while keeping imports and writes on the existing serial writer; rely on WAL-compatible reads and existing history-change notifications for invalidation.
  - Verification plan: run concurrent dashboard reload and History reload tests with a spy/slow importer; confirm History reads are not blocked by capture work; run query-plan/performance regression tests and the installed-app visual timing pass.

- Fix performance diagnostics accuracy and retention
  - Observed evidence: popover timing has cancelled spans far longer than real user-visible open times, while dashboard open/reload samples are under-retained because History reload events dominate the 500-event store.
  - Likely code path/root cause: `StatusItemController.togglePopover` can leave long-lived cancelled `menuPopoverOpenToContent` spans depending on popover state and close path. `AppPerformanceInstrumentationStore` uses one global bounded ring rather than per-flow retention.
  - Proposed implementation shape: finish or discard popover spans on every close/cancel path; distinguish popover window-visible from content-loaded; keep per-kind bounded samples plus aggregate summaries so dashboard evidence survives frequent History reloads.
  - Verification plan: open/close popover repeatedly and confirm no multi-second cancelled popover spans; verify Settings Data still exports diagnostics; add retention tests proving dashboard events are not evicted by History-only churn.

- Cache or precompute Token Dashboard period snapshots
  - Observed evidence: first Token Dashboard month reload took 2.7s despite a small presentation result; repeated warm reloads fell to about 0.63s.
  - Likely code path/root cause: Token Dashboard lacks the view-model snapshot cache already added to Performance Dashboard and still recomputes period/breakdown data on repeated toggles.
  - Proposed implementation shape: add a bounded view-model cache keyed by period, range, breakdown, selected filters, and calendar/time zone; invalidate on history-change notifications; optionally prewarm the current month only after launch capture work is idle.
  - Verification plan: spy-worker tests for cache hit/miss/invalidation; installed-app timing for cold first open, close/reopen, period revisit, breakdown revisit, sort, and CSV export.

- Optimize Performance Dashboard reliability-heavy SQL paths
  - Observed evidence: Performance Dashboard month reloads remain multi-second after mode-aware loading, presentation pre-aggregation, caching, and indexed task timing timestamps.
  - Likely code path/root cause: `UsageHistoryStore+PerformanceQueries.swift` still scans and groups many `codex_turn_performance_events` rows for reliability counts and top errors across month/year windows.
  - Proposed implementation shape: run `EXPLAIN QUERY PLAN` for the slow live query shapes; add narrowly scoped composite indexes or derived daily/monthly reliability summaries; avoid grouping full error summaries unless visible/exported.
  - Verification plan: query-plan tests for month/year Performance and Efficiency snapshots; realistic fixture and live DB timing before/after; verify failure-rate and top-error semantics stay unchanged.

- Make dashboard loading and empty states explicit
  - Observed evidence: dashboards can render a no-data state before an async reload finishes, which makes a slow load look like missing data.
  - Likely code path/root cause: first render and reload state are not visually distinct enough from true empty periods in Token Dashboard and Performance Dashboard.
  - Proposed implementation shape: keep the previous successful snapshot visible or show an explicit loading state until the first reload completes; distinguish no captured data from no data for the selected period.
  - Verification plan: UI/view-model tests for first load, period changes, filtered-out data, and no-data periods; visual verification at default window size.

- Make launch-time capture work budgeted and lazy
  - Observed evidence: first menu-bar title was roughly 0.9s-1.1s, but forced capture tasks begin immediately after launch and can occupy the shared worker before the first dashboard open.
  - Likely code path/root cause: `CodexUsageMenuBarApp.applicationDidFinishLaunching` schedules forced turn-performance, session timing, thread catalog, and model capability captures at launch.
  - Proposed implementation shape: make launch capture staggered, budgeted, and cancelable; prioritize menu title and user-requested dashboard reads; let diagnostics show stale capture state instead of blocking reads.
  - Verification plan: launch timing, first popover timing, first dashboard timing, and Settings diagnostics freshness before/after; confirm capture still runs eventually and app relaunch/fingerprint checks pass.

## Conditional Watchlist

- Review live token payload audit sample
  - A bounded probe on May 19, 2026 generated local Codex token activity and was captured through the log-based token importer, but app-server diagnostics still showed `0` `thread/tokenUsage/updated` notifications and no `live-token-payload-audit.json`.
  - Keep this blocked until Settings Data or `~/Library/Application Support/CodexStatusBar/live-token-payload-audit.json` shows a real sanitized payload.
  - If a future sample appears with useful fields, plan `Record live token context fields directly`; otherwise keep local log/session capture as the evidence-backed live token source.

## Done

- Comprehensive performance audit and backlog update
  - Measured installed-app latency using the local performance diagnostics store, wall-clock UI automation where reliable, visual verification, and direct SQLite inspection.
  - Audited dashboard view models, window controllers, the shared database worker, dashboard snapshot paths, launch capture tasks, SQLite table sizes, and instrumentation behavior.
  - Added prioritized performance work items with observed timings, likely code paths, implementation shapes, verification plans, and planning needs.

- Add indexed event timestamp for session task timing queries
  - Added a stored `event_timestamp` column to `codex_session_task_timing_events`.
  - Backfilled existing timing rows from `started_at`, then `completed_at`, then `recorded_at`.
  - Indexed `event_timestamp` and updated Performance Dashboard timing and bounds queries to use it directly instead of computed `COALESCE(...)` filters.
  - Updated session timing imports and backup restore to maintain or reconstruct the indexed timestamp.
  - Added migration, upsert, backup compatibility, and query-plan tests for the indexed timestamp path.

- Add built-in dashboard/menu performance instrumentation
  - Added a local JSON-backed performance diagnostics store with bounded retention and metadata sanitization.
  - Instrumented app launch to first real menu-bar title, menu popover first render, History reloads, Token Dashboard reloads/period/breakdown changes, Performance Dashboard reloads/mode/period/breakdown changes, and Performance Dashboard cache-hit versus worker-backed reloads.
  - Added Settings Data performance diagnostics with recent event summaries plus export and clear actions.
  - Added tests for event recording, sanitization, retention, export/clear, write failures, Settings presentation, and Token/Performance Dashboard instrumentation.

- Add dashboard snapshot and presentation caching
  - Added bounded view-model scoped caching for Performance Dashboard presentation snapshots by mode, breakdown, range, period, and calendar/time zone.
  - Cache hits now apply already-loaded rows and chart points without calling the database worker.
  - Sorting and row selection remain UI-only and do not invalidate or miss the snapshot cache.
  - History-change notifications clear cached snapshots and reload the current dashboard selection.
  - Added tests for cache hits, misses, failure behavior, invalidation, stale async results, unsupported Efficiency breakdown reset, and bounded pruning.

- Return pre-aggregated Performance Dashboard presentation rows
  - Moved Performance Dashboard presentation aggregation into store/worker snapshot queries.
  - Performance mode now returns pre-bucketed duration points, reliability points, breakdown rows, series, and bounds for the selected breakdown.
  - Efficiency mode now returns pre-bucketed efficiency points, efficiency rows, series, and bounds for supported breakdowns.
  - The view model consumes presentation-ready arrays instead of rebuilding from raw sample arrays on the main actor.
  - Added parity tests against the existing presentation builder and realistic fixture regression coverage for month/year Performance and Efficiency snapshots.

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
