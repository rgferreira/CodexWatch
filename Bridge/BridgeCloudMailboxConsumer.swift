import CryptoKit
import Foundation
import OSLog

actor BridgeCloudMailboxConsumer {
    enum DeliveryOutcome: Sendable {
        case completed(String)
        case queued(String)
        case rejected(String)
        case reconciliationRequired(String)
        case retryableFailure
    }

    typealias Deliver = @Sendable (CodexCommand) async -> DeliveryOutcome
    typealias CreateTask = @Sendable (NewTaskCommand) async -> DeliveryOutcome
    typealias ListTasks = @Sendable () async throws -> [CodexTask]
    typealias ListProjects = @Sendable () async throws -> [CodexProject]
    typealias ReadConversation = @Sendable (String) async throws -> [CodexMessage]
    typealias DeliverVoice = @Sendable (CodexVoiceCommand, Data) async -> DeliveryOutcome
    typealias OperationStatus = @Sendable (UUID) async throws -> String
    typealias Heartbeat = @Sendable (Date) async -> Void

    private static let logger = Logger(
        subsystem: "com.rgferreira.CodexWatchBridge",
        category: "HTTPSMailbox"
    )
    private static func audit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    private let transport: any BlindMailboxTransport
    private let outbox: CloudRelayOutbox
    private let pairingID: String
    private let key: SymmetricKey
    private let deliver: Deliver
    private let createTask: CreateTask
    private let listTasks: ListTasks
    private let listProjects: ListProjects
    private let readConversation: ReadConversation
    private let deliverVoice: DeliverVoice
    private let voiceInbox: CloudVoiceInbox
    private let operationStatus: OperationStatus
    private let heartbeat: Heartbeat

    init(
        transport: any BlindMailboxTransport,
        outbox: CloudRelayOutbox,
        pairingID: String,
        localPrivateKey: Data,
        peerPublicKey: Data,
        deliver: @escaping Deliver,
        createTask: @escaping CreateTask = { _ in .rejected("Creación directa no disponible") },
        listTasks: @escaping ListTasks = { [] },
        listProjects: @escaping ListProjects = { [] },
        readConversation: @escaping ReadConversation = { _ in [] },
        deliverVoice: @escaping DeliverVoice = { _, _ in .rejected("Voz directa no disponible") },
        voiceInbox: CloudVoiceInbox? = nil,
        operationStatus: @escaping OperationStatus,
        heartbeat: @escaping Heartbeat = { _ in }
    ) throws {
        self.transport = transport
        self.outbox = outbox
        self.pairingID = pairingID
        key = try CloudRelayProtocol.sharedKey(
            privateKey: localPrivateKey,
            peerPublicKey: peerPublicKey,
            pairingID: pairingID
        )
        self.deliver = deliver
        self.createTask = createTask
        self.listTasks = listTasks
        self.listProjects = listProjects
        self.readConversation = readConversation
        self.deliverVoice = deliverVoice
        self.voiceInbox = try voiceInbox ?? CloudVoiceInbox()
        self.operationStatus = operationStatus
        self.heartbeat = heartbeat
    }

    /// Drains only one item so the caller can apply bounded backoff and a circuit
    /// breaker around each iteration. Different consumers must not be started for
    /// the same pairing on one Mac.
    func drainOnce(waitSeconds: Int = 20) async throws -> Bool {
        let claims = try await transport.claim(
            direction: .watchToMac,
            waitSeconds: waitSeconds,
            leaseSeconds: 90,
            limit: 1
        )
        guard let claim = claims.first else { return false }
        let payload = try CloudRelayProtocol.open(
            claim.envelope,
            expectedDirection: .watchToMac,
            key: key
        )
        let correlationID = payload.commandID.uuidString.lowercased()
        Self.audit(
            "codexwatch_mailbox_receive correlation=\(correlationID) operation=\(payload.operation.rawValue) result=start"
        )
        if payload.operation == .heartbeat {
            let value = try payload.decode(CloudRelayProtocol.Heartbeat.self)
            await heartbeat(value.sentAt)
            try await publish(
                commandID: payload.commandID,
                operation: .heartbeatAck,
                body: CloudRelayProtocol.HeartbeatAck(
                    requestID: payload.commandID,
                    receivedAt: Date()
                )
            )
            try await transport.acknowledge(
                recordID: claim.recordID,
                leaseToken: claim.leaseToken
            )
            return true
        }
        switch payload.operation {
        case .textCommand:
            let command = try payload.decode(CodexCommand.self)
            guard command.id == payload.commandID else {
                throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
            }
            return try await handleWrite(
                commandID: command.id,
                operation: "text-write",
                claim: claim,
                operationBlock: { [deliver] in await deliver(command) }
            )
        case .newTaskCommand:
            let command = try payload.decode(NewTaskCommand.self)
            guard command.id == payload.commandID else {
                throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
            }
            return try await handleWrite(
                commandID: command.id,
                operation: "create",
                claim: claim,
                operationBlock: { [createTask] in await createTask(command) }
            )
        case .taskListRequest:
            _ = try payload.decode(CloudTaskListRequest.self)
            do {
                let tasks = try await listTasks()
                let revision = Date()
                try await publish(
                    commandID: payload.commandID,
                    operation: .taskListResponse,
                    body: CloudTaskListResponse(
                        requestID: payload.commandID,
                        tasks: tasks,
                        revision: revision
                    )
                )
                Self.audit(
                    "codexwatch_mailbox_receive correlation=\(correlationID) operation=task-list result=success count=\(tasks.count)"
                )
            } catch {
                Self.audit(
                    "codexwatch_mailbox_receive correlation=\(correlationID) operation=task-list result=failure error=\(String(describing: type(of: error)))"
                )
                try await publishReadFailure(
                    requestID: payload.commandID,
                    kind: .tasks,
                    taskID: nil,
                    message: "El Mac no pudo actualizar las tareas"
                )
            }
            try await acknowledge(claim)
            return true
        case .projectListRequest:
            _ = try payload.decode(CloudProjectListRequest.self)
            do {
                let projects = try await listProjects()
                try await publish(
                    commandID: payload.commandID,
                    operation: .projectListResponse,
                    body: CloudProjectListResponse(
                        requestID: payload.commandID,
                        projects: projects,
                        revision: Date()
                    )
                )
                Self.audit(
                    "codexwatch_mailbox_receive correlation=\(correlationID) operation=project-list result=success count=\(projects.count)"
                )
            } catch {
                Self.audit(
                    "codexwatch_mailbox_receive correlation=\(correlationID) operation=project-list result=failure error=\(String(describing: type(of: error)))"
                )
                try await publishReadFailure(
                    requestID: payload.commandID,
                    kind: .projects,
                    taskID: nil,
                    message: "El Mac no pudo actualizar los proyectos"
                )
            }
            try await acknowledge(claim)
            return true
        case .conversationRequest:
            let request = try payload.decode(CloudConversationRequest.self)
            do {
                let messages = try await readConversation(request.taskID)
                try await publish(
                    commandID: payload.commandID,
                    operation: .conversationResponse,
                    body: CloudConversationResponse(
                        requestID: payload.commandID,
                        conversation: CodexConversation(taskID: request.taskID, messages: messages),
                        revision: request.revision
                    )
                )
                Self.audit(
                    "codexwatch_mailbox_receive correlation=\(correlationID) thread=\(request.taskID) operation=conversation-read result=success count=\(messages.count)"
                )
            } catch {
                Self.audit(
                    "codexwatch_mailbox_receive correlation=\(correlationID) thread=\(request.taskID) operation=conversation-read result=failure error=\(String(describing: type(of: error)))"
                )
                try await publishReadFailure(
                    requestID: payload.commandID,
                    kind: .conversation,
                    taskID: request.taskID,
                    message: "El Mac no pudo cargar la conversación"
                )
            }
            try await acknowledge(claim)
            return true
        case .voiceChunk:
            let chunk = try payload.decode(CloudVoiceChunk.self)
            guard chunk.command.id == payload.commandID else {
                throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
            }
            do {
                let completed = try await voiceInbox.ingest(chunk)
                try await acknowledge(claim)
                if let completed { try await processVoice(completed) }
            } catch {
                try? await voiceInbox.remove(commandID: chunk.command.id)
                try await publishReceipt(CommandReceipt(
                    commandID: chunk.command.id,
                    state: .failed,
                    message: error.localizedDescription
                ))
                try await acknowledge(claim)
            }
            return true
        default:
            throw CloudRelayProtocol.ProtocolError.operationMismatch
        }
    }

    private func handleWrite(
        commandID: UUID,
        operation: String,
        claim: BlindMailboxHTTPClient.ClaimedEnvelope,
        operationBlock: @escaping @Sendable () async -> DeliveryOutcome
    ) async throws -> Bool {
        let correlationID = "mailbox-\(commandID.uuidString.lowercased())"
        Self.logger.notice(
            "correlation=\(correlationID, privacy: .public) command=\(commandID.uuidString, privacy: .public) operation=\(operation, privacy: .public) origin=watch-https result=start"
        )
        let renewal = Task { [transport, recordID = claim.recordID, token = claim.leaseToken] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                try? await transport.renew(
                    recordID: recordID,
                    leaseToken: token,
                    leaseSeconds: 90
                )
            }
        }
        let outcome = await operationBlock()
        renewal.cancel()
        switch outcome {
        case .completed(let message):
            try await publishReceipt(
                CommandReceipt(commandID: commandID, state: .sent, message: message)
            )
            try await acknowledge(claim)
        case .queued(let message):
            if operation == "text-write" {
                try await outbox.recordQueued(pairingID: pairingID, commandID: commandID)
            }
            try await publishReceipt(
                CommandReceipt(commandID: commandID, state: .queued, message: message)
            )
            try await acknowledge(claim)
        case .rejected(let message):
            try await publishReceipt(
                CommandReceipt(commandID: commandID, state: .failed, message: message)
            )
            try await acknowledge(claim)
        case .reconciliationRequired(let message):
            try await publishReceipt(
                CommandReceipt(commandID: commandID, state: .failed, message: message)
            )
            try await acknowledge(claim)
        case .retryableFailure:
            Self.logger.error(
                "correlation=\(correlationID, privacy: .public) command=\(commandID.uuidString, privacy: .public) operation=\(operation, privacy: .public) origin=watch-https result=lease-expiry-retry"
            )
            return false
        }
        Self.logger.notice(
            "correlation=\(correlationID, privacy: .public) command=\(commandID.uuidString, privacy: .public) operation=\(operation, privacy: .public) origin=watch-https result=transport-acked"
        )
        return true
    }

    func reconcileVoiceInbox() async throws {
        for completed in try await voiceInbox.completedEntries() {
            try await processVoice(completed)
        }
    }

    private func processVoice(_ completed: CloudVoiceInbox.Completed) async throws {
        let outcome = await deliverVoice(completed.command, completed.audio)
        switch outcome {
        case .completed(let message):
            try await publishReceipt(.init(
                commandID: completed.command.id, state: .sent, message: message
            ))
        case .queued(let message):
            try await outbox.recordQueued(
                pairingID: pairingID,
                commandID: completed.command.id
            )
            try await publishReceipt(.init(
                commandID: completed.command.id, state: .queued, message: message
            ))
        case .rejected(let message), .reconciliationRequired(let message):
            try await publishReceipt(.init(
                commandID: completed.command.id, state: .failed, message: message
            ))
        case .retryableFailure:
            return
        }
        try await voiceInbox.remove(commandID: completed.command.id)
    }

    private func publishReadFailure(
        requestID: UUID,
        kind: CloudReadFailure.Kind,
        taskID: String?,
        message: String
    ) async throws {
        try await publish(
            commandID: requestID,
            operation: .readFailure,
            body: CloudReadFailure(
                requestID: requestID,
                kind: kind,
                taskID: taskID,
                message: message
            )
        )
    }

    private func publish<T: Encodable>(
        commandID: UUID,
        operation: CloudRelayProtocol.Operation,
        body: T
    ) async throws {
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: commandID,
            operation: operation,
            body: body
        )
        let digest = payload.bodySHA256.prefix(6).map { String(format: "%02x", $0) }.joined()
        try await transport.put(CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .macToWatch,
            key: key,
            recordDiscriminator: "\(operation.rawValue)-\(digest)"
        ))
    }

    private func acknowledge(_ claim: BlindMailboxHTTPClient.ClaimedEnvelope) async throws {
        try await transport.acknowledge(
            recordID: claim.recordID,
            leaseToken: claim.leaseToken
        )
    }

    /// Rebuilds receipt delivery after Bridge restart. The journal stores no
    /// prompt or receipt text; Controller remains the source of truth.
    func reconcileOutbox() async throws {
        for entry in await outbox.pending() {
            let status: String
            do { status = try await operationStatus(entry.commandID) }
            catch { continue }
            switch status {
            case "queued", "running":
                continue
            case "completed":
                try await outbox.markTerminalPending(operationID: entry.operationID)
                try await publishReceipt(CommandReceipt(
                    commandID: entry.commandID,
                    state: .sent,
                    message: "Orden completada por Relay"
                ))
                try await outbox.remove(operationID: entry.operationID)
            case "failed", "cancelled":
                try await outbox.markTerminalPending(operationID: entry.operationID)
                try await publishReceipt(CommandReceipt(
                    commandID: entry.commandID,
                    state: .failed,
                    message: "Relay no pudo completar la orden aceptada"
                ))
                try await outbox.remove(operationID: entry.operationID)
            case "unknown", "conflict":
                try await outbox.markTerminalPending(operationID: entry.operationID)
                try await publishReceipt(CommandReceipt(
                    commandID: entry.commandID,
                    state: .failed,
                    message: "La operación requiere conciliación; no se ha reenviado"
                ))
                try await outbox.remove(operationID: entry.operationID)
            default:
                continue
            }
        }
    }

    private func publishReceipt(_ receipt: CommandReceipt) async throws {
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: receipt.commandID,
            operation: .commandReceipt,
            body: receipt
        )
        let envelope = try CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .macToWatch,
            key: key,
            recordDiscriminator: "receipt-\(receipt.state.rawValue)"
        )
        try await transport.put(envelope)
    }
}
