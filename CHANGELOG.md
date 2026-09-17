# Changelog

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
