# Backlog

## Done

- Usage history by time and model
  - Added local SQLite history recording for sampled usage percentages.
  - Added rolling day, week, month, and year chart views.
  - Added aggregate and per-model series when model buckets are available.
  - Added CSV export and clear-history controls.

## Next Candidates

- Improve History chart polish and interaction
  - Add point hover details, clearer empty states per range, and better legend behavior when many models exist.

- Add data-management preferences
  - Show history database location and size.
  - Add explicit raw-sample retention controls.
  - Add an import/export path for backup or migration.

- Validate model bucket behavior against live Codex data
  - Capture the real app-server bucket shape for current Codex model names.
  - Confirm whether per-model percentages are comparable across models or only independent quota signals.

- Add install/update visibility
  - Surface version/build info in the popover or History window.
  - Add a lightweight changelog section for user-facing feature changes.
