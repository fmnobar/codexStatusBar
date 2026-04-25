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

- Add GitHub Actions release automation
  - Added a manual release workflow for signed, notarized GitHub Release assets.
  - Kept local release scripts as the source of truth while adding CI keychain and notary support.
  - Documented required repository secrets and protected-branch behavior.

## Next Candidates

- Add in-app update download/install flow
  - Let the app download the latest GitHub Release asset and guide the user through replacing the installed app.
  - Keep user confirmation and macOS trust prompts explicit.
