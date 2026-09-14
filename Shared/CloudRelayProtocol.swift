import CryptoKit
import Foundation

enum CloudRelayProtocol {
    static let version = 1
    static let containerIdentifier = "iCloud.com.rgferreira.CodexWatch"
    static let pairingRecordType = "CWPairingV1"
    static let envelopeRecordType = "CWEnvelopeV1"
    static let maximumPlaintextBytes = 64 * 1_024
    static let envelopeLifetime: TimeInterval = 24 * 60 * 60
    static let pairingLifetime: TimeInterval = 10 * 60
    static let maximumClockSkew: TimeInterval = 2 * 60
    static let claimLifetime: TimeInterval = 45

    enum Direction: String, Codable, Sendable {
        case watchToMac
        case macToWatch
    }

    enum Operation: String, Codable, Sendable {
        case textCommand
        case newTaskCommand
        case commandReceipt
        case heartbeat
        case heartbeatAck
        case taskListRequest
        case taskListResponse
        case projectListRequest
        case projectListResponse
        case conversationRequest
        case conversationResponse
        case readFailure
        case voiceChunk
    }

    struct Heartbeat: Codable, Hashable, Sendable {
        let sentAt: Date
    }

    struct HeartbeatAck: Codable, Hashable, Sendable {
        let requestID: UUID
        let receivedAt: Date
    }

    enum ProtocolError: LocalizedError, Equatable {
        case unsupportedVersion
        case invalidIdentifier
        case invalidKey
        case malformedEnvelope
        case authenticationFailed
        case expired
        case createdInFuture
        case payloadTooLarge
        case payloadHashMismatch
        case recordBindingMismatch
        case operationMismatch

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "Versión de transporte no compatible"
            case .invalidIdentifier: "Identificador de transporte no válido"
            case .invalidKey: "Clave de emparejamiento no válida"
            case .malformedEnvelope: "Sobre cifrado no válido"
            case .authenticationFailed: "No se pudo autenticar el sobre cifrado"
            case .expired: "El sobre cifrado ha caducado"
            case .createdInFuture: "La fecha del sobre cifrado no es válida"
            case .payloadTooLarge: "El mensaje supera el tamaño permitido"
            case .payloadHashMismatch: "El contenido no coincide con su huella"
            case .recordBindingMismatch: "El sobre no coincide con su identificador"
            case .operationMismatch: "La operación cifrada no coincide con la esperada"
            }
        }
    }

    struct PairingMaterial: Codable, Hashable, Sendable {
        let pairingID: String
        let deviceID: String
        let privateKey: Data
        let peerPublicKey: Data?
        let approvedAt: Date?

        var isApproved: Bool { peerPublicKey != nil && approvedAt != nil }
    }

    struct EnvelopeContext: Codable, Hashable, Sendable {
        let version: Int
        let pairingID: String
        let direction: Direction
        let recordName: String
        let recordDiscriminator: String
        let createdAtMilliseconds: Int64
        let expiresAtMilliseconds: Int64

        init(
            pairingID: String,
            direction: Direction,
            recordName: String,
            recordDiscriminator: String = "",
            createdAt: Date,
            expiresAt: Date
        ) {
            version = CloudRelayProtocol.version
            self.pairingID = pairingID
            self.direction = direction
            self.recordName = recordName
            self.recordDiscriminator = recordDiscriminator
            createdAtMilliseconds = Int64(createdAt.timeIntervalSince1970 * 1_000)
            expiresAtMilliseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000)
        }

        var createdAt: Date {
            Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1_000)
        }

        var expiresAt: Date {
            Date(timeIntervalSince1970: TimeInterval(expiresAtMilliseconds) / 1_000)
        }
    }

    struct SealedPayload: Codable, Hashable, Sendable {
        let version: Int
        let commandID: UUID
        let operation: Operation
        let body: Data
        let bodySHA256: Data

        init<T: Encodable>(commandID: UUID, operation: Operation, body: T) throws {
            version = CloudRelayProtocol.version
            self.commandID = commandID
            self.operation = operation
            self.body = try CodexWatchWire.encode(body)
            bodySHA256 = Data(SHA256.hash(data: self.body))
            guard self.body.count <= CloudRelayProtocol.maximumPlaintextBytes else {
                throw ProtocolError.payloadTooLarge
            }
        }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            guard body.count <= CloudRelayProtocol.maximumPlaintextBytes else {
                throw ProtocolError.payloadTooLarge
            }
            guard Data(SHA256.hash(data: body)) == bodySHA256 else {
                throw ProtocolError.payloadHashMismatch
            }
            return try CodexWatchWire.decode(type, from: body)
        }
    }

    struct SealedEnvelope: Codable, Hashable, Sendable {
        let context: EnvelopeContext
        let combinedCiphertext: Data
        let bindingTag: Data
    }

    static func generatePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    static func publicKey(for privateKey: Data) throws -> Data {
        do {
            return try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: privateKey
            ).publicKey.rawRepresentation
        } catch {
            throw ProtocolError.invalidKey
        }
    }

    static func sharedKey(
        privateKey: Data,
        peerPublicKey: Data,
        pairingID: String
    ) throws -> SymmetricKey {
        guard validIdentifier(pairingID) else { throw ProtocolError.invalidIdentifier }
        do {
            let local = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            let secret = try local.sharedSecretFromKeyAgreement(with: peer)
            return secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("CodexWatch.CloudRelay.v1.\(pairingID)".utf8),
                sharedInfo: Data("Watch-Mac blind mailbox".utf8),
                outputByteCount: 32
            )
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.invalidKey
        }
    }

    static func recordName(
        commandID: UUID,
        direction: Direction,
        discriminator: String = "",
        key: SymmetricKey
    ) -> String {
        let input = Data(
            "v1|\(direction.rawValue)|\(commandID.uuidString.lowercased())|\(discriminator)".utf8
        )
        let authentication = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
        return "e1_" + base64URL(authentication)
    }

    static func seal(
        payload: SealedPayload,
        pairingID: String,
        direction: Direction,
        key: SymmetricKey,
        recordDiscriminator: String = "",
        now: Date = Date(),
        lifetime: TimeInterval = envelopeLifetime
    ) throws -> SealedEnvelope {
        guard payload.version == version else { throw ProtocolError.unsupportedVersion }
        guard validIdentifier(pairingID) else { throw ProtocolError.invalidIdentifier }
        guard payload.body.count <= maximumPlaintextBytes else { throw ProtocolError.payloadTooLarge }
        guard recordDiscriminator.count <= 64 else { throw ProtocolError.invalidIdentifier }
        let name = recordName(
            commandID: payload.commandID,
            direction: direction,
            discriminator: recordDiscriminator,
            key: key
        )
        let context = EnvelopeContext(
            pairingID: pairingID,
            direction: direction,
            recordName: name,
            recordDiscriminator: recordDiscriminator,
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        let plaintext = try canonicalEncoder.encode(payload)
        guard plaintext.count <= maximumPlaintextBytes + 2_048 else {
            throw ProtocolError.payloadTooLarge
        }
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: try canonicalEncoder.encode(context)
        )
        return SealedEnvelope(
            context: context,
            combinedCiphertext: box.combined,
            bindingTag: bindingTag(for: payload, recordName: name, key: key)
        )
    }

    static func open(
        _ envelope: SealedEnvelope,
        expectedDirection: Direction,
        key: SymmetricKey,
        now: Date = Date()
    ) throws -> SealedPayload {
        let context = envelope.context
        guard context.version == version else { throw ProtocolError.unsupportedVersion }
        guard context.direction == expectedDirection else { throw ProtocolError.operationMismatch }
        guard validIdentifier(context.pairingID), validRecordName(context.recordName) else {
            throw ProtocolError.invalidIdentifier
        }
        guard context.createdAt.timeIntervalSince(now) <= maximumClockSkew else {
            throw ProtocolError.createdInFuture
        }
        guard now.timeIntervalSince(context.expiresAt) <= maximumClockSkew else {
            throw ProtocolError.expired
        }
        guard context.expiresAt > context.createdAt,
              context.expiresAt.timeIntervalSince(context.createdAt) <= envelopeLifetime + maximumClockSkew else {
            throw ProtocolError.malformedEnvelope
        }
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: envelope.combinedCiphertext)
            let plaintext = try ChaChaPoly.open(
                box,
                using: key,
                authenticating: try canonicalEncoder.encode(context)
            )
            guard plaintext.count <= maximumPlaintextBytes + 2_048 else {
                throw ProtocolError.payloadTooLarge
            }
            let payload = try canonicalDecoder.decode(SealedPayload.self, from: plaintext)
            guard payload.version == version else { throw ProtocolError.unsupportedVersion }
            guard payload.body.count <= maximumPlaintextBytes else { throw ProtocolError.payloadTooLarge }
            guard Data(SHA256.hash(data: payload.body)) == payload.bodySHA256 else {
                throw ProtocolError.payloadHashMismatch
            }
            guard recordName(
                commandID: payload.commandID,
                direction: context.direction,
                discriminator: context.recordDiscriminator,
                key: key
            ) == context.recordName else {
                throw ProtocolError.recordBindingMismatch
            }
            guard bindingTag(for: payload, recordName: context.recordName, key: key)
                    == envelope.bindingTag else {
                throw ProtocolError.payloadHashMismatch
            }
            return payload
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.authenticationFailed
        }
    }

    static func verificationCode(pairingID: String, watchPublicKey: Data) -> String {
        let digest = SHA256.hash(data: Data(pairingID.utf8) + watchPublicKey)
        let value = digest.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    static func shortAuthenticationString(
        pairingID: String,
        firstPublicKey: Data,
        secondPublicKey: Data
    ) -> String {
        let ordered = firstPublicKey.lexicographicallyPrecedes(secondPublicKey)
            ? [firstPublicKey, secondPublicKey]
            : [secondPublicKey, firstPublicKey]
        var input = Data("CodexWatch.Pairing.SAS.v1|\(pairingID)|".utf8)
        input.append(ordered[0])
        input.append(ordered[1])
        let digest = SHA256.hash(data: input)
        let value = digest.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    static func payloadFingerprint(_ payload: SealedPayload) -> Data {
        var value = Data(payload.operation.rawValue.utf8)
        value.append(Data(payload.commandID.uuidString.lowercased().utf8))
        value.append(payload.bodySHA256)
        return Data(SHA256.hash(data: value))
    }

    private static func bindingTag(
        for payload: SealedPayload,
        recordName: String,
        key: SymmetricKey
    ) -> Data {
        var input = Data(recordName.utf8)
        input.append(payloadFingerprint(payload))
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
    }

    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var canonicalDecoder: JSONDecoder { JSONDecoder() }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func validRecordName(_ value: String) -> Bool {
        value.hasPrefix("e1_") && value.count == 46 && validIdentifier(value)
    }
}
