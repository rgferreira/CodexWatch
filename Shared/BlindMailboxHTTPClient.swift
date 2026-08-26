import CryptoKit
import Foundation
import Security

protocol BlindMailboxTransport: Sendable {
    func put(_ envelope: CloudRelayProtocol.SealedEnvelope) async throws
    func claim(
        direction: CloudRelayProtocol.Direction,
        waitSeconds: Int,
        leaseSeconds: Int,
        limit: Int
    ) async throws -> [BlindMailboxHTTPClient.ClaimedEnvelope]
    func renew(recordID: String, leaseToken: String, leaseSeconds: Int) async throws
    func acknowledge(recordID: String, leaseToken: String) async throws
}

final class BlindMailboxHTTPClient: BlindMailboxTransport, @unchecked Sendable {
    struct Configuration: Codable, Hashable, Sendable {
        let baseURL: URL
        let pairingID: String
        let transportSecret: Data

        init(
            baseURL: URL,
            pairingID: String,
            transportSecret: Data,
            allowInsecureLocalhost: Bool = false
        ) throws {
            let isLocalhost = baseURL.host == "127.0.0.1" || baseURL.host == "localhost"
            guard baseURL.scheme == "https" || (allowInsecureLocalhost && isLocalhost),
                  baseURL.user == nil,
                  baseURL.password == nil,
                  baseURL.query == nil,
                  baseURL.fragment == nil,
                  BlindMailboxHTTPClient.validOpaqueIdentifier(pairingID),
                  transportSecret.count >= 32 else {
                throw ClientError.invalidConfiguration
            }
            self.baseURL = baseURL
            self.pairingID = pairingID
            self.transportSecret = transportSecret
        }
    }

    struct ClaimedEnvelope: Hashable, Sendable {
        let recordID: String
        let envelope: CloudRelayProtocol.SealedEnvelope
        let leaseToken: String
        let leaseExpiresAt: Date
    }

    enum ClientError: LocalizedError, Equatable {
        case invalidConfiguration
        case invalidResponse
        case authenticationRejected
        case idempotencyConflict
        case expired
        case payloadTooLarge
        case rateLimited
        case leaseLost
        case unavailable(Int)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "Configuración del buzón no válida"
            case .invalidResponse: "El buzón devolvió una respuesta no válida"
            case .authenticationRejected: "El buzón rechazó la autenticación"
            case .idempotencyConflict: "El mismo ID contiene otro sobre"
            case .expired: "El sobre ha caducado"
            case .payloadTooLarge: "El sobre supera el tamaño permitido"
            case .rateLimited: "El buzón ha limitado temporalmente las solicitudes"
            case .leaseLost: "Otro consumidor posee el lease"
            case .unavailable(let status): "Buzón HTTPS no disponible (HTTP \(status))"
            }
        }
    }

    private struct ClaimRequest: Codable {
        let direction: String
        let waitSeconds: Int
        let leaseSeconds: Int
        let limit: Int

        enum CodingKeys: String, CodingKey {
            case direction
            case waitSeconds = "wait_seconds"
            case leaseSeconds = "lease_seconds"
            case limit
        }
    }

    private struct ClaimResponse: Codable {
        struct Item: Codable {
            let recordID: String
            let envelope: Data
            let leaseToken: String
            let leaseExpiresAt: Date

            enum CodingKeys: String, CodingKey {
                case recordID = "record_id"
                case envelope
                case leaseToken = "lease_token"
                case leaseExpiresAt = "lease_expires_at"
            }
        }
        let items: [Item]
    }

    private struct LeaseRequest: Codable {
        let leaseToken: String
        let leaseSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case leaseToken = "lease_token"
            case leaseSeconds = "lease_seconds"
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let value = URLSessionConfiguration.ephemeral
            value.timeoutIntervalForRequest = 35
            value.timeoutIntervalForResource = 40
            value.waitsForConnectivity = false
            value.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: value)
        }
    }

    func put(_ envelope: CloudRelayProtocol.SealedEnvelope) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(envelope)
        guard body.count <= 70 * 1_024 else { throw ClientError.payloadTooLarge }
        var request = try authenticatedRequest(
            method: "POST",
            path: pairingPath("/envelopes"),
            body: body
        )
        request.setValue(
            String(envelope.context.version),
            forHTTPHeaderField: "X-Envelope-Version"
        )
        request.setValue(
            envelope.context.direction.rawValue == "watchToMac" ? "watch_to_mac" : "mac_to_watch",
            forHTTPHeaderField: "X-Direction"
        )
        request.setValue(envelope.context.recordName, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(
            base64URL(envelope.bindingTag),
            forHTTPHeaderField: "X-Idempotency-Digest"
        )
        request.setValue(
            ISO8601DateFormatter().string(from: envelope.context.expiresAt),
            forHTTPHeaderField: "X-Expires-At"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try validate(response, accepted: [200, 201])
    }

    func claim(
        direction: CloudRelayProtocol.Direction,
        waitSeconds: Int = 20,
        leaseSeconds: Int = 45,
        limit: Int = 1
    ) async throws -> [ClaimedEnvelope] {
        guard (0...25).contains(waitSeconds),
              (5...90).contains(leaseSeconds),
              (1...4).contains(limit) else {
            throw ClientError.invalidConfiguration
        }
        let body = try CodexWatchWire.encode(ClaimRequest(
            direction: direction == .watchToMac ? "watch_to_mac" : "mac_to_watch",
            waitSeconds: waitSeconds,
            leaseSeconds: leaseSeconds,
            limit: limit
        ))
        var request = try authenticatedRequest(
            method: "POST",
            path: pairingPath("/claims"),
            body: body
        )
        request.timeoutInterval = TimeInterval(waitSeconds + 10)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response, accepted: [200])
        guard data.count <= 320 * 1_024 else { throw ClientError.payloadTooLarge }
        let decoded = try CodexWatchWire.decode(ClaimResponse.self, from: data)
        return try decoded.items.map { item in
            ClaimedEnvelope(
                recordID: item.recordID,
                envelope: try CodexWatchWire.decode(
                    CloudRelayProtocol.SealedEnvelope.self,
                    from: item.envelope
                ),
                leaseToken: item.leaseToken,
                leaseExpiresAt: item.leaseExpiresAt
            )
        }
    }

    func renew(recordID: String, leaseToken: String, leaseSeconds: Int = 45) async throws {
        guard (5...90).contains(leaseSeconds) else { throw ClientError.invalidConfiguration }
        try await postLeaseAction(
            recordID: recordID,
            action: "lease",
            payload: LeaseRequest(leaseToken: leaseToken, leaseSeconds: leaseSeconds)
        )
    }

    func acknowledge(recordID: String, leaseToken: String) async throws {
        try await postLeaseAction(
            recordID: recordID,
            action: "ack",
            payload: LeaseRequest(leaseToken: leaseToken, leaseSeconds: nil)
        )
    }

    func authenticatedRequest(
        method: String,
        path: String,
        body: Data,
        now: Date = Date(),
        nonce: Data? = nil
    ) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains(".."),
              let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw ClientError.invalidConfiguration
        }
        let timestamp = String(Int64(now.timeIntervalSince1970))
        let nonceData = try nonce ?? secureRandom(count: 16)
        let nonceValue = base64URL(nonceData)
        let digest = base64URL(Data(SHA256.hash(data: body)))
        let canonical = Data(
            "\(method.uppercased())\n\(path)\n\(timestamp)\n\(nonceValue)\n\(digest)".utf8
        )
        let signature = base64URL(Data(HMAC<SHA256>.authenticationCode(
            for: canonical,
            using: SymmetricKey(data: configuration.transportSecret)
        )))
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.httpBody = body
        request.setValue(timestamp, forHTTPHeaderField: "X-Transport-Timestamp")
        request.setValue(nonceValue, forHTTPHeaderField: "X-Transport-Nonce")
        request.setValue(digest, forHTTPHeaderField: "X-Content-Digest")
        request.setValue("CW-HMAC \(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func postLeaseAction<T: Encodable>(
        recordID: String,
        action: String,
        payload: T
    ) async throws {
        guard Self.validOpaqueIdentifier(recordID) else {
            throw ClientError.invalidConfiguration
        }
        let body = try CodexWatchWire.encode(payload)
        var request = try authenticatedRequest(
            method: "POST",
            path: pairingPath("/envelopes/\(recordID)/\(action)"),
            body: body
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try validate(response, accepted: [200, 204])
    }

    private func pairingPath(_ suffix: String) -> String {
        let encoded = configuration.pairingID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? configuration.pairingID
        return "/v1/pairings/\(encoded)\(suffix)"
    }

    private func validate(_ response: URLResponse, accepted: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard accepted.contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw ClientError.authenticationRejected
            case 409: throw ClientError.idempotencyConflict
            case 410: throw ClientError.expired
            case 413: throw ClientError.payloadTooLarge
            case 423: throw ClientError.leaseLost
            case 429: throw ClientError.rateLimited
            default: throw ClientError.unavailable(http.statusCode)
            }
        }
    }

    private func secureRandom(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw ClientError.invalidConfiguration }
        return data
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func validOpaqueIdentifier(_ value: String) -> Bool {
        guard (16...128).contains(value.count) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
