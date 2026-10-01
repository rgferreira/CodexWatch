# Changelog

## Mac Bridge hotfix — build 46 (2026-10-01)

- Accepts Relay's durable `queued` response when the Watch creates a task.
  The previous Bridge falsely reported failure even though Codex was already
  executing the task.
- Tracks new-task operations by their exact `codex-watch:new:<UUID>` identity
  in the restart-safe receipt outbox and sends the terminal result to the Watch.
- Keeps the iPhone-mediated creation path consistent with the same operation
  lifecycle. The iPhone and Watch apps remain on build 45.

## v0.8.1 — build 45 (2026-09-25)

- Never removes a text command from the Watch outbox because of a transient
  HTTPS or connectivity failure.
- Replays every locally queued command after reconnection and restart with its
  original UUID, so Relay's operation idempotency prevents duplicate turns.
- Distinguishes «guardada en el Watch» from transport acceptance and keeps the
  pending state visible until a terminal receipt arrives.
- Adds regression coverage proving that a queued retry remains durable while a
  completed receipt still removes it exactly once.

## v0.8.0 — build 44 (2026-09-21)

- Adds first-run Watch-to-Mac pairing without the iPhone Companion. The Mac
  publishes a 15-minute bootstrap offer through the user's end-to-end encrypted
  iCloud Keychain; the Watch creates its own X25519 identity and both devices
  require the same six-digit verification code before activation.
- Keeps the Cloudflare mailbox blind: no pairing secret, Codex credential,
  prompt or audio is made readable to the Worker.
- Adds voice input and transcription-model controls to both the Watch and the
  Mac Bridge, synchronized through the approved encrypted mailbox.
- Retains the last valid pairing during a cancelled re-pairing attempt and adds
  regression tests for expiry, key binding, tampering, settings round trips,
  packaging and signed entitlements.
- Defers TestFlight/App Store distribution without a target date. Development
  signing remains the supported installation route for this release.

## v0.7.1 — build 42 (2026-09-18)

- Replaces the split Personal Team identities with one coherent iPhone and
  Apple Watch application pair signed by the same development team.
- Gives the Companion and Watch app a new, stable bundle hierarchy so the
  iPhone no longer reconciles the current Watch build against the obsolete
  build 34 companion package and removes it overnight.
- Builds and validates the Watch binary as embedded content of the matching
  iPhone Companion, while retaining independent Watch operation.
- Removes the periodic installation checker introduced as a temporary
  mitigation; it did not address the packaging conflict.

## v0.7.0 — build 41 (2026-09-16)

First stable release of the independent Apple Watch workflow.

- Adds the end-to-end encrypted HTTPS mailbox between Apple Watch and Mac,
  while retaining the iPhone/ZeroTier path as a fallback.
- Lists and refreshes Codex tasks, reads bounded recent conversation history,
  creates tasks with the canonical Codex project catalog, and sends text or
  voice commands.
- Preserves command identity and delegates all durable ordering and writes to
  Relay's local Controller.
- Improves direct-connection state, request timeouts, redelivery, idempotency,
  and nonblocking mailbox acknowledgements.
- Fixes conversation history becoming stuck when a four-envelope claim batch
  exceeds the previous client-side response bound.
- Adds regression coverage for maximum-size mailbox batches, concurrent
  delivery, restart recovery, conversation reads, and hanging acknowledgements.

## v0.6 — build 28

Stable restore point for the original iPhone-mediated Watch workflow.
