# Releasing Codex Status Bar

This project uses a local release workflow. Release assets are zip files
containing `CodexStatusBar.app`. The default path is unsigned for local testing;
the public distribution path should use Developer ID signing and notarization.

## Requirements

- macOS
- Xcode 17+
- A clean `main` branch
- Access to create GitHub Releases in `fmnobar/codexStatusBar`
- For signed releases: a valid Developer ID Application certificate
- For notarized releases: a notarytool keychain profile

## Prepare A Release

Use semantic versions in `X.Y.Z` format. Tags must use the matching `vX.Y.Z`
format because the app checks GitHub Releases for updates.

For the recommended signed and notarized release path:

```bash
git checkout main
git pull
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export DEVELOPMENT_TEAM="TEAMID"
export NOTARYTOOL_PROFILE="codex-status-bar"
scripts/prepare_release.sh 1.0.0 1 --signed --notarize
```

For an unsigned local validation build:

```bash
git checkout main
git pull
scripts/prepare_release.sh 1.0.0 1
```

`prepare_release.sh` will:

- update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
- run shell syntax checks
- run `git diff --check`
- run the Xcode test suite
- create `dist/CodexStatusBar-vX.Y.Z-buildN.zip`

## Signing And Notarization Setup

Install a Developer ID Application certificate in the login keychain, then use
its exact identity name in `DEVELOPER_ID_APPLICATION`. You can inspect local
signing identities with:

```bash
security find-identity -p codesigning -v
```

Create the notarytool profile outside the repo. Do not commit Apple ID,
app-specific password, issuer, key, or team credentials.

```bash
xcrun notarytool store-credentials codex-status-bar \
  --apple-id "you@example.com" \
  --team-id "TEAMID"
```

`scripts/package_release.sh --signed --notarize` builds with hardened runtime,
verifies the Developer ID signature, submits a temporary upload zip, staples the
accepted ticket to `CodexStatusBar.app`, validates the staple, then creates the
final GitHub Release zip.

## Publish

After release prep succeeds:

```bash
git status
git add CodexUsageMenuBar.xcodeproj/project.pbxproj
git commit -m "Bump version to X.Y.Z"
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

Then create a GitHub Release:

- Title: `Codex Status Bar vX.Y.Z`
- Tag: `vX.Y.Z`
- Asset: `dist/CodexStatusBar-vX.Y.Z-buildN.zip`
- Notes: summarize user-facing changes since the previous release

The app's live update checker reads GitHub's latest published release. Raw git
tags are not enough; the GitHub Release must be published.

## Validate The Artifact

To inspect a generated zip locally:

```bash
tmpdir="$(mktemp -d)"
ditto -x -k dist/CodexStatusBar-vX.Y.Z-buildN.zip "$tmpdir"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$tmpdir/CodexStatusBar.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$tmpdir/CodexStatusBar.app/Contents/Info.plist"
```

The app bundle should be present at:

```text
CodexStatusBar.app
```

For a signed release, also validate the unzipped app:

```bash
codesign --verify --deep --strict --verbose=2 "$tmpdir/CodexStatusBar.app"
xcrun stapler validate "$tmpdir/CodexStatusBar.app"
spctl -a -vv --type execute "$tmpdir/CodexStatusBar.app"
```

## Unsigned Fallback

The unsigned path remains available for local release workflow testing:

```bash
scripts/package_release.sh
```

Unsigned downloaded zips may trigger Gatekeeper warnings and should not be used
as the preferred public distribution artifact.
