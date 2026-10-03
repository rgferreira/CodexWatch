# Codex Watch

**English** · [Español](README_es.md)

An experimental app for selecting a recent Codex task from Apple Watch, reading its latest messages, recording a voice command, and sending it to Codex running on your Mac.

## Current stable release

**Codex Watch v0.8.1 · build 45** makes the independent Watch path self-contained
and resilient to temporary connectivity failures.
It pairs directly with the Mac using a short-lived, end-to-end encrypted iCloud
Keychain rendezvous and a six-digit verification code, without requiring the
iPhone Companion. Voice mode and transcription model can be selected on either
the Watch or Mac and are synchronized through the encrypted mailbox. The
iPhone/ZeroTier path remains available as a fallback. Text commands that have
not reached HTTPS remain visibly queued on the Watch and retry with their
original UUID after reconnection; an accepted command is never uploaded again.
See
[CHANGELOG.md](CHANGELOG.md).

The latest installed development builds are **Watch 49** and **Mac Bridge 48**
(2026-10-03). They improve task-list synchronization but have not been promoted
to a new stable release. Development signing can expire; these builds are not
an App Store/TestFlight distribution.

## See it in action

<p align="center"><img src="docs/assets/codexwatch-demo.gif" alt="Codex Watch one-minute demo" width="360"></p>

<p align="center"><sub>Full one-minute walkthrough · plays directly in the README.</sub></p>

## Components

- `CodexWatch`: iPhone companion app and WatchConnectivity link.
- `CodexWatch Watch App`: chronological task picker, message reader, voice input, and command delivery.
- `CodexWatch Standalone`: Watch-only build with direct HTTPS transport and no
  runtime dependency on the iPhone app.
- `CodexWatchBridge`: authenticated local bridge that uses Relay's loopback
  `CodexController`; it owns no Codex App Server process or writer path.

The bridge detects ZeroTier and binds its listener exclusively to that IPv4 address and its CIDR. It requires the access token displayed by the macOS app and does not advertise through Bonjour.

The menu bar icon reports recent authenticated contact from either the iPhone Companion or the direct Watch HTTPS route: green with contact in the last 45 seconds, orange when local services are ready but neither device has contacted them recently, and red when a required local service is unavailable. Green indicates transport contact, not proof that the task list is current. The Watch stores the latest messages from previously opened conversations and shows them immediately when a task is opened. The bridge reads a bounded tail of the local history, so a large conversation does not need to be reconstructed in full. It requests a conversation again only when the list's `updatedAt` marker signals new information; the refresh happens in the background without hiding messages or changing the reading position.

The Watch requests a task snapshot when its list opens and every 30 seconds while that screen remains visible. On the independent Watch build, the encrypted HTTPS mailbox carries the request to the Mac Bridge, which reads a fresh list from Relay's Controller; the Watch orders responses by request sequence and can apply a late response unless a newer one has already been applied. The Watch shows a loading or stale-list warning instead of treating a transport heartbeat as proof of fresh tasks. On the paired build, WatchConnectivity wakes the iPhone companion, which queries the bridge and responds to the Watch; the iPhone also refreshes its copy every 15 seconds whenever the app can run. Companion changes are additionally sent as persistent, versioned snapshots, and the iPhone retains its last valid list rather than replacing it with an empty cache.

The `+` icon in the top corner of the task list creates a new task. Its picker mirrors the canonical local project catalog and visible names from Codex Desktop, including projects with no recent tasks, with one row per project identity rather than per folder. The Watch lets you choose a project or no project, collects the request through dictation, and submits one idempotent domain operation to Relay's Controller using the stable project ID.

## Voice commands

The Watch and Mac Bridge provide two selectable paths:

- **Apple Watch dictation:** the Watch converts speech to text and the app sends that text to Codex. This path does not use the OpenAI API.
- **OpenAI API:** the Watch records an AAC/M4A voice note and transfers it without transcription directly to the Mac over the encrypted mailbox. The bridge sends it to the OpenAI transcription endpoint and delivers the resulting text to the selected task. This option incurs API charges.

The Watch and Mac Bridge let you select any of the six supported file-transcription models: `gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-mini-transcribe-2025-12-15`, `gpt-4o-transcribe-diarize`, and `whisper-1`. The preference is synchronized only inside the approved E2E channel. The API key is configured in Codex Watch Bridge and stored only in the Mac Keychain.

The bridge sends every write to Relay's loopback Controller with an idempotency identifier. Relay is responsible for per-thread ordering, App Server lifecycle, bounded interruption and completion. The Watch reports success only after Relay confirms the final `turn/completed`.

## Away from home

In the iPhone app, configure the connection method, the Mac's IP address or hostname, the port, and the token copied from the bridge. The address is stored only on the device and is not part of the source code. The random 256-bit token is stored in Keychain on both macOS and iOS. WatchConnectivity keeps this detail away from Apple Watch: the Watch talks to the iPhone, and the iPhone forwards the request to the Mac.

For use away from home, the active bridge configuration uses the Mac's detected private ZeroTier IP address. The client supports other private destinations, but the service must be bound explicitly to the corresponding interface; it does not automatically open on Wi-Fi/LAN. A domain name or public IP address requires HTTPS and a secure proxy. The bridge's HTTP port `48720` must never be exposed directly to the Internet.

### Independent Watch transport

Build 0.8/44 adds autonomous first-run pairing to the iPhone-independent,
end-to-end encrypted blind HTTPS mailbox. Watch and Mac discover one another
through a 15-minute iCloud Keychain offer and require a matching six-digit code;
the normal mailbox still uses outbound-only HTTPS, preserves command UUIDs and
terminates in Relay's loopback Controller. The iPhone route remains the fallback.
The protocol, threat boundary, live validation and rollback are documented in
[Independent Watch transport](docs/HTTPS-MAILBOX-TRANSPORT.md).

## Security controls

- Listener bound to the IPv4 address reported by `zerotier-cli`, with an allowlist covering its CIDR and loopback; any other source is rejected before request data is read.
- A 256-bit token generated with `SecRandomCopyBytes`, stored in Keychain, and compared in constant time.
- Temporary lockout after five failed authentication attempts from one source.
- A maximum of 24 simultaneous connections and a 90-second maximum connection lifetime.
- Headers limited to 16 KiB and request bodies to 2 MiB to support audio; `Transfer-Encoding` is not accepted.
- Generic HTTP error messages; internal details are logged locally only.
- `/health` requires the same authentication as every other endpoint.

The attack surface and known limitations are documented in [SECURITY.md](SECURITY.md).

## Mac bridge

The active build can be installed at `~/Applications/CodexWatchBridge.app`. A local LaunchAgent can start it at login. Upgrades must preserve the signing Team ID so existing Keychain entries remain available to background launches. The icon reflects local service readiness and recent authenticated contact from either the iPhone or the direct Watch route; it does not validate the freshness of the task list. The `/health` endpoint accepts private-network sources only and requires the token.

## Conversation safety

Listing tasks and opening messages are strictly read-only operations and never resume a thread. Only an explicit send or create action can write. Commands are deduplicated by UUID and Relay serializes them per thread. The bridge contains no App Server or Desktop IPC writer. See the [August 15, 2026 incident report](docs/INCIDENT-2026-08-15.md).
