import CryptoKit
import Foundation

actor MockMailboxTransport: BlindMailboxTransport {
    private var inbound: [BlindMailboxHTTPClient.ClaimedEnvelope] = []
    private var published: [CloudRelayProtocol.SealedEnvelope] = []
    private var acknowledged: [String] = []
    private var renewals = 0
    private var putFailuresRemaining = 0
    private var acknowledgeFailuresRemaining = 0
    private var putFailure = BlindMailboxHTTPClient.ClientError.unavailable(503)

    func failNextPuts(
        _ count: Int,
        with error: BlindMailboxHTTPClient.ClientError = .unavailable(503)
    ) {
        putFailuresRemaining = count
        putFailure = error
    }
    func failNextAcknowledgements(_ count: Int) { acknowledgeFailuresRemaining = count }

    func seed(_ claim: BlindMailboxHTTPClient.ClaimedEnvelope) {
        inbound.append(claim)
    }

    func put(_ envelope: CloudRelayProtocol.SealedEnvelope) async throws {
        if putFailuresRemaining > 0 {
            putFailuresRemaining -= 1
            throw putFailure
        }
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
        if acknowledgeFailuresRemaining > 0 {
            acknowledgeFailuresRemaining -= 1
            throw BlindMailboxHTTPClient.ClientError.leaseLost
        }
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

actor VoiceBox {
    private(set) var receivedBytes = 0
    func record(_ count: Int) { receivedBytes = count }
    func get() -> Int { receivedBytes }
}

actor HeartbeatBox {
    private(set) var received = false
    func markReceived() { received = true }
    func get() -> Bool { received }
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
        let voices = VoiceBox()
        let heartbeats = HeartbeatBox()
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
        let projects = [
            CodexProject(
                id: "platform", name: "PLATFORM ENGINEERING",
                path: "/projects/Relay"
            ),
            CodexProject(
                id: "music", name: "MUSIC SYSTEMS",
                path: "/projects/ScoreIR"
            )
        ]
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
            listTasks: { [task] },
            listProjects: { projects },
            readConversation: { threadID in
                precondition(threadID == task.id)
                return [CodexMessage(
                    id: "message-1",
                    role: .assistant,
                    text: "Read-only response",
                    createdAt: Date()
                )]
            },
            deliverVoice: { voiceCommand, audio in
                precondition(voiceCommand.taskID == task.id)
                await voices.record(audio.count)
                return .completed("Voice delivered")
            },
            voiceInbox: try CloudVoiceInbox(
                root: directory.appendingPathComponent("voice", isDirectory: true)
            ),
            operationStatus: { _ in await statuses.get() },
            heartbeat: { _ in await heartbeats.markReceived() }
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

        let taskRequestID = UUID()
        let taskRequest = try CloudRelayProtocol.seal(
            payload: try .init(
                commandID: taskRequestID,
                operation: .taskListRequest,
                body: CloudTaskListRequest(requestedAt: Date())
            ),
            pairingID: pairingID,
            direction: .watchToMac,
            key: watchKey
        )
        await transport.seed(.init(
            recordID: taskRequest.context.recordName,
            envelope: taskRequest,
            leaseToken: "lease-tasks",
            leaseExpiresAt: Date().addingTimeInterval(90)
        ))
        await transport.failNextPuts(2, with: .rateLimited)
        await transport.failNextAcknowledgements(2)
        let drainedTasks = try await consumer.drainOnce(waitSeconds: 0)
        precondition(drainedTasks)
        let afterTasks = await transport.snapshot()
        let taskPayload = try CloudRelayProtocol.open(
            afterTasks.published.last!, expectedDirection: .macToWatch, key: watchKey
        )
        let taskResponse = try taskPayload.decode(CloudTaskListResponse.self)
        precondition(taskResponse.requestID == taskRequestID)
        precondition(taskResponse.tasks.count == 1)
        precondition(taskResponse.tasks[0].id == task.id)

        let projectRequestID = UUID()
        let projectRequest = try CloudRelayProtocol.seal(
            payload: try .init(
                commandID: projectRequestID,
                operation: .projectListRequest,
                body: CloudProjectListRequest(requestedAt: Date())
            ),
            pairingID: pairingID,
            direction: .watchToMac,
            key: watchKey
        )
        await transport.seed(.init(
            recordID: projectRequest.context.recordName,
            envelope: projectRequest,
            leaseToken: "lease-projects",
            leaseExpiresAt: Date().addingTimeInterval(90)
        ))
        let drainedProjects = try await consumer.drainOnce(waitSeconds: 0)
        precondition(drainedProjects)
        let afterProjects = await transport.snapshot()
        let projectPayload = try CloudRelayProtocol.open(
            afterProjects.published.last!, expectedDirection: .macToWatch, key: watchKey
        )
        let projectResponse = try projectPayload.decode(CloudProjectListResponse.self)
        precondition(projectResponse.requestID == projectRequestID)
        precondition(projectResponse.projects.map(\.name) == [
            "PLATFORM ENGINEERING", "MUSIC SYSTEMS"
        ])
        precondition(projectResponse.projects[1].path == "/projects/ScoreIR")

        let conversationRequestID = UUID()
        let conversationRequest = try CloudRelayProtocol.seal(
            payload: try .init(
                commandID: conversationRequestID,
                operation: .conversationRequest,
                body: CloudConversationRequest(taskID: task.id, revision: task.updatedAt)
            ),
            pairingID: pairingID,
            direction: .watchToMac,
            key: watchKey
        )
        await transport.seed(.init(
            recordID: conversationRequest.context.recordName,
            envelope: conversationRequest,
            leaseToken: "lease-conversation",
            leaseExpiresAt: Date().addingTimeInterval(90)
        ))
        let drainedConversation = try await consumer.drainOnce(waitSeconds: 0)
        precondition(drainedConversation)
        let afterConversation = await transport.snapshot()
        let conversationPayload = try CloudRelayProtocol.open(
            afterConversation.published.last!, expectedDirection: .macToWatch, key: watchKey
        )
        let conversationResponse = try conversationPayload.decode(
            CloudConversationResponse.self
        )
        precondition(conversationResponse.requestID == conversationRequestID)
        precondition(conversationResponse.conversation.messages.count == 1)

        let voiceCommand = CodexVoiceCommand(task: task, transcriptionModel: .gptTranscribe)
        let audio = Data((0..<75_000).map { UInt8($0 % 251) })
        let audioHash = Data(SHA256.hash(data: audio))
        let chunkSize = CloudVoiceChunk.preferredChunkBytes
        let chunkCount = (audio.count + chunkSize - 1) / chunkSize
        for index in 0..<chunkCount {
            let lower = index * chunkSize
            let upper = min(lower + chunkSize, audio.count)
            let chunk = CloudVoiceChunk(
                command: voiceCommand,
                chunkIndex: index,
                chunkCount: chunkCount,
                audioSHA256: audioHash,
                bytes: audio.subdata(in: lower..<upper)
            )
            let envelope = try CloudRelayProtocol.seal(
                payload: try .init(
                    commandID: voiceCommand.id,
                    operation: .voiceChunk,
                    body: chunk
                ),
                pairingID: pairingID,
                direction: .watchToMac,
                key: watchKey,
                recordDiscriminator: "voice-\(index)-of-\(chunkCount)"
            )
            await transport.seed(.init(
                recordID: envelope.context.recordName,
                envelope: envelope,
                leaseToken: "lease-voice-\(index)",
                leaseExpiresAt: Date().addingTimeInterval(90)
            ))
            let drainedVoice = try await consumer.drainOnce(waitSeconds: 0)
            precondition(drainedVoice)
        }
        let receivedVoiceBytes = await voices.get()
        precondition(receivedVoiceBytes == audio.count)
        let afterVoice = await transport.snapshot()
        let voicePayload = try CloudRelayProtocol.open(
            afterVoice.published.last!, expectedDirection: .macToWatch, key: watchKey
        )
        let voiceReceipt = try voicePayload.decode(CommandReceipt.self)
        precondition(voiceReceipt.commandID == voiceCommand.id)
        precondition(voiceReceipt.state == .sent)

        let heartbeatID = UUID()
        let heartbeat = try CloudRelayProtocol.seal(
            payload: try .init(
                commandID: heartbeatID,
                operation: .heartbeat,
                body: CloudRelayProtocol.Heartbeat(sentAt: Date())
            ),
            pairingID: pairingID,
            direction: .watchToMac,
            key: watchKey
        )
        await transport.seed(.init(
            recordID: heartbeat.context.recordName,
            envelope: heartbeat,
            leaseToken: "lease-heartbeat",
            leaseExpiresAt: Date().addingTimeInterval(90)
        ))
        let drainedHeartbeat = try await consumer.drainOnce(waitSeconds: 0)
        precondition(drainedHeartbeat)
        let heartbeatReceived = await heartbeats.get()
        precondition(heartbeatReceived)
        let afterHeartbeat = await transport.snapshot()
        let heartbeatPayload = try CloudRelayProtocol.open(
            afterHeartbeat.published.last!, expectedDirection: .macToWatch, key: watchKey
        )
        precondition(heartbeatPayload.operation == .heartbeatAck)
        let heartbeatAck = try heartbeatPayload.decode(CloudRelayProtocol.HeartbeatAck.self)
        precondition(heartbeatAck.requestID == heartbeatID)

        try? FileManager.default.removeItem(at: directory)
        print("Bridge cloud mailbox consumer validation passed")
    }
}
