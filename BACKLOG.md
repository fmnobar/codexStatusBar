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

## Next Candidates

- Review exported diagnostics and decide History chart semantics
  - Capture real diagnostics across a few usage changes.
  - Decide whether model series should remain independent lines or be presented as comparable contributors.
  - Update chart wording only after the real bucket behavior is confirmed.

- Improve History chart polish and interaction
  - Add point hover details, clearer empty states per range, and better legend behavior when many models exist.

- Add data-management preferences
  - Show history database location and size.
  - Add explicit raw-sample retention controls.
  - Add an import/export path for backup or migration.

- Add install/update visibility
  - Surface version/build info in the popover or History window.
  - Add a lightweight changelog section for user-facing feature changes.
