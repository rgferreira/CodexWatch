# Watch app removal after direct installation

## Symptom

The Watch app disappeared overnight even though its Personal Team provisioning
profile was still valid. Reinstalling the Watch target directly restored it
temporarily.

## Root cause

The installed products did not form one coherent application pair:

- iPhone retained Companion build 34 under `com.rgferreira.CodexWatch`;
- Watch was repeatedly installed directly as build 41;
- the two bundle identifiers had been provisioned through incompatible Personal
  Team histories;
- the iPhone package therefore could not be rebuilt with the current Watch
  binary embedded and validated.

The paired-device reconciliation later removed the directly installed Watch
binary. This happened before profile expiry, ruling out the seven-day lifetime
as the cause of the daily removal.

## Resolution

Build 42 introduces a single hierarchy, development team, build number, and
validated package:

- Companion: `com.rgferreira.CodexWatchCompanion`
- Watch: `com.rgferreira.CodexWatchCompanion.watchapp`
- Team: `RR6C5FHDDS`

The Watch binary is embedded in the matching iPhone app and validated during a
scheme build. The obsolete Companion was backed up and removed before installing
the new pair. Non-sensitive Companion preferences were migrated; Keychain items
and Watch mailbox pairing must be established once under the new application
identity.

`Tests/run_packaging_validation.sh` enforces these invariants for Debug and
Release so future changes cannot silently reintroduce split packaging.

The free Personal Team profile still expires after seven days. That is a
separate Apple signing constraint, not the former daily-removal defect.
