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
            GroupBox("Conexión HTTPS directa del Watch") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        controller.cloudRelayStatus,
                        systemImage: controller.isCloudRelayPaired
                            ? "applewatch.radiowaves.left.and.right"
                            : "icloud.slash"
                    )
                    .foregroundStyle(controller.isCloudRelayPaired ? .green : .secondary)
                    if let code = controller.pendingCloudPairingCode {
                        Text("Comprueba que el Watch muestra este código:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(.title, design: .monospaced).bold())
                            .textSelection(.enabled)
                    }
                    Text("El buzón es cifrado de extremo a extremo y el Mac solo realiza conexiones HTTPS salientes.")
                        .font(.caption)
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
    @Published private(set) var cloudRelayStatus = "No configurado"
    @Published private(set) var pendingCloudPairingCode: String?
    @Published private(set) var isCloudRelayPaired = false

    private let appServer = CodexAppServerClient()
    private let openAITranscriber = OpenAITranscriptionClient()
    private var httpServer: LocalHTTPServer?
    private var retryTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var cloudConsumerTask: Task<Void, Never>?
    private var isHTTPReady = false
    private var isCodexReady = false
    private var refreshInProgress = false
    private var creationInProgress = false
    private var hasLoadedTasks = false
    private var lastSuccessfulCompanionContact: Date?
    private var lastSuccessfulCloudWatchContact: Date?
    private var cloudProvisioning: BridgeCloudRelayProvisioning?
    private var pendingCloudPairing: CloudRelayPairingOffer?
    private var cloudTransportConfigured = false
    private var authenticationLimiter = AuthenticationRateLimiter()
    private var commandReceipts: [UUID: CommandReceipt] = [:]
    private var operationSafety = BridgeOperationSafety()
    private var readBreakers: [String: OperationCircuitBreaker] = [:]
    private static let companionContactTimeout: TimeInterval = 45

    private static func audit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private struct PendingDelivery {
        let command: CodexCommand
        let successMessage: String
        let correlationID: String
        let origin: String
    }

    init() {
        Self.audit("codexwatch_controller_initializing")
        UserDefaults.standard.removeObject(forKey: "pairingCode")
        do {
            accessToken = try SecureTokenStore.loadOrCreate(
                service: Self.tokenService,
                account: Self.tokenAccount
            )
            Self.audit("codexwatch_access_token_ready")
            do {
                hasOpenAIAPIKey = try SecureTokenStore.load(
                    service: Self.openAIKeyService,
                    account: Self.openAIKeyAccount
                ) != nil
            } catch {
                hasOpenAIAPIKey = false
                Self.logger.warning("La clave opcional de transcripción requiere acceso interactivo al llavero")
            }
            Self.audit("codexwatch_secure_state_ready")
            configureCloudRelay()
        } catch {
            status = "No se pudo acceder al llavero: \(error.localizedDescription)"
            Self.logger.error("No se pudo cargar el estado seguro del Bridge: \(error.localizedDescription, privacy: .public)")
            print("codexwatch_secure_state_error type=\(type(of: error))")
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
            hasLoadedTasks = true
            isCodexReady = true
        } catch {
            isCodexReady = false
            status = "Error de Codex: \(error.localizedDescription)"
        }
        updateReadiness()
    }

    private func start() async {
        Self.audit("codexwatch_start_requested")
        guard !accessToken.isEmpty else { return }
        startConnectionMonitor()
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try appServer.start()
                    Self.audit("codexwatch_relay_controller_token_ready")
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
                        Self.audit("codexwatch_http_server_created")
                    }
                    await refreshTasks()
                } catch {
                    status = "Reintentando la conexión con Codex…"
                    isCodexReady = false
                    updateReadiness(preserveStatus: true)
                    Self.logger.error("Fallo al conectar con Relay Codex Controller: \(error.localizedDescription, privacy: .public)")
                    print("codexwatch_controller_error type=\(type(of: error)) detail=\(error.localizedDescription)")
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func updateReadiness(preserveStatus: Bool = false) {
        let latestWatchContact = [lastSuccessfulCompanionContact, lastSuccessfulCloudWatchContact]
            .compactMap { $0 }
            .max()
        connectionState = .resolve(
            localServicesReady: isCodexReady && (isHTTPReady || cloudTransportConfigured),
            lastSuccessfulCompanionContact: latestWatchContact,
            now: Date(),
            contactTimeout: Self.companionContactTimeout
        )
        if preserveStatus { return }
        switch connectionState {
        case .connected:
            if let cloud = lastSuccessfulCloudWatchContact,
               Date().timeIntervalSince(cloud) <= Self.companionContactTimeout {
                status = "Watch conectado directamente por HTTPS · Codex disponible"
            } else {
                status = "iPhone conectado · Codex y puente disponibles"
            }
        case .waitingForCompanion:
            status = cloudTransportConfigured
                ? "Codex y HTTPS disponibles · esperando al Watch"
                : "Codex y puente disponibles · esperando al iPhone"
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

        if request.method == "POST", request.path == "/cloud-relay/pair" {
            guard let value = try? CodexWatchWire.decode(
                CloudRelayPairingRequest.self,
                from: request.body
            ) else { return .badRequest }
            do {
                return .encodable(try beginCloudPairing(value))
            } catch {
                Self.logger.error("No se pudo iniciar el pairing HTTPS: \(error.localizedDescription, privacy: .public)")
                return .serverError()
            }
        }

        if request.method == "POST", request.path == "/cloud-relay/approve" {
            guard let value = try? CodexWatchWire.decode(
                CloudRelayPairingApproval.self,
                from: request.body
            ) else { return .badRequest }
            do {
                return .encodable(try approveCloudPairing(value))
            } catch {
                Self.logger.error("No se pudo aprobar el pairing HTTPS: \(error.localizedDescription, privacy: .public)")
                return .serverError()
            }
        }

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
        let receipt = await processVoiceCommand(
            voiceCommand,
            audio: request.body,
            correlationID: correlationID(for: request),
            origin: origin(for: request)
        )
        return .encodable(receipt)
    }

    private func processVoiceCommand(
        _ voiceCommand: CodexVoiceCommand,
        audio: Data,
        correlationID: String,
        origin: String
    ) async -> CommandReceipt {
        if let existing = commandReceipts[voiceCommand.id] { return existing }
        switch operationSafety.beginWrite(commandID: voiceCommand.id, threadID: voiceCommand.taskID) {
        case .duplicate(let receipt): return receipt
        case .threadBusy:
            return CommandReceipt(commandID: voiceCommand.id, state: .failed, message: "Otra orden ya está en curso para esta tarea")
        case .circuitOpen:
            return CommandReceipt(commandID: voiceCommand.id, state: .failed, message: "Reintentos detenidos temporalmente para proteger la tarea")
        case .started:
            telemetry(correlationID, threadID: voiceCommand.taskID, operation: "voice-write", origin: origin, result: "start")
        }
        let started = Date()

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexwatch-\(voiceCommand.id.uuidString)")
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            try audio.write(to: audioURL, options: .atomic)
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
            return receipt
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
            return receipt
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
            let disposition = try await appServer.send(delivery.command)
            switch disposition {
            case .completed:
                receipt = CommandReceipt(
                    commandID: delivery.command.id,
                    state: .sent,
                    message: delivery.successMessage
                )
            case .queued:
                receipt = CommandReceipt(
                    commandID: delivery.command.id,
                    state: .queued,
                    message: "Orden aceptada; esperando disponibilidad de la tarea"
                )
            }
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
            result: receipt.state == .sent ? "success" : (receipt.state == .queued ? "queued" : "failed"),
            duration: Date().timeIntervalSince(started)
        )
        if receipt.state == .queued {
            Task { [weak self] in
                await self?.monitorQueuedCommand(delivery)
            }
        }
        return receipt
    }

    private func monitorQueuedCommand(_ delivery: PendingDelivery) async {
        for _ in 0..<360 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                let status = try await appServer.operationStatus(
                    for: delivery.command.id
                )
                if status == "queued" { continue }
                if status == "running" {
                    remember(CommandReceipt(
                        commandID: delivery.command.id,
                        state: .queued,
                        message: "Orden aceptada; procesando"
                    ))
                    continue
                }
                let receipt: CommandReceipt
                if status == "completed" {
                    receipt = CommandReceipt(
                        commandID: delivery.command.id,
                        state: .sent,
                        message: delivery.successMessage
                    )
                } else {
                    receipt = CommandReceipt(
                        commandID: delivery.command.id,
                        state: .failed,
                        message: "Relay no pudo completar la orden aceptada"
                    )
                }
                operationSafety.finishWrite(
                    threadID: delivery.command.taskID,
                    receipt: receipt
                )
                remember(receipt)
                return
            } catch {
                continue
            }
        }
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

    private func configureCloudRelay() {
        do {
            let provisioning = try BridgeCloudRelayProvisioning.load()
            cloudProvisioning = provisioning
            cloudRelayStatus = "Buzón desplegado · esperando emparejamiento"
            if CloudRelayKeyStore.loadActivePairingID(role: "mac") == provisioning.pairingID,
               let pairing = try CloudRelayKeyStore.loadPairing(
                   role: "mac",
                   pairingID: provisioning.pairingID
               ), pairing.isApproved {
                isCloudRelayPaired = true
                startCloudConsumer(pairing: pairing, provisioning: provisioning)
            }
        } catch {
            cloudRelayStatus = "Buzón HTTPS no aprovisionado"
            Self.logger.info("El transporte HTTPS todavía no está disponible: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginCloudPairing(
        _ request: CloudRelayPairingRequest
    ) throws -> CloudRelayPairingOffer {
        guard request.watchPublicKey.count == 32,
              !request.watchDeviceID.isEmpty,
              let provisioning = cloudProvisioning else {
            throw NSError(
                domain: "CodexWatch.CloudRelay",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "El buzón HTTPS no está preparado"]
            )
        }
        let identity = try CloudRelayKeyStore.loadOrCreateIdentity(role: "mac")
        let publicKey = try CloudRelayProtocol.publicKey(for: identity.privateKey)
        let code = CloudRelayProtocol.shortAuthenticationString(
            pairingID: provisioning.pairingID,
            firstPublicKey: request.watchPublicKey,
            secondPublicKey: publicKey
        )
        let offer = CloudRelayPairingOffer(
            configuration: provisioning.transportConfiguration,
            macDeviceID: identity.deviceID,
            macPublicKey: publicKey,
            watchDeviceID: request.watchDeviceID,
            watchPublicKey: request.watchPublicKey,
            authenticationCode: code
        )
        pendingCloudPairing = offer
        try CloudRelayKeyStore.savePendingOffer(offer, role: "mac")
        pendingCloudPairingCode = code
        cloudRelayStatus = "Comprobación pendiente en el Watch"
        return offer
    }

    private func approveCloudPairing(
        _ approval: CloudRelayPairingApproval
    ) throws -> CloudRelayPairingResult {
        let recoveredOffer = try CloudRelayKeyStore.loadPendingOffer(role: "mac")
        guard let offer = pendingCloudPairing ?? recoveredOffer,
              offer.configuration.pairingID == approval.pairingID,
              offer.watchDeviceID == approval.watchDeviceID,
              offer.watchPublicKey == approval.watchPublicKey,
              offer.authenticationCode == approval.authenticationCode,
              let provisioning = cloudProvisioning else {
            throw NSError(
                domain: "CodexWatch.CloudRelay",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "La comprobación de claves no coincide"]
            )
        }
        let identity = try CloudRelayKeyStore.loadOrCreateIdentity(role: "mac")
        let pairing = CloudRelayProtocol.PairingMaterial(
            pairingID: approval.pairingID,
            deviceID: identity.deviceID,
            privateKey: identity.privateKey,
            peerPublicKey: approval.watchPublicKey,
            approvedAt: Date()
        )
        try CloudRelayKeyStore.savePairing(pairing, role: "mac")
        try CloudRelayKeyStore.saveTransport(
            provisioning.transportConfiguration,
            role: "mac"
        )
        CloudRelayKeyStore.setActivePairingID(approval.pairingID, role: "mac")
        pendingCloudPairing = nil
        try? CloudRelayKeyStore.deletePendingOffer(role: "mac")
        pendingCloudPairingCode = nil
        isCloudRelayPaired = true
        startCloudConsumer(pairing: pairing, provisioning: provisioning)
        return CloudRelayPairingResult(
            pairingID: approval.pairingID,
            accepted: true,
            message: "Conexión HTTPS directa activada"
        )
    }

    private func startCloudConsumer(
        pairing: CloudRelayProtocol.PairingMaterial,
        provisioning: BridgeCloudRelayProvisioning
    ) {
        cloudConsumerTask?.cancel()
        do {
            let transport = BlindMailboxHTTPClient(configuration: try .init(
                baseURL: provisioning.baseURL,
                pairingID: provisioning.pairingID,
                transportSecret: provisioning.transportSecret
            ))
            let outbox = try CloudRelayOutbox()
            let consumer = try BridgeCloudMailboxConsumer(
                transport: transport,
                outbox: outbox,
                pairingID: provisioning.pairingID,
                localPrivateKey: pairing.privateKey,
                peerPublicKey: pairing.peerPublicKey!,
                deliver: { [weak self] command in
                    guard let self else { return .retryableFailure }
                    return await self.deliverCloudCommand(command)
                },
                createTask: { [weak self] command in
                    guard let self else { return .retryableFailure }
                    return await self.deliverCloudNewTask(command)
                },
                listTasks: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.cloudTasksSnapshot()
                },
                readConversation: { [weak self] taskID in
                    guard let self else { throw CancellationError() }
                    return try await self.appServer.recentMessages(threadID: taskID)
                },
                deliverVoice: { [weak self] command, audio in
                    guard let self else { return .retryableFailure }
                    return await self.deliverCloudVoice(command, audio: audio)
                },
                operationStatus: { [weak self] commandID in
                    guard let self else { throw CancellationError() }
                    return try await self.appServer.operationStatus(for: commandID)
                },
                heartbeat: { [weak self] _ in
                    await self?.recordCloudHeartbeat()
                }
            )
            cloudTransportConfigured = true
            cloudRelayStatus = "Emparejado · esperando al Watch"
            cloudConsumerTask = Task { [weak self] in
                var delay: UInt64 = 2
                while !Task.isCancelled {
                    do {
                        try await consumer.reconcileOutbox()
                        try await consumer.reconcileVoiceInbox()
                        _ = try await consumer.drainOnce(waitSeconds: 20)
                        delay = 2
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.cloudRelayStatus = "HTTPS temporalmente no disponible"
                        Self.audit(
                            "codexwatch_cloud_consumer_error type=\(String(describing: type(of: error)))"
                        )
                        try? await Task.sleep(for: .seconds(delay))
                        delay = min(delay * 2, 30)
                    }
                }
            }
            updateReadiness()
        } catch {
            cloudTransportConfigured = false
            cloudRelayStatus = "No se pudo iniciar HTTPS: \(error.localizedDescription)"
        }
    }

    private func recordCloudHeartbeat() {
        lastSuccessfulCloudWatchContact = Date()
        cloudRelayStatus = "Watch conectado directamente"
        updateReadiness()
    }

    private func deliverCloudCommand(
        _ command: CodexCommand
    ) async -> BridgeCloudMailboxConsumer.DeliveryOutcome {
        let correlationID = "mailbox-\(command.id.uuidString.lowercased())"
        switch operationSafety.beginWrite(commandID: command.id, threadID: command.taskID) {
        case .duplicate(let receipt):
            switch receipt.state {
            case .sent: return .completed(receipt.message)
            case .queued: return .queued(receipt.message)
            case .failed: return .rejected(receipt.message)
            }
        case .threadBusy, .circuitOpen:
            return .retryableFailure
        case .started:
            telemetry(
                correlationID,
                threadID: command.taskID,
                operation: "write",
                origin: "watch-https",
                result: "start"
            )
        }
        do {
            let disposition = try await appServer.send(command)
            let receipt: CommandReceipt
            let outcome: BridgeCloudMailboxConsumer.DeliveryOutcome
            switch disposition {
            case .completed:
                receipt = .init(commandID: command.id, state: .sent, message: "Orden enviada")
                outcome = .completed(receipt.message)
            case .queued:
                receipt = .init(
                    commandID: command.id,
                    state: .queued,
                    message: "Orden aceptada; esperando disponibilidad de la tarea"
                )
                outcome = .queued(receipt.message)
            }
            operationSafety.finishWrite(threadID: command.taskID, receipt: receipt)
            remember(receipt)
            return outcome
        } catch {
            let text = error.localizedDescription
            let retryable = error is CancellationError
                || (error as? URLError)?.code == .timedOut
                || text.contains("HTTP 503")
                || text.localizedCaseInsensitiveContains("no disponible")
            let receipt = CommandReceipt(commandID: command.id, state: .failed, message: text)
            operationSafety.finishWrite(threadID: command.taskID, receipt: receipt)
            remember(receipt)
            return retryable ? .retryableFailure : .rejected(text)
        }
    }

    private func cloudTasksSnapshot() async throws -> [CodexTask] {
        // The Bridge already owns the periodic Controller refresh. Serving the
        // Watch from that read model keeps the single mailbox consumer free for
        // conversation reads, commands and heartbeats instead of stacking a
        // second expensive /v1/threads request every ten seconds.
        if !hasLoadedTasks {
            await refreshTasks()
        }
        guard hasLoadedTasks else {
            throw NSError(
                domain: "CodexWatch",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Las tareas todavía no están disponibles"]
            )
        }
        return tasks
    }

    private func deliverCloudNewTask(
        _ command: NewTaskCommand
    ) async -> BridgeCloudMailboxConsumer.DeliveryOutcome {
        if let existing = commandReceipts[command.id] {
            switch existing.state {
            case .sent: return .completed(existing.message)
            case .queued: return .queued(existing.message)
            case .failed: return .rejected(existing.message)
            }
        }
        let thread = "new-task"
        switch operationSafety.beginWrite(commandID: command.id, threadID: thread) {
        case .duplicate(let receipt):
            return receipt.state == .sent
                ? .completed(receipt.message)
                : .rejected(receipt.message)
        case .threadBusy, .circuitOpen:
            return .retryableFailure
        case .started:
            break
        }
        do {
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
            operationSafety.finishWrite(threadID: thread, receipt: receipt)
            remember(receipt)
            _ = try? await cloudTasksSnapshot()
            return .completed(receipt.message)
        } catch {
            let receipt = CommandReceipt(
                commandID: command.id,
                state: .failed,
                message: error.localizedDescription
            )
            operationSafety.finishWrite(threadID: thread, receipt: receipt)
            remember(receipt)
            return .rejected(receipt.message)
        }
    }

    private func deliverCloudVoice(
        _ command: CodexVoiceCommand,
        audio: Data
    ) async -> BridgeCloudMailboxConsumer.DeliveryOutcome {
        let receipt = await processVoiceCommand(
            command,
            audio: audio,
            correlationID: "mailbox-\(command.id.uuidString.lowercased())",
            origin: "watch-https"
        )
        switch receipt.state {
        case .sent: return .completed(receipt.message)
        case .queued: return .queued(receipt.message)
        case .failed: return .rejected(receipt.message)
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
