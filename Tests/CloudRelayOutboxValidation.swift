import Foundation

@main
struct CloudRelayOutboxValidation {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexwatch-outbox-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("outbox.json")
        let commandID = UUID()
        let first = try CloudRelayOutbox(fileURL: url)
        try await first.recordQueued(pairingID: "pairing", commandID: commandID)
        let firstPending = await first.pending()
        precondition(firstPending.count == 1)
        precondition(firstPending[0].operationID == "codex-watch:\(commandID.uuidString)")

        let restarted = try CloudRelayOutbox(fileURL: url)
        let afterRestart = await restarted.pending()
        precondition(afterRestart.count == 1)
        precondition(afterRestart[0].operationID == firstPending[0].operationID)
        precondition(afterRestart[0].commandID == firstPending[0].commandID)
        precondition(afterRestart[0].deliveryState == firstPending[0].deliveryState)
        try await restarted.markTerminalPending(operationID: afterRestart[0].operationID)

        let restartedAgain = try CloudRelayOutbox(fileURL: url)
        let terminal = await restartedAgain.pending()
        precondition(terminal[0].deliveryState == .terminalPendingUpload)
        try await restartedAgain.remove(operationID: terminal[0].operationID)
        let finalEntries = await restartedAgain.pending()
        precondition(finalEntries.isEmpty)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        precondition(permissions == 0o600)
        try? FileManager.default.removeItem(at: directory)
        print("Cloud relay outbox restart validation passed")
    }
}
