# Watch installation keeper

`watch-install-keeper.sh` protects the development installation from disappearing silently.
It runs as a per-user LaunchAgent every three hours and at login. When the paired Watch is
reachable, it verifies that `com.rgferreira.CodexWatch.watchkitapp` is installed. If it is
missing, it reinstalls the last promoted stable build. When the embedded Personal Team
profile has expired, it attempts to rebuild and sign the pinned stable source first.

The keeper is deliberately conservative:

- it never uninstalls an app;
- it does not keep a permanent Watch connection open;
- it skips work while the Watch is unavailable and retries on the next run;
- it does not pull source code or install an uncommitted working tree;
- expired profiles are moved to a recoverable local backup before Xcode requests a new one;
- logs contain operation status only, never prompts, credentials, pairing secrets, or audio.

Install or refresh it with:

```sh
./scripts/install-watch-keeper.sh
```

The free Xcode Personal Team still imposes a seven-day lifetime on App IDs, registered
devices, and provisioning profiles. The keeper minimizes downtime but cannot override
Apple's signing policy, wake an unreachable Watch, or guarantee uninterrupted installation
while the Watch is away from the Mac. App Store distribution through the paid Apple
Developer Program is the permanent solution.
