# Reliability correction — development build 50

This is not a new stable release or a claim of complete physical-device acceptance.

## Established facts and limits

- Watch-created chats previously used the CLI `exec` source. Desktop's normal interactive listing excludes that source. Changing only `threadSource` does not fix it: a real disposable test remained invisible.
- Relay now creates a native `vscode` / `user` chat and starts the first turn on the same Controller-owned App Server. A disposable native chat appeared in Desktop's listing. The writer is closed and release is verified before recording completion. Existing-thread Desktop ownership still uses the established owner-aware queue path.
- One reported dictation differs from the prompt stored in the Controller and transcript. The available evidence does **not** establish truncation, two dictations, or the component responsible. Do not blame missing user input or present a hypothesis as a root cause.
- Old failure rows were repeatedly resurfacing by their polling timestamp. Creation date now determines order; validation incidents are identified separately.

## Changes

- New-task intents and drafts persist on Watch before upload. Retries retain the original command UUID and full prompt. Accepted transports are not uploaded again; failed intents remain recoverable without automatic execution.
- Commands created by build 50 carry a SHA-256 fingerprint and UTF-8 byte count. The Bridge rejects a mismatch before calling the Controller. Older commands without either field remain compatible; partial fingerprints are rejected. These fingerprints cannot establish what Apple dictation displayed before the app received its callback.
- Transient Bridge errors release the UUID for a safe retry instead of caching a permanent rejection. HTTP 409 / uncertain outcomes are never blindly resent.
- The Controller exposes dated operations and conservative recovery states, exports all recent Watch operations into Relay History, and maintains a durable idempotent Telegram notification outbox. Turn completion means a response is available, **not** proof of a completed reservation or other external effect.
- Uncertain handoffs stop polling after 24 hours / 300 checks, or immediately for absent/ambiguous correlation. Unstarted Watch orders stop automatic retries after 24 hours / 64 attempts. Manual reconciliation reads exact turn evidence without resubmission.
- Native first-turn workers have a four-worker capacity limit, cancellation on shutdown, own-turn interruption, guaranteed client close and writer-release verification. Restart after thread creation cannot create a second task.
- Bridge exports private runtime/presence metadata. Installed Watch build, live contact, idle state and optional iPhone fallback are separate facts. Relay does not infer end-to-end health merely from a running process.

## Validation

- Independent Swift transport suite: durable text/new-task outboxes, restart, duplicate tap, content mismatch, bounded concurrency, lease/ACK, retry safety, packaging and HTTP mock.
- Relay regression suite: native creation, duplicate operation, lost start response, shutdown, crash between thread and turn, exact-turn read-only reconciliation, metadata privacy, notification idempotence/restart/network failure/quiet hours, History idempotence and stale-order expiry.
- Real disposable native Controller creation: same operation submitted twice, one thread/turn, terminal completion after release; Desktop listing verified. No production reservation was repeated by this test.
- Watch build 50 compiles and signs. Physical Watch installation and acceptance remain pending when the device is unavailable; the existing renewed build 49 must not be uninstalled to force this update.

## Deployment and rollback

Install Relay and Bridge only after their regression checks pass. Preserve the previous signed apps and a SQLite backup outside launchable/indexed app locations. Watch installation is a separate checked step; update its private installation record only after physical launch succeeds. Do not overwrite that record with a compiled candidate.

Rollback restores the previous signed Mac bundles and restarts their single canonical launch locations. Schema changes are additive. Do not replace a live Controller database with an old backup after newer operations have been accepted: preserve the current ledger and reconcile it first. Never clear Codex locks or replay uncertain operations during rollback.
