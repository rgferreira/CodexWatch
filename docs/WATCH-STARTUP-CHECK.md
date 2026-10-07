# Watch startup check

The diagnostic section checks an installed Watch app that does not open. Its
only action on the app is a single bounded foreground launch. The recovery
section continues the same check with an explicitly requested signing renewal
and in-place update. Raw device inventories and preference backups stay in the
private local forensic store, outside Git.

## Recorded check: 2026-10-07

Checked at approximately 21:36 Europe/Madrid, using the physical Watch:

- CoreDevice reported the Watch available and paired; the lock-state capture
  reported it unlocked.
- `com.rgferreira.CodexWatchStandalone` remained installed, version 0.8.1,
  build 49, visible and developer-installed. No Codex Watch process appeared
  in the captured process inventory.
- The provisioning-profile inventory completed successfully and returned no
  provisioning profiles. An empty inventory alone is not sufficient to
  diagnose expiry.
- One launch attempt failed with CoreDevice error 10002, followed by
  `FBSOpenApplicationErrorDomain` code 3 (`Security`). watchOS rejected the
  signature, entitlements or trust before the app could start.
- The retained signed build-49 artifact passed `codesign --verify --deep
  --strict`. Its embedded profile was created at `2026-09-28T23:11:39Z` and
  expired at `2026-10-05T23:11:39Z`: **29 September 01:11:39 to 6 October
  01:11:39 Europe/Madrid**. The artifact identifies itself as the same bundle
  and build as the installed app; the installed binary was not extracted for
  a byte-for-byte comparison.

The evidence identifies expired development provisioning as the explanation
for this launch failure. This is distinct from the earlier AppConduit removal:
the app is still installed. The seven-day profile interval began when the
profile was issued, so installation on 3 October did not provide seven new
days. Recovery requires a renewed development profile and a signed update.
No recovery or application changes were performed during the initial diagnostic
check. The subsequently requested recovery is recorded below.

Snapshot label: `20261007T193551Z-startup-check-20261007`, under
`~/Library/Application Support/CodexWatch/Forensics/`. The snapshot includes
inventory output, per-command exit codes and SHA-256 hashes; the launch error
and retained-artifact checks are recorded above separately.

## Repeatable steps

1. Run `xcode-select -p` and `xcrun devicectl list devices`. Select the physical
   Watch explicitly. A simulator does not validate the installation. An
   unavailable device is an inconclusive check, not evidence of removal.
2. Run the existing read-only capture from the repository root:

   ```sh
   Tests/capture_watch_install_state.sh '<physical Watch UDID>' startup-check
   ```

   It captures device details, lock state, standalone/paired/legacy app
   inventories, provisioning profiles and processes. Inspect each exit code:
   failure to query is different from a successful empty result. Use the
   selected Xcode via `DEVELOPER_DIR` if its path differs from the script's
   default.
3. Read the installed bundle ID, version and build from `app-standalone.json`.
   Confirm the Watch is unlocked. Compare the signed local artifact's
   `CFBundleIdentifier`, `CFBundleVersion`, `CFBundleShortVersionString` and
   `WKWatchOnly` with that inventory before inspecting its profile. An old
   artifact cannot establish the current installation's expiry.
4. Inspect the matching artifact without printing its complete profile:

   ```sh
   signed_watch_app='/absolute/path/to/CodexWatch Standalone.app'
   /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleVersion' "$signed_watch_app/Info.plist"
   security cms -D -i "$signed_watch_app/embedded.mobileprovision" | plutil -extract CreationDate raw -o - -
   security cms -D -i "$signed_watch_app/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -
   codesign --verify --deep --strict --verbose=2 "$signed_watch_app"
   ```

   Code integrity on disk and provisioning validity on the device are separate
   checks. Preserve UTC timestamps and report their Europe/Madrid equivalents.
5. If the app is installed and the Watch is accessible, attempt one launch:

   ```sh
   xcrun devicectl device process launch --device '<physical Watch UDID>' com.rgferreira.CodexWatchStandalone --timeout 30
   ```

   Capture its exit status and complete error chain. A security rejection
   before execution is not an application crash or a mailbox outage. If launch
   succeeds, query processes once to confirm it remains running; only then
   investigate task synchronization or crash reports as needed.
6. Finish the check without a debugger, attached console, polling loop or
   simulator session left running. Keep raw outputs private and record only
   the relevant status, build, dates and error codes in project documentation.

## Recovery following the same check

User preparation: keep the Watch unlocked, near the unlocked paired iPhone,
with both devices on the same Wi-Fi. A USB connection from iPhone to Mac is
useful when available. Keep the external developer volume mounted. If Xcode
requires Apple-account authentication or a device trust confirmation, the user
must complete that system prompt; the workflow must report the exact blocker.

1. Preserve the previous signed artifact and capture preferences privately
   before the update. For this recovery, the old build remains in its original
   build directory and a preferences copy is stored with mode 0600 in the
   initial forensic snapshot. Do not print or commit its contents.

   ```sh
   xcrun devicectl device copy from --device '<physical Watch UDID>' --domain-type appDataContainer --domain-identifier com.rgferreira.CodexWatchStandalone --source Library/Preferences/com.rgferreira.CodexWatchStandalone.plist --destination '<private snapshot>/pre-renewal-preferences.plist' --timeout 30
   chmod 600 '<private snapshot>/pre-renewal-preferences.plist'
   ```

2. Build the same source and standalone target in a separate build directory,
   allowing Xcode to renew automatic provisioning:

   ```sh
   xcodebuild -quiet -project CodexWatch.xcodeproj -scheme 'CodexWatch Standalone' -configuration Release -destination 'id=<physical Watch UDID>' -derivedDataPath '<new build directory on the developer volume>' -allowProvisioningUpdates build
   ```

   Preserve the full build result with `-resultBundlePath` when diagnosing a
   failure. Renewal does not require a source change or build-number bump.
3. Verify the renewed app with the artifact checks above. Require the same
   bundle ID, signing team and Keychain access groups, `WKWatchOnly = YES`, a
   successful code-signature check and an embedded profile that has not
   expired. Record the actual new expiry before installing.
4. Install as an update through CoreDevice, without first uninstalling:

   ```sh
   xcrun devicectl device install app --device '<physical Watch UDID>' '<new build directory>/Build/Products/Release-watchos/CodexWatch Standalone.app' --timeout 120
   ```

   Preserve the existing app container and Keychain identity. Do not use the
   iPhone Watch app to reinstall the standalone development build.
5. Run the bounded launch command from the diagnostic steps. Capture its
   result, then repeat the inventory with a `post-renewal` label to confirm the
   app, provisioning profile and running process. A successful install alone
   does not establish a successful launch.
6. Confirm that the existing pairing resumes and a new task-list response is
   applied, using metadata-only `taskSyncTrace` entries or the visible task
   list. Keep startup success and transport/task-sync success as separate
   results. End without leaving a debugger or continuous device polling.

### Recorded renewal: 2026-10-07

- Rebuilt unchanged version 0.8.1/build 49 in
  `/Volumes/Corsair/Developer/DeviceBuilds/CodexWatch-0.8.1-49-renewed-20261007`.
  The Xcode result bundle reports success, zero errors and two existing Swift
  warnings. The signed bundle passed strict signature validation, retained the
  same team and Keychain groups, and remains Watch-only.
- The new embedded profile expires at `2026-10-14T19:39:41Z`, **14 October
  2026 at 21:39:41 Europe/Madrid**. This recorded expiry applies to this signed
  artifact, not to future builds.
- CoreDevice installed the update successfully and the subsequent explicit
  launch succeeded. The post-renewal process inventory confirms the launched
  executable remained running. The Watch reports the renewed provisioning
  profile as valid.
- The existing preference history survived the update and the existing pairing
  resumed without a new pairing flow. At `2026-10-07T19:40:39Z`, the Watch
  recorded `response_applied_12`: a new direct response containing 12 tasks.
- The post-renewal snapshot is labelled
  `20261007T194052Z-post-renewal-build49`. Before/after inventories,
  install/launch JSON, preference backups and the build result bundle are
  stored in the private forensic store. No debugger or continuous diagnostic
  polling was left running.

## Conditions for a future automation

- Classify results separately: unreachable/locked, missing app, security
  rejection, launched then exited, or running. Never treat a failed query as
  an empty app list.
- Validate the installed build against the artifact before using its expiry;
  return unknown when the matching artifact cannot be found.
- Use bounded commands and a single launch attempt. Launching wakes the app
  and may run its existing background work; an inventory-only check should
  skip that step.
- Keep the diagnostic-only mode separate from an authorized recovery mode.
  Diagnosis must not reinstall, delete the app, reset pairing or repeatedly
  retry a security rejection. Recovery may renew and update in place using
  the sequence above; it must stop on an unresolved signing/trust failure.
- Record the profile's actual expiry rather than calculating seven days from
  the installation date. Keep metadata and evidence local; do not store
  credentials, audio, conversation content or full profile payloads in Git.

## Weekly Sunday maintenance

Rafa subsequently requested the complete sequence every Sunday night, even
before the current profile expires, with Telegram preparation and outcome
messages. Two active heartbeats belong to the original CodexWatch thread:

- `codexwatch-aviso-previo-del-domingo`: preparation at 21:35 Europe/Madrid.
- `codexwatch-renovaci-n-del-domingo`: maintenance at 21:45 Europe/Madrid.

The first three dates are 11, 18 and 25 October 2026. Both times retain their
Madrid wall-clock value when daylight saving ends on 25 October. The exact
stored rules were verified before and after creation and loaded by the app.
The scheduler's first nominal times are 11 October 19:35/19:45 UTC; its
registered dispatch times include jitter, currently 19:37:13/19:48:08 UTC.
This is an approximate evening slot, not a second-exact dispatch guarantee.

The preparation message asks Rafa to keep Mac and Codex running, Corsair
mounted, and iPhone/Watch unlocked, nearby and on the same Wi-Fi; USB from
iPhone to Mac is useful when available. Maintenance checks that the advance
notice was confirmed at least five minutes earlier. It reports a blocked
execution if preparation was not delivered with enough margin or a required
device/tool/signing prerequisite is missing.

Each run repeats inventory, private backup, signing renewal, in-place update,
bounded launch and fresh task-list verification with the already validated
application version. It must not install unvalidated source or downgrade a
newer app, modify Relay/Bridge or reset pairing.

Xcode may reuse an unexpired profile. Build success or reinstall success alone
does not prove a new seven-day interval. Compare the old and new profile
expiries; if Xcode does not renew, preserve the valid installation and report
`INCOMPLETE`, with its real expiry. Do not delete profiles or revoke
certificates to force renewal. Full success requires an actually renewed
profile, successful launch and a fresh direct task-list response.

Telegram uses the global `codex-notifications` MCP and stable keys per Sunday:
`codexwatch-weekly-prepare-YYYY-MM-DD` and
`codexwatch-weekly-result-YYYY-MM-DD`. Confirm `message_id` or durable delivery
status, preserve the exact outcome text for retries and deduplicate the
maintenance itself. Outcomes distinguish success, failure and incomplete
renewal, and report build, launch/task-sync results and actual Madrid expiry.
No credentials or conversation content enter the messages or Git. Quiet
hours remain 00:00–08:00 Europe/Madrid.

The calendar `Codex` holds the next three maintenance windows (21:35–22:15),
linked to the automation and original thread. Each maintenance run refreshes
that rolling set using IDs `codexwatch-weekly-maintenance-YYYY-MM-DD`.
Operational ownership stays in this CodexWatch thread. Relay's backlog and
corrective threads receive the coordination note; this task does not create
another Relay scheduler or change the Controller, mailbox or writer behavior.
