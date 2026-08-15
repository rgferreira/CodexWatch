import Foundation

@main
struct DisposableThreadProbe {
    static func main() async throws {
        guard CommandLine.arguments.contains("--run-real") else {
            print("Pass --run-real to create one disposable safety-test thread")
            return
        }
        let client = CodexAppServerClient()
        let threadID = try await client.createTask(NewTaskCommand(
            prompt: "Disposable CodexWatch safety test. Reply only with: SAFETY TEST OK.",
            projectPath: nil
        ))
        try await Task.sleep(for: .seconds(2))
        let tasks = try await client.listTasks()
        guard tasks.contains(where: { $0.id == threadID }) else {
            throw NSError(
                domain: "CodexWatchProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The disposable thread was not readable after writer shutdown"]
            )
        }
        print("Disposable thread probe passed: \(threadID)")
    }
}
