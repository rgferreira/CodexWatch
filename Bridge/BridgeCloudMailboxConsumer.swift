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
    typealias OperationStatus = @Sendable (UUID) async throws -> String
    typealias Heartbeat = @Sendable (Date) async -> Void

    private static let logger = Logger(
        subsystem: "com.rgferreira.CodexWatchBridge",
        category: "HTTPSMailbox"
    )
    private let transport: any BlindMailboxTransport
    private let outbox: CloudRelayOutbox
    private let pairingID: String
    private let key: SymmetricKey
    private let deliver: Deliver
    private let operationStatus: OperationStatus
    private let heartbeat: Heartbeat

    init(
        transport: any BlindMailboxTransport,
        outbox: CloudRelayOutbox,
        pairingID: String,
        localPrivateKey: Data,
        peerPublicKey: Data,
        deliver: @escaping Deliver,
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
        if payload.operation == .heartbeat {
            let value = try payload.decode(CloudRelayProtocol.Heartbeat.self)
            await heartbeat(value.sentAt)
            try await transport.acknowledge(
                recordID: claim.recordID,
                leaseToken: claim.leaseToken
            )
            return true
        }
        guard payload.operation == .textCommand else {
            throw CloudRelayProtocol.ProtocolError.operationMismatch
        }
        let command = try payload.decode(CodexCommand.self)
        guard command.id == payload.commandID else {
            throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
        }
        let correlationID = "mailbox-\(command.id.uuidString.lowercased())"
        Self.logger.notice(
            "correlation=\(correlationID, privacy: .public) command=\(command.id.uuidString, privacy: .public) operation=text-write origin=watch-https result=start"
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
        let outcome = await deliver(command)
        renewal.cancel()

        switch outcome {
        case .completed(let message):
            try await publishReceipt(
                CommandReceipt(commandID: command.id, state: .sent, message: message)
            )
            try await transport.acknowledge(
                recordID: claim.recordID,
                leaseToken: claim.leaseToken
            )
        case .queued(let message):
            try await outbox.recordQueued(pairingID: pairingID, commandID: command.id)
            try await publishReceipt(
                CommandReceipt(commandID: command.id, state: .queued, message: message)
            )
            try await transport.acknowledge(
                recordID: claim.recordID,
                leaseToken: claim.leaseToken
            )
        case .rejected(let message):
            try await publishReceipt(
                CommandReceipt(commandID: command.id, state: .failed, message: message)
            )
            try await transport.acknowledge(
                recordID: claim.recordID,
                leaseToken: claim.leaseToken
            )
        case .reconciliationRequired(let message):
            try await publishReceipt(
                CommandReceipt(commandID: command.id, state: .failed, message: message)
            )
            try await transport.acknowledge(
                recordID: claim.recordID,
                leaseToken: claim.leaseToken
            )
        case .retryableFailure:
            Self.logger.error(
                "correlation=\(correlationID, privacy: .public) command=\(command.id.uuidString, privacy: .public) operation=text-write origin=watch-https result=lease-expiry-retry"
            )
            return false
        }
        Self.logger.notice(
            "correlation=\(correlationID, privacy: .public) command=\(command.id.uuidString, privacy: .public) operation=text-write origin=watch-https result=transport-acked"
        )
        return true
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
