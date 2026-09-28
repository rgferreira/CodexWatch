import CryptoKit
import Foundation

struct CloudRelayTransportConfiguration: Codable, Hashable, Sendable {
    let baseURL: URL
    let pairingID: String
    let transportSecret: Data
}

struct CloudRelayPairingRequest: Codable, Hashable, Sendable {
    let watchDeviceID: String
    let watchPublicKey: Data
}

struct CloudRelayPairingOffer: Codable, Hashable, Sendable {
    let configuration: CloudRelayTransportConfiguration
    let macDeviceID: String
    let macPublicKey: Data
    let watchDeviceID: String
    let watchPublicKey: Data
    let authenticationCode: String
}

struct CloudRelayPairingApproval: Codable, Hashable, Sendable {
    let pairingID: String
    let watchDeviceID: String
    let watchPublicKey: Data
    let authenticationCode: String
}

struct CloudRelayPairingResult: Codable, Hashable, Sendable {
    let pairingID: String
    let accepted: Bool
    let message: String
}

/// Ephemeral bootstrap material synchronized by iCloud Keychain between the
/// Mac bridge and the Watch-only app. The transport secret never crosses an
/// unauthenticated network endpoint; the user still compares the SAS before
/// either peer promotes the material to an approved E2E pairing.
struct CloudRelayStandaloneBootstrapOffer: Codable, Hashable, Sendable {
    static let version = 1
    static let lifetime: TimeInterval = 15 * 60

    let protocolVersion: Int
    let bootstrapID: UUID
    let createdAt: Date
    let expiresAt: Date
    let configuration: CloudRelayTransportConfiguration
    let macDeviceID: String
    let macPublicKey: Data

    init(
        bootstrapID: UUID = UUID(),
        createdAt: Date = Date(),
        configuration: CloudRelayTransportConfiguration,
        macDeviceID: String,
        macPublicKey: Data
    ) {
        protocolVersion = Self.version
        self.bootstrapID = bootstrapID
        let normalizedCreatedAt = Date(
            timeIntervalSince1970: floor(createdAt.timeIntervalSince1970)
        )
        self.createdAt = normalizedCreatedAt
        expiresAt = normalizedCreatedAt.addingTimeInterval(Self.lifetime)
        self.configuration = configuration
        self.macDeviceID = macDeviceID
        self.macPublicKey = macPublicKey
    }

    func isValid(at now: Date = Date()) -> Bool {
        protocolVersion == Self.version
            && !macDeviceID.isEmpty
            && macPublicKey.count == 32
            && !configuration.pairingID.isEmpty
            && configuration.transportSecret.count >= 32
            && configuration.baseURL.scheme?.lowercased() == "https"
            && expiresAt > createdAt
            && expiresAt.timeIntervalSince(createdAt) <= Self.lifetime + 1
            && now >= createdAt.addingTimeInterval(-CloudRelayProtocol.maximumClockSkew)
            && now <= expiresAt
    }

    /// Binds the human-verification code to every security-relevant bootstrap
    /// field, including the mailbox URL and transport secret. An altered iCloud
    /// copy therefore cannot retain the same six-digit SAS.
    func bindingDigest() -> Data {
        let fields = [
            Data(String(protocolVersion).utf8),
            Data(bootstrapID.uuidString.lowercased().utf8),
            Data(String(Int64(createdAt.timeIntervalSince1970)).utf8),
            Data(String(Int64(expiresAt.timeIntervalSince1970)).utf8),
            Data(configuration.baseURL.absoluteString.utf8),
            Data(configuration.pairingID.utf8),
            configuration.transportSecret,
            Data(macDeviceID.utf8),
            macPublicKey
        ]
        var value = Data("CodexWatch.StandaloneBootstrap.v1".utf8)
        for field in fields {
            var count = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &count) { value.append(contentsOf: $0) }
            value.append(field)
        }
        return Data(SHA256.hash(data: value))
    }
}

struct CloudRelayStandaloneBootstrapResponse: Codable, Hashable, Sendable {
    let protocolVersion: Int
    let bootstrapID: UUID
    let pairingID: String
    let macDeviceID: String
    let macPublicKey: Data
    let watchDeviceID: String
    let watchPublicKey: Data
    let offerBindingSHA256: Data
    let authenticationCode: String
    let approvedOnWatch: Bool
    let updatedAt: Date

    init(
        offer: CloudRelayStandaloneBootstrapOffer,
        watchDeviceID: String,
        watchPublicKey: Data,
        approvedOnWatch: Bool,
        updatedAt: Date = Date()
    ) {
        protocolVersion = CloudRelayStandaloneBootstrapOffer.version
        bootstrapID = offer.bootstrapID
        pairingID = offer.configuration.pairingID
        macDeviceID = offer.macDeviceID
        macPublicKey = offer.macPublicKey
        self.watchDeviceID = watchDeviceID
        self.watchPublicKey = watchPublicKey
        offerBindingSHA256 = offer.bindingDigest()
        authenticationCode = CloudRelayProtocol.shortAuthenticationString(
            pairingID: offer.configuration.pairingID,
            firstPublicKey: watchPublicKey,
            secondPublicKey: offer.macPublicKey,
            binding: offerBindingSHA256
        )
        self.approvedOnWatch = approvedOnWatch
        self.updatedAt = updatedAt
    }

    func matches(
        _ offer: CloudRelayStandaloneBootstrapOffer,
        at now: Date = Date()
    ) -> Bool {
        offer.isValid(at: now)
            && protocolVersion == offer.protocolVersion
            && bootstrapID == offer.bootstrapID
            && pairingID == offer.configuration.pairingID
            && macDeviceID == offer.macDeviceID
            && macPublicKey == offer.macPublicKey
            && !watchDeviceID.isEmpty
            && watchPublicKey.count == 32
            && offerBindingSHA256 == offer.bindingDigest()
            && authenticationCode == CloudRelayProtocol.shortAuthenticationString(
                pairingID: pairingID,
                firstPublicKey: watchPublicKey,
                secondPublicKey: macPublicKey,
                binding: offerBindingSHA256
            )
            && updatedAt >= offer.createdAt.addingTimeInterval(-CloudRelayProtocol.maximumClockSkew)
            && updatedAt <= offer.expiresAt.addingTimeInterval(CloudRelayProtocol.maximumClockSkew)
    }
}
