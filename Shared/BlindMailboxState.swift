import Foundation

/// Reference state machine for the external blind mailbox. It contains no Codex
/// semantics and is also used by the concurrency validation suite.
actor BlindMailboxState {
    struct Item: Hashable, Sendable {
        let recordName: String
        let pairingID: String
        let direction: CloudRelayProtocol.Direction
        let bindingTag: Data
        let ciphertext: Data
        let createdAt: Date
        let expiresAt: Date
        var leaseOwner: String?
        var leaseUntil: Date?
    }

    enum PutResult: Equatable, Sendable {
        case inserted
        case duplicate
        case conflict
    }

    enum AcknowledgeResult: Equatable, Sendable {
        case removed
        case notFound
        case leaseMismatch
    }

    private var items: [String: Item] = [:]
    private let maximumItemsPerPairing: Int
    private let maximumCiphertextBytes: Int

    init(maximumItemsPerPairing: Int = 100, maximumCiphertextBytes: Int = 70 * 1_024) {
        self.maximumItemsPerPairing = maximumItemsPerPairing
        self.maximumCiphertextBytes = maximumCiphertextBytes
    }

    func put(_ item: Item, now: Date = Date()) -> PutResult {
        purgeExpired(now: now)
        guard item.expiresAt > now,
              item.createdAt.timeIntervalSince(now) <= CloudRelayProtocol.maximumClockSkew,
              item.expiresAt.timeIntervalSince(item.createdAt)
                <= CloudRelayProtocol.envelopeLifetime + CloudRelayProtocol.maximumClockSkew,
              item.ciphertext.count <= maximumCiphertextBytes else {
            return .conflict
        }
        if let existing = items[item.recordName] {
            return existing.bindingTag == item.bindingTag ? .duplicate : .conflict
        }
        let count = items.values.lazy.filter { $0.pairingID == item.pairingID }.count
        guard count < maximumItemsPerPairing else { return .conflict }
        items[item.recordName] = item
        return .inserted
    }

    func claimNext(
        pairingID: String,
        direction: CloudRelayProtocol.Direction,
        owner: String,
        now: Date = Date(),
        leaseLifetime: TimeInterval = CloudRelayProtocol.claimLifetime
    ) -> Item? {
        purgeExpired(now: now)
        let candidateName = items.values
            .filter {
                $0.pairingID == pairingID
                    && $0.direction == direction
                    && ($0.leaseUntil == nil || $0.leaseUntil! <= now || $0.leaseOwner == owner)
            }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.recordName < $1.recordName }
                return $0.createdAt < $1.createdAt
            }
            .first?.recordName
        guard let candidateName, var item = items[candidateName] else { return nil }
        item.leaseOwner = owner
        item.leaseUntil = now.addingTimeInterval(leaseLifetime)
        items[candidateName] = item
        return item
    }

    func acknowledge(recordName: String, owner: String) -> AcknowledgeResult {
        guard let item = items[recordName] else { return .notFound }
        guard item.leaseOwner == owner else { return .leaseMismatch }
        items.removeValue(forKey: recordName)
        return .removed
    }

    func count(now: Date = Date()) -> Int {
        purgeExpired(now: now)
        return items.count
    }

    private func purgeExpired(now: Date) {
        items = items.filter { $0.value.expiresAt > now }
    }
}
