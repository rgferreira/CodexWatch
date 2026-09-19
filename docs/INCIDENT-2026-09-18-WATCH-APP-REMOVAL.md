# Watch app removal after direct installation

## Symptom

The Watch app disappeared before its Personal Team provisioning profile expired.
Installing from the iPhone Watch app completed its progress animation and then
returned Codex Watch to “Available Apps”. Installing the Watch target directly
from Xcode/CoreDevice worked, but a later iPhone–Watch reconciliation removed it.

## Proven root cause

The paired iPhone's AppConduit service was deleting the directly installed Watch
app during companion reconciliation. This was not profile expiry and was not
device management.

The Watch sysdiagnose records the complete causal sequence:

- `appconduitd` receives `_onQueue_handleDeletionListMessage` from the paired
  phone and logs `Uninstalling com.rgferreira.CodexWatchCompanion.watchapp`;
- MobileInstallation records the caller as `appconduitd`, removes the app's
  still-valid provisioning profile, and destroys its containers;
- iPhone-initiated reinstall attempts then fail with `MIInstallerErrorDomain`
  code 111: an app signed by a free provisioning profile is not allowed to be
  installed from the AppConduit source;
- the same binary installs successfully when CoreDevice uses the Developer
  installation source.

The earlier split identities (Companion build 34 and directly installed Watch
build 41) were a real packaging defect, but not the root cause. Build 42 made the
pair coherent and was still removed by AppConduit at 02:34 while its profile was
valid until 24 September 2026.

The captured sysdiagnose is kept outside the repository on the external
developer volume. Its SHA-256 is
`a41e33444b97ddf0d84a366e6570f13a73ca4f2b82299717bed6ba9b225aac09`.

## Permanent local-development fix

Build 43 adds `CodexWatch Standalone`, a true Watch-only target for Personal
Team installation:

- bundle ID: `com.rgferreira.CodexWatchStandalone`;
- `WKWatchOnly = YES`;
- no `WKCompanionAppBundleIdentifier`;
- not embedded in, and not a dependency of, the iPhone Companion target;
- installed only through the Developer/CoreDevice source.

Because AppConduit no longer owns this bundle as iPhone companion content, its
companion deletion list cannot remove it. The original companion target remains
available for a future TestFlight/App Store distribution.

The Watch-only target can read the previous Watch app's Keychain access group so
the encrypted HTTPS mailbox pairing survives the identity migration. New writes
use the standalone access group. No secret is embedded in the binary or stored
in the repository.

`Tests/run_packaging_validation.sh` checks both packaging modes in Debug and
Release. It requires the companion pair to remain coherent and the standalone
target to be Watch-only, independently identified, on the same team and build,
and without a companion identifier.

## Forensic and validation procedure

`Tests/capture_watch_install_state.sh` records a signed point-in-time inventory
without installing, launching, or repairing anything. It captures the
standalone, companion and legacy bundle IDs, provisioning profiles, processes,
lock state, device details, exit status and SHA-256 hashes.

The controlled validation for the fix is:

1. capture the existing companion state;
2. install build 43 from CoreDevice and confirm `WKWatchOnly` in the installed
   product;
3. confirm the standalone app recovers the existing direct HTTPS connection;
4. trigger iPhone–Watch reconciliation and capture a second inventory;
5. verify that the standalone app and its unexpired profile remain present and
   that AppConduit did not issue a deletion for the standalone bundle;
6. remove the obsolete companion Watch bundle only after those checks pass.

The paired iPhone 18 Pro / Apple Watch Series 12 simulator completed the same
package-reconciliation sequence successfully: the standalone build was present
before the Companion installation, remained at the identical container after
installing and launching the Companion, and remained installed after shutting
down and rebooting both simulated devices.

The physical-device release gate also passed with build 43:

- the standalone app was installed through CoreDevice while the old companion
  Watch bundle was still present;
- launching the iPhone Watch app forced an AppConduit reconciliation and the
  standalone app remained installed;
- the obsolete companion Watch bundle was removed and another reconciliation
  did not recreate or remove the standalone app;
- the physical Watch was rebooted, unlocked and reconciled again; build 43
  remained installed, the obsolete bundle remained absent and the standalone
  provisioning profile remained valid;
- after reboot the standalone process recovered the existing encrypted mailbox
  pairing and produced fresh direct heartbeats, task-list responses and
  conversation responses without an iPhone fallback.

The final non-mutating forensic snapshot after explicitly opening the iPhone
Watch app is labelled `final-post-reboot-appconduit-build43`; the preceding
install, reboot and reconciliation snapshots are retained in the same local
forensic store. These captures contain device-specific data and are
intentionally excluded from the repository.

The Personal Team profile still expires after seven days. That Apple signing
limit is separate from this incident; AppConduit must no longer delete the app
prematurely. TestFlight or App Store distribution remains the long-term way to
remove the seven-day signing limit.

## Rollback

Uninstall `com.rgferreira.CodexWatchStandalone` and reinstall the companion Watch
target directly from the previous signed build. The source rollback point before
this fix is commit `b608ffa`. The companion target and its packaging were kept
unchanged apart from the shared build-number increment.
