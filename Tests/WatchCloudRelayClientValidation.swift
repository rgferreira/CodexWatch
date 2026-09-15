import CryptoKit
import Foundation

actor WatchAckFailingTransport: BlindMailboxTransport {
    private var claimValues: [BlindMailboxHTTPClient.ClaimedEnvelope]
    private var acknowledgmentAttempts = 0
    private var acknowledgmentStarted = false

    init(claims: [BlindMailboxHTTPClient.ClaimedEnvelope]) {
        claimValues = claims
    }

    func put(_ envelope: CloudRelayProtocol.SealedEnvelope) async throws {}

    func claim(
        direction: CloudRelayProtocol.Direction,
        waitSeconds: Int,
        leaseSeconds: Int,
        limit: Int
    ) async throws -> [BlindMailboxHTTPClient.ClaimedEnvelope] {
        precondition(direction == .macToWatch)
        guard !claimValues.isEmpty else { return [] }
        return [claimValues.removeFirst()]
    }

    func renew(recordID: String, leaseToken: String, leaseSeconds: Int) async throws {}

    func acknowledge(recordID: String, leaseToken: String) async throws {
        acknowledgmentAttempts += 1
        acknowledgmentStarted = true
        try await Task.sleep(for: .seconds(30))
        throw BlindMailboxHTTPClient.ClientError.unavailable(503)
    }

    func attempts() -> Int { acknowledgmentAttempts }
    func started() -> Bool { acknowledgmentStarted }
}

@main
struct WatchCloudRelayClientValidation {
    static func main() async throws {
        let pairingID = "watch-ack-failure-validation"
        let watchPrivate = CloudRelayProtocol.generatePrivateKey()
        let macPrivate = CloudRelayProtocol.generatePrivateKey()
        let key = try CloudRelayProtocol.sharedKey(
            privateKey: watchPrivate,
            peerPublicKey: CloudRelayProtocol.publicKey(for: macPrivate),
            pairingID: pairingID
        )
        let requestIDs = (0..<3).map { _ in UUID() }
        let claims = try requestIDs.enumerated().map { index, requestID in
            let response = CloudConversationResponse(
                requestID: requestID,
                conversation: CodexConversation(
                    taskID: "old-thread-\(index)",
                    messages: [CodexMessage(
                        id: "message-\(index)",
                        role: .assistant,
                        text: "Conversation \(index)",
                        createdAt: Date()
                    )]
                ),
                revision: Date()
            )
            let envelope = try CloudRelayProtocol.seal(
                payload: try .init(
                    commandID: requestID,
                    operation: .conversationResponse,
                    body: response
                ),
                pairingID: pairingID,
                direction: .macToWatch,
                key: key
            )
            return BlindMailboxHTTPClient.ClaimedEnvelope(
                recordID: envelope.context.recordName,
                envelope: envelope,
                leaseToken: "lease-\(index)",
                leaseExpiresAt: Date().addingTimeInterval(45)
            )
        }
        let transport = WatchAckFailingTransport(claims: claims)
        let client = WatchCloudRelayClient(
            transport: transport,
            pairingID: pairingID,
            key: key
        )

        for (index, requestID) in requestIDs.enumerated() {
            let startedAt = ContinuousClock.now
            let events = try await client.receiveOnce(waitSeconds: 0)
            let deliveryTime = startedAt.duration(to: .now)
            guard case .conversation(let received) = events.first else {
                preconditionFailure("Conversation \(index) was suppressed by an earlier ACK")
            }
            precondition(received.requestID == requestID)
            precondition(received.conversation.messages.first?.text == "Conversation \(index)")
            precondition(deliveryTime < .seconds(1))
        }
        for _ in 0..<20 {
            if await transport.started() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let acknowledgmentStarted = await transport.started()
        precondition(acknowledgmentStarted)
        let acknowledgmentAttempts = await transport.attempts()
        precondition(acknowledgmentAttempts == 3)
        print("Three Watch conversations bypass hanging ACKs")
    }
}
