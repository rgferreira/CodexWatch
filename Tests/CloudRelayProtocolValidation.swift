import CryptoKit
import Foundation

@main
struct CloudRelayProtocolValidation {
    static func main() throws {
        let watchPrivate = CloudRelayProtocol.generatePrivateKey()
        let macPrivate = CloudRelayProtocol.generatePrivateKey()
        let watchPublic = try CloudRelayProtocol.publicKey(for: watchPrivate)
        let macPublic = try CloudRelayProtocol.publicKey(for: macPrivate)
        let pairingID = UUID().uuidString.lowercased()
        let watchKey = try CloudRelayProtocol.sharedKey(
            privateKey: watchPrivate,
            peerPublicKey: macPublic,
            pairingID: pairingID
        )
        let macKey = try CloudRelayProtocol.sharedKey(
            privateKey: macPrivate,
            peerPublicKey: watchPublic,
            pairingID: pairingID
        )
        precondition(watchKey.withUnsafeBytes { Data($0) } == macKey.withUnsafeBytes { Data($0) })
        let watchSAS = CloudRelayProtocol.shortAuthenticationString(
            pairingID: pairingID,
            firstPublicKey: watchPublic,
            secondPublicKey: macPublic
        )
        let macSAS = CloudRelayProtocol.shortAuthenticationString(
            pairingID: pairingID,
            firstPublicKey: macPublic,
            secondPublicKey: watchPublic
        )
        precondition(watchSAS == macSAS)
        precondition(watchSAS.count == 6)

        let task = CodexTask(
            id: "test-thread",
            title: "Disposable transport test",
            preview: "",
            projectPath: nil,
            updatedAt: Date(),
            state: .idle
        )
        let command = CodexCommand(task: task, text: "Encrypted test command")
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: command.id,
            operation: .textCommand,
            body: command
        )
        let now = Date()
        let envelope = try CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .watchToMac,
            key: watchKey,
            now: now
        )
        let opened = try CloudRelayProtocol.open(
            envelope,
            expectedDirection: .watchToMac,
            key: macKey,
            now: now
        )
        let decoded = try opened.decode(CodexCommand.self)
        precondition(decoded.id == command.id)
        precondition(decoded.taskID == command.taskID)
        precondition(decoded.taskTitle == command.taskTitle)
        precondition(decoded.text == command.text)

        let stableName = CloudRelayProtocol.recordName(
            commandID: command.id,
            direction: .watchToMac,
            key: watchKey
        )
        precondition(stableName == envelope.context.recordName)
        precondition(stableName == CloudRelayProtocol.recordName(
            commandID: command.id,
            direction: .watchToMac,
            key: macKey
        ))
        precondition(stableName != CloudRelayProtocol.recordName(
            commandID: command.id,
            direction: .macToWatch,
            key: macKey
        ))

        let secondEnvelope = try CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .watchToMac,
            key: watchKey,
            now: now
        )
        precondition(envelope.combinedCiphertext != secondEnvelope.combinedCiphertext)

        var tamperedCiphertext = envelope.combinedCiphertext
        tamperedCiphertext[tamperedCiphertext.startIndex] ^= 1
        try expect(.authenticationFailed) {
            _ = try CloudRelayProtocol.open(
                .init(
                    context: envelope.context,
                    combinedCiphertext: tamperedCiphertext,
                    bindingTag: envelope.bindingTag
                ),
                expectedDirection: .watchToMac,
                key: macKey,
                now: now
            )
        }

        let alteredContext = CloudRelayProtocol.EnvelopeContext(
            pairingID: pairingID,
            direction: .watchToMac,
            recordName: "e1_" + String(repeating: "a", count: 43),
            createdAt: now,
            expiresAt: now.addingTimeInterval(CloudRelayProtocol.envelopeLifetime)
        )
        try expect(.authenticationFailed) {
            _ = try CloudRelayProtocol.open(
                .init(
                    context: alteredContext,
                    combinedCiphertext: envelope.combinedCiphertext,
                    bindingTag: envelope.bindingTag
                ),
                expectedDirection: .watchToMac,
                key: macKey,
                now: now
            )
        }

        try expect(.operationMismatch) {
            _ = try CloudRelayProtocol.open(
                envelope,
                expectedDirection: .macToWatch,
                key: macKey,
                now: now
            )
        }

        try expect(.expired) {
            _ = try CloudRelayProtocol.open(
                envelope,
                expectedDirection: .watchToMac,
                key: macKey,
                now: now.addingTimeInterval(
                    CloudRelayProtocol.envelopeLifetime + CloudRelayProtocol.maximumClockSkew + 1
                )
            )
        }

        let otherKey = try CloudRelayProtocol.sharedKey(
            privateKey: CloudRelayProtocol.generatePrivateKey(),
            peerPublicKey: macPublic,
            pairingID: pairingID
        )
        try expect(.authenticationFailed) {
            _ = try CloudRelayProtocol.open(
                envelope,
                expectedDirection: .watchToMac,
                key: otherKey,
                now: now
            )
        }

        let changed = CodexCommand(task: task, text: "Different content")
        let changedPayload = try CloudRelayProtocol.SealedPayload(
            commandID: command.id,
            operation: .textCommand,
            body: changed
        )
        precondition(
            CloudRelayProtocol.payloadFingerprint(payload)
                != CloudRelayProtocol.payloadFingerprint(changedPayload)
        )

        print("Cloud relay protocol validation passed")
    }

    private static func expect(
        _ expected: CloudRelayProtocol.ProtocolError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            preconditionFailure("Expected \(expected)")
        } catch let error as CloudRelayProtocol.ProtocolError {
            precondition(error == expected, "Expected \(expected), got \(error)")
        }
    }
}
