import Foundation

@main
struct RolloutConversationValidation {
    static func main() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexwatch-rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data(repeating: 0x78, count: 400_000)
        data.append(0x0A)
        for index in 0..<8 {
            let role = index.isMultiple(of: 2) ? "user_message" : "agent_message"
            let object: [String: Any] = [
                "timestamp": "2026-08-14T20:00:0\(index).000Z",
                "type": "event_msg",
                "payload": ["type": role, "message": "mensaje \(index)"]
            ]
            data.append(try JSONSerialization.data(withJSONObject: object))
            data.append(0x0A)
        }
        try data.write(to: url)

        let messages = try CodexAppServerClient.recentMessagesFromRollout(
            at: url.path,
            limit: 6
        )
        precondition(messages.count == 6)
        precondition(messages.map(\.text) == (2..<8).map { "mensaje \($0)" })
        precondition(messages.first?.role == .user)
        precondition(messages.last?.role == .assistant)

        if CommandLine.arguments.count > 1 {
            let started = Date()
            let realMessages = try CodexAppServerClient.recentMessagesFromRollout(
                at: CommandLine.arguments[1],
                limit: 6
            )
            precondition(realMessages.count == 6)
            print("Real rollout: \(realMessages.count) messages in \(Date().timeIntervalSince(started))s")
        }
        print("Rollout conversation validation passed")
    }
}
