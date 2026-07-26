# Backlog

Last reconciled: July 26, 2026 after completing every source, migration, storage, installation, and runtime gate that does not require unlocking the current macOS login session.

## Current status

- `LIGHTWEIGHT-STORAGE-20260717` has completed `STORAGE-20260717-01` through `-06`. `-07` and `-08` are parked only on the native click-through and same-process UI-toggle evidence that requires an unlocked macOS login session; their implementation, automated verification, production-copy rehearsal, live migration, installation, and independent runtime/storage gates are complete.
- No product, UX, migration, privacy, retention, or distribution decision remains for this initiative. The defaults and failure behavior below are authoritative; later implementation must not stop for owner input unless the source proves an external constraint that cannot be handled by the recorded fallback.
- The July 10 audit program and July 12 intake work remain complete. Do not reopen those items while implementing this initiative.
- No blocked distribution decision remains. The repository is licensed under MIT.
- Public release, signing, notarization, tagging, upload, and publication were not performed. The release workflow remains disabled.
- All work predating this initiative is complete and pushed to `main`. Its final owner report carries the post-commit verifier, build-local UI, process-cleanup, and upstream-parity evidence.
- Historical detail remains available with `git show 43bd86d:BACKLOG.md`; do not restore the former audit queue or Done ledger here.

## Lightweight storage initiative

### Intake evidence and problem statement

This initiative restores the product boundary promised by the README: Codex Status Bar is a small menu-bar utility first, with detailed local analytics available only when deliberately enabled.

Read-only evidence captured July 17, 2026:

- The live schema is version 2 and the operational store is `~/Library/Application Support/CodexStatusBar/usage-history.sqlite3`.
- Application Support occupies 2.9 GiB. The database has 761,857 4 KiB pages and only seven free-list pages, so an immediate `VACUUM` would not address the root cause.
- The store contains 613,884 token samples, 7,588,267 token-dimension rows, 348,422 performance events, and only 343 distinct dimension-catalog entries.
- The dimension table, its composite-primary-key autoindex, and its key/value index occupy about 2.27 GiB, roughly three quarters of the database. Repeated string dimensions attached to every cumulative token sample are the dominant defect.
- `UsageHistoryStore.enforceTelemetryRetention` exists and has a six-hour throttle, but production calls it only after the Settings retention picker changes. Normal app launch starts collection without scheduling maintenance, and the live database has no `telemetry_retention_last_run` metadata.
- In the current code, `CodexLiveTokenCaptureCoordinator` starts every 30 seconds. `CodexBackgroundMetadataCaptureCoordinator` also starts at launch and captures turn performance, session timing, thread catalog, and model capabilities even if the user only wants status-bar limits. The frozen Lightweight contract below intentionally replaces that local-token cadence with 5 minutes.
- `Import All History...` currently feeds the operational database.

Primary source gates for the later drain:

- `Sources/CodexUsageMenuBar/CodexUsageCoreAppDelegate.swift` — collector composition and startup.
- `Sources/CodexUsageMenuBar/UsageHistoryDatabaseWorker.swift` — serialized writers and metadata coordinators.
- `Sources/CodexUsageMenuBar/UsageHistoryStore.swift` — schema version, retention preference, and production-store construction.
- `Sources/CodexUsageMenuBar/UsageHistoryStore+Migrations.swift` — schema, indexes, and versioned migration framework.
- `Sources/CodexUsageMenuBar/UsageHistoryStore+Recording.swift` — sample/dimension writes, baselines, rollups, and retention.
- `Sources/CodexUsageMenuBar/UsageHistoryStore+TokenQueries.swift` and `UsageHistoryStore+PerformanceQueries.swift` — raw/rollup query parity.
- `Sources/CodexUsageMenuBar/UsageHistoryStore+DataManagement.swift` and `DataManagementSettingsView.swift` — size reporting, backup/import, and user controls.

### Frozen product and engineering decisions

1. **Lightweight is the default.** The user-facing control is one `Detailed Analytics` toggle. A missing preference resolves to off for fresh and upgraded installations.
2. **The status experience remains useful.** Lightweight mode retains 5h/7d/Tightest status and reset information, account-token display, rate-limit History, and the live local-token fallback used when account data is unavailable. Its local-token trend is exactly the aggregate Tokens series in History for the last 7 local calendar days at daily granularity. Lightweight capture runs at launch and every 5 minutes; Detailed Analytics may retain the existing 30-second cadence.
3. **Advanced collection is opt-in; retained data remains readable.** Turn-performance, session-timing, thread-catalog, model-capability, and detailed token-dimension collection require Detailed Analytics. Enabling starts future collection only; it never silently backfills. Disabling cancels advanced collectors immediately and schedules maintenance without deleting data synchronously. Operational Token and Performance dashboards remain read-only when retained data exists and show `Collection paused`; an explicitly opened archive is viewable without enabling live collection.
4. **Retention is fixed, not user-tunable.** Low-cardinality rate-limit raw samples live for 7 days, their hourly aggregates for 90 days, and their daily aggregates for 365 days. Token/performance raw detail lives for 72 hours, hourly aggregates for 90 days, and daily aggregates for 365 days. Older data is deleted. The existing 7/14/30/90-day picker is removed.
5. **Operational storage is budgeted.** Lightweight has a 100 MiB maintenance target and 250 MiB hard maximum. Detailed Analytics has a 250 MiB target and 500 MiB hard maximum. The operational budget includes the SQLite database, WAL, and SHM. Time retention and the budget both apply; the budget wins.
6. **Dimension semantics are preserved.** Dimensions may vary between cumulative samples, so normalization uses reusable immutable dimension sets rather than assuming one mutable dimension record per turn.
7. **All-history data is an archive, not live state.** A manual all-history operation builds a user-selected token-history SQLite archive that is opened read-only and on demand. It is never opened at launch, never receives collectors, and is reported separately from the operational budget. It supports aggregate Token History and Token Dashboard views; Performance Dashboard remains operational-only because the session-history importer does not supply equivalent performance evidence.
8. **Maintenance never breaks core status.** If advanced data cannot fit after compaction, Detailed Analytics ingestion pauses with a visible diagnostic. Current limits, reset information, account tokens, and the latest lightweight counters continue.
9. **Physical reclamation is transactional.** No in-place destructive vacuum is allowed. Rebuild into a same-volume temporary database, validate it, atomically replace the original, verify reopen, and only then remove the rollback copy.
10. **No cloud analytics or release expansion.** All data remains local and metadata-only. This initiative does not authorize public release, signing, notarization, upload, publication, or a separate analytics service.

### Global implementation contract

- Execute the entire drain in one Codex task with one agent. Do not create subagents, worker threads, handoffs, or other Codex tasks.
- No product decision remains open. Make ordinary engineering decisions autonomously within the frozen contract. If a change would alter that contract or risk data loss, park only that portion instead of asking the owner or pausing the drain.
- A parked item stays unchecked and records the exact blocked portion, evidence, attempted safe alternatives, true dependents, and resume condition. Continue every dependency-independent implementation, test, documentation, commit, and push; revisit parked work once after the feasible queue is exhausted.
- Never report the backlog as drained while parked work remains. The final report separates completed and parked items and launches the newest fully verified source-safe app even when unrelated work is parked.
- Drain `STORAGE-20260717-01` through `STORAGE-20260717-08` in order. Later items may be developed together when necessary, but no item is complete until its own acceptance criteria pass.
- Never persist or include prompts, messages, summaries, tool payloads, credentials, account identifiers, arbitrary protocol payloads, or private error text in operational storage, backups, archives, diagnostics, or test evidence. Only the already-approved sanitized metadata and aggregate measurements are allowed.
- Never use the live user database as an XCTest fixture. Build synthetic production-shaped fixtures and use a SQLite-consistent copy for final migration rehearsal.
- Data-scanning migration/backfill, maintenance, import, archive, and optimization work must be cancellable, restartable, idempotent, serialized through the database worker, and kept off the main actor. The bounded structural schema-open transaction is the sole cancellation exception: it may execute only a constant number of DDL/metadata statements and may not scan or rewrite application tables.
- Existing dashboards must return equivalent totals and attribution for every retained period before and after migration. A deliberate loss of detail outside the frozen retention tiers is not a parity failure.
- Failure metadata records the stage and safe retry action without sensitive row contents. Failure never advances the success cursor or deletes the last valid database/archive.
- Update README/privacy/data-management copy in the same drain. Do not leave the shipped UI claiming that raw retention is configurable or that rollups live indefinitely.
- Completion requires the canonical verifier, a copied-production-database migration rehearsal, installation through `./install.sh`, installed-bundle relaunch, native UI inspection, runtime/storage soak evidence, commit, and push. Release publication remains disabled.

### [x] `STORAGE-20260717-01` — Lightweight collection policy and runtime composition

**Status:** `completed` — implementation is present in `a24b5b5` with verification/recovery fixes through `d69a6f7`; focused tests and the canonical verifier passed on July 26, 2026.

**Outcome:** ordinary app launch performs only the work needed for a dependable status bar; detailed analytics becomes explicit opt-in functionality.

**Requirements**

- Add a persisted collection policy with internal cases `lightweight` and `detailedAnalytics`; expose it as one Settings toggle labelled `Detailed Analytics`.
- Treat a missing or invalid preference as `lightweight`, including on upgrades from schema v2. Do not silently preserve the former always-on behavior.
- Keep limit/account refresh and low-cardinality rate-limit recording active in Lightweight. Run `CodexLiveTokenCaptureCoordinator` once at launch and every 5 minutes in Lightweight, versus 30 seconds in Detailed Analytics, so current-day local token fallback and the defined 7-day daily trend still work.
- In Lightweight, store only the token components and identifiers required for deduplication, cumulative-delta correctness, current-day totals, and the short trend. Do not persist project/session/effort/context dimensions or populate dimension sets/catalogs.
- Start turn-performance, session-timing, thread-catalog, model-capability, and full token-dimension collection only in Detailed Analytics.
- Enabling Detailed Analytics takes effect without relaunch and collects prospectively. It does not run recent/all-history import.
- Disabling it cancels advanced tasks before their next write, prevents stale in-flight results from committing, leaves already-collected data readable, and queues bounded maintenance.
- Keep operational Token and Performance dashboard routes available when retained data exists, but make them read-only and label them `Collection paused` while off. When no retained data exists, use an empty state with one enable action. Explicit read-only archives remain viewable while collection is off. Rate-limit History and the lightweight token trend always remain reachable. No storage meter is added to the menu title or ordinary popover.
- Extract an injectable startup/collector plan from `CodexUsageCoreAppDelegate` so the policy can be tested without launching AppKit.

**Acceptance**

- Pure policy/defaults tests cover fresh, upgraded, valid, invalid, and toggled preferences.
- Coordinator-spy tests prove the Lightweight and Detailed startup plans, launch/5-minute versus 30-second token cadence, same-process enable/disable, cancellation, stale-result rejection, and idempotent repeated starts/stops.
- Lightweight startup makes zero turn-performance, session-timing, thread-catalog, model-capability, or detailed-dimension writes while token totals refresh at the frozen cadence and the 7-day daily aggregate series remains correct.
- Detailed Analytics starts exactly the advanced collectors once, and disabling it prevents every subsequent advanced write without interrupting core status.

**Depends on:** none. Blocks all later items.

### [x] `STORAGE-20260717-02` — Bounded automatic lifecycle and tiered rollups

**Status:** `completed` — implementation is present in `a24b5b5` with production-history bounding fixes through `d69a6f7`; focused tests, a repeated production-copy maintenance pass, and the canonical verifier passed on July 26, 2026.

**Outcome:** retention is guaranteed during ordinary use and can safely catch up from a multi-gigabyte database without freezing launch or holding one enormous transaction.

**Requirements**

- Replace the selectable raw-retention policy with the frozen tiers: rate-limit raw 7 days; token/performance raw 72 hours; hourly aggregates 90 days; daily aggregates 365 days.
- Retain and prune the existing hourly/daily rate-limit rollups rather than creating a duplicate rate-limit aggregation path. Add daily token, token-dimension, performance, and reliability/error aggregates wherever an equivalent retained dashboard view requires them. Queries choose raw/hourly/daily sources without double counting boundaries.
- Preserve one query-hidden cumulative token baseline per inactive thread only as long as needed for correct future deltas. Expire an inactive baseline after 30 days; the first later observation establishes a zero-delta baseline rather than counting the entire cumulative value.
- Refactor `enforceTelemetryRetention` into restartable batches of no more than 24 completed hourly buckets per transaction. Persist the next cursor only after a batch commits, yield between batches, and resume until caught up.
- Coalesce concurrent triggers. Start maintenance after 60 seconds of launch idle, then at most every six hours, and enqueue it after mode changes, operational imports, backup imports, and the budget reaching 90% of its hard maximum.
- Preserve the current rule for live operational capture and `Import Last 7 Days...`: neither synchronously executes the full retention job before returning; they enqueue maintenance. Backup restore is different by design: it migrates, retains, budgets, optimizes when eligible, and validates an offline candidate database before one atomic publication, so the live writer never crosses the cap.
- Record last attempt, last success, current stage/cursor, rows/bytes compacted, and a sanitized error. A failure must not overwrite the last-success timestamp.
- Prune expired catalogs and capture-state rows only when no retained raw/rollup row references them.

**Acceptance**

- Tests cover absent/fresh/stale maintenance metadata, coalescing, retry, cancellation, interruption after any committed batch, idempotent rerun, and no main-actor blocking.
- Raw/hourly/daily boundary, late-arriving data, local-calendar, DST forward/backward, cumulative-baseline, and inactive-baseline-expiry tests preserve exact totals.
- No non-baseline raw detail survives its tier; no hourly aggregate survives 90 days; no daily aggregate survives 365 days.
- Dashboard snapshots and backup/export aggregates are equal before and after lifecycle enforcement for all retained ranges.

**Depends on:** `STORAGE-20260717-01`.

### [x] `STORAGE-20260717-03` — Schema-v3 dimension-set normalization and index diet

**Status:** `completed` — implementation and the production-shaped measurement gate are present in `a24b5b5` with migration retry fixes through `d69a6f7`; the production-copy rehearsal preserved retained aggregates, passed integrity/parity/query gates, and exceeded the required reduction thresholds on July 26, 2026.

**Outcome:** repeated strings are stored once while sample-specific attribution remains exact.

**Required schema**

- Add `token_dimension_values(value_id INTEGER PRIMARY KEY, dimension_key TEXT NOT NULL, dimension_value TEXT NOT NULL, first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL, UNIQUE(dimension_key, dimension_value))`.
- Add `token_dimension_sets(set_id INTEGER PRIMARY KEY, signature BLOB NOT NULL UNIQUE)`.
- Add `token_dimension_set_members(set_id INTEGER NOT NULL, value_id INTEGER NOT NULL, PRIMARY KEY(set_id, value_id))` with enforced foreign keys.
- Rebuild `token_usage_samples` during final cutover so nullable `dimension_set_id` has an enforced foreign key to `token_dimension_sets(set_id)`. It remains null for Lightweight samples without detailed dimensions. If the transition initially adds the column without an FK, every chunk/cutover/reopen must run an explicit orphan query until the rebuilt table is authoritative.
- Encode the sorted unique value-ID list as a deterministic, collision-free canonical BLOB. Reusing a dimension combination must create zero new values, sets, or members.

**Migration and query requirements**

- Keep the structural schema-v3 open migration fast. It may create tables/columns/indexes and state metadata, but it must not synchronously scan millions of legacy rows while the store opens.
- After `STORAGE-20260717-02` compacts expired v2 data, dual-write old/new representations and backfill retained legacy samples in restartable rowid chunks. Record and validate the cursor after each chunk.
- During transition, query the normalized set when present and the legacy rows otherwise. Never double count a dual-written sample.
- Rewrite every raw-dimension series, coverage, catalog, repair, backup, export, and rollup path. Preserve conflicting/sample-varying dimension semantics and existing safe-value sanitization.
- After backfill, compare retained aggregate snapshots and membership counts, run the explicit orphan query plus `PRAGMA foreign_key_check` and `PRAGMA quick_check`, cut reads to v3, rebuild the sample table with the enforced FK, remove the legacy dimension table/indexes, and record finalization durably.
- A failure before a chunk commit rolls back only that chunk and resumes from the previous cursor. A failure after a durable cutover phase resumes forward from that phase; after the validated legacy drop, recovery must never attempt to return to v2 reads.
- Audit `EXPLAIN QUERY PLAN` and measured object sizes before replacing wide sample keys or dropping indexes. Use compact surrogate identifiers where they measurably reduce disk/write amplification without weakening import deduplication or bounded query plans.

**Acceptance**

- A production-shaped fixture contains 10,000 turns, 14 cumulative samples per turn, 12 repeated dimensions per sample, changing-dimension cases, duplicates, unsafe values, and a small value dictionary.
- v2-to-v3 migration tests cover forced interruption/rollback/reopen at structural creation, each backfill stage, cutover, legacy drop, and finalization.
- Reimport repair, catalog discovery, all breakdowns, attribution coverage, raw-to-rollup conversion, backups, and CSV exports are bit-for-bit equivalent within retained ranges.
- Normalized dimension-table/index bytes are at least 80% below the equivalent v2 fixture; total database+WAL+SHM is at most 40% of v2 after checkpoint and physical optimization.
- Existing query-plan and conservative latency gates remain bounded with no new full scans over token samples or dimension memberships.

**Depends on:** `STORAGE-20260717-02`.

### [x] `STORAGE-20260717-04` — Enforced operational storage budgets

**Status:** `completed` — implementation is present in `a24b5b5` with deterministic pressure safeguards through `d69a6f7`; focused budget tests, the production-shaped fixture, live Lightweight budget enforcement, and the canonical verifier passed on July 26, 2026.

**Outcome:** the operational database cannot silently grow without bound.

**Requirements**

- Extend database information with operational DB/WAL/SHM bytes, archive bytes, logical live bytes, reclaimable bytes, collection mode, soft target, hard maximum, oldest raw/hourly/daily bucket, and maintenance state.
- Apply the frozen budgets: Lightweight target/hard = 100/250 MiB; Detailed Analytics target/hard = 250/500 MiB.
- Reserve enough headroom to preflight the conservative worst-case page/index/WAL growth of each ingestion batch. Include a fixed 64 KiB physical-file reserve for one WAL header/frame boundary and one SHM allocation increment. No advanced batch may begin when current physical DB+WAL+SHM bytes plus the conservative bound and reserve would exceed the hard maximum; trigger pressure handling first. Track logical live pages separately at exact 4 KiB page granularity and do not treat that logical unit as a tolerance for physical files.
- Pressure order: checkpoint WAL; finish expired raw-to-hourly work; fold expired hourly into daily; delete daily data older than one year; prune orphaned catalogs/baselines; shorten the oldest optional raw detail even if still inside its time tier; delete the oldest in-tier hourly rows already represented by daily rows; delete the oldest in-tier daily analytics rows; then run safe physical optimization when eligible. The latest core status/reset state and current lightweight counters remain protected throughout.
- Never delete the newest limit snapshot, the state needed for current reset/status presentation, or the newest cumulative baseline for an active token stream.
- If Lightweight remains above its hard maximum, retain only current status plus mutable current-day aggregate counters until maintenance succeeds. If Detailed Analytics remains above its hard maximum, pause advanced ingestion. Neither case may stop limit/account refresh.
- Automatically resume paused collection only after a successful maintenance pass returns below the mode's soft target.
- The archive is displayed separately and excluded from the operational budget because its location and lifetime are explicitly user-controlled.

**Acceptance**

- Deterministic tests cross 90%, soft, and hard thresholds through DB, WAL, and SHM growth, prove the conservative batch bound and 64 KiB physical reserve, assert exact logical-page accounting separately, and exercise each pressure step in order.
- Tests preserve current limit/reset state, active-token delta correctness, and latest aggregate counters under severe pressure.
- After maintenance, the operational store is at or below the current mode's soft target unless a diagnosed invariant prevents it; in that case it is below the hard maximum with advanced ingestion paused.
- Use one seeded 30-day budget fixture: two rate-limit windows sampled every 5 minutes; 500 token turns/day; 14 cumulative samples/turn; 12 safe dimensions chosen from 64 repeated sets; and 10,000 performance/session events/day in Detailed mode. After lifecycle enforcement and checkpoint, Lightweight remains below 100 MiB and Detailed Analytics remains at or below 500 MiB.

**Depends on:** `STORAGE-20260717-03`.

### [x] `STORAGE-20260717-05` — Failure-safe migration and physical reclamation

**Status:** `completed` — implementation and phase-injection coverage are present in `a24b5b5` with recovery fixes through `d69a6f7`; failpoint tests, copied-production recovery, live migration, canonical-file reopen, and integrity checks passed on July 26, 2026.

**Outcome:** logical cleanup returns real disk space without risking the user's only valid history database.

**Requirements**

- Add a maintenance mode that coalesces requests, pauses collectors, rejects new writer work with a retryable state, drains the serialized writer, checkpoints WAL, and closes cached writer/read-only dashboard connections before file replacement.
- Enable incremental auto-vacuum for new/rebuilt v3 databases and reclaim a bounded number of pages after later lifecycle passes.
- Offer full physical optimization only when reclaimable space is at least 64 MiB and at least 20% of the database. It may run automatically only for schema-v3 migration, validated backup restore, or hard-budget recovery while the app is idle. Ordinary lifecycle passes use bounded incremental vacuum; all other full rebuilds require `Optimize Now`.
- Preflight same-volume free space against estimated compacted live pages plus WAL and a 25% safety margin. If insufficient, skip safely, continue core status, and report the required versus available space.
- Build with `VACUUM INTO` in the Application Support directory. Validate schema version, expected tables/indexes, aggregate invariants, `quick_check`, and `foreign_key_check` before replacement.
- Use a same-volume atomic replacement primitive that installs the validated candidate at the canonical path while retaining a rollback item; the canonical path must never be intentionally absent between two independent renames. Reopen both writer and read-only query paths, rerun invariants, then delete the rollback item. Any failure before verified reopen leaves or restores one valid canonical database according to the journal.
- On launch, clean abandoned unvalidated temporary files and resume or roll back from a durable maintenance journal. Never guess from filenames alone.
- Keep the status item responsive throughout migration. Expose compact progress and a retryable error in Settings; do not block app launch on the multi-gigabyte backfill/rebuild.

**Acceptance**

- Failure injection after maintenance entry, WAL checkpoint, temporary creation, rebuild, validation, atomic replacement, and reopen leaves exactly one valid canonical database plus at most one journaled rollback item.
- Repeated cancellation/relaunch is idempotent and never loses a committed sample or archive.
- When preflight, rebuild, or pre-replacement validation fails, retained application rows and query results remain logically equivalent. Compare canonical-file checksums only from the defined post-checkpoint boundary, since WAL checkpointing and maintenance-journal metadata may legitimately change bytes.
- A successful run reduces physical bytes, has no unexpected WAL growth, and returns identical retained dashboard/aggregate snapshots.

**Depends on:** `STORAGE-20260717-04`.

### [x] `STORAGE-20260717-06` — Bounded imports and separate historical archives

**Status:** `completed` — implementation and archive/restore coverage are present in `a24b5b5`; cancellation, validation, replacement, isolation, compatibility, and canonical verification gates passed on July 26, 2026.

**Outcome:** manual imports cannot inflate the status-bar database indefinitely.

**Requirements**

- Rename `Import Recent Sessions...` to `Import Last 7 Days...`, require Detailed Analytics, stream into the operational v3 schema, and enqueue lifecycle/budget maintenance on completion.
- Replace `Import All History...` with `Build Historical Archive...`. This action does not require live Detailed Analytics collection. Use a save panel and write a separate schema-v3 token-history SQLite file at the user-selected location.
- Build an archive transactionally through a sibling temporary file. Cancellation/failure removes the partial file; success validates and atomically publishes it.
- Archives are metadata-only, normalized, query-compatible, immutable after completion, opened read-only only when the user chooses one, and closed when its dashboard window closes. They never receive capture or maintenance coordinators. They expose aggregate Token History and Token Dashboard only; no unsupported Performance view is synthesized.
- Add `Open Archive...` plus an explicit Operational/Archive source selector in the supported token views. Archive viewing cannot alter the operational DB, start collectors, or change the Detailed Analytics preference.
- Show archive path and size separately and provide `Export Archive...`, `Reveal Archive`, `Close Archive`, and confirmed `Delete Archive` actions. Deletion is limited to the exact selected archive after signature/schema validation.
- Rebuilding to an existing path requires explicit replacement confirmation and uses the same sibling-temporary validation plus atomic replacement contract. It never appends to or silently overwrites an existing file.
- Keep operational backup import/export compatible with v2 and v3. Restore into an offline candidate database, normalize, enforce current retention/budget, physically optimize if eligible, and validate it before atomically publishing it as the operational store and reporting success.
- Keep archives and operational backups as distinct formats/flows; do not silently restore an archive into live collection.

**Acceptance**

- All-history archive creation leaves operational row counts and bytes unchanged apart from bounded diagnostic metadata.
- Archive creation/open/query/close/reopen is equivalent to v3 operational token analytics for the same source data; rebuilding to a new path is deterministic, while existing-path replacement follows the explicit confirmation contract.
- Cancellation, insufficient space, malformed source, wrong schema, validation failure, and delete-path substitution cannot damage the operational DB or an existing archive.
- Operational recent import cannot report success above the active hard maximum and only enqueues maintenance. Backup restore completes normalization, retention, budget enforcement, eligible optimization, and validation on its offline candidate before atomic publication and success.

**Depends on:** `STORAGE-20260717-05`.

### [ ] `STORAGE-20260717-07` — Simple storage UI, accessibility, and documentation

**Status:** `parked` — implementation, documentation, accessibility text, deterministic Debug fixtures, and canonical verification pass; only the unlocked-session native inspection remains.

**Current blocker (July 26, 2026):** source/tests/docs and deterministic fixture coverage pass, but the current macOS session is at the password-protected login screen. Computer Use, the installed app's exact accessibility element, Launch Services de-duplication, and the app's real Settings responder were each exercised safely; macOS will not expose the Settings/History/dashboard windows until the owner unlocks the session. No password was requested or handled. Only the frozen light/dark, size, keyboard, and accessibility click-through remains. This blocks no source work and only the corresponding native-inspection gate in `STORAGE-20260717-08`. Resume by unlocking macOS, then inspect the already-installed `d69a6f7` fixtures and production surfaces; no product or engineering decision is required.

**Outcome:** storage behavior is understandable without turning Settings or the popover into a database console.

**Settings > Data contract**

- Lead with the `Detailed Analytics` toggle and a compact line such as `Storage: 82 MB (250 MB maximum)` for the operational store.
- State the fixed retention policy in plain language and show last successful maintenance plus a concise active/progress/failure state.
- Provide `Optimize Now`, `Export Backup...`, and confirmed `Clear Analytics Data...`. Clearing analytics removes detailed dimensions, performance, session-timing, thread-catalog, model-capability, and related advanced catalogs only; it preserves preferences, rate-limit History, the 7-day lightweight token trend/current-day fallback, current limit/reset state, and independently managed archives.
- When an archive is open, show its name/path/size and the archive actions from `STORAGE-20260717-06` separately.
- Put raw database location, source coverage, capture-state details, payload audits, remote-control diagnostics, catalogs, and similar developer tooling under a collapsed `Advanced` disclosure. Launch may read bounded cached warning state and perform only the source/app-server health work required for core status; full remote-control, payload, coverage, catalog, and diagnostic probes wait until `Advanced` is expanded.
- Remove the raw-retention picker and all “rollups are kept indefinitely” language.
- When Detailed Analytics is off, explain that detailed collection is off. Retained operational dashboards remain read-only and show `Collection paused`; an empty dashboard offers one enable action without alarmist copy or dark patterns. Explicit archives remain readable independently.
- Keep storage status out of the normal status title and popover. The popover remains focused on limits, resets, freshness, and the established actions.

**Documentation and accessibility**

- Update `README.md`, privacy/local-data wording, data-management help, import/archive wording, backup compatibility, uninstall behavior, and any release notes affected by the new defaults.
- Add stable accessibility labels/help for the toggle, meter, maintenance status/progress, archive selector, and destructive confirmations. Preserve keyboard navigation and reduced-motion behavior.
- Keep errors actionable: what failed, whether data is safe, what will retry automatically, and the single available user action. Do not expose SQL or private paths in ordinary copy.

**Acceptance**

- View-model tests cover default/persistence, target/maximum formatting, reclaimable/maintenance states, advanced lazy loading, archive state, destructive confirmations, and accessibility text.
- Add a non-shipping deterministic state renderer or injected Debug/test fixture for Lightweight, Detailed Analytics, migrating, over-budget/paused, insufficient-space, archive-open, empty, and failure states; never induce real disk/database failures for visual QA.
- Native inspection covers those injected states in light and dark appearances at Settings 760x700; History 700x520 and 880x640; Token Dashboard 1120x560 and 1280x720; and Performance Dashboard 1280x680 and 1360x760.
- README and UI agree exactly on mode defaults, fixed tiers, budgets, archive isolation, privacy, backup behavior, and uninstall data retention.

**Depends on:** `STORAGE-20260717-06`.

### [ ] `STORAGE-20260717-08` — Full verification, production-copy rehearsal, installation, and soak

**Status:** `parked` — every automated, migration, storage, install, provenance, launch-latency, process-cleanup, and resource-soak gate has passed. The remaining native surface inspection and same-process UI-toggle proof inherit the unlocked-login requirement recorded in `STORAGE-20260717-07`.

**Current blocker (July 26, 2026):** the installed app cannot expose interactive windows while macOS is at the password-protected login screen. A real persisted-mode relaunch proved Detailed Analytics starts every advanced collector and the final Lightweight relaunch proved all advanced capture timestamps stop while core capture continues, but the acceptance wording additionally requires the toggle transition in the same process. Resume after the owner unlocks macOS: run the native fixture matrix, toggle Detailed Analytics on and back off in the live Settings window, verify the already-covered collector transition without relaunch, then check `-07` and `-08`. No code change or product decision is currently indicated.

**Outcome:** the initiative ships only after proving correctness, substantial storage reduction, lightweight runtime behavior, and safe migration on production-shaped data.

**Automated gates**

- Add focused suites for collection policy/composition, scheduled lifecycle, tiered rollups, schema-v3 migration, dimension sets, budgets, physical optimization, archive import, backup compatibility, and Data UI state.
- Extend migration interruption coverage in `UsageHistoryStoreMigrationTests`, storage/data-management coverage in `UsageHistoryStoreDataManagementTests`, token/retention parity in `UsageHistoryStoreTokenTests`, importer coverage in `CodexSessionTokenBackfillTests`, and index/latency coverage in `UsageHistoryPerformanceRegressionTests`.
- Run the production-shaped fixture from `STORAGE-20260717-03` through migration, retention, budget pressure, checkpoint, optimization, export/import, and reopen. Record per-object and total before/after bytes plus aggregate parity.
- Run `scripts/verify.sh` with all tests, analyzer, warning gate, Release build, source-bundle finalization/validation, coverage, and retained failure evidence.

**Real-data safety gate**

- Before the installed app touches the live 2.9 GiB store, use the SQLite backup API to create a consistent local rehearsal copy. Do not copy an open database with a plain filesystem copy and do not place user data in the repository/evidence bundle.
- Record only sanitized aggregate evidence: schema/page counts, object bytes, row/cardinality counts, token/performance sums, dashboard exports, migration journal stages, `quick_check`, and `foreign_key_check`.
- Migrate/retain/normalize/optimize the copy first. It must preserve retained aggregates, reduce dimension object bytes by at least 80%, and remain below the 250 MiB Lightweight hard maximum; at or below the 100 MiB target is the preferred pass. If a protected core invariant keeps it above 100 MiB, record that invariant and keep optional/advanced ingestion paused until later maintenance reaches the target. Any parity, integrity, or hard-maximum failure blocks live migration but not completion of unrelated code/tests.
- Let the installed app migrate the real store only after the rehearsal passes. Keep the rollback copy until the new database successfully reopens and passes the same invariant checks, then remove it automatically.

**Installed-app evidence**

- Install from source with `./install.sh` and verify the running executable is `/Users/farzadmahmoodinobar/Applications/CodexStatusBar.app/Contents/MacOS/CodexStatusBar`.
- Prove first menu title within 3 seconds and correct 5h/7d/Tightest/reset/account-token behavior during migration and after completion.
- In Lightweight, a 6-minute probe must show the launch and 5-minute live-token checks but zero advanced-capture writes. For the idle soak, warm for 2 minutes, checkpoint/truncate WAL, then sample every 10 seconds for 10 minutes. Compare logical live bytes plus post-checkpoint DB/WAL/SHM at the start and end; growth must be no more than 1 MiB.
- Measure every process owned by the status app, including its helper/app-server, with macOS `footprint` and process CPU sampling over the same soak. The combined physical-footprint p95 must be at most 100 MiB; combined CPU median must be at most 1% and p95 at most 5%, excluding one separately identified scheduled-refresh sample.
- Enable Detailed Analytics and prove all intended collectors write; disable it and prove subsequent advanced writes stop in the same process.
- Inspect the native Settings/Data, History, dashboard gating, maintenance, archive, error, and accessibility states through the deterministic non-shipping fixtures and exact sizes/appearances in `STORAGE-20260717-07`.
- Verify one clean installed app instance, no orphan helper/app-server owned processes after quit/relaunch, clean repository state, committed backlog closure, and successful push to `main`.

**Depends on:** `STORAGE-20260717-01` through `STORAGE-20260717-07`.

## Completed in this drain

### Intake

- [x] `INTAKE-20260712-01` — Rate-limit windows are classified by exact duration rather than primary/secondary position. Single-window, reversed-slot, nonstandard, missing, and fractional-minute payloads remain correctly labelled without guessing. Completed in `310f036`.
- [x] `INTAKE-20260712-02` — Menu-bar account-token data now refreshes on a five-minute cadence, manual Refresh bypasses the cache, live local capture remains network-free, and tooltip/accessibility detail identifies source day, fetched age, UTC fallback, stale cache, and refresh failure. Concurrent fetches coalesce and obsolete async loads cannot overwrite newer state. Completed in `005036f`.

### Audit program

Items `AUDIT-20260710-01` through `AUDIT-20260710-15` were reviewed against the reference code, implemented, tested, documented, committed, and pushed in `a697cc3`:

1. Canonical executable discovery and bounded capability probes.
2. Coalesced app-server lifecycle, request deadlines, cancellation, and owned-process retirement.
3. Destructive-path guards plus transactional source install/uninstall behavior.
4. Fail-closed in-app update provenance, signer continuity, digest, version, and build checks.
5. Shared source/public bundle finalization, validation, fingerprints, and complete app-icon assets.
6. Transactional in-app replacement with verification, relaunch confirmation, and rollback.
7. Resumable release preparation and publication source while keeping the workflow disabled.
8. Configurable raw telemetry retention with durable bounded hourly rollups and cumulative baselines.
9. Shared serialized SQLite writer, fallback recovery, and transactional schema-v2 migrations.
10. Bounded incremental large-session tailing, persisted cursors, and oversized-line recovery.
11. Sanitized persisted/exported Git remote identity with migration and backup coverage.
12. Reachable, lazy, and accessible History/Settings/popover/status-item surfaces.
13. Production `CodexUsageCore` module extraction and real app-wiring test coverage.
14. Canonical non-publishing verification and read-only CI with retained failure evidence.
15. README, release, security, contribution, privacy, retention, uninstall, and interaction documentation aligned to the accepted code.

## Verification recorded during the drain

### Lightweight storage implementation and live migration — July 26, 2026

- Implementation/recovery commits `f950d9f`, `94771c9`, and `d69a6f7` are pushed on top of `a24b5b5`. Focused migration, lifecycle, collection-policy, budget, archive, UI-state, recovery, and query-plan suites passed. `./scripts/verify.sh` then passed the complete test suite, analyzer, warning and coverage gates, universal Release build, and source-bundle finalization/validation.
- A SQLite-backup-API copy of the live schema-v2 store was migrated, retained, normalized, optimized, reopened, and maintained twice in isolation. It preserved 1,006,908 represented token samples and exact retained token-component totals, passed `quick_check` and `foreign_key_check`, finalized schema v3 without legacy dimension storage, reduced dimension objects from 3,834,564,608 bytes to 69,632 bytes (99.998% reduction), and reduced total optimized storage by 98.392%.
- Only after rehearsal passed, a fresh SQLite-backup-API safety copy was created and validated. `./install.sh` installed clean source commit `d69a6f7`; the installed app migrated the live store to schema v3 and reclaimed 4,766,814,208 bytes. The operational DB/WAL/SHM family is approximately 98 MiB, below the 100 MiB Lightweight target, with `quick_check=ok`, zero foreign-key violations, and idle maintenance.
- Installed provenance validates as a clean `main` source checkout at `d69a6f7`. The newest Lightweight relaunch produced a valid menu title in 1.381 seconds. Detailed-mode relaunch started turn-performance, session-timing, thread-catalog, and model-capability collectors; the final Lightweight relaunch advanced core token capture while all four advanced capture timestamps remained unchanged.
- The 10-minute installed Lightweight soak sampled 61 times: combined CPU median/p95 were 0.0%/0.0%, owned-process physical-footprint p95 was 25 MiB, logical database growth was 8 KiB, and total post-checkpoint DB/WAL/SHM growth was 683,920 bytes. No advanced writes occurred and the live token check advanced on the five-minute cadence.
- One installed app and one direct child app-server are running; earlier relaunch children retired. The only remaining evidence is the native light/dark/size/keyboard/accessibility fixture matrix and same-process Settings toggle, parked above because macOS is at its password-protected login screen.

### Lightweight storage drain — July 19, 2026

- Implementation checkpoint `a24b5b5` is pushed to `main`. Swift parser checks, focused storage-core type-checking, project-file validation, shell syntax, release-script fixtures, and `git diff --check` passed.
- `scripts/measure_storage_fixture.py` passed the frozen 10,000-turn, 140,000-sample, 1,680,000-dimension synthetic benchmark. Dimension objects fell from 466,599,936 bytes in v2 to 188,416 bytes in v3 (99.96% reduction); total optimized v3 size was 49,926,144 bytes versus 514,957,312 bytes for v2 (9.70%). Evidence: `/tmp/codex-storage-fixture-20260719.json`.
- The final `./scripts/verify.sh` attempt was rejected before execution by the external approval service because the account execution quota is exhausted. No test, analyzer, Release bundle, migration rehearsal, install, native inspection, or soak claim is made from that attempt.
- The unchanged installed source bundle at `~/Applications/CodexStatusBar.app` validated successfully against its recorded clean `ee47daa` provenance. It was not running, and the final `open` request was rejected by the same quota gate, so no launch claim is made.
- Resume condition: execution quota or explicit execution approval becomes available. Then run `./scripts/verify.sh`; rehearse v3 on a SQLite-consistent live-store copy; require parity, integrity, normalization, query-plan, latency, and `<250 MiB` gates; install only the resulting verified source bundle; run installed mode/runtime/UI/storage/resource soaks; then check `STORAGE-01` through `-08` and remove their `parked` labels.

- Canonical verifier after the audit program and duration fix: 525 tests, analyzer, warning gate, universal arm64/x86_64 Release build, source-bundle finalization/validation, and 63.65% production-core coverage. Evidence root: `/private/tmp/codex-owner-all-final-20260712-180301/DerivedData`.
- Token-freshness focused suites: 68 tests passed. Full imported-module XCTest suite: 534 tests passed. Evidence root: `/tmp/codex-token-freshness-20260712`.
- Independent reviews found no remaining blocking issue in either intake implementation.

## Completed decision

### `DECISION-20260711-01` — Public repository license

- **Status:** `completed` on July 13, 2026.
- **Decision:** MIT License, selected by the owner from Codex's permissive-license recommendation.
- **Repository contract:** The canonical license text is in `LICENSE`; README and contribution guidance link to it.

## Conditional watchlist

These are not active implementation items. Codex must not work on them until the stated evidence gate becomes true.

### Live token payload evidence

- **Status:** `watchlist`; gate currently false. No `live-token-payload-audit.json` exists as of July 12, 2026.
- **Gate:** A real sanitized `thread/tokenUsage/updated` sample appears in Settings Data or `~/Library/Application Support/CodexStatusBar/live-token-payload-audit.json`.
- Until then, retain local log/session capture as the evidence-backed source and do not add passive-payload storage or UI.
- When true, create a new intake item from sanitized field evidence before implementation.

### Codex agent-job tables

- **Status:** `watchlist`; gate currently false. `agent_jobs` and `agent_job_items` both contain zero rows in `~/.codex/state_5.sqlite` as of July 12, 2026.
- **Gate:** Either table contains real rows.
- Until then, do not add storage or UI for these tables.
- When true, create a metadata-only intake item limited to status, timestamps, counts, and thread linkage. Exclude instructions, payloads, outputs, schemas, local file contents, and potentially private error text.

## Historical reference

- `git show 43bd86d:BACKLOG.md` contains the detailed June/July audit snapshots and former completed-work ledger.
- `archive/2026-06-13-app-server-account-usage-read.md` preserves the design boundary between server/account metrics and local captured analytics.
- Current source, tests, persisted state, and runtime evidence take precedence over historical snapshots.
