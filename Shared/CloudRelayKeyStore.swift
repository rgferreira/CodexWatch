import Foundation

enum CloudRelayKeyStore {
    private static let service = "com.rgferreira.CodexWatch.CloudRelay.v1"

    struct Identity: Codable, Hashable, Sendable {
        let deviceID: String
        let privateKey: Data
    }

    static func loadOrCreateIdentity(role: String) throws -> Identity {
        let account = "\(role)-identity"
        if let data = try SecureTokenStore.loadData(service: service, account: account) {
            return try CodexWatchWire.decode(Identity.self, from: data)
        }
        let identity = Identity(
            deviceID: UUID().uuidString.lowercased(),
            privateKey: CloudRelayProtocol.generatePrivateKey()
        )
        try SecureTokenStore.saveData(
            CodexWatchWire.encode(identity),
            service: service,
            account: account
        )
        return identity
    }

    static func loadPairing(role: String, pairingID: String) throws
        -> CloudRelayProtocol.PairingMaterial? {
        guard let data = try SecureTokenStore.loadData(
            service: service,
            account: "\(role)-pairing-\(pairingID)"
        ) else { return nil }
        return try CodexWatchWire.decode(CloudRelayProtocol.PairingMaterial.self, from: data)
    }

    static func savePairing(
        _ pairing: CloudRelayProtocol.PairingMaterial,
        role: String
    ) throws {
        try SecureTokenStore.saveData(
            CodexWatchWire.encode(pairing),
            service: service,
            account: "\(role)-pairing-\(pairing.pairingID)"
        )
    }

    static func deletePairing(role: String, pairingID: String) throws {
        try SecureTokenStore.delete(
            service: service,
            account: "\(role)-pairing-\(pairingID)"
        )
    }

    static func loadActivePairingID(role: String) -> String? {
        UserDefaults.standard.string(forKey: "cloudRelay.\(role).activePairingID")
    }

    static func setActivePairingID(_ pairingID: String?, role: String) {
        UserDefaults.standard.set(pairingID, forKey: "cloudRelay.\(role).activePairingID")
    }

    static func loadTransport(role: String, pairingID: String) throws
        -> CloudRelayTransportConfiguration? {
        guard let data = try SecureTokenStore.loadData(
            service: service,
            account: "\(role)-transport-\(pairingID)"
        ) else { return nil }
        return try CodexWatchWire.decode(CloudRelayTransportConfiguration.self, from: data)
    }

    static func saveTransport(
        _ configuration: CloudRelayTransportConfiguration,
        role: String
    ) throws {
        try SecureTokenStore.saveData(
            CodexWatchWire.encode(configuration),
            service: service,
            account: "\(role)-transport-\(configuration.pairingID)"
        )
    }

    static func loadPendingOffer(role: String) throws -> CloudRelayPairingOffer? {
        guard let data = try SecureTokenStore.loadData(
            service: service,
            account: "\(role)-pending-offer"
        ) else { return nil }
        return try CodexWatchWire.decode(CloudRelayPairingOffer.self, from: data)
    }

    static func savePendingOffer(_ offer: CloudRelayPairingOffer, role: String) throws {
        try SecureTokenStore.saveData(
            CodexWatchWire.encode(offer),
            service: service,
            account: "\(role)-pending-offer"
        )
    }

    static func deletePendingOffer(role: String) throws {
        try SecureTokenStore.delete(
            service: service,
            account: "\(role)-pending-offer"
        )
    }
}
