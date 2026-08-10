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

    init(voiceCommand: CodexVoiceCommand, text: String) {
        id = voiceCommand.id
        taskID = voiceCommand.taskID
        taskTitle = voiceCommand.taskTitle
        self.text = text
        createdAt = voiceCommand.createdAt
    }
}

enum VoiceInputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case watchDictation
    case openAIAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .watchDictation: "Dictado del Apple Watch"
        case .openAIAPI: "OpenAI API (facturable)"
        }
    }

    var detail: String {
        switch self {
        case .watchDictation: "El reloj convierte la voz en texto antes de enviarla. No usa la API de OpenAI."
        case .openAIAPI: "El reloj envía el audio al Mac y el modelo seleccionado lo transcribe con facturación de API."
        }
    }
}

enum OpenAITranscriptionModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case gptTranscribe = "gpt-transcribe"
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case gpt4oMiniTranscribe20251215 = "gpt-4o-mini-transcribe-2025-12-15"
    case gpt4oTranscribeDiarize = "gpt-4o-transcribe-diarize"
    case whisper1 = "whisper-1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gptTranscribe: "GPT Transcribe (recomendado)"
        case .gpt4oTranscribe: "GPT-4o Transcribe"
        case .gpt4oMiniTranscribe: "GPT-4o mini Transcribe"
        case .gpt4oMiniTranscribe20251215: "GPT-4o mini Transcribe (2025-12-15)"
        case .gpt4oTranscribeDiarize: "GPT-4o Transcribe Diarize"
        case .whisper1: "Whisper"
        }
    }

    var detail: String {
        switch self {
        case .gptTranscribe: "Modelo actual de alta precisión para ficheros de audio."
        case .gpt4oTranscribe: "Modelo GPT-4o de transcripción de alta precisión."
        case .gpt4oMiniTranscribe: "Alternativa más económica y rápida."
        case .gpt4oMiniTranscribe20251215: "Snapshot fijado de GPT-4o mini para repetir pruebas con la misma versión."
        case .gpt4oTranscribeDiarize: "Añade identificación de hablantes; innecesaria para una orden normal."
        case .whisper1: "Modelo anterior, útil como referencia de calidad y coste."
        }
    }

    var usesDiarizedResponse: Bool { self == .gpt4oTranscribeDiarize }
}

struct CodexVoiceCommand: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let taskID: String
    let taskTitle: String
    let createdAt: Date
    let transcriptionModel: OpenAITranscriptionModel

    init(task: CodexTask, transcriptionModel: OpenAITranscriptionModel) {
        id = UUID()
        taskID = task.id
        taskTitle = task.title
        createdAt = Date()
        self.transcriptionModel = transcriptionModel
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
    static let commandReceipt = "codexwatch.command.receipt"
    static let commandReceiptRequest = "codexwatch.command.receipt.request"
    static let voiceCommand = "codexwatch.voice.command"
    static let voiceInputMode = "codexwatch.voice.input-mode"
    static let transcriptionModel = "codexwatch.transcription.model"
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
