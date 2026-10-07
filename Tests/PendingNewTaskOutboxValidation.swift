import Foundation

@main
struct PendingNewTaskOutboxValidation {
    static func main() throws {
        let command = NewTaskCommand(prompt: "Five people, Saturday at 13:45, Fuencarral", projectPath: nil)
        let queued = CommandReceipt(commandID: command.id, state: .queued, message: "Local")
        var outbox = PendingNewTaskOutbox()
        precondition(outbox.record(command, receipt: queued))
        precondition(outbox.record(command, receipt: queued))
        precondition(outbox.intents.count == 1)
        let data = try CodexWatchWire.encode(outbox)
        var restored = try CodexWatchWire.decode(PendingNewTaskOutbox.self, from: data)
        precondition(restored.pendingTransportUpload().first?.command.id == command.id)
        precondition(restored.pendingTransportUpload().first?.command.prompt == command.prompt)
        precondition(CommandContentFingerprint.matches(command.prompt, digest: command.contentSHA256, bytes: command.contentBytes))
        precondition(!CommandContentFingerprint.matches("cut message", digest: command.contentSHA256, bytes: command.contentBytes))
        precondition(!CommandContentFingerprint.matches(command.prompt, digest: command.contentSHA256, bytes: nil))
        precondition(CommandContentFingerprint.matches(command.prompt, digest: nil, bytes: nil)) // Old build compatibility.
        var altered = try JSONSerialization.jsonObject(with: CodexWatchWire.encode(command)) as! [String: Any]
        altered["prompt"] = "cut message"
        let changed = try CodexWatchWire.decode(NewTaskCommand.self, from: JSONSerialization.data(withJSONObject: altered))
        precondition(!CommandContentFingerprint.matches(changed.prompt, digest: changed.contentSHA256, bytes: changed.contentBytes))
        let duplicateTap = NewTaskCommand(prompt: command.prompt, projectPath: nil)
        precondition(restored.matching(duplicateTap)?.command.id == command.id)
        restored.apply(queued, transportAccepted: true)
        precondition(restored.pendingTransportUpload().isEmpty)
        precondition(restored.intents.first?.command.prompt == command.prompt)
        restored.apply(.init(commandID: command.id, state: .failed, message: "Reconciliation required"))
        precondition(restored.intents.count == 1) // Failed payload remains recoverable, never auto-replayed.
        precondition(restored.pendingTransportUpload().isEmpty)
        restored.apply(.init(commandID: command.id, state: .sent, message: "Response ready"))
        precondition(restored.intents.isEmpty)
        print("Pending new task outbox validation passed")
    }
}
