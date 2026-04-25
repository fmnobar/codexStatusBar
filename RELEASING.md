# Releasing Codex Status Bar

This project currently uses the local script workflow for public releases.
Release assets are zip files containing `CodexStatusBar.app`. The public
distribution path should use Developer ID signing and notarization.

The GitHub Actions release workflow is intentionally disabled to avoid Actions
notifications. Its source is kept at `.github/workflows/release.yml.disabled`
for future reference; rename it back to `.github/workflows/release.yml` only
when CI-based releases are needed again.

## Requirements

- macOS
- Xcode 17+
- A clean `main` branch
- Access to create GitHub Releases in `fmnobar/codexStatusBar`
- For signed releases: a valid Developer ID Application certificate
- For notarized releases: a notarytool keychain profile

## Disabled GitHub Actions Release

The manual `Release` workflow is disabled. When enabled, it bumps versions,
runs validation and tests, builds a Developer ID signed and notarized app,
pushes the release commit and `vX.Y.Z` tag, and publishes the zip asset to a
GitHub Release.

Required repository secrets:

- `DEVELOPER_ID_APPLICATION`: exact certificate identity, for example
  `Developer ID Application: Your Name (TEAMID)`
- `DEVELOPMENT_TEAM`: Apple team ID
- `DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded Developer ID Application
  `.p12`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`: password for the `.p12`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization

To create the certificate secret, export the Developer ID Application identity
as a password-protected `.p12` from Keychain Access, then encode it:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Then add the copied value as `DEVELOPER_ID_CERTIFICATE_BASE64`.

To re-enable and run the workflow:

1. Rename `.github/workflows/release.yml.disabled` to `.github/workflows/release.yml`.
2. Commit and push that change to `main`.
3. Open GitHub Actions.
4. Select `Release`.
5. Choose `Run workflow` on `main`.
6. Enter `version` as `X.Y.Z` and `build` as a positive integer.
7. Optionally enter release notes. If blank, the workflow uses commit subjects
   since the previous `v*` tag.

The generated release uses:

- Tag: `vX.Y.Z`
- Title: `Codex Status Bar vX.Y.Z`
- Asset: `dist/CodexStatusBar-vX.Y.Z-buildN.zip`

The workflow uses `GITHUB_TOKEN` with `contents: write` to push the version
commit and tag. If branch protection blocks GitHub Actions from pushing to
`main`, either allow GitHub Actions to bypass the protection for this workflow
or use the local release flow below.

## Prepare A Release

Use semantic versions in `X.Y.Z` format. Tags must use the matching `vX.Y.Z`
format because the app checks GitHub Releases for updates.

For the local signed and notarized fallback path:

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

## Publish A Local Release

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
tags are not enough; the GitHub Release must be published. The disabled GitHub
Actions workflow can perform these publish steps automatically if it is
re-enabled.

## In-App Updates

The Updates settings tab reads the latest published GitHub Release and looks for
an asset named:

```text
CodexStatusBar-vX.Y.Z-buildN.zip
```

When that asset exists, the app can download it, verify a `sha256:` digest when
GitHub exposes one, unzip it, check the bundle identifier and version, validate
the app with `codesign` and `spctl`, then guide the user through replacing the
currently installed app. If the current app location is not writable, the app
reveals the verified download and leaves replacement manual.

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
