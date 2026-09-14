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

        outbox.apply(CommandReceipt(commandID: first.id, state: .sent, message: "Enviada"))
        precondition(outbox.latest(taskID: task.id) == nil)
        precondition(outbox.intents.isEmpty)

        print("Pending text command outbox validation passed")
    }
}
