# Use App-Server Account Usage Read For Account Token Comparison

## Context

Codex 0.140 exposes a first-party app-server request, `account/usage/read`, in generated protocol output from:

```bash
/Applications/Codex.app/Contents/Resources/codex app-server generate-ts --out <dir>
```

The generated `GetAccountTokenUsageResponse` contains `summary` and bounded daily token buckets:

- `summary.lifetimeTokens`
- `summary.peakDailyTokens`
- `summary.longestRunningTurnSec`
- `summary.currentStreakDays`
- `summary.longestStreakDays`
- `dailyUsageBuckets[].startDate`
- `dailyUsageBuckets[].tokens`

The current app already has a generic app-server request path in `CodexAppServerClient.sendRequest(...)`, but Settings Data account-token comparison currently goes through `CodexProfileTokenUsageHTTPClient`, which calls `https://chatgpt.com/backend-api/wham/profiles/me` after retrieving auth through `getAuthStatus`.

## Requirements

### Problem Summary

The app uses a direct backend HTTP request for account/Profile token comparison even though the local Codex app-server now exposes a typed account usage request with equivalent token fields plus additional safe summary metrics.

### Product Goal

Settings Data should compare StatusBar local captured tokens with Codex account/server tokens through the first-party app-server interface where available, while preserving the existing clear distinction between local captured component totals and server/account token numbers.

### Scope

- Fetch account token usage through `account/usage/read`.
- Decode and store only safe account-usage metrics:
  - lifetime tokens
  - peak daily tokens
  - daily token buckets
  - longest running turn seconds
  - current streak days
  - longest streak days
- Keep the existing local comparison rows for all-time, current UTC month, and current UTC day.
- Add compact Settings Data rows for longest turn and streak metrics.
- Keep a compatibility fallback to the existing Profile HTTP path only if app-server account usage is unavailable or malformed.

### Non-Goals

- Do not change menu-bar token totals.
- Do not change local token storage/import semantics.
- Do not attempt to reconcile local captured tokens to server/account billing semantics.
- Do not store account identity, email, auth tokens, raw account payloads, or raw response JSON.
- Do not add a dashboard surface for server/account tokens in this pass.
- Do not remove the existing Profile token cache until compatibility behavior is proven.

### Constraints

- Preserve privacy boundaries already used by Profile token comparison.
- Use the existing `CodexAppServerClient` request pipeline.
- Preserve offline/no-auth/failure behavior in Settings Data.
- Persist bounded daily buckets only.
- Push and reinstall/relaunch after implementation.

### Required Behaviors

- When `account/usage/read` succeeds, Settings Data uses that snapshot for account-token comparison.
- When `account/usage/read` fails because the method is unavailable, malformed, or temporarily unsupported, Settings Data can fall back to the existing Profile HTTP fetch path.
- The UI labels account/server tokens separately from local captured tokens.
- New longest-turn/streak fields show unavailable placeholders when absent.
- Cached account usage remains bounded and has clear sync status/time/error.
- Manual refresh bypasses stale cache behavior.

### Edge Cases

- `dailyUsageBuckets` is null or empty.
- Summary fields are null.
- `bigint`-sized token counts exceed Swift `Int` but fit in `Int64`.
- App-server request returns JSON-RPC error for older Codex.
- App-server connection is unavailable but existing Profile HTTP path still works.
- No auth is available.

### Acceptance Criteria

- Existing Profile comparison tests still pass or are intentionally updated.
- New decoder/client tests cover app-server account usage success, partial/null payloads, and fallback.
- Settings Data shows server/account token totals, local captured totals, deltas, peak daily, longest turn, and streak metrics without raw account identity.
- Installed app relaunches and Settings Data renders the account-token section.

## Spec

### Architecture Choice

Use `CodexAppServerClient` as the primary `CodexProfileTokenUsageFetching` implementation, but change its implementation from direct Profile HTTP first to app-server `account/usage/read` first.

Keep `CodexProfileTokenUsageHTTPClient` as a fallback adapter for compatibility with older app-server builds. The store type can continue using the existing `CodexProfileTokenUsageSnapshot` name initially, but the user-facing copy should say Codex account/server tokens rather than Profile identity.

### Data Flow

1. Settings Data calls `profileTokenClient.profileTokenUsageSnapshot()`.
2. `CodexAppServerClient.profileTokenUsageSnapshot()` ensures app-server connection.
3. It sends:

```json
{ "method": "account/usage/read" }
```

4. It decodes the response into a sanitized account-usage response model.
5. It maps the response into the existing persisted snapshot shape, extended with optional longest-turn/streak fields.
6. If the app-server method fails for compatibility reasons, it falls back to `CodexProfileTokenUsageHTTPClient`.
7. `CodexProfileTokenUsageStore` persists the bounded snapshot and sync status.
8. `DataManagementSettingsViewModel` builds comparison rows against local component totals.

### Ownership Boundaries

- `CodexAppServerClient.swift`
  - owns app-server request execution and fallback ordering.
- `CodexRateLimitModels.swift`
  - owns account usage response decoding and domain snapshot mapping.
- `DataManagementSettingsView.swift`
  - owns Settings labels and additional display rows.
- `CodexProfileTokenUsageStore`
  - remains JSON-backed and bounded.

### Interfaces And Types

Add or extend internal-only types:

- `CodexAccountTokenUsageResponse`
- `CodexAccountTokenUsageSummary`
- `CodexAccountTokenUsageDailyBucket`
- Optional fields on `CodexProfileTokenUsageSnapshot`:
  - `longestRunningTurnSeconds`
  - `currentStreakDays`
  - `longestStreakDays`

Compatibility rule: existing JSON snapshots must decode with these fields absent.

### Persistence

No SQLite migration. The existing JSON store remains the persistence mechanism.

Persist only:

- bounded daily buckets
- lifetime tokens
- peak daily tokens
- longest running turn seconds
- current streak days
- longest streak days
- sync status/time/error

### UI Behavior

Settings Data section remains compact:

- Status
- Last sync
- Server lifetime
- Peak daily
- Current UTC day/month server tokens versus local captured totals
- Longest turn
- Current streak
- Longest streak
- Last error

Labels should say `Codex account tokens` or `Server account tokens`, not imply that they should equal local captured tokens.

### Failure Handling

- App-server unavailable: preserve current failure/no-auth state.
- `account/usage/read` JSON-RPC unsupported: fallback to Profile HTTP.
- Profile fallback unauthorized: retry once through existing refresh behavior.
- Malformed response: record failure unless fallback succeeds.

### Validation Strategy

Validation should prove:

- No account identity or auth fields enter stored models.
- App-server path and HTTP fallback both produce equivalent comparison rows when they contain equivalent token buckets.
- Local component totals are unchanged.

## Plan

### Summary

Replace direct Profile HTTP as the primary Settings Data account-token source with the new app-server `account/usage/read` request. Keep the existing HTTP Profile path as a compatibility fallback and extend Settings Data with safe longest-turn/streak metrics.

### Implementation Phases

1. Add app-server account usage models.
   - Add decoders for `account/usage/read` response shape.
   - Map camelCase app-server fields into the existing domain snapshot.
   - Add optional snapshot fields for longest turn and streaks with backward-compatible decoding.

2. Update `CodexAppServerClient`.
   - Make `profileTokenUsageSnapshot()` try `account/usage/read` first.
   - On unsupported/malformed compatibility failure, fall back to existing `CodexProfileTokenUsageHTTPClient`.
   - Keep `getAuthStatus` token flow only for fallback.

3. Update Settings Data presentation.
   - Rename relevant copy from Profile-specific wording to Codex account/server token wording.
   - Add longest turn/current streak/longest streak rows.
   - Preserve no-auth, stale, cached, refresh, and failure states.

4. Update tests.
   - Decoder tests for complete and partial app-server account usage payloads.
   - Client tests for app-server success, fallback, no-auth, and malformed response.
   - Store tests for backward-compatible JSON decode and bounded buckets.
   - View-model tests for new rows and copy.

5. Update `BACKLOG.md`.
   - Move the item to Done after implementation.
   - Reprioritize `Extend app-server notification audit for Codex 0.140 v2 surfaces`.

### Targeted Files

- `Sources/CodexUsageMenuBar/CodexAppServerClient.swift`
- `Sources/CodexUsageMenuBar/CodexRateLimitModels.swift`
- `Sources/CodexUsageMenuBar/DataManagementSettingsView.swift`
- `Tests/CodexUsageMenuBarTests/CodexRateLimitDecodingTests.swift`
- `Tests/CodexUsageMenuBarTests/UsageHistoryStoreDataManagementTests.swift`
- `Tests/CodexUsageMenuBarTests/UsageHistoryStoreTokenTests.swift` if comparison models need local-total assertions
- `BACKLOG.md`

### Test Plan

Run:

```bash
git diff --check
xcodebuild test -project CodexUsageMenuBar.xcodeproj -scheme CodexUsageMenuBar -destination 'platform=macOS'
```

### Manual Verification

After commit and push:

```bash
./install.sh
pgrep -fl CodexStatusBar
git rev-parse HEAD
plutil -extract gitCommit raw -o - /Users/farzadmahmoodinobar/Applications/CodexStatusBar.app/Contents/Resources/BuildFingerprint.json
```

Visible check:

- Menu-bar title is useful and not a silent `--` fallback.
- Settings > Data opens.
- Account-token section renders.
- Local captured tokens and Codex account/server tokens remain clearly separate.
- New longest-turn/streak rows show values or unavailable placeholders.

### Follow-Up

Next recommended backlog item after this lands:

`Extend app-server notification audit for Codex 0.140 v2 surfaces`
