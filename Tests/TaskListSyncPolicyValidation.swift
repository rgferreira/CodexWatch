import Foundation

@main
struct TaskListSyncPolicyValidation {
    static func main() {
        precondition(TaskListSyncPolicy.acceptsDirectResponse(
            requestGeneration: 1, lastAppliedGeneration: 0
        ))
        // A timed-out response remains useful after request 2 begins.
        precondition(TaskListSyncPolicy.acceptsDirectResponse(
            requestGeneration: 1, lastAppliedGeneration: 0
        ))
        // Once request 2 was applied, request 1 cannot roll the list back.
        precondition(!TaskListSyncPolicy.acceptsDirectResponse(
            requestGeneration: 1, lastAppliedGeneration: 2
        ))
        precondition(!TaskListSyncPolicy.acceptsDirectResponse(
            requestGeneration: nil, lastAppliedGeneration: 0
        ))
        // Device clocks must not veto a response to the current direct request.
        let futureCompanionRevision = Date().addingTimeInterval(3_600).timeIntervalSince1970
        precondition(TaskListSyncPolicy.acceptsDirectResponse(
            requestGeneration: 2, lastAppliedGeneration: 0
        ))
        precondition(!TaskListSyncPolicy.acceptsCompanionRevision(
            Date().timeIntervalSince1970,
            latestRevision: futureCompanionRevision
        ))
        precondition(TaskListSyncPolicy.acceptsCompanionRevision(nil, latestRevision: 0))
        precondition(!TaskListSyncPolicy.acceptsCompanionRevision(nil, latestRevision: 1))
        let now = Date()
        precondition(TaskListSyncPolicy.isStale(lastUpdatedAt: nil, now: now))
        precondition(!TaskListSyncPolicy.isStale(lastUpdatedAt: now.addingTimeInterval(-60), now: now))
        precondition(TaskListSyncPolicy.isStale(lastUpdatedAt: now.addingTimeInterval(-121), now: now))
        print("task-list synchronization policy: ok")
    }
}
