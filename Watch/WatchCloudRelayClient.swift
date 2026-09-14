import CryptoKit
import Foundation

actor WatchCloudRelayClient {
    enum Event: Sendable {
        case receipt(CommandReceipt)
        case tasks(CloudTaskListResponse)
        case conversation(CloudConversationResponse)
        case readFailure(CloudReadFailure)
        case heartbeatAck(CloudRelayProtocol.HeartbeatAck)
    }

    private let transport: BlindMailboxHTTPClient
    private let pairingID: String
    private let key: SymmetricKey

    init(
        configuration: CloudRelayTransportConfiguration,
        pairing: CloudRelayProtocol.PairingMaterial
    ) throws {
        guard let peerPublicKey = pairing.peerPublicKey,
              pairing.pairingID == configuration.pairingID,
              pairing.isApproved else {
            throw BlindMailboxHTTPClient.ClientError.invalidConfiguration
        }
        transport = BlindMailboxHTTPClient(configuration: try .init(
            baseURL: configuration.baseURL,
            pairingID: configuration.pairingID,
            transportSecret: configuration.transportSecret
        ))
        pairingID = configuration.pairingID
        key = try CloudRelayProtocol.sharedKey(
            privateKey: pairing.privateKey,
            peerPublicKey: peerPublicKey,
            pairingID: configuration.pairingID
        )
    }

    func send(_ command: CodexCommand) async throws {
        try await put(
            commandID: command.id,
            operation: .textCommand,
            body: command
        )
    }

    func createTask(_ command: NewTaskCommand) async throws {
        try await put(
            commandID: command.id,
            operation: .newTaskCommand,
            body: command
        )
    }

    func requestTasks(requestID: UUID) async throws {
        try await put(
            commandID: requestID,
            operation: .taskListRequest,
            body: CloudTaskListRequest(requestedAt: Date())
        )
    }

    func requestConversation(
        requestID: UUID,
        taskID: String,
        revision: Date
    ) async throws {
        try await put(
            commandID: requestID,
            operation: .conversationRequest,
            body: CloudConversationRequest(taskID: taskID, revision: revision)
        )
    }

    func sendVoice(_ command: CodexVoiceCommand, audio: Data) async throws {
        guard !audio.isEmpty, audio.count <= CloudVoiceChunk.maximumAudioBytes else {
            throw CloudRelayProtocol.ProtocolError.payloadTooLarge
        }
        let chunkSize = CloudVoiceChunk.preferredChunkBytes
        let count = (audio.count + chunkSize - 1) / chunkSize
        let digest = Data(SHA256.hash(data: audio))
        for index in 0..<count {
            let lower = index * chunkSize
            let upper = min(lower + chunkSize, audio.count)
            let chunk = CloudVoiceChunk(
                command: command,
                chunkIndex: index,
                chunkCount: count,
                audioSHA256: digest,
                bytes: audio.subdata(in: lower..<upper)
            )
            try await putWithRetry(
                commandID: command.id,
                operation: .voiceChunk,
                body: chunk,
                discriminator: "voice-\(index)-of-\(count)"
            )
            if index + 1 < count {
                try await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    func sendHeartbeat() async throws -> UUID {
        let identifier = UUID()
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: identifier,
            operation: .heartbeat,
            body: CloudRelayProtocol.Heartbeat(sentAt: Date())
        )
        try await putWithShortRetry(CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .watchToMac,
            key: key
        ))
        return identifier
    }

    func receiveOnce(waitSeconds: Int = 20) async throws -> [Event] {
        let claims = try await transport.claim(
            direction: .macToWatch,
            waitSeconds: waitSeconds,
            leaseSeconds: 45,
            limit: 4
        )
        var events: [Event] = []
        for claim in claims {
            let payload = try CloudRelayProtocol.open(
                claim.envelope,
                expectedDirection: .macToWatch,
                key: key
            )
            let event: Event
            switch payload.operation {
            case .commandReceipt:
                let receipt = try payload.decode(CommandReceipt.self)
                guard receipt.commandID == payload.commandID else {
                    throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
                }
                event = .receipt(receipt)
            case .taskListResponse:
                let response = try payload.decode(CloudTaskListResponse.self)
                guard response.requestID == payload.commandID else {
                    throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
                }
                event = .tasks(response)
            case .conversationResponse:
                let response = try payload.decode(CloudConversationResponse.self)
                guard response.requestID == payload.commandID else {
                    throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
                }
                event = .conversation(response)
            case .readFailure:
                let failure = try payload.decode(CloudReadFailure.self)
                guard failure.requestID == payload.commandID else {
                    throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
                }
                event = .readFailure(failure)
            case .heartbeatAck:
                let acknowledgment = try payload.decode(CloudRelayProtocol.HeartbeatAck.self)
                guard acknowledgment.requestID == payload.commandID else {
                    throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
                }
                event = .heartbeatAck(acknowledgment)
            default:
                throw CloudRelayProtocol.ProtocolError.operationMismatch
            }
            try await transport.acknowledge(
                recordID: claim.recordID,
                leaseToken: claim.leaseToken
            )
            events.append(event)
        }
        return events
    }

    private func put<T: Encodable>(
        commandID: UUID,
        operation: CloudRelayProtocol.Operation,
        body: T,
        discriminator: String = ""
    ) async throws {
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: commandID,
            operation: operation,
            body: body
        )
        try await putWithShortRetry(CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .watchToMac,
            key: key,
            recordDiscriminator: discriminator
        ))
    }

    private func putWithShortRetry(
        _ envelope: CloudRelayProtocol.SealedEnvelope
    ) async throws {
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        var retry = 0
        while true {
            do {
                try await transport.put(envelope)
                return
            } catch BlindMailboxHTTPClient.ClientError.rateLimited where retry < delays.count {
                try await Task.sleep(for: delays[retry])
                retry += 1
            } catch BlindMailboxHTTPClient.ClientError.unavailable where retry < delays.count {
                try await Task.sleep(for: delays[retry])
                retry += 1
            } catch let error as URLError where retry < delays.count
                && [.timedOut, .networkConnectionLost, .notConnectedToInternet]
                    .contains(error.code) {
                try await Task.sleep(for: delays[retry])
                retry += 1
            }
        }
    }

    private func putWithRetry<T: Encodable>(
        commandID: UUID,
        operation: CloudRelayProtocol.Operation,
        body: T,
        discriminator: String
    ) async throws {
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: commandID,
            operation: operation,
            body: body
        )
        let envelope = try CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .watchToMac,
            key: key,
            recordDiscriminator: discriminator
        )
        let delays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
        var retry = 0
        while true {
            do {
                try await transport.put(envelope)
                return
            } catch BlindMailboxHTTPClient.ClientError.rateLimited where retry < delays.count {
                try await Task.sleep(for: delays[retry])
                retry += 1
            } catch BlindMailboxHTTPClient.ClientError.unavailable where retry < delays.count {
                try await Task.sleep(for: delays[retry])
                retry += 1
            } catch let error as URLError where retry < delays.count
                && [.timedOut, .networkConnectionLost, .notConnectedToInternet]
                    .contains(error.code) {
                try await Task.sleep(for: delays[retry])
                retry += 1
            }
        }
    }
}
