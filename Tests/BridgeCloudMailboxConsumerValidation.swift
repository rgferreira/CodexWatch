import Foundation

actor MockMailboxTransport: BlindMailboxTransport {
    private var inbound: [BlindMailboxHTTPClient.ClaimedEnvelope] = []
    private var published: [CloudRelayProtocol.SealedEnvelope] = []
    private var acknowledged: [String] = []
    private var renewals = 0

    func seed(_ claim: BlindMailboxHTTPClient.ClaimedEnvelope) {
        inbound.append(claim)
    }

    func put(_ envelope: CloudRelayProtocol.SealedEnvelope) async throws {
        published.append(envelope)
    }

    func claim(
        direction: CloudRelayProtocol.Direction,
        waitSeconds: Int,
        leaseSeconds: Int,
        limit: Int
    ) async throws -> [BlindMailboxHTTPClient.ClaimedEnvelope] {
        guard direction == .watchToMac, !inbound.isEmpty else { return [] }
        return [inbound.removeFirst()]
    }

    func renew(recordID: String, leaseToken: String, leaseSeconds: Int) async throws {
        renewals += 1
    }

    func acknowledge(recordID: String, leaseToken: String) async throws {
        acknowledged.append(recordID)
    }

    func snapshot() -> (published: [CloudRelayProtocol.SealedEnvelope], acknowledged: [String]) {
        (published, acknowledged)
    }
}

actor StatusBox {
    var status = "queued"
    func set(_ value: String) { status = value }
    func get() -> String { status }
}

@main
struct BridgeCloudMailboxConsumerValidation {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexwatch-consumer-\(UUID().uuidString)", isDirectory: true)
        let outbox = try CloudRelayOutbox(
            fileURL: directory.appendingPathComponent("outbox.json")
        )
        let transport = MockMailboxTransport()
        let statuses = StatusBox()
        let watchPrivate = CloudRelayProtocol.generatePrivateKey()
        let macPrivate = CloudRelayProtocol.generatePrivateKey()
        let watchPublic = try CloudRelayProtocol.publicKey(for: watchPrivate)
        let macPublic = try CloudRelayProtocol.publicKey(for: macPrivate)
        let pairingID = "consumer-pairing"
        let watchKey = try CloudRelayProtocol.sharedKey(
            privateKey: watchPrivate,
            peerPublicKey: macPublic,
            pairingID: pairingID
        )
        let task = CodexTask(
            id: "disposable-thread", title: "Consumer validation", preview: "",
            projectPath: nil, updatedAt: Date(), state: .idle
        )
        let command = CodexCommand(task: task, text: "Queue this once")
        let request = try CloudRelayProtocol.seal(
            payload: try .init(
                commandID: command.id,
                operation: .textCommand,
                body: command
            ),
            pairingID: pairingID,
            direction: .watchToMac,
            key: watchKey
        )
        await transport.seed(.init(
            recordID: request.context.recordName,
            envelope: request,
            leaseToken: "lease",
            leaseExpiresAt: Date().addingTimeInterval(90)
        ))
        let consumer = try BridgeCloudMailboxConsumer(
            transport: transport,
            outbox: outbox,
            pairingID: pairingID,
            localPrivateKey: macPrivate,
            peerPublicKey: watchPublic,
            deliver: { received in
                precondition(received.id == command.id)
                return .queued("Accepted by Controller")
            },
            operationStatus: { _ in await statuses.get() }
        )
        let drained = try await consumer.drainOnce(waitSeconds: 0)
        precondition(drained)
        let afterQueue = await transport.snapshot()
        precondition(afterQueue.acknowledged == [request.context.recordName])
        precondition(afterQueue.published.count == 1)
        let queuedPayload = try CloudRelayProtocol.open(
            afterQueue.published[0], expectedDirection: .macToWatch, key: watchKey
        )
        let queuedReceipt = try queuedPayload.decode(CommandReceipt.self)
        precondition(queuedReceipt.state == .queued)
        let queuedOutbox = await outbox.pending()
        precondition(queuedOutbox.count == 1)

        await statuses.set("completed")
        try await consumer.reconcileOutbox()
        let afterTerminal = await transport.snapshot()
        precondition(afterTerminal.published.count == 2)
        precondition(afterTerminal.published[0].context.recordName
            != afterTerminal.published[1].context.recordName)
        let terminalPayload = try CloudRelayProtocol.open(
            afterTerminal.published[1], expectedDirection: .macToWatch, key: watchKey
        )
        let terminalReceipt = try terminalPayload.decode(CommandReceipt.self)
        precondition(terminalReceipt.state == .sent)
        let finalOutbox = await outbox.pending()
        precondition(finalOutbox.isEmpty)
        try? FileManager.default.removeItem(at: directory)
        print("Bridge cloud mailbox consumer validation passed")
    }
}
