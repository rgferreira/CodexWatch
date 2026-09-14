import CryptoKit
import Foundation

/// Durable, bounded staging for encrypted voice chunks after the blind mailbox
/// has handed them to the Mac. Audio is removed as soon as it is processed.
actor CloudVoiceInbox {
    struct Completed: Sendable {
        let command: CodexVoiceCommand
        let audio: Data
    }

    private struct Manifest: Codable, Hashable {
        let command: CodexVoiceCommand
        let chunkCount: Int
        let audioSHA256: Data
        let createdAt: Date
    }

    enum InboxError: LocalizedError {
        case invalidChunk
        case conflictingChunk
        case invalidAudio

        var errorDescription: String? {
            switch self {
            case .invalidChunk: "Fragmento de audio no válido"
            case .conflictingChunk: "Los fragmentos de audio no coinciden"
            case .invalidAudio: "La nota de voz reconstruida no es válida"
            }
        }
    }

    private let root: URL

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexWatchBridge", isDirectory: true)
            .appendingPathComponent("cloud-voice-inbox", isDirectory: true)
        try Self.secureDirectory(self.root)
    }

    func ingest(_ chunk: CloudVoiceChunk) throws -> Completed? {
        guard (1...64).contains(chunk.chunkCount),
              chunk.chunkIndex >= 0,
              chunk.chunkIndex < chunk.chunkCount,
              !chunk.bytes.isEmpty,
              chunk.bytes.count <= CloudVoiceChunk.preferredChunkBytes,
              chunk.audioSHA256.count == SHA256.byteCount else {
            throw InboxError.invalidChunk
        }
        let directory = directory(for: chunk.command.id)
        try Self.secureDirectory(directory)
        let manifest = Manifest(
            command: chunk.command,
            chunkCount: chunk.chunkCount,
            audioSHA256: chunk.audioSHA256,
            createdAt: chunk.command.createdAt
        )
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let existing = try CodexWatchWire.decode(
                Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard existing == manifest else { throw InboxError.conflictingChunk }
        } else {
            try writeSecure(try CodexWatchWire.encode(manifest), to: manifestURL)
        }

        let partURL = directory.appendingPathComponent("part-\(chunk.chunkIndex).bin")
        if FileManager.default.fileExists(atPath: partURL.path) {
            guard try Data(contentsOf: partURL) == chunk.bytes else {
                throw InboxError.conflictingChunk
            }
        } else {
            try writeSecure(chunk.bytes, to: partURL)
        }
        return try completed(in: directory, manifest: manifest)
    }

    func completedEntries() throws -> [Completed] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            let manifest = try CodexWatchWire.decode(
                Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
            return try completed(in: directory, manifest: manifest)
        }
    }

    func remove(commandID: UUID) throws {
        let target = directory(for: commandID)
        guard target.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw InboxError.invalidChunk
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    private func completed(in directory: URL, manifest: Manifest) throws -> Completed? {
        var audio = Data()
        for index in 0..<manifest.chunkCount {
            let partURL = directory.appendingPathComponent("part-\(index).bin")
            guard FileManager.default.fileExists(atPath: partURL.path) else { return nil }
            let part = try Data(contentsOf: partURL)
            guard !part.isEmpty, part.count <= CloudVoiceChunk.preferredChunkBytes else {
                throw InboxError.invalidChunk
            }
            guard audio.count + part.count <= CloudVoiceChunk.maximumAudioBytes else {
                throw InboxError.invalidAudio
            }
            audio.append(part)
        }
        guard !audio.isEmpty,
              Data(SHA256.hash(data: audio)) == manifest.audioSHA256 else {
            throw InboxError.invalidAudio
        }
        return Completed(command: manifest.command, audio: audio)
    }

    private func directory(for commandID: UUID) -> URL {
        root.appendingPathComponent(commandID.uuidString.lowercased(), isDirectory: true)
    }

    private static func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeSecure(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
