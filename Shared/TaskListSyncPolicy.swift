import Foundation

/// Direct mailbox responses are ordered by a local Watch request sequence,
/// not by clocks on the Watch, iPhone and Mac. A late response may still be
/// useful even when a newer request is already in flight. Companion pushes
/// retain their revision ordering because they lack a request sequence.
enum TaskListSyncPolicy {
    static let staleAfter: TimeInterval = 120

    static func acceptsDirectResponse(
        requestGeneration: UInt64?,
        lastAppliedGeneration: UInt64
    ) -> Bool {
        guard let requestGeneration else { return false }
        return requestGeneration > lastAppliedGeneration
    }

    static func acceptsCompanionRevision(_ revision: TimeInterval?, latestRevision: TimeInterval) -> Bool {
        if let revision { return revision >= latestRevision }
        return latestRevision == 0
    }

    static func isStale(lastUpdatedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastUpdatedAt else { return true }
        return now.timeIntervalSince(lastUpdatedAt) > staleAfter
    }
}
