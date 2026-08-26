import Foundation

@main
struct BlindMailboxHTTPClientValidation {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let baseURL = URL(string: CommandLine.arguments[1]),
              let secret = Data(base64Encoded: CommandLine.arguments[2]) else {
            fatalError("usage: validation baseURL secretBase64")
        }
        let configuration = try BlindMailboxHTTPClient.Configuration(
            baseURL: baseURL,
            pairingID: "test-pairing-0123456789",
            transportSecret: secret,
            allowInsecureLocalhost: true
        )
        let client = BlindMailboxHTTPClient(configuration: configuration)
        let watchPrivate = CloudRelayProtocol.generatePrivateKey()
        let macPrivate = CloudRelayProtocol.generatePrivateKey()
        let key = try CloudRelayProtocol.sharedKey(
            privateKey: watchPrivate,
            peerPublicKey: CloudRelayProtocol.publicKey(for: macPrivate),
            pairingID: configuration.pairingID
        )
        let task = CodexTask(
            id: "disposable-thread", title: "Mock mailbox", preview: "",
            projectPath: nil, updatedAt: Date(), state: .idle
        )
        let command = CodexCommand(task: task, text: "Mock end-to-end")
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: command.id,
            operation: .textCommand,
            body: command
        )
        let envelope = try CloudRelayProtocol.seal(
            payload: payload,
            pairingID: configuration.pairingID,
            direction: .watchToMac,
            key: key
        )
        try await client.put(envelope)
        try await client.put(envelope)
        let resealed = try CloudRelayProtocol.seal(
            payload: payload,
            pairingID: configuration.pairingID,
            direction: .watchToMac,
            key: key
        )
        precondition(resealed.combinedCiphertext != envelope.combinedCiphertext)
        try await client.put(resealed)

        let changed = CodexCommand(task: task, text: "Conflicting payload")
        let changedEnvelope = try CloudRelayProtocol.seal(
            payload: try .init(
                commandID: command.id,
                operation: .textCommand,
                body: changed
            ),
            pairingID: configuration.pairingID,
            direction: .watchToMac,
            key: key
        )
        do {
            try await client.put(changedEnvelope)
            preconditionFailure("Expected idempotency conflict")
        } catch let error as BlindMailboxHTTPClient.ClientError {
            precondition(error == .idempotencyConflict)
        }

        let claimed = try await client.claim(
            direction: .watchToMac,
            waitSeconds: 0,
            leaseSeconds: 10,
            limit: 2
        )
        precondition(claimed.count == 1)
        precondition(claimed[0].recordID == envelope.context.recordName)
        let opened = try CloudRelayProtocol.open(
            claimed[0].envelope,
            expectedDirection: .watchToMac,
            key: key
        )
        precondition(opened.commandID == command.id)

        do {
            try await client.acknowledge(recordID: claimed[0].recordID, leaseToken: "wrong")
            preconditionFailure("Expected lease mismatch")
        } catch let error as BlindMailboxHTTPClient.ClientError {
            precondition(error == .leaseLost)
        }
        try await client.renew(
            recordID: claimed[0].recordID,
            leaseToken: claimed[0].leaseToken,
            leaseSeconds: 15
        )
        try await client.acknowledge(
            recordID: claimed[0].recordID,
            leaseToken: claimed[0].leaseToken
        )
        let empty = try await client.claim(
            direction: .watchToMac,
            waitSeconds: 0,
            leaseSeconds: 10,
            limit: 1
        )
        precondition(empty.isEmpty)

        let fixedNonce = Data(repeating: 7, count: 16)
        let replayRequest = try client.authenticatedRequest(
            method: "POST",
            path: "/v1/pairings/test-pairing-0123456789/claims",
            body: CodexWatchWire.encode([
                "direction": "watch_to_mac",
                "wait_seconds": "0",
                "lease_seconds": "10",
                "limit": "1"
            ]),
            nonce: fixedNonce
        )
        let (_, firstReplayResponse) = try await URLSession.shared.data(for: replayRequest)
        let (_, secondReplayResponse) = try await URLSession.shared.data(for: replayRequest)
        precondition((firstReplayResponse as? HTTPURLResponse)?.statusCode == 200)
        precondition((secondReplayResponse as? HTTPURLResponse)?.statusCode == 401)
        print("Blind mailbox HTTP client validation passed")
    }
}
