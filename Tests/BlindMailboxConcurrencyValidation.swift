import Foundation

@main
struct BlindMailboxConcurrencyValidation {
    static func main() async {
        let now = Date()
        let mailbox = BlindMailboxState(maximumItemsPerPairing: 3)
        let item = BlindMailboxState.Item(
            recordName: "e1_" + String(repeating: "a", count: 43),
            pairingID: "pairing",
            direction: .watchToMac,
            bindingTag: Data(repeating: 1, count: 32),
            ciphertext: Data(repeating: 2, count: 128),
            createdAt: now,
            expiresAt: now.addingTimeInterval(900),
            leaseOwner: nil,
            leaseUntil: nil
        )
        let firstPut = await mailbox.put(item, now: now)
        let duplicatePut = await mailbox.put(item, now: now)
        precondition(firstPut == .inserted)
        precondition(duplicatePut == .duplicate)
        var conflict = item
        conflict = .init(
            recordName: item.recordName,
            pairingID: item.pairingID,
            direction: item.direction,
            bindingTag: Data(repeating: 9, count: 32),
            ciphertext: item.ciphertext,
            createdAt: item.createdAt,
            expiresAt: item.expiresAt,
            leaseOwner: nil,
            leaseUntil: nil
        )
        let conflictPut = await mailbox.put(conflict, now: now)
        precondition(conflictPut == .conflict)

        let claims = await withTaskGroup(of: BlindMailboxState.Item?.self) { group in
            group.addTask {
                await mailbox.claimNext(
                    pairingID: "pairing", direction: .watchToMac,
                    owner: "mac-a", now: now
                )
            }
            group.addTask {
                await mailbox.claimNext(
                    pairingID: "pairing", direction: .watchToMac,
                    owner: "mac-b", now: now
                )
            }
            var values: [BlindMailboxState.Item?] = []
            for await value in group { values.append(value) }
            return values
        }
        precondition(claims.compactMap { $0 }.count == 1)
        let winner = claims.compactMap { $0 }.first!
        let loser = winner.leaseOwner == "mac-a" ? "mac-b" : "mac-a"
        let losingAcknowledgement = await mailbox.acknowledge(
            recordName: winner.recordName, owner: loser
        )
        precondition(losingAcknowledgement == .leaseMismatch)

        let reclaimed = await mailbox.claimNext(
            pairingID: "pairing",
            direction: .watchToMac,
            owner: loser,
            now: now.addingTimeInterval(CloudRelayProtocol.claimLifetime + 1)
        )
        precondition(reclaimed?.leaseOwner == loser)
        let winningAcknowledgement = await mailbox.acknowledge(
            recordName: item.recordName, owner: loser
        )
        precondition(winningAcknowledgement == .removed)

        let expired = BlindMailboxState.Item(
            recordName: "e1_" + String(repeating: "b", count: 43),
            pairingID: "pairing",
            direction: .watchToMac,
            bindingTag: Data(repeating: 3, count: 32),
            ciphertext: Data(repeating: 4, count: 128),
            createdAt: now.addingTimeInterval(-901),
            expiresAt: now.addingTimeInterval(-1),
            leaseOwner: nil,
            leaseUntil: nil
        )
        let expiredPut = await mailbox.put(expired, now: now)
        let remaining = await mailbox.count(now: now)
        precondition(expiredPut == .conflict)
        precondition(remaining == 0)
        print("Blind mailbox concurrency validation passed")
    }
}
