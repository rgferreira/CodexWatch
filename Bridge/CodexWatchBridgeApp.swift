import SwiftUI
import AppKit
import OSLog

@main
struct CodexWatchBridgeApp: App {
    @StateObject private var controller = BridgeController()

    var body: some Scene {
        MenuBarExtra {
            BridgeMenuView(controller: controller)
        } label: {
            BridgeStatusIcon(state: controller.connectionState)
                .help(controller.connectionState.helpText)
        }

        Window("Codex Watch Bridge", id: "bridge") {
            BridgeConfigurationView(controller: controller)
        }
    }
}

private struct BridgeMenuView: View {
    @ObservedObject var controller: BridgeController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.status).font(.headline)
            Text("Voz: dictado del Watch u OpenAI API")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Copiar token de acceso") { controller.copyAccessToken() }
            Button("Configurar conexión…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "bridge")
            }
            Button("Actualizar tareas") { Task { await controller.refreshTasks() } }
            Button("Salir") { NSApplication.shared.terminate(nil) }
        }
        .padding()
    }
}

private struct BridgeConfigurationView: View {
    @ObservedObject var controller: BridgeController
    @State private var openAIAPIKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Codex Watch Bridge").font(.largeTitle.bold())
            Text(controller.status)
            GroupBox("Emparejamiento") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.accessToken)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("Copiar token") { controller.copyAccessToken() }
                        Spacer()
                        Button("Revocar y generar otro") { controller.regenerateAccessToken() }
                    }
                    Text("Pega este token en la app del iPhone. Al regenerarlo se desconectarán los dispositivos actuales.")
                        .foregroundStyle(.secondary)
                }
            }
            GroupBox("Transcripción de notas de voz") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        controller.hasOpenAIAPIKey ? "API key configurada" : "API key no configurada",
                        systemImage: controller.hasOpenAIAPIKey ? "checkmark.shield.fill" : "key"
                    )
                    .foregroundStyle(controller.hasOpenAIAPIKey ? .green : .orange)
                    SecureField("OpenAI API key", text: $openAIAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Guardar API key en el llavero") {
                        if controller.saveOpenAIAPIKey(openAIAPIKey) {
                            openAIAPIKey = ""
                        }
                    }
                    .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Solo se usa cuando el Companion selecciona OpenAI API. La transcripción genera facturación en tu cuenta de API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("La clave permanece en el llavero del Mac y nunca se envía al iPhone, al Watch ni se guarda en el repositorio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Tareas disponibles: \(controller.tasks.count)")
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 430)
    }
}

@MainActor
final class BridgeController: ObservableObject {
    private static let tokenService = "com.rgferreira.CodexWatchBridge"
    private static let tokenAccount = "bridge-access-token"
    private static let openAIKeyService = "com.rgferreira.CodexWatchBridge.openai"
    private static let openAIKeyAccount = "api-key"
    private static let logger = Logger(subsystem: "com.rgferreira.CodexWatchBridge", category: "Bridge")

    @Published private(set) var status = "Iniciando…"
    @Published private(set) var connectionState: BridgeConnectionState = .unavailable
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var accessToken = ""
    @Published private(set) var hasOpenAIAPIKey = false

    private let appServer = CodexAppServerClient()
    private let openAITranscriber = OpenAITranscriptionClient()
    private var httpServer: LocalHTTPServer?
    private var retryTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var isHTTPReady = false
    private var isCodexReady = false
    private var refreshInProgress = false
    private var creationInProgress = false
    private var lastSuccessfulCompanionContact: Date?
    private var authenticationLimiter = AuthenticationRateLimiter()
    private var commandReceipts: [UUID: CommandReceipt] = [:]
    private var operationSafety = BridgeOperationSafety()
    private var readBreakers: [String: OperationCircuitBreaker] = [:]
    private static let companionContactTimeout: TimeInterval = 45

    private struct PendingDelivery {
        let command: CodexCommand
        let successMessage: String
        let correlationID: String
        let origin: String
    }

    init() {
        UserDefaults.standard.removeObject(forKey: "pairingCode")
        do {
            accessToken = try SecureTokenStore.loadOrCreate(
                service: Self.tokenService,
                account: Self.tokenAccount
            )
            hasOpenAIAPIKey = try SecureTokenStore.load(
                service: Self.openAIKeyService,
                account: Self.openAIKeyAccount
            ) != nil
        } catch {
            status = "No se pudo acceder al llavero: \(error.localizedDescription)"
        }
        Task { await start() }
    }

    func copyAccessToken() {
        guard !accessToken.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accessToken, forType: .string)
    }

    func regenerateAccessToken() {
        do {
            let token = try SecureTokenStore.makeToken()
            try SecureTokenStore.save(token, service: Self.tokenService, account: Self.tokenAccount)
            accessToken = token
            authenticationLimiter.reset()
            lastSuccessfulCompanionContact = nil
            status = "Token renovado · vuelve a pegarlo en el iPhone"
            updateReadiness(preserveStatus: true)
        } catch {
            status = "No se pudo renovar el token: \(error.localizedDescription)"
        }
    }

    func saveOpenAIAPIKey(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        do {
            try SecureTokenStore.save(
                value,
                service: Self.openAIKeyService,
                account: Self.openAIKeyAccount
            )
            hasOpenAIAPIKey = true
            return true
        } catch {
            status = "No se pudo guardar la API key: \(error.localizedDescription)"
            return false
        }
    }

    func refreshTasks() async {
        guard !refreshInProgress, !creationInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        do {
            tasks = try await appServer.listTasks()
            isCodexReady = true
        } catch {
            isCodexReady = false
            status = "Error de Codex: \(error.localizedDescription)"
        }
        updateReadiness()
    }

    private func start() async {
        guard !accessToken.isEmpty else { return }
        startConnectionMonitor()
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try appServer.start()
                    if httpServer == nil {
                        let network = try? ZeroTierAddressDetector.activeIPv4Network()
                        httpServer = try LocalHTTPServer(allowedIPv4Address: network?.address ?? "127.0.0.1", prefixLength: network?.prefixLength ?? 32, port: 48720, onStateChange: { [weak self] ready, error in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                isHTTPReady = ready
                                if let error {
                                    status = "Error de red: \(error)"
                                    httpServer = nil
                                }
                                updateReadiness()
                            }
                        }) { [weak self] request in
                            guard let self else { return .serverError() }
                            return await self.handle(request)
                        }
                    }
                    await refreshTasks()
                } catch {
                    status = "Reintentando la conexión con Codex…"
                    isCodexReady = false
                    updateReadiness(preserveStatus: true)
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func updateReadiness(preserveStatus: Bool = false) {
        connectionState = .resolve(
            localServicesReady: isHTTPReady && isCodexReady,
            lastSuccessfulCompanionContact: lastSuccessfulCompanionContact,
            now: Date(),
            contactTimeout: Self.companionContactTimeout
        )
        if preserveStatus { return }
        switch connectionState {
        case .connected:
            status = "iPhone conectado · Codex y puente disponibles"
        case .waitingForCompanion:
            status = "Codex y puente disponibles · esperando al iPhone"
        case .unavailable where !isHTTPReady && isCodexReady:
            status = "Codex disponible · iniciando el puente…"
        case .unavailable:
            break
        }
    }

    private func startConnectionMonitor() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self else { return }
                updateReadiness()
            }
        }
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let rejection = authenticate(request) { return rejection }
        let response = await handleAuthenticated(request)
        if (200..<300).contains(response.status),
           request.headers[CodexWatchWire.companionHTTPHeader]
            == CodexWatchWire.companionHTTPIdentifier {
            lastSuccessfulCompanionContact = Date()
            updateReadiness()
        }
        return response
    }

    private func handleAuthenticated(_ request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/health" { return .json(["status": "ok"]) }

        if request.method == "GET", request.path.hasPrefix("/commands/") {
            let rawID = String(request.path.dropFirst("/commands/".count))
            guard let commandID = UUID(uuidString: rawID),
                  let receipt = commandReceipts[commandID] else {
                return .notFound
            }
            return .encodable(receipt)
        }

        switch (request.method, request.path) {
        case ("GET", "/tasks"):
            await refreshTasks()
            return .encodable(tasks)
        case ("POST", "/tasks"):
            guard let command = try? CodexWatchWire.decode(NewTaskCommand.self, from: request.body) else {
                return .badRequest
            }
            do {
                let started = Date()
                creationInProgress = true
                defer { creationInProgress = false }
                if let existing = commandReceipts[command.id] { return .encodable(existing) }
                let operationThread = "new-task"
                let correlationID = correlationID(for: request)
                switch operationSafety.beginWrite(commandID: command.id, threadID: operationThread) {
                case .duplicate(let receipt): return .encodable(receipt)
                case .threadBusy:
                    return .encodable(CommandReceipt(commandID: command.id, state: .failed, message: "Ya hay una creación en curso"))
                case .circuitOpen:
                    return .encodable(CommandReceipt(commandID: command.id, state: .failed, message: "Protección activa; inténtalo de nuevo en un minuto"))
                case .started:
                    telemetry(correlationID, threadID: operationThread, operation: "create", origin: origin(for: request), result: "start")
                }
                if let projectPath = command.projectPath,
                   !projectPath.isEmpty,
                   !tasks.contains(where: { $0.projectPath == projectPath }) {
                    throw NSError(
                        domain: "CodexWatch",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "El proyecto seleccionado ya no está disponible"]
                    )
                }
                _ = try await appServer.createTask(command)
                let receipt = CommandReceipt(
                    commandID: command.id,
                    state: .sent,
                    message: "Tarea creada"
                )
                operationSafety.finishWrite(threadID: operationThread, receipt: receipt)
                telemetry(correlationID, threadID: operationThread, operation: "create", origin: origin(for: request), result: "success", duration: Date().timeIntervalSince(started))
                remember(receipt)
                await refreshTasks()
                return .encodable(receipt)
            } catch {
                Self.logger.error("No se pudo crear una tarea: \(error.localizedDescription, privacy: .private)")
                let receipt = CommandReceipt(
                    commandID: command.id,
                    state: .failed,
                    message: error.localizedDescription
                )
                operationSafety.finishWrite(threadID: "new-task", receipt: receipt)
                remember(receipt)
                telemetry(correlationID(for: request), threadID: "new-task", operation: "create", origin: origin(for: request), result: telemetryResult(for: error))
                return .encodable(receipt)
            }
        case ("POST", "/commands"):
            do {
                let command = try CodexWatchWire.decode(CodexCommand.self, from: request.body)
                if let existing = commandReceipts[command.id] { return .encodable(existing) }
                let receipt = await deliver(
                    PendingDelivery(
                        command: command,
                        successMessage: "Orden enviada",
                        correlationID: correlationID(for: request),
                        origin: origin(for: request)
                    )
                )
                return .encodable(receipt)
            } catch {
                Self.logger.error("No se pudo enviar una orden: \(error.localizedDescription, privacy: .private)")
                return .serverError()
            }
        case ("POST", "/voice-commands"):
            return await handleVoiceCommand(request)
        default:
            let prefix = "/tasks/"
            let suffix = "/messages"
            if request.method == "GET",
               request.path.hasPrefix(prefix), request.path.hasSuffix(suffix) {
                let start = request.path.index(request.path.startIndex, offsetBy: prefix.count)
                let end = request.path.index(request.path.endIndex, offsetBy: -suffix.count)
                let taskID = String(request.path[start..<end])
                guard !taskID.isEmpty else { return .notFound }
                var breaker = readBreakers[taskID] ?? OperationCircuitBreaker()
                guard breaker.allowsOperation() else {
                    readBreakers[taskID] = breaker
                    return .serverError()
                }
                let correlationID = correlationID(for: request)
                let started = Date()
                do {
                    telemetry(correlationID, threadID: taskID, operation: "read", origin: origin(for: request), result: "start")
                    let messages = try await appServer.recentMessages(threadID: taskID)
                    breaker.recordSuccess()
                    readBreakers[taskID] = breaker
                    telemetry(correlationID, threadID: taskID, operation: "read", origin: origin(for: request), result: "success", duration: Date().timeIntervalSince(started))
                    return .encodable(CodexConversation(taskID: taskID, messages: messages))
                } catch {
                    breaker.recordFailure()
                    readBreakers[taskID] = breaker
                    telemetry(correlationID, threadID: taskID, operation: "read", origin: origin(for: request), result: telemetryResult(for: error), duration: Date().timeIntervalSince(started))
                    Self.logger.error("No se pudo recuperar una conversación: \(error.localizedDescription, privacy: .private)")
                    return .serverError()
                }
            }
            return .notFound
        }
    }

    private func handleVoiceCommand(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.headers["content-type"]?.lowercased().hasPrefix("audio/mp4") == true,
              let encodedMetadata = request.headers["x-codexwatch-voice-metadata"],
              let metadata = Data(base64Encoded: encodedMetadata),
              let voiceCommand = try? CodexWatchWire.decode(CodexVoiceCommand.self, from: metadata),
              !request.body.isEmpty else {
            return .badRequest
        }
        if let existing = commandReceipts[voiceCommand.id] { return .encodable(existing) }

        let correlationID = correlationID(for: request)
        let origin = origin(for: request)
        switch operationSafety.beginWrite(commandID: voiceCommand.id, threadID: voiceCommand.taskID) {
        case .duplicate(let receipt): return .encodable(receipt)
        case .threadBusy:
            return .encodable(CommandReceipt(commandID: voiceCommand.id, state: .failed, message: "Otra orden ya está en curso para esta tarea"))
        case .circuitOpen:
            return .encodable(CommandReceipt(commandID: voiceCommand.id, state: .failed, message: "Reintentos detenidos temporalmente para proteger la tarea"))
        case .started:
            telemetry(correlationID, threadID: voiceCommand.taskID, operation: "voice-write", origin: origin, result: "start")
        }
        let started = Date()

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexwatch-\(voiceCommand.id.uuidString)")
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            try request.body.write(to: audioURL, options: .atomic)
            guard let apiKey = try SecureTokenStore.load(
                service: Self.openAIKeyService,
                account: Self.openAIKeyAccount
            ) else {
                throw OpenAITranscriptionClient.TranscriptionError.missingAPIKey
            }
            let transcript = try await openAITranscriber.transcribe(
                audioURL: audioURL,
                model: voiceCommand.transcriptionModel,
                apiKey: apiKey
            )
            let receipt = await sendAcquired(
                PendingDelivery(command: CodexCommand(voiceCommand: voiceCommand, text: transcript), successMessage: "Orden transcrita y enviada", correlationID: correlationID, origin: origin),
                operation: "voice-write",
                started: started
            )
            return .encodable(receipt)
        } catch {
            Self.logger.error("No se pudo procesar una nota de voz: \(error.localizedDescription, privacy: .private)")
            let receipt = CommandReceipt(
                commandID: voiceCommand.id,
                state: .failed,
                message: error.localizedDescription
            )
            operationSafety.finishWrite(threadID: voiceCommand.taskID, receipt: receipt)
            remember(receipt)
            telemetry(correlationID, threadID: voiceCommand.taskID, operation: "voice-write", origin: origin, result: telemetryResult(for: error), duration: Date().timeIntervalSince(started))
            return .encodable(receipt)
        }
    }

    private func deliver(_ delivery: PendingDelivery) async -> CommandReceipt {
        switch operationSafety.beginWrite(
            commandID: delivery.command.id,
            threadID: delivery.command.taskID
        ) {
        case .duplicate(let receipt): return receipt
        case .threadBusy:
            return CommandReceipt(
                commandID: delivery.command.id,
                state: .failed,
                message: "Otra orden ya está en curso para esta tarea"
            )
        case .circuitOpen:
            return CommandReceipt(
                commandID: delivery.command.id,
                state: .failed,
                message: "Reintentos detenidos temporalmente para proteger la tarea"
            )
        case .started:
            telemetry(
                delivery.correlationID,
                threadID: delivery.command.taskID,
                operation: "write",
                origin: delivery.origin,
                result: "start"
            )
        }
        return await sendAcquired(delivery, operation: "write", started: Date())
    }

    private func sendAcquired(
        _ delivery: PendingDelivery,
        operation: String,
        started: Date
    ) async -> CommandReceipt {
        let receipt: CommandReceipt
        do {
            try await appServer.send(delivery.command)
            receipt = CommandReceipt(
                commandID: delivery.command.id,
                state: .sent,
                message: delivery.successMessage
            )
        } catch {
            receipt = CommandReceipt(
                commandID: delivery.command.id,
                state: .failed,
                message: error.localizedDescription
            )
        }
        operationSafety.finishWrite(threadID: delivery.command.taskID, receipt: receipt)
        remember(receipt)
        telemetry(
            delivery.correlationID,
            threadID: delivery.command.taskID,
            operation: operation,
            origin: delivery.origin,
            result: receipt.state == .sent ? "success" : "failed",
            duration: Date().timeIntervalSince(started)
        )
        return receipt
    }

    private func telemetryResult(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if (error as? URLError)?.code == .timedOut { return "timeout" }
        return "failed"
    }

    private func correlationID(for request: HTTPRequest) -> String {
        request.headers[CodexWatchWire.correlationHTTPHeader] ?? UUID().uuidString
    }

    private func origin(for request: HTTPRequest) -> String {
        request.headers[CodexWatchWire.originHTTPHeader] ?? "unknown"
    }

    private func telemetry(
        _ correlationID: String,
        threadID: String,
        operation: String,
        origin: String,
        result: String,
        duration: TimeInterval? = nil
    ) {
        let elapsed = duration.map { String(format: "%.3f", $0) } ?? "-"
        Self.logger.notice(
            "correlation=\(correlationID, privacy: .public) thread=\(threadID, privacy: .public) operation=\(operation, privacy: .public) origin=\(origin, privacy: .public) result=\(result, privacy: .public) duration=\(elapsed, privacy: .public)"
        )
    }

    private func remember(_ receipt: CommandReceipt) {
        commandReceipts[receipt.commandID] = receipt
        if commandReceipts.count > 100 {
            commandReceipts.removeValue(forKey: commandReceipts.keys.first!)
        }
    }

    private func authenticate(_ request: HTTPRequest) -> HTTPResponse? {
        let supplied = request.headers["x-codexwatch-token"] ?? ""
        switch authenticationLimiter.evaluate(
            clientIdentifier: request.clientIdentifier,
            suppliedToken: supplied,
            expectedToken: accessToken
        ) {
        case .authorized:
            return nil
        case .unauthorized:
            Self.logger.warning("Solicitud privada rechazada por autenticación")
            return .unauthorized
        case .rateLimited:
            Self.logger.warning("Origen privado bloqueado temporalmente por autenticación")
            return .rateLimited
        }
    }
}

private struct BridgeStatusIcon: View {
    let state: BridgeConnectionState

    var body: some View {
        Image(nsImage: Self.makeIcon(color: state.color))
    }

    private static func makeIcon(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            NSColor.white.setStroke()
            let pulse = NSBezierPath()
            pulse.lineWidth = 1.6
            pulse.lineCapStyle = .round
            pulse.move(to: NSPoint(x: 4.5, y: 9))
            pulse.line(to: NSPoint(x: 7, y: 9))
            pulse.line(to: NSPoint(x: 8.3, y: 12))
            pulse.line(to: NSPoint(x: 10, y: 6))
            pulse.line(to: NSPoint(x: 11.3, y: 9))
            pulse.line(to: NSPoint(x: 13.5, y: 9))
            pulse.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension BridgeConnectionState {
    var color: NSColor {
        switch self {
        case .connected: .systemGreen
        case .waitingForCompanion: .systemOrange
        case .unavailable: .systemRed
        }
    }

    var helpText: String {
        switch self {
        case .connected: "Codex Watch conectado al iPhone"
        case .waitingForCompanion: "Puente preparado; sin contacto reciente del iPhone"
        case .unavailable: "Codex Watch no está disponible"
        }
    }
}
