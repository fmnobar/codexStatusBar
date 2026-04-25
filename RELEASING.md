# Releasing Codex Status Bar

This project uses a local release workflow. Release assets are unsigned zip files
containing `CodexStatusBar.app`; they are not Developer ID signed or notarized.

## Requirements

- macOS
- Xcode 17+
- A clean `main` branch
- Access to create GitHub Releases in `fmnobar/codexStatusBar`

## Prepare A Release

Use semantic versions in `X.Y.Z` format. Tags must use the matching `vX.Y.Z`
format because the app checks GitHub Releases for updates.

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

## Signing Status

The current release artifact is intentionally unsigned and not notarized. Users
may see macOS Gatekeeper warnings when opening a downloaded zip build. A future
workflow should add Developer ID signing and notarization before treating this as
a polished public distribution channel.
