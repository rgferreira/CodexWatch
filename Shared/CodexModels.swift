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

struct NewTaskCommand: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let prompt: String
    let projectPath: String?
    let createdAt: Date

    init(prompt: String, projectPath: String?) {
        id = UUID()
        self.prompt = prompt
        self.projectPath = projectPath
        createdAt = Date()
    }
}

struct ProjectSelectionState: Equatable, Sendable {
    private(set) var selectedPath = ""
    private(set) var isInitialized = false

    mutating func initializeIfNeeded(projectPaths: [String]) {
        guard !isInitialized else { return }
        selectedPath = projectPaths.first ?? ""
        isInitialized = true
    }

    mutating func select(_ path: String) {
        selectedPath = path
        isInitialized = true
    }
}

enum BridgeConnectionState: Equatable, Sendable {
    case unavailable
    case waitingForCompanion
    case connected

    static func resolve(
        localServicesReady: Bool,
        lastSuccessfulCompanionContact: Date?,
        now: Date,
        contactTimeout: TimeInterval
    ) -> Self {
        guard localServicesReady else { return .unavailable }
        guard let lastSuccessfulCompanionContact,
              now.timeIntervalSince(lastSuccessfulCompanionContact) <= contactTimeout else {
            return .waitingForCompanion
        }
        return .connected
    }
}

struct OperationCircuitBreaker: Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var openUntil: Date?
    let failureThreshold: Int
    let cooldown: TimeInterval

    init(failureThreshold: Int = 3, cooldown: TimeInterval = 60) {
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
    }

    mutating func allowsOperation(at now: Date = Date()) -> Bool {
        guard let openUntil else { return true }
        if now >= openUntil {
            self.openUntil = nil
            consecutiveFailures = 0
            return true
        }
        return false
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
    }

    mutating func recordFailure(at now: Date = Date()) {
        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold {
            openUntil = now.addingTimeInterval(cooldown)
        }
    }
}

struct BridgeOperationSafety: Sendable {
    enum BeginResult: Equatable {
        case started
        case duplicate(CommandReceipt)
        case threadBusy
        case circuitOpen
    }

    private var activeWrites: [String: UUID] = [:]
    private var receipts: [UUID: CommandReceipt] = [:]
    private var breakers: [String: OperationCircuitBreaker] = [:]

    mutating func beginWrite(
        commandID: UUID,
        threadID: String,
        now: Date = Date()
    ) -> BeginResult {
        if let receipt = receipts[commandID] { return .duplicate(receipt) }
        if activeWrites[threadID] == commandID {
            return .duplicate(CommandReceipt(
                commandID: commandID,
                state: .queued,
                message: "Operación en curso"
            ))
        }
        if activeWrites[threadID] != nil { return .threadBusy }
        var breaker = breakers[threadID] ?? OperationCircuitBreaker()
        guard breaker.allowsOperation(at: now) else {
            breakers[threadID] = breaker
            return .circuitOpen
        }
        breakers[threadID] = breaker
        activeWrites[threadID] = commandID
        return .started
    }

    mutating func finishWrite(
        threadID: String,
        receipt: CommandReceipt,
        now: Date = Date()
    ) {
        if activeWrites[threadID] == receipt.commandID {
            activeWrites.removeValue(forKey: threadID)
        }
        receipts[receipt.commandID] = receipt
        var breaker = breakers[threadID] ?? OperationCircuitBreaker()
        if receipt.state == .failed { breaker.recordFailure(at: now) }
        else if receipt.state == .sent { breaker.recordSuccess() }
        breakers[threadID] = breaker
        if receipts.count > 100, let oldest = receipts.keys.first {
            receipts.removeValue(forKey: oldest)
        }
    }

    func hasActiveWrite(for threadID: String) -> Bool {
        activeWrites[threadID] != nil
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
    static let companionHTTPHeader = "x-codexwatch-client"
    static let companionHTTPIdentifier = "iphone-companion"
    static let correlationHTTPHeader = "x-codexwatch-correlation-id"
    static let originHTTPHeader = "x-codexwatch-origin"
    static let tasks = "codexwatch.tasks"
    static let tasksRequest = "codexwatch.tasks.request"
    static let tasksResponse = "codexwatch.tasks.response"
    static let tasksError = "codexwatch.tasks.error"
    static let tasksRevision = "codexwatch.tasks.revision"
    static let command = "codexwatch.command"
    static let newTaskCommand = "codexwatch.task.create"
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
