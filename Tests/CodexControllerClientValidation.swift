import Foundation

@main
struct CodexControllerClientValidation {
    static func main() throws {
        let client = CodexAppServerClient()
        let threadID = UUID().uuidString
        let queued = try client.taskCreationResult(from: [
            "status": "queued", "thread_id": threadID
        ])
        precondition(queued.threadID == threadID)
        if case .queued = queued.disposition {} else {
            preconditionFailure("A durable 202 must remain pending")
        }

        let completed = try client.taskCreationResult(from: [
            "status": "completed", "thread_id": threadID
        ])
        if case .completed = completed.disposition {} else {
            preconditionFailure("A completed turn must be terminal")
        }

        for invalid in [
            ["status": "queued"],
            ["status": "unknown", "thread_id": threadID]
        ] {
            do {
                _ = try client.taskCreationResult(from: invalid)
                preconditionFailure("Unconfirmed creation was accepted")
            } catch {}
        }
        print("Controller create response validation passed")
    }
}
