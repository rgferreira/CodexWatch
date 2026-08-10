import Foundation
import Darwin

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
    private let desktopIPC = CodexDesktopIPCClient()

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
        do {
            _ = try await request(method: "thread/resume", params: ["threadId": command.taskID])
            _ = try await request(method: "turn/start", params: [
                "threadId": command.taskID,
                "input": [["type": "text", "text": command.text]]
            ])
        } catch where Self.isActiveWriterError(error) {
            // Codex Desktop keeps the writer lock for every task it owns, even
            // while it is idle. Ask that existing owner to start the turn over
            // Codex's same-user IPC channel instead of waiting on that lock.
            try await desktopIPC.send(command)
        }
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

    private static func isActiveWriterError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("already has an active writer")
    }
}

/// Minimal client for the private, same-user coordination channel exposed by
/// Codex Desktop. It is used only when Desktop already owns the selected task.
private final class CodexDesktopIPCClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexWatch.DesktopIPC")

    func send(_ command: CodexCommand) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.sendSynchronously(command)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendSynchronously(_ command: CodexCommand) throws {
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock").path
        let descriptor = try connect(to: socketPath)
        defer { Darwin.close(descriptor) }

        let initializeID = UUID().uuidString
        try writeRequest(
            descriptor: descriptor,
            requestID: initializeID,
            sourceClientID: "initializing-client",
            version: 0,
            method: "initialize",
            params: ["clientType": "codex-watch-bridge"]
        )
        let initialize = try readResponse(descriptor: descriptor, requestID: initializeID)
        guard initialize["resultType"] as? String == "success",
              let result = initialize["result"] as? [String: Any],
              let clientID = result["clientId"] as? String else {
            throw ipcError(from: initialize, fallback: "Codex Desktop rechazó la conexión local")
        }

        let discoveryID = UUID().uuidString
        try writeRequest(
            descriptor: descriptor,
            requestID: discoveryID,
            sourceClientID: clientID,
            version: 1,
            method: "thread-owner-discovery",
            params: ["hostId": "local", "conversationId": command.taskID]
        )
        let discovery = try readResponse(descriptor: descriptor, requestID: discoveryID)
        guard discovery["resultType"] as? String == "success",
              let ownerClientID = discovery["handledByClientId"] as? String else {
            throw ipcError(from: discovery, fallback: "Codex Desktop no encontró la tarea abierta")
        }

        let startTurnID = UUID().uuidString
        try writeRequest(
            descriptor: descriptor,
            requestID: startTurnID,
            sourceClientID: clientID,
            targetClientID: ownerClientID,
            version: 1,
            method: "thread-follower-start-turn",
            params: [
                "conversationId": command.taskID,
                "turnStartParams": [
                    "input": [["type": "text", "text": command.text]]
                ]
            ],
            timeoutMilliseconds: 20_000
        )
        let startTurn = try readResponse(descriptor: descriptor, requestID: startTurnID)
        guard startTurn["resultType"] as? String == "success" else {
            throw ipcError(from: startTurn, fallback: "Codex Desktop no pudo enviar la orden")
        }
    }

    private func connect(to path: String) throws -> Int32 {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw makeError("La ruta IPC de Codex es demasiado larga")
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw makePOSIXError("No se pudo crear la conexión IPC") }

        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let error = makePOSIXError("No se pudo contactar con Codex Desktop")
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func writeRequest(
        descriptor: Int32,
        requestID: String,
        sourceClientID: String,
        targetClientID: String? = nil,
        version: Int,
        method: String,
        params: [String: Any],
        timeoutMilliseconds: Int = 5_000
    ) throws {
        var request: [String: Any] = [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": sourceClientID,
            "version": version,
            "method": method,
            "params": params,
            "timeoutMs": timeoutMilliseconds
        ]
        if let targetClientID { request["targetClientId"] = targetClientID }

        let payload = try JSONSerialization.data(withJSONObject: request)
        guard payload.count <= Int(UInt32.max) else { throw makeError("Mensaje IPC demasiado grande") }
        var length = UInt32(payload.count).littleEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try writeAll(header, descriptor: descriptor)
        try writeAll(payload, descriptor: descriptor)
    }

    private func readResponse(descriptor: Int32, requestID: String) throws -> [String: Any] {
        while true {
            let header = try readExactly(MemoryLayout<UInt32>.size, descriptor: descriptor)
            let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            guard length > 0, length <= 256 * 1024 * 1024 else {
                throw makeError("Codex Desktop devolvió una respuesta IPC inválida")
            }
            let payload = try readExactly(Int(length), descriptor: descriptor)
            guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw makeError("Codex Desktop devolvió una respuesta ilegible")
            }
            if message["type"] as? String == "response",
               message["requestId"] as? String == requestID {
                return message
            }
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                guard result > 0 else { throw makePOSIXError("Se cortó el envío a Codex Desktop") }
                written += result
            }
        }
    }

    private func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        let received = try data.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            var offset = 0
            while offset < count {
                let result = Darwin.read(descriptor, baseAddress.advanced(by: offset), count - offset)
                guard result > 0 else { throw makePOSIXError("Se cortó la respuesta de Codex Desktop") }
                offset += result
            }
            return offset
        }
        guard received == count else { throw makeError("Respuesta IPC incompleta") }
        return data
    }

    private func ipcError(from response: [String: Any], fallback: String) -> Error {
        makeError((response["error"] as? String).map { "\(fallback): \($0)" } ?? fallback)
    }

    private func makePOSIXError(_ prefix: String) -> Error {
        makeError("\(prefix): \(String(cString: strerror(errno)))")
    }

    private func makeError(_ message: String) -> Error {
        NSError(domain: "CodexDesktopIPC", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
