# Backlog

## Delivery Rule

- After every app or source update, run `./install.sh` and verify the installed app is relaunched from `/Users/farzadmahmoodinobar/Applications/CodexStatusBar.app` before calling the work complete.
- Verification must include a direct visible app check, not just process/fingerprint checks: the menu-bar title should be useful and not a silent `--` fallback unless `--` is the explicitly expected state, and any touched window should open and render.

## Remaining Work

| Priority | Item | Evidence | Plan Needed? |
| --- | --- | --- | --- |
| 1 | Fix Performance Dashboard body empty-state mismatch when summaries have data | Installed-app verification after model-capability annotations showed Performance Dashboard Model breakdown for May 2026 with nonzero summary tiles, but the chart/table body rendered `No data for this selection`; Efficiency showed the same mismatch with token summaries. | Yes |

## Codex Update Audit Details

- May 30, 2026 local audit evidence:
  - Installed app is running from `/Users/farzadmahmoodinobar/Applications/CodexStatusBar.app`.
  - App-bundled Codex binary reports `codex-cli 0.135.0-alpha.1`.
  - `~/.codex/models_cache.json` reports `client_version = 0.135.0` and contains 7 models.
  - Homebrew `/opt/homebrew/bin/codex` reports `codex-cli 0.128.0`.
  - `~/.codex/version.json` still reports `latest_version = 0.128.0` with `last_checked_at = 2026-05-05T02:25:24Z`.
  - `state_5.sqlite` has 497 threads, 250 spawn edges, 472 dynamic tools, 1 remote-control enrollment, and empty `agent_jobs` / `agent_job_items` tables.
  - The app history database already has about 73k token samples, 564k token dimensions, 229k turn-performance events, 1.2k session task timing rows, 494 thread catalog rows, and 7 model capability rows.
  - `codex app-server generate-ts` shows additional safe status surfaces including `remoteControl/status/changed`, `thread/status/changed`, `turn/started`, `turn/completed`, `model/rerouted`, `warning`, `configWarning`, `account/updated`, `thread/goal/updated`, and `permissionProfile/list`.
- Product direction:
  - Prefer diagnostic capture first for new app-server notifications and OTEL fields.
  - Keep privacy boundaries unchanged: do not store prompts, messages, summaries, tool payloads, auth tokens, account ids, email addresses, raw websocket URLs, or arbitrary unknown values.
  - Any app/source update must still run `./install.sh` and relaunch the installed app before completion.

## Codex Profile Token Mismatch Details

- May 30, 2026 verification:
  - Installed `CodexStatusBar.app` matched source commit `e287cdcb6daaf13da3c15aac4e11ce27d2b7d82a` and the visible menu-bar token value matched the local component-total path, not Codex Profile.
  - Codex Settings Profile code in `/Applications/Codex.app/Contents/Resources/app.asar` maps `/wham/profiles/me` into `summary.totalTextTokens = stats.lifetime_tokens`, `summary.peakTokens = stats.peak_daily_tokens`, and daily chart rows from `stats.daily_usage_buckets[].tokens`.
  - Profile dates are UTC-style day buckets; local StatusBar menu uses the local calendar for "today" and dashboard/history views use local calendar-period navigation unless explicitly changed.
- Observed count mismatch:
  - Codex Profile server lifetime: `17,220,508,070`.
  - Codex Profile May 2026 bucket sum: `6,260,075,438`.
  - Codex Profile May 30, 2026 UTC bucket: `23,714,051`.
  - Local StatusBar all-time component total: `15,979,420,798`.
  - Local StatusBar May 2026 component total: `9,163,337,642`.
  - Local StatusBar May 30, 2026 UTC component total: `100,944,203`.
  - Local StatusBar May 30, 2026 local-time/menu component total: about `82.7M`, displayed compactly as about `83M`.
- Likely root causes:
  - Codex Profile is server/account-side usage with a single opaque `tokens` value per day; local StatusBar is a local capture/import system.
  - Local component totals intentionally count `input + cached input + output + reasoning`, while Profile does not equal either that component sum or legacy `observed_total_tokens`.
  - Local all-time history starts later than the server profile window and can miss server-counted usage, while some local days are higher than server buckets because cached input and repeated local samples are counted under local analytics semantics.
  - UTC Profile buckets and local-calendar menu/dashboard periods will differ around day boundaries even when the underlying events are the same.
- Product direction:
  - Do not rewrite the local token importer to chase the Profile number without an explicit server definition.
  - If server counts are shown, keep them separate from local captured analytics and label both surfaces clearly.
  - Fetch/store only bounded, metadata-only server stats needed for display and comparison; do not persist auth tokens, account ids, email addresses, prompts, messages, summaries, or raw server payloads.
  - Add a diagnostic row showing latest Profile sync time, server bucket count/date range, lifetime, peak daily, and local-vs-server delta for the selected UTC day/month.

## Conditional Watchlist

- Review live token payload audit sample
  - A bounded probe on May 19, 2026 generated local Codex token activity and was captured through the log-based token importer, but app-server diagnostics still showed `0` `thread/tokenUsage/updated` notifications and no `live-token-payload-audit.json`.
  - Keep this blocked until Settings Data or `~/Library/Application Support/CodexStatusBar/live-token-payload-audit.json` shows a real sanitized payload.
  - If a future sample appears with useful fields, plan `Record live token context fields directly`; otherwise keep local log/session capture as the evidence-backed live token source.

- Watch Codex agent-job tables
  - `state_5.sqlite` now contains `agent_jobs` and `agent_job_items`, but both tables had `0` rows during the May 30 audit.
  - Do not build UI or storage around these tables until real rows appear.
  - If rows appear, plan metadata-only capture for job status, timestamps, counts, and assigned thread linkage while excluding instructions, row payloads, outputs, schemas, local file contents, and error details that may contain private content.

## Done

- Add model/provider capability annotations to dashboards
  - Used already captured `codex_model_capabilities` data to add compact capability annotations to model rows in Token Dashboard and Performance Dashboard.
  - Shows context-window, reasoning, modality, tool, service/speed tier, API, and visibility context only for real model rows.
  - Kept aggregate, unattributed, effort, project, generic dimension, transport, and wire API rows uncluttered.
  - Preserved token totals, dashboard metrics, chart semantics, CSV output, telemetry capture/import behavior, storage schema, and the right-click menu.

- Extend safe OTEL runtime dimensions from Codex 0.135 logs
  - Added a turn-performance runtime-dimension layer for safe Codex 0.135 OTEL metadata in `logs_2.sqlite`.
  - Captured allowlisted `auth_mode`, metadata-header presence, WebSocket warmup state, request reasoning effort, request/connection count buckets, and tool-output size buckets.
  - Used `codex.request.reasoning_effort` as an explicit effort fallback only when the event effort is missing, while also storing it as a runtime dimension.
  - Stored runtime dimensions and catalogs in SQLite, backup/import, clear-history, and Settings Data diagnostics while excluding prompts, messages, summaries, tool payloads, auth data, account/user IDs, emails, URLs, raw paths, request/response bodies, schemas, titles, descriptions, and arbitrary unknown fields.
  - Preserved token totals, dashboards, History charts, menu-bar behavior, and the right-click menu.

- Add safe app-server notification audit v2
  - Extended the existing JSON-backed app-server diagnostics with a bounded notification audit summary for newly exposed app-server notification methods.
  - Audited safe enum/status/presence metadata for thread status, turn start/completion, model reroute, account updates, thread settings, thread goals, realtime events, and warning/config/deprecation/guardian notifications.
  - Stored method counts, supported/unsupported counts, rejected unsafe-field counts, last safe summaries, and compact per-method rows while excluding prompts, messages, summaries, tool payloads, auth data, account/user IDs, raw thread/turn IDs, raw paths, websocket URLs, transcripts, SDP, audio, schemas, and arbitrary unknown values.
  - Added Settings Data display and clear controls for the notification audit, with no new popover warning for normal audit data.
  - Left `permissionProfile/list` out of v2 capture because the generated app-server surface exposes it as request/response, not an inbound notification to audit passively.
  - Kept token totals, dashboards, capture/import behavior, storage schema, and the right-click menu unchanged.

- Add remote-control and app-server health diagnostics
  - Extended app-server diagnostics with safe remote-control status tracking from `remoteControl/status/changed`.
  - Stored only notification counts, enum-like status values, warning state, connection state, last method, and aggregate enrollment metadata from `state_5.sqlite`.
  - Read `remote_control_enrollments` defensively as count/latest-update only, excluding websocket URLs, account IDs, environment IDs, server IDs, auth data, payloads, prompts, messages, tools, and row contents.
  - Added Settings Data refresh/clear UI and compact popover warnings only for disconnected/error/failure states.
  - Kept token totals, dashboard semantics, capture/import behavior, and the right-click menu unchanged.

- Add Codex version and source health diagnostics
  - Added a read-only JSON-backed Codex source health cache under Application Support.
  - Reused the app-server executable candidate ordering for source diagnostics so the reported active executable matches the app-server path.
  - Captured only safe local version signals: executable paths, `codex --version` strings, file mtimes, models-cache client version/fetch time/model count, and `version.json` latest/check metadata.
  - Added mismatch, stale, missing, malformed, and failed classifications with Settings Data diagnostics and a compact popover warning only when attention is needed.
  - Kept token totals, dashboards, capture/import behavior, and the right-click menu unchanged.

- Add Codex Profile token comparison and local-token labels
  - Added sanitized read-only fetching for `/wham/profiles/me` through the existing Codex app-server auth path.
  - Stored only bounded Profile token stats in a local JSON cache: lifetime tokens, peak daily tokens, daily UTC token buckets, sync status, and last sync/error metadata.
  - Added Settings Data comparison rows that keep Codex Profile account tokens separate from StatusBar local captured component totals for all-time, current UTC month, and current UTC day.
  - Updated local token copy so user-facing surfaces identify StatusBar totals as local captured tokens where space allows, without changing compact menu-bar formatting or local token calculations.

- Audit remaining local token total semantics
  - Updated `tokenTotalForDay` to use the same local component-total definition as the menu bar and Token Dashboard: input + cached input + output + reasoning.
  - Updated Token History `.total` points and bounds to use component totals instead of legacy `observed_total_tokens`.
  - Updated token series catalog visibility so `.total` is available when any observed token component exists, including cached-only, output-only, or reasoning-only samples.
  - Kept `observed_total_tokens` stored/imported for duplicate detection and raw legacy metadata, but removed it from default user-facing local-token totals.

- Make dashboard loading and empty states explicit
  - Added explicit primary snapshot load state to Token Dashboard and Performance Dashboard view models.
  - Dashboard views now show loading states for first loads and stale period/mode/breakdown selections instead of premature no-data surfaces.
  - Same-selection Performance Dashboard refreshes keep current content visible with a small refreshing indicator.
  - CSV export remains disabled until the current dashboard snapshot, and Token Dashboard attribution coverage, are ready.
  - Preserved cache-hit behavior so already-loaded selections apply immediately without a loading flash.

- Reduce Token Dashboard reload disk I/O
  - Split Token Dashboard loading into a primary chart/summary/table snapshot and a separate lazy attribution coverage load.
  - Added separate coverage caching by clipped period so breakdown switches reuse attribution coverage instead of re-querying it.
  - Added safe Token Dashboard subquery timing metadata for primary and coverage phases in local performance diagnostics.
  - Debounced history-change reloads so notification storms coalesce into one cache invalidation and one reload.
  - Set the read-only dashboard SQLite connection to `PRAGMA temp_store=MEMORY` to avoid file-backed temp sorter writes for dashboard read queries.
  - Kept token totals, chart points, coverage rows, CSV columns, dashboard semantics, and privacy boundaries unchanged.

- Optimize Performance Dashboard reliability-heavy SQL paths
  - Split Performance Dashboard reliability aggregation into separate bounded status-count and failure-error phases so success and unknown rows no longer group by `error_summary`.
  - Added covering index `idx_codex_turn_performance_events_reliability_cover` for month/year reliability reads while preserving existing narrower query indexes.
  - Preserved failure-rate, unknown-count, top-error, row-selection, snapshot-cache, and CSV semantics for Performance and Efficiency dashboards.
  - Added query-plan, correctness, and regression tests for month/year reliability paths across supported breakdowns.

- Cache or precompute Token Dashboard period snapshots
  - Added bounded Token Dashboard view-model snapshot caching by breakdown dimension, range, clipped query period, and calendar/time zone.
  - Cache hits now apply already-loaded Token Dashboard points, rows, attribution coverage, available dimensions, and bounds without calling the dashboard query worker.
  - Sorting and row selection remain UI-only and do not invalidate or miss the snapshot cache.
  - History-change notifications clear cached snapshots and reload the current dashboard selection.
  - Added cache hit/miss, revisit, failure, invalidation, stale-result, unavailable-breakdown reset, pruning, and instrumentation tests.

- Fix performance diagnostics accuracy and retention
  - Added deterministic popover open-to-content span tracking so close/cancel paths discard pending popover spans instead of recording misleading cancelled open-to-content outliers.
  - Updated performance diagnostics retention to age-prune first, then reserve representative recent samples by event kind before filling remaining capacity with newest events.
  - Added tests for representative retention under History reload churn, age pruning, and discarded cancelled popover spans.
  - Verified with the full macOS Xcode test suite, release install, relaunch process check, and installed build fingerprint; final visible surface inspection requires an unlocked macOS session.

- Add a dedicated read-only dashboard query worker or connection
  - Added read-only SQLite open support with `PRAGMA query_only=ON` for persisted dashboard/history snapshots.
  - Added a dedicated `UsageHistoryDashboardQueryWorker` for History, Token Dashboard, and Performance Dashboard snapshot reads.
  - Added a `UsageHistoryDatabaseRouter` so dashboard reads use the read-only query worker while recording, token freshness, capture/import, settings, backup/restore, clear-history, and project rename stay on the writer worker.
  - Added tests for read-only snapshot parity, read-only mutation rejection, first-launch missing database fallback, router routing, and snapshot completion while writer capture is blocked.

- Decouple dashboard reads from live capture/import work
  - Removed metadata capture/import calls from Token Dashboard and Performance Dashboard snapshot reads so dashboard opens and toggles read already persisted rows.
  - Added a delayed background metadata capture coordinator owned by the app delegate.
  - Staggered turn performance, session task timing, thread catalog, and model capability captures with `force: false` while keeping Settings diagnostics refreshes and live token capture behavior unchanged.
  - Added tests proving dashboard snapshots do not invoke metadata importers and the background coordinator delays, staggers, continues after failures, and does not call live token capture.

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

Next item to plan: `Make dashboard loading and empty states explicit`.
