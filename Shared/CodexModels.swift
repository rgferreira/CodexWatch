import Foundation

struct CodexTask: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case idle
        case working
        case needsAttention
        case unknown
    }

    let id: String
    let title: String
    let preview: String
    let projectPath: String?
    let updatedAt: Date
    let state: State
}

struct CodexMessage: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let createdAt: Date
}

struct CodexConversation: Codable, Hashable, Sendable {
    let taskID: String
    let messages: [CodexMessage]
}

struct CodexCommand: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let taskID: String
    let taskTitle: String
    let text: String
    let createdAt: Date

    init(task: CodexTask, text: String) {
        id = UUID()
        taskID = task.id
        taskTitle = task.title
        self.text = text
        createdAt = Date()
    }
}

struct CommandReceipt: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case queued
        case sent
        case failed
    }

    let commandID: UUID
    let state: State
    let message: String
}

enum CodexWatchWire {
    static let tasks = "codexwatch.tasks"
    static let tasksRequest = "codexwatch.tasks.request"
    static let tasksResponse = "codexwatch.tasks.response"
    static let tasksError = "codexwatch.tasks.error"
    static let command = "codexwatch.command"
    static let conversationRequest = "codexwatch.conversation.request"
    static let conversationResponse = "codexwatch.conversation.response"
    static let conversationError = "codexwatch.conversation.error"

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
