import Foundation

final class CodexAppServerClient: @unchecked Sendable {
    private struct SendableParameters: @unchecked Sendable {
        let value: [String: Any]
    }

    private let queue = DispatchQueue(label: "CodexWatch.AppServer")
    private let input = Pipe()
    private let output = Pipe()
    private var process: Process?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    func start() throws {
        guard process == nil else { return }
        let executable = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ].first(where: FileManager.default.isExecutableFile(atPath:))

        guard let executable else {
            throw NSError(domain: "CodexWatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se encontró el ejecutable de Codex"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let client = self else { return }
            client.queue.async { [weak client] in client?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let client = self else { return }
            client.queue.async { [weak client] in client?.failAll(message: "Codex app-server se ha cerrado") }
        }
        try process.run()
        self.process = process
    }

    func listTasks() async throws -> [CodexTask] {
        try start()
        _ = try await initializeIfNeeded()
        let response = try await request(method: "thread/list", params: [
            "limit": 12,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "archived": false,
            "useStateDbOnly": true,
            "sourceKinds": ["appServer", "cli", "vscode"]
        ])

        guard let result = response["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (row["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = (name?.isEmpty == false ? name! : preview).isEmpty ? "Tarea sin título" : (name?.isEmpty == false ? name! : preview)
            let updated = (row["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            let statusValue: String
            if let status = row["status"] as? String { statusValue = status }
            else if let status = row["status"] as? [String: Any] { statusValue = status["type"] as? String ?? "unknown" }
            else { statusValue = "unknown" }
            let state: CodexTask.State = statusValue.contains("active") || statusValue.contains("working") ? .working : .idle
            return CodexTask(id: id, title: String(title.prefix(80)), preview: preview, projectPath: row["cwd"] as? String, updatedAt: Date(timeIntervalSince1970: updated), state: state)
        }
    }

    func send(_ command: CodexCommand) async throws {
        try start()
        _ = try await initializeIfNeeded()
        _ = try await request(method: "thread/resume", params: ["threadId": command.taskID])
        _ = try await request(method: "turn/start", params: [
            "threadId": command.taskID,
            "input": [["type": "text", "text": command.text]]
        ])
    }

    func recentMessages(threadID: String, limit: Int = 6) async throws -> [CodexMessage] {
        try start()
        _ = try await initializeIfNeeded()
        let response = try await request(method: "thread/read", params: [
            "threadId": threadID,
            "includeTurns": true
        ])

        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]] else { return [] }

        var messages: [CodexMessage] = []
        for turn in turns {
            let timestamp = (turn["startedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            let date = Date(timeIntervalSince1970: timestamp)
            for item in (turn["items"] as? [[String: Any]]) ?? [] {
                guard let type = item["type"] as? String,
                      let id = item["id"] as? String else { continue }
                if type == "userMessage" {
                    let parts = (item["content"] as? [[String: Any]]) ?? []
                    let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if let text = watchExcerpt(from: text) {
                        messages.append(CodexMessage(id: id, role: .user, text: text, createdAt: date))
                    }
                } else if type == "agentMessage", let text = item["text"] as? String, !text.isEmpty {
                    if let text = watchExcerpt(from: text) {
                        messages.append(CodexMessage(id: id, role: .assistant, text: text, createdAt: date))
                    }
                }
            }
        }
        return Array(messages.suffix(limit))
    }

    private func watchExcerpt(from source: String, maximumLength: Int = 700) -> String? {
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

    private var initialized = false

    private func initializeIfNeeded() async throws -> [String: Any] {
        if initialized { return [:] }
        let response = try await request(method: "initialize", params: [
            "clientInfo": ["name": "codex-watch-bridge", "title": "Codex Watch Bridge", "version": "0.4.0"]
        ])
        initialized = true
        return response
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let sendableParameters = SendableParameters(value: params)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let id = self.nextID
                self.nextID += 1
                let message: [String: Any] = ["method": method, "id": id, "params": sendableParameters.value]
                do {
                    var encoded = try JSONSerialization.data(withJSONObject: message)
                    encoded.append(0x0A)
                    self.pending[id] = continuation
                    try self.input.fileHandleForWriting.write(contentsOf: encoded)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if let error = object["error"] as? [String: Any] {
            throw NSError(domain: "CodexAppServer", code: error["code"] as? Int ?? -1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Error de Codex"])
        }
        return object
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: 0..<newline)
            buffer.removeSubrange(0...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue,
                  let continuation = pending.removeValue(forKey: id) else { continue }
            continuation.resume(returning: line)
        }
    }

    private func failAll(message: String) {
        let error = NSError(domain: "CodexAppServer", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        process = nil
        initialized = false
    }
}
