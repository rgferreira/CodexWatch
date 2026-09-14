import Foundation

enum CloudRelayKeyStore {
    private static let service = "com.rgferreira.CodexWatch.CloudRelay.v1"
    private static func activeAccount(role: String) -> String { "\(role)-active-pairing" }

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
        if let stored = try? SecureTokenStore.load(
            service: service,
            account: activeAccount(role: role)
        ) {
            UserDefaults.standard.set(stored, forKey: "cloudRelay.\(role).activePairingID")
            return stored
        }
        guard let legacy = UserDefaults.standard.string(
            forKey: "cloudRelay.\(role).activePairingID"
        ) else { return nil }
        try? SecureTokenStore.save(
            legacy,
            service: service,
            account: activeAccount(role: role)
        )
        return legacy
    }

    static func setActivePairingID(_ pairingID: String?, role: String) {
        UserDefaults.standard.set(pairingID, forKey: "cloudRelay.\(role).activePairingID")
        if let pairingID {
            try? SecureTokenStore.save(
                pairingID,
                service: service,
                account: activeAccount(role: role)
            )
        } else {
            try? SecureTokenStore.delete(
                service: service,
                account: activeAccount(role: role)
            )
        }
    }

    static func recoverApprovedPairing(
        role: String
    ) throws -> (
        pairing: CloudRelayProtocol.PairingMaterial,
        transport: CloudRelayTransportConfiguration
    )? {
        let prefix = "\(role)-pairing-"
        let identifiers = try SecureTokenStore.accounts(service: service)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        let candidates = try identifiers.compactMap { pairingID -> (
            CloudRelayProtocol.PairingMaterial,
            CloudRelayTransportConfiguration
        )? in
            guard let pairing = try loadPairing(role: role, pairingID: pairingID),
                  pairing.isApproved,
                  let transport = try loadTransport(role: role, pairingID: pairingID),
                  transport.pairingID == pairingID else { return nil }
            return (pairing, transport)
        }
        guard let recovered = candidates.max(by: {
            ($0.0.approvedAt ?? .distantPast) < ($1.0.approvedAt ?? .distantPast)
        }) else { return nil }
        setActivePairingID(recovered.0.pairingID, role: role)
        return (recovered.0, recovered.1)
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
