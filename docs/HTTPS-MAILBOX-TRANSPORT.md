# Independent Watch transport

Status: protocol and first text slice validated locally and against the deployed
Cloudflare Worker. The pilot mailbox and its first pairing were provisioned on
2026-08-26. Build 0.7/29 adds verified pairing and direct Watch-to-Mac text
commands; the stable rollback point remains `codexwatch-v0.6-build28-stable`
(`5fd8d18`).

## Decision record

CloudKit was prototyped first, but a signed build proved that the configured
Apple Personal Team cannot use the iCloud capability. The CloudKit client and
entitlements were removed before release. Unsigned compilation is not treated as
evidence that CloudKit can ship.

The selected design is a separate blind HTTPS mailbox owned by Relay. Its pilot
runtime is a Cloudflare Worker with one SQLite Durable Object per pairing. The
base URL remains secure configuration rather than a value compiled into the app.

## Purpose and authority

The mailbox only moves end-to-end encrypted envelopes between Apple Watch and
the Mac over outbound HTTPS. It does not expose ports 48720 or 48721 and never
receives the local Controller bearer.

The Relay Controller on `127.0.0.1:48721` remains the only durable owner and
writer of Codex turns. Upload, claim and ACK are transport events, not acceptance
by Codex. A command becomes accepted only after Controller persistence, and
completed only after Controller reports the terminal turn event.

The existing Watch -> iPhone -> Bridge route remains the production fallback.
Both paths preserve the UUID created once by the Watch, producing the same
`codex-watch:<UUID>` operation ID.

## Cryptographic protocol v1

- Each Watch and Mac use local X25519 private keys stored in Keychain.
- X25519 plus HKDF-SHA256 derives an envelope key for a random pairing ID.
- ChaCha20-Poly1305 authenticates the encrypted payload and immutable context.
- HMAC-SHA256 derives opaque, non-enumerable record IDs.
- A second pairing transport secret signs every HTTP request. The request MAC
  binds method, path, timestamp, random nonce and SHA-256 body digest.
- The server has neither key and cannot read prompts, thread IDs or receipts.
- Pairing must finish with a short-authentication-string check on both devices;
  server-side public-key substitution must never be silently accepted.

The encrypted payload binds command UUID, operation class and body hash. Reusing
the same command UUID with different text yields HTTP 409, never overwrite.
Receipt records use a state discriminator while retaining the same command UUID,
so `queued` may safely progress to one terminal receipt.

The HTTP idempotency digest is the keyed semantic binding tag, not the random
ciphertext digest. A retry may therefore use a fresh safe AEAD nonce while the
mailbox still recognizes the identical command. The transport request MAC always
binds the exact ciphertext bytes. A changed payload produces another semantic
digest and HTTP 409.

The first slice is text only and limits plaintext to 64 KiB. Audio remains out of
scope until text is proven on the deployed Worker.

## Provider-neutral HTTPS contract

- `POST /v1/pairings/{pairing_id}/envelopes`: idempotent opaque upload.
- `POST /v1/pairings/{pairing_id}/claims`: long-poll claim with a bounded lease.
- `POST /v1/pairings/{pairing_id}/envelopes/{record_id}/lease`: lease renewal.
- `POST /v1/pairings/{pairing_id}/envelopes/{record_id}/ack`: idempotent ACK and
  logical deletion.
- `GET /v1/pairings/{pairing_id}/envelopes/{record_id}`: transport diagnostics
  only; never turn status.

Claims are mutations. V1 uses HTTPS long-polling (at most 25 seconds), not a
WebSocket. Initial service limits are 64 KiB per envelope, 100 pending records,
two concurrent long-polls and 30 writes per minute per pairing. TTL is 24 hours
with a 72-hour hard maximum. Logs exclude bodies and ciphertext.

## Mac delivery and restart safety

The Mac consumer claims one text command, verifies AEAD and payload bindings,
renews the lease while Relay is working, and terminates in the existing
Controller client. It keeps at most one write in flight per thread.

- Controller 200: upload terminal receipt, then ACK the command.
- Controller 202: persist a minimal outbox entry, upload queued receipt and ACK
  because Controller has accepted durably. Poll the same operation ID to terminal.
- Lost response: reconcile the same operation ID before deciding; never mint one.
- 409/unknown: emit `reconciliation_required`, with no blind retry.
- 503/unavailable: do not ACK; lease expiry redelivers the same encrypted command.

`CloudRelayOutbox` persists only pairing ID, operation ID, command ID and receipt
delivery state in a mode-0600 atomic journal. It stores no prompt. After a Bridge
restart it reconstructs terminal receipts from Controller, which remains the
source of truth.

## Validation completed

- shared-key agreement and cryptographic round trip;
- random nonces, wrong key, tampered ciphertext and tampered AAD;
- expiry, clock skew, body hash and record binding;
- same ID/same digest duplicate and same ID/different digest conflict;
- signed HTTP request, nonce replay rejection and transport authentication;
- two concurrent claimers, lease ownership/renewal/expiry and idempotent ACK;
- queued receipt, Controller-terminal reconciliation and distinct receipt IDs;
- journal restart recovery and file mode 0600;
- signed macOS build after removal of the unsupported CloudKit entitlement.
- live encrypted upload, claim, decrypt and ACK against the deployed Worker.

The HTTP client is exercised against `Tests/mock_mailbox_server.py`; the mock is
test-only and is never exposed outside loopback.

## Rollback

1. Disable the build-29 HTTPS pairing and reinstall build 28.
2. Continue through the iPhone/Bridge route.
3. If a binary rollback is needed, install the archived artifacts from
   `~/Library/Application Support/CodexWatch/RestorePoints/0.6-build-28-5fd8d18/`
   or build tag `codexwatch-v0.6-build28-stable`.

No migration deletes iPhone settings, Bridge tokens, Codex tasks or Relay state.
