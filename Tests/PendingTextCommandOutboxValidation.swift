import Foundation

@main
struct PendingTextCommandOutboxValidation {
    static func main() throws {
        let task = CodexTask(
            id: "thread-a",
            title: "Test thread",
            preview: "",
            projectPath: nil,
            updatedAt: Date(),
            state: .idle
        )
        let first = CodexCommand(task: task, text: "Continúa.\n")
        let queued = CommandReceipt(
            commandID: first.id,
            state: .queued,
            message: "Pendiente"
        )
        var outbox = PendingTextCommandOutbox()
        outbox.record(first, receipt: queued)

        precondition(outbox.latest(taskID: task.id)?.command.id == first.id)
        precondition(outbox.matching(taskID: task.id, text: "Continúa.")?.command.id == first.id)
        precondition(outbox.matching(taskID: task.id, text: "Continúa.   ")?.command.id == first.id)
        precondition(outbox.matching(taskID: task.id, text: "Otra orden") == nil)

        let encoded = try JSONEncoder().encode(outbox)
        let restored = try JSONDecoder().decode(PendingTextCommandOutbox.self, from: encoded)
        precondition(restored.matching(taskID: task.id, text: "Continúa.")?.receipt == queued)
        precondition(restored.pending().map(\.command.id) == [first.id])
        precondition(restored.pendingTransportUpload().map(\.command.id) == [first.id])

        // Build 43/44 wrote no transportAcceptedAt field. It must decode as a
        // local-only intent so the exact original UUID can be recovered.
        let legacyObject = try JSONSerialization.jsonObject(with: encoded)
        var legacyDictionary = legacyObject as! [String: Any]
        var legacyIntents = legacyDictionary["intents"] as! [[String: Any]]
        legacyIntents[0].removeValue(forKey: "transportAcceptedAt")
        legacyDictionary["intents"] = legacyIntents
        let legacyData = try JSONSerialization.data(withJSONObject: legacyDictionary)
        let legacyRestored = try JSONDecoder().decode(
            PendingTextCommandOutbox.self,
            from: legacyData
        )
        precondition(legacyRestored.pendingTransportUpload().map(\.command.id) == [first.id])

        outbox.apply(CommandReceipt(
            commandID: first.id,
            state: .queued,
            message: "Solo en el Watch · se reenviará automáticamente"
        ))
        precondition(outbox.pending().map(\.command.id) == [first.id])
        precondition(outbox.pendingTransportUpload().map(\.command.id) == [first.id])

        let accepted = CommandReceipt(
            commandID: first.id,
            state: .queued,
            message: "Aceptada por HTTPS · esperando al Mac"
        )
        outbox.markTransportAccepted(accepted, at: Date(timeIntervalSince1970: 123))
        precondition(outbox.pending().map(\.command.id) == [first.id])
        precondition(outbox.pendingTransportUpload().isEmpty)

        // A queued receipt received from the Mac must not reset the durable
        // transport acknowledgment and trigger another upload.
        outbox.apply(CommandReceipt(
            commandID: first.id,
            state: .queued,
            message: "Orden aceptada; esperando disponibilidad de la tarea"
        ))
        precondition(outbox.pendingTransportUpload().isEmpty)

        outbox.apply(CommandReceipt(commandID: first.id, state: .sent, message: "Enviada"))
        precondition(outbox.latest(taskID: task.id) == nil)
        precondition(outbox.intents.isEmpty)

        print("Pending text command outbox validation passed")
    }
}
