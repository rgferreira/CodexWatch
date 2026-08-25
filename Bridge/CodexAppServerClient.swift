import Foundation

/// Compatibility name retained while CodexWatch migrates to Relay's controller.
/// This component owns no Codex App Server process, JSON-RPC connection or
/// Desktop writer path.
final class CodexAppServerClient: @unchecked Sendable {
    enum SubmissionDisposition {
        case completed
        case queued
    }
    private let baseURL = URL(string: "http://127.0.0.1:48721")!
    private let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Relay/controller-token")
    private let stateQueue = DispatchQueue(label: "CodexWatch.RelayController.State")
    private var threadPaths: [String: String] = [:]

    func start() throws {
        _ = try controllerToken()
    }

    func listTasks() async throws -> [CodexTask] {
        let object = try await request(path: "/v1/threads?limit=12", method: "GET")
        guard let rows = object["threads"] as? [[String: Any]] else { return [] }

        var discoveredPaths: [String: String] = [:]
        let tasks: [CodexTask] = rows.compactMap { row -> CodexTask? in
            guard let id = row["id"] as? String else { return nil }
            if let path = row["path"] as? String, !path.isEmpty {
                discoveredPaths[id] = path
            }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (row["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let candidate = name?.isEmpty == false ? name! : preview
            let title = candidate.isEmpty ? "Tarea sin título" : candidate
            let updated = (row["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            let statusValue: String
            if let status = row["status"] as? String { statusValue = status }
            else if let status = row["status"] as? [String: Any] {
                statusValue = status["type"] as? String ?? "unknown"
            } else { statusValue = "unknown" }
            let state: CodexTask.State = statusValue.contains("active") || statusValue.contains("working") ? .working : .idle
            return CodexTask(
                id: id,
                title: String(title.prefix(80)),
                preview: preview,
                projectPath: row["cwd"] as? String,
                updatedAt: Date(timeIntervalSince1970: updated),
                state: state
            )
        }
        stateQueue.sync {
            threadPaths.merge(discoveredPaths) { _, new in new }
        }
        return tasks
    }

    func send(_ command: CodexCommand) async throws -> SubmissionDisposition {
        let text = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 12_000 else {
            throw makeError("La petición debe tener entre 1 y 12.000 caracteres")
        }
        let result = try await request(
            path: "/v1/turns/submit",
            method: "POST",
            payload: [
                "operation_id": "codex-watch:\(command.id.uuidString)",
                "thread_id": command.taskID,
                "prompt": text,
                "timeout_seconds": 30 * 60
            ],
            timeout: 30 * 60 + 30
        )
        switch result["status"] as? String {
        case "completed": return .completed
        case "queued": return .queued
        default: throw makeError("Relay devolvió un estado de operación desconocido")
        }
    }

    func operationStatus(for commandID: UUID) async throws -> String {
        let result = try await request(
            path: "/v1/operations/codex-watch:\(commandID.uuidString)",
            method: "GET"
        )
        return result["status"] as? String ?? "unknown"
    }

    func createTask(_ command: NewTaskCommand) async throws -> String {
        let prompt = command.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 12_000 else {
            throw makeError("La petición debe tener entre 1 y 12.000 caracteres")
        }
        let projectPath = command.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await request(
            path: "/v1/threads/create-and-submit",
            method: "POST",
            payload: [
                "operation_id": "codex-watch:new:\(command.id.uuidString)",
                "project_path": projectPath?.isEmpty == false
                    ? projectPath!
                    : FileManager.default.homeDirectoryForCurrentUser.path,
                "thread_name": "CodexWatch · \(ISO8601DateFormatter().string(from: command.createdAt))",
                "prompt": prompt,
                "timeout_seconds": 30 * 60
            ],
            timeout: 30 * 60 + 30
        )
        guard result["status"] as? String == "completed",
              let threadID = result["thread_id"] as? String,
              !threadID.isEmpty else {
            throw makeError("Relay no confirmó la nueva tarea")
        }
        return threadID
    }

    func recentMessages(threadID: String, limit: Int = 6) async throws -> [CodexMessage] {
        let path = stateQueue.sync { threadPaths[threadID] }
        guard let path else { return [] }
        return (try? Self.recentMessagesFromRollout(at: path, limit: limit)) ?? []
    }

    private func controllerToken() throws -> String {
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw makeError("El token del Controller está vacío") }
        return token
    }

    private func request(
        path: String,
        method: String,
        payload: [String: Any]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw makeError("Ruta del Controller no válida")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(try controllerToken())", forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError("Relay Codex Controller no devolvió HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw makeError("Relay Codex Controller HTTP \(http.statusCode): \(detail)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw makeError("Relay Codex Controller devolvió JSON inválido")
        }
        return object
    }

    /// Reads only the tail of a local rollout provided by Relay's read model.
    static func recentMessagesFromRollout(at path: String, limit: Int) throws -> [CodexMessage] {
        guard limit > 0 else { return [] }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        var position = try handle.seekToEnd()
        var remainder = Data()
        var newestFirst: [CodexMessage] = []
        let chunkSize: UInt64 = 256 * 1_024

        while position > 0, newestFirst.count < limit {
            let count = min(position, chunkSize)
            position -= count
            try handle.seek(toOffset: position)
            let chunk = try handle.read(upToCount: Int(count)) ?? Data()
            var combined = chunk
            combined.append(remainder)
            let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstLineIsComplete = position == 0
            remainder = firstLineIsComplete ? Data() : Data(lines.first ?? Data.SubSequence())
            let firstIndex = firstLineIsComplete ? 0 : 1

            guard lines.count > firstIndex else { continue }
            for index in stride(from: lines.count - 1, through: firstIndex, by: -1) {
                guard !lines[index].isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(lines[index])) as? [String: Any],
                      object["type"] as? String == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      let eventType = payload["type"] as? String,
                      eventType == "user_message" || eventType == "agent_message",
                      let source = payload["message"] as? String,
                      let text = watchExcerpt(from: source) else { continue }
                let role: CodexMessage.Role = eventType == "user_message" ? .user : .assistant
                let timestamp = object["timestamp"] as? String ?? ""
                newestFirst.append(CodexMessage(
                    id: "\(timestamp)-\(eventType)-\(position)-\(index)",
                    role: role,
                    text: text,
                    createdAt: parseRolloutDate(timestamp)
                ))
                if newestFirst.count == limit { break }
            }
        }
        return newestFirst.reversed()
    }

    private static func parseRolloutDate(_ source: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: source) ?? ISO8601DateFormatter().date(from: source) ?? Date()
    }

    private static func watchExcerpt(from source: String, maximumLength: Int = 700) -> String? {
        let allowedControls = CharacterSet(charactersIn: "\n\t")
        let cleanedScalars = source.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || allowedControls.contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > maximumLength else { return cleaned }
        return String(cleaned.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func makeError(_ message: String) -> Error {
        NSError(domain: "RelayCodexController", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
