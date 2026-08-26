import Foundation

actor CloudRelayOutbox {
    struct Entry: Codable, Hashable, Sendable {
        enum DeliveryState: String, Codable, Sendable {
            case controllerQueued
            case terminalPendingUpload
        }

        let pairingID: String
        let commandID: UUID
        let operationID: String
        var deliveryState: DeliveryState
        let createdAt: Date
        var updatedAt: Date
    }

    enum OutboxError: LocalizedError {
        case unsafeOperationID
        case corruptJournal

        var errorDescription: String? {
            switch self {
            case .unsafeOperationID: "El operation ID del journal no es válido"
            case .corruptJournal: "El journal cifrado de recibos no es válido"
            }
        }
    }

    private let fileURL: URL
    private var entries: [String: Entry]

    init(fileURL: URL? = nil) throws {
        let resolved = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexWatchBridge", isDirectory: true)
            .appendingPathComponent("cloud-relay-outbox.json")
        self.fileURL = resolved
        if FileManager.default.fileExists(atPath: resolved.path) {
            let data = try Data(contentsOf: resolved)
            do {
                entries = try CodexWatchWire.decode([String: Entry].self, from: data)
            } catch {
                throw OutboxError.corruptJournal
            }
        } else {
            entries = [:]
        }
    }

    func recordQueued(pairingID: String, commandID: UUID, now: Date = Date()) throws {
        let operationID = "codex-watch:\(commandID.uuidString)"
        guard operationID.count <= 240, pairingID.count <= 128 else {
            throw OutboxError.unsafeOperationID
        }
        entries[operationID] = Entry(
            pairingID: pairingID,
            commandID: commandID,
            operationID: operationID,
            deliveryState: .controllerQueued,
            createdAt: entries[operationID]?.createdAt ?? now,
            updatedAt: now
        )
        try persist()
    }

    func markTerminalPending(operationID: String, now: Date = Date()) throws {
        guard var entry = entries[operationID] else { return }
        entry.deliveryState = .terminalPendingUpload
        entry.updatedAt = now
        entries[operationID] = entry
        try persist()
    }

    func remove(operationID: String) throws {
        entries.removeValue(forKey: operationID)
        try persist()
    }

    func pending() -> [Entry] {
        entries.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try CodexWatchWire.encode(entries)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
