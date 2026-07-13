# Backlog

Last reconciled: July 13, 2026 after resolving the final owner decision.

## Current status

- No executable engineering item remains in the canonical backlog.
- No blocked product or distribution decision remains. The repository is licensed under MIT.
- Public release, signing, notarization, tagging, upload, and publication were not performed. The release workflow remains disabled.
- Ordinary implementation is complete and pushed to `main`. The active owner task's final report carries the post-commit verifier, build-local UI, process-cleanup, and upstream-parity evidence.
- Historical detail remains available with `git show 43bd86d:BACKLOG.md`; do not restore the former audit queue or Done ledger here.

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
