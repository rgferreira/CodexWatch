# Codex Watch

**English** · [Español](README_es.md)

An experimental app for selecting a recent Codex task from Apple Watch, reading its latest messages, recording a voice command, and sending it to Codex running on your Mac.

## See it in action

<p align="center"><img src="docs/assets/codexwatch-demo.gif" alt="Codex Watch one-minute demo" width="360"></p>

<p align="center"><sub>Full one-minute walkthrough · plays directly in the README.</sub></p>

## Components

- `CodexWatch`: iPhone companion app and WatchConnectivity link.
- `CodexWatch Watch App`: chronological task picker, message reader, voice input, and command delivery.
- `CodexWatchBridge`: authenticated local bridge that uses Relay's loopback
  `CodexController`; it owns no Codex App Server process or writer path.

The bridge detects ZeroTier and binds its listener exclusively to that IPv4 address and its CIDR. It requires the access token displayed by the macOS app and does not advertise through Bonjour.

The menu bar icon reports end-to-end connection status: green only after a recent authenticated response to the iPhone Companion, orange when Codex and the bridge are ready but there has been no recent iPhone contact, and red if either local service fails. Green status expires after 45 seconds without another successful response. The Watch stores the latest messages from previously opened conversations and shows them immediately when a task is opened. The bridge reads a bounded tail of the local history, so a large conversation does not need to be reconstructed in full. It requests a conversation again only when the list's `updatedAt` marker signals new information; the refresh happens in the background without hiding messages or changing the reading position.

The Watch task list requests a fresh snapshot when opened and every 10 seconds while visible. The WatchConnectivity request wakes the iPhone companion, which queries the bridge and responds directly to the Watch; the iPhone also refreshes its copy every 15 seconds whenever the app can run. Every change is additionally sent as a persistent, versioned, and deduplicated snapshot: the Watch receives the newest list even if the immediate message fails and discards stale deliveries. The iPhone retains the last valid list so it cannot overwrite the Watch with an empty cache when resuming in the background.

The `+` icon in the top corner of the task list creates a new task. The Watch suggests the project from the most recent task, lets you choose another project or no project, collects the request through dictation, and submits one idempotent domain operation to Relay's Controller.

## Voice commands

The companion app provides two paths:

- **Apple Watch dictation:** the Watch converts speech to text and the app sends that text to Codex. This path does not use the OpenAI API.
- **OpenAI API:** the Watch records an AAC/M4A voice note and transfers it without transcription to the iPhone and Mac. The bridge sends it to the OpenAI transcription endpoint and delivers the resulting text to the selected task. This option incurs API charges.

The Companion lets you select any of the six supported file-transcription models: `gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-mini-transcribe-2025-12-15`, `gpt-4o-transcribe-diarize`, and `whisper-1`. The API key is configured in Codex Watch Bridge and stored only in the Mac Keychain.

The bridge sends every write to Relay's loopback Controller with an idempotency identifier. Relay is responsible for per-thread ordering, App Server lifecycle, bounded interruption and completion. The Watch reports success only after Relay confirms the final `turn/completed`.

## Away from home

In the iPhone app, configure the connection method, the Mac's IP address or hostname, the port, and the token copied from the bridge. The address is stored only on the device and is not part of the source code. The random 256-bit token is stored in Keychain on both macOS and iOS. WatchConnectivity keeps this detail away from Apple Watch: the Watch talks to the iPhone, and the iPhone forwards the request to the Mac.

For use away from home, the active bridge configuration uses the Mac's detected private ZeroTier IP address. The client supports other private destinations, but the service must be bound explicitly to the corresponding interface; it does not automatically open on Wi-Fi/LAN. A domain name or public IP address requires HTTPS and a secure proxy. The bridge's HTTP port `48720` must never be exposed directly to the Internet.

### Independent Watch transport (in development)

An iPhone-independent path is being built as an end-to-end encrypted, blind
HTTPS mailbox with outbound-only connections from Watch and Mac. It preserves
the same command UUID and still terminates in Relay's loopback Controller. No
public mailbox is provisioned yet, so this path is not enabled in the production
app and the iPhone route remains the fallback. The protocol, threat boundary,
mock validation and rollback are documented in
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

The active build can be installed at `~/Applications/CodexWatchBridge.app`. A local LaunchAgent can start it at login. Upgrades must preserve the signing Team ID so existing Keychain entries remain available to background launches. A red icon means Codex or the private server is not ready, orange means the Mac is ready but has not responded to the Companion recently, and green confirms a recent authenticated response to the iPhone. The `/health` endpoint accepts private-network sources only and requires the token.

## Conversation safety

Listing tasks and opening messages are strictly read-only operations and never resume a thread. Only an explicit send or create action can write. Commands are deduplicated by UUID and Relay serializes them per thread. The bridge contains no App Server or Desktop IPC writer. See the [August 15, 2026 incident report](docs/INCIDENT-2026-08-15.md).
