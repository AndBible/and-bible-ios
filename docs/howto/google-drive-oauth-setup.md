# Google Drive OAuth Setup

This document closes the last repo-local gap for the Google Drive sync backend: how to supply real iOS OAuth values to the existing code without committing environment-specific configuration.

## Current Status

Google Drive sync is code-complete enough for local and CI validation, but it is currently parked on one external dependency:

- a real iOS Google OAuth client for the `org.andbible.ios` bundle

Already implemented in the repo:

- Google Drive transport and adapter
- Google Sign-In auth service
- settings UI and runtime wiring
- background refresh scheduling
- simulator-backed sync and auth coverage
- secret-free bundle placeholders
- local xcconfig override path for non-committed credentials

Still outstanding before live end-user validation:

- provision the real iOS OAuth client
- populate local credential overrides
- run live sign-in and end-to-end sync validation against a real Google account

## UX Contract

There are two separate audiences here, and they must not be conflated.

### Developer / Release-Engineering Responsibility

Developers provide the app-level Google OAuth configuration once for the AndBible iOS bundle.

That is what this document covers:

- `GOOGLE_DRIVE_CLIENT_ID`
- `GOOGLE_DRIVE_SERVER_CLIENT_ID`
- `GOOGLE_DRIVE_REVERSED_CLIENT_ID`

Those are build-time application settings, not user-entered data.

### End-User Responsibility

End users should only perform the normal Google account sign-in flow inside the app.

The intended user-facing flow is:

1. Open `Settings > Sync`
2. Choose `Google Drive`
3. Tap `Sign In to Google Drive`
4. Choose a Google account
5. Grant access
6. Enable one or more sync categories

End users must never be asked to:

- look up an OAuth client ID
- enter a callback URL scheme
- paste Google Cloud Console values into the app

If the app shows `Google Drive sign-in is not configured for this build.`, that is a build/release problem, not a user workflow.

## iOS Deviation From Android

The user-facing UX target remains Android-aligned:

- the user taps a Google Drive sign-in action
- the app presents Google account/consent UI
- the app receives Drive-authorized access
- the app syncs against Google Drive `appDataFolder`

The implementation detail differs across platforms.

### Android

Android already uses Google OAuth and Drive APIs. It does not ask the user for a Google username/password for direct API login.

In the current Android code:

- the app starts Google sign-in through One Tap
- the adapter is built with a compiled client ID constant
- Drive access is authorized with `DriveScopes.DRIVE_APPDATA`
- all sync file operations run through the Google Drive API

### iOS

iOS uses the same high-level model:

- app-level Google OAuth registration
- interactive Google sign-in
- Drive API access with the `drive.appdata` scope

But iOS requires one additional bundle-time constraint:

- the OAuth client ID and reversed callback scheme must be present in the app bundle so Google Sign-In can return control to the app

That is why iOS needs:

- `GIDClientID`
- optional `GIDServerClientID`
- `CFBundleURLTypes` entry for the reversed client ID

### Practical Disposition

This is an implementation deviation, not a UX deviation.

The intended shipped behavior is:

- Android: user taps sign-in and approves Google access
- iOS: user taps sign-in and approves Google access

The internal setup differs:

- Android currently carries its Google client configuration in the shipped app code/resources
- iOS must carry its Google client configuration in bundle settings and URL-scheme metadata

The iOS app should therefore never expose OAuth setup to end users. That setup belongs to the app build.

## Current Code State

The app already has the Google Drive runtime pieces wired:

- `AndBible/Info.plist` exposes:
  - `GIDClientID = $(GOOGLE_DRIVE_CLIENT_ID)`
  - `GIDServerClientID = $(GOOGLE_DRIVE_SERVER_CLIENT_ID)`
  - `CFBundleURLTypes -> $(GOOGLE_DRIVE_REVERSED_CLIENT_ID)`
- `AndBible.xcodeproj/project.pbxproj` defines blank defaults for those three build settings in Debug and Release.
- `Sources/BibleCore/Sources/BibleCore/Services/GoogleDriveAuthService.swift` validates the bundle configuration and leaves the app in an explicit `.notConfigured` state when values are blank or invalid.
- `AndBible/AndBibleApp.swift` restores cached sign-in state at launch and forwards OAuth callback URLs back to Google Sign-In.
- `Sources/BibleUI/Sources/BibleUI/Settings/SyncSettingsView.swift` already exposes the user-facing Google Drive sign-in and per-category sync flow.

No additional code changes are required to test live Google Drive sign-in.

## Required External Values

The app expects three build-time values:

1. `GOOGLE_DRIVE_CLIENT_ID`
2. `GOOGLE_DRIVE_SERVER_CLIENT_ID`
3. `GOOGLE_DRIVE_REVERSED_CLIENT_ID`

### `GOOGLE_DRIVE_CLIENT_ID`

This must be a real iOS OAuth client ID for the AndBible iOS bundle identifier:

- `org.andbible.ios`

If this value is blank, `GoogleDriveAuthService` treats the build as not configured and the sync UI will show:

- `Google Drive sign-in is not configured for this build.`

### `GOOGLE_DRIVE_SERVER_CLIENT_ID`

This is optional in the current code. `GoogleDriveAuthService` accepts a missing or blank server client ID.

If you do not need server-side token exchange, leave it blank.

### `GOOGLE_DRIVE_REVERSED_CLIENT_ID`

This must match the reversed callback scheme derived from the client ID.

The app computes it the same way Google Sign-In expects: split the client ID on `.` and reverse the components.

Example shape:

- client ID: `1234567890-abcdefg.apps.googleusercontent.com`
- reversed scheme: `com.googleusercontent.apps.1234567890-abcdefg`

If this scheme is missing from `CFBundleURLTypes`, `GoogleDriveAuthService` will surface:

- `Google Drive sign-in callback is not configured for this build.`

## Where To Set The Values

The recommended local path is an ignored xcconfig file, not hand-editing the project file.

### Recommended: local xcconfig override

1. Copy:

- `Config/Secrets.example.xcconfig`

to:

- `Config/Secrets.xcconfig.local`

2. Fill in:

- `GOOGLE_DRIVE_CLIENT_ID`
- `GOOGLE_DRIVE_SERVER_CLIENT_ID`
- `GOOGLE_DRIVE_REVERSED_CLIENT_ID`

3. Build the `AndBible` app target normally.

The app target now includes `Config/Secrets.xcconfig.local` automatically for both Debug and Release builds through:

- `Config/AndBible-Debug.xcconfig`
- `Config/AndBible-Release.xcconfig`

The local file is ignored by git, so real credentials stay out of the repo.

### Alternative: override in Xcode build settings

If you need a one-off manual override, you can still set the values directly in Xcode:

1. Open `AndBible.xcodeproj`
2. Select the `AndBible` target
3. Open `Build Settings`
4. Search for `GOOGLE_DRIVE_`
5. Override these three settings for your local configuration:
   - `GOOGLE_DRIVE_CLIENT_ID`
   - `GOOGLE_DRIVE_SERVER_CLIENT_ID`
   - `GOOGLE_DRIVE_REVERSED_CLIENT_ID`

The committed project keeps empty defaults on purpose so repo builds stay secret-free and unconfigured builds fail safely instead of attempting a broken OAuth flow.

Release expectation:

- development and CI builds may remain intentionally unconfigured
- user-facing builds that advertise Google Drive sync should ship with real values populated

## Expected Runtime Behavior

With valid bundle values in place:

1. The app starts normally.
2. `AndBibleApp` calls `restorePreviousSignInIfNeeded()` during startup.
3. `Settings > Sync` can switch the backend picker to `Google Drive`.
4. The Google Drive status row should no longer show the "not configured" message.
5. Tapping `Sign In to Google Drive` should present Google Sign-In.
6. After consent, the status should become:
   - `OK` when the cached account already has the Drive scope
   - `Google Drive permission is required` only if an account exists without the required Drive scope

The required scope is:

- `https://www.googleapis.com/auth/drive.appdata`

The sync backend uses Google Drive's hidden app-private storage:

- `appDataFolder`

That means synced files do not appear in the user's normal Drive file list.

## In-App Validation Path

After setting the build values, validate the live flow in the simulator:

1. Build and run the app on a simulator.
2. Open `Settings`.
3. Open `Sync`.
4. Change `Synchronization Backend` to `Google Drive`.
5. Verify the status row is no longer `Google Drive sign-in is not configured for this build.`
6. Tap `Sign In to Google Drive`.
7. Complete Google authentication.
8. Confirm the status row becomes `OK`.
9. Enable one category such as bookmarks or workspaces.
10. Confirm the first sync pass no longer fails on auth and proceeds into the remote bootstrap flow.

The first category enablement follows the Android-style bootstrap path already implemented in `SyncSettingsView` and `RemoteSyncSynchronizationService`:

- adopt existing remote data when a same-named folder is found
- create a new remote folder and upload `initial.sqlite3.gz` when no remote folder exists

## Troubleshooting

### Status says "not configured"

Cause:

- `GIDClientID` resolved to blank after build-setting expansion

Check:

- `GOOGLE_DRIVE_CLIENT_ID` is set for the active configuration
- the value is reaching `AndBible/Info.plist`

### Status says callback is not configured

Cause:

- the URL scheme in `CFBundleURLTypes` does not match the reversed client ID

Check:

- `GOOGLE_DRIVE_REVERSED_CLIENT_ID` exactly matches the reversed form of `GOOGLE_DRIVE_CLIENT_ID`

### Sign-in UI does not appear

Cause:

- no presenting view controller was available at sign-in time

Current surfaced error:

- `Google Drive sign-in could not present authentication UI.`

This is a runtime presentation problem, not a credential problem.

### Status remains signed out after a successful build

Cause:

- the bundle is configured correctly, but no Google session has been established yet

Expected fix:

- tap `Sign In to Google Drive`

### Sync starts but later fails remotely

At that point OAuth is no longer the likely problem. The next place to inspect is the Google Drive transport and sync pipeline:

- `Sources/BibleCore/Sources/BibleCore/Services/GoogleDriveSyncAdapter.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSynchronizationService.swift`

## What Still Remains Outside The Repo

The remaining Google Drive work is operational, not code-side:

- provision a real iOS OAuth client for `org.andbible.ios`
- set the three build values locally
- perform live end-to-end sign-in and sync validation against a real Google account

Until those values exist, the repo is expected to stay in the explicit "not configured" state for Google Drive.
