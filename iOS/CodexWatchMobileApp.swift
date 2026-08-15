import SwiftUI
import WatchConnectivity
import Foundation
import UIKit

enum MacConnectionMethod: String, CaseIterable, Identifiable {
    case zeroTierVPN
    case localNetwork
    case secureHTTPS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zeroTierVPN: "ZeroTier / VPN"
        case .localNetwork: "Red local"
        case .secureHTTPS: "HTTPS personalizado"
        }
    }

    var defaultPort: Int { self == .secureHTTPS ? 443 : 48720 }
    var scheme: String { self == .secureHTTPS ? "https" : "http" }
}

@main
struct CodexWatchMobileApp: App {
    @StateObject private var relay = PhoneRelay.shared

    var body: some Scene {
        WindowGroup {
            PhoneHomeView()
                .environmentObject(relay)
                .task { relay.start() }
        }
    }
}

struct PhoneHomeView: View {
    private enum Field: Hashable {
        case host
        case port
        case accessToken
    }

    @EnvironmentObject private var relay: PhoneRelay
    @State private var connectionMethod: MacConnectionMethod = .zeroTierVPN
    @State private var bridgeHost = ""
    @State private var bridgePort = "48720"
    @State private var accessToken = ""
    @State private var connectAttempts = 0
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            List {
                Section("Estado") {
                    Label(relay.statusMessage, systemImage: relay.isConnected ? "checkmark.circle.fill" : "wifi.exclamationmark")
                        .foregroundStyle(relay.isConnected ? .green : .secondary)
                }

                Section("Puente del Mac") {
                    Picker("Método", selection: $connectionMethod) {
                        ForEach(MacConnectionMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .onChange(of: connectionMethod) { oldValue, newValue in
                        if bridgePort == String(oldValue.defaultPort) || bridgePort.isEmpty {
                            bridgePort = String(newValue.defaultPort)
                        }
                    }

                    TextField("IP o nombre del Mac", text: $bridgeHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .host)
                        .onSubmit { focusedField = .port }
                    TextField("Puerto", text: $bridgePort)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .onChange(of: bridgePort) { _, value in
                            let sanitized = String(value.filter(\.isNumber).prefix(5))
                            if bridgePort != sanitized { bridgePort = sanitized }
                        }
                    SecureField("Token de acceso", text: $accessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .accessToken)
                        .onSubmit { connect() }
                        .onChange(of: accessToken) { _, newValue in
                            let allowed = newValue.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                            let sanitized = String(allowed.prefix(128))
                            if accessToken != sanitized { accessToken = sanitized }
                            if sanitized.count == 43 { focusedField = nil }
                        }

                    Button {
                        connect()
                    } label: {
                        HStack(spacing: 10) {
                            if relay.isConnecting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "network")
                            }
                            Text(relay.isConnecting ? "Conectando…" : "Guardar y conectar")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(relay.isConnecting || bridgeHost.isEmpty || bridgePort.isEmpty || accessToken.count != 43)
                    .sensoryFeedback(.impact(weight: .medium), trigger: connectAttempts)

                    Text(connectionHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Órdenes de voz") {
                    Picker("Transcripción", selection: Binding(
                        get: { relay.voiceInputMode },
                        set: { relay.setVoiceInputMode($0) }
                    )) {
                        ForEach(VoiceInputMode.allCases) { mode in
                            Text(mode.displayName)
                            .tag(mode)
                        }
                    }

                    if relay.voiceInputMode == .openAIAPI {
                        Picker("Modelo", selection: Binding(
                            get: { relay.transcriptionModel },
                            set: { relay.setTranscriptionModel($0) }
                        )) {
                            ForEach(OpenAITranscriptionModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        Text(relay.transcriptionModel.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("Usa la API de OpenAI y genera facturación. La API key se guarda solo en el Mac.", systemImage: "creditcard")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text(relay.voiceInputMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Tareas recientes") {
                    if relay.tasks.isEmpty {
                        ContentUnavailableView("Sin tareas", systemImage: "tray", description: Text("Conecta el puente del Mac para cargar tus tareas de Codex."))
                    } else {
                        ForEach(relay.tasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).font(.headline)
                                Text(task.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Codex Watch")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Listo") { focusedField = nil }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                connectionMethod = relay.connectionMethod
                bridgeHost = relay.bridgeHost
                bridgePort = String(relay.bridgePort)
                accessToken = relay.accessToken
            }
            .refreshable { await relay.refreshTasks() }
        }
    }

    private func connect() {
        guard !relay.isConnecting,
              !bridgeHost.isEmpty,
              let port = Int(bridgePort),
              (1...65_535).contains(port),
              accessToken.count == 43 else { return }
        focusedField = nil
        connectAttempts += 1
        relay.configure(
            method: connectionMethod,
            host: bridgeHost,
            port: port,
            accessToken: accessToken
        )
    }

    private var connectionHelp: String {
        switch connectionMethod {
        case .zeroTierVPN:
            "Introduce manualmente la IP privada del Mac en ZeroTier, Tailscale o WireGuard."
        case .localNetwork:
            "Usa la IP privada o el nombre .local del Mac cuando ambos dispositivos estén en la misma red."
        case .secureHTTPS:
            "Para una IP pública o un dominio se exige HTTPS mediante un proxy seguro delante del puente."
        }
    }
}

@MainActor
final class PhoneRelay: NSObject, ObservableObject {
    static let shared = PhoneRelay()

    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var statusMessage = "Esperando al puente del Mac"
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionMethod: MacConnectionMethod
    @Published private(set) var bridgeHost: String
    @Published private(set) var bridgePort: Int
    @Published private(set) var accessToken: String
    @Published private(set) var voiceInputMode: VoiceInputMode
    @Published private(set) var transcriptionModel: OpenAITranscriptionModel

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private var pollingTask: Task<Void, Never>?
    private var receiptPollingTasks: [UUID: Task<Void, Never>] = [:]
    private var conversationFetchTasks: [String: Task<CodexConversation, Error>] = [:]
    private var conversationBreakers: [String: OperationCircuitBreaker] = [:]
    private var activeBridgeURL: String?
    private var tasksRevision: TimeInterval = 0
    private var hasLoadedTasks = false
    private var refreshInProgress = false
    private var lastDurableTasksData: Data?
    private var lastDurableVoiceInputMode: String?
    private var lastDurableTranscriptionModel: String?
    private static let tokenService = "com.rgferreira.CodexWatch"
    private static let tokenAccount = "bridge-access-token"
    private static let cachedTasksKey = "cachedTasks"
    private static let cachedTasksRevisionKey = "cachedTasksRevision"

    private override init() {
        let defaults = UserDefaults.standard
        let legacyURL = defaults.string(forKey: "bridgeURL").flatMap(URLComponents.init(string:))
        let savedConnectionMethod = MacConnectionMethod(
            rawValue: defaults.string(forKey: "connectionMethod") ?? ""
        ) ?? ((legacyURL?.scheme == "https") ? .secureHTTPS : .zeroTierVPN)
        connectionMethod = savedConnectionMethod
        bridgeHost = defaults.string(forKey: "bridgeHost") ?? legacyURL?.host ?? ""
        bridgePort = defaults.object(forKey: "bridgePort") as? Int
            ?? legacyURL?.port
            ?? savedConnectionMethod.defaultPort
        accessToken = (try? SecureTokenStore.load(service: Self.tokenService, account: Self.tokenAccount)) ?? ""
        voiceInputMode = VoiceInputMode(
            rawValue: defaults.string(forKey: "voiceInputMode") ?? ""
        ) ?? .watchDictation
        transcriptionModel = OpenAITranscriptionModel(
            rawValue: defaults.string(forKey: "transcriptionModel") ?? ""
        ) ?? .gptTranscribe
        if let cachedData = defaults.data(forKey: Self.cachedTasksKey),
           let cachedTasks = try? CodexWatchWire.decode([CodexTask].self, from: cachedData) {
            tasks = cachedTasks.sorted { $0.updatedAt > $1.updatedAt }
            tasksRevision = defaults.double(forKey: Self.cachedTasksRevisionKey)
            hasLoadedTasks = true
        }
        defaults.removeObject(forKey: "pairingCode")
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func start() {
        // La activación temprana permite que WatchConnectivity despierte la app en segundo plano.
        if session?.delegate == nil {
            session?.delegate = self
            session?.activate()
        }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTasks()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func configure(method: MacConnectionMethod, host: String, port: Int, accessToken: String) {
        connectionMethod = method
        bridgeHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        bridgePort = port
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        defaults.set(connectionMethod.rawValue, forKey: "connectionMethod")
        defaults.set(bridgeHost, forKey: "bridgeHost")
        defaults.set(bridgePort, forKey: "bridgePort")
        defaults.removeObject(forKey: "bridgeURL")
        do {
            try SecureTokenStore.save(self.accessToken, service: Self.tokenService, account: Self.tokenAccount)
        } catch {
            statusMessage = "No se pudo guardar el token en el llavero"
            isConnected = false
            return
        }
        Task {
            isConnecting = true
            statusMessage = "Conectando con el Mac…"
            await refreshTasks()
            isConnecting = false
        }
    }

    func setVoiceInputMode(_ mode: VoiceInputMode) {
        voiceInputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "voiceInputMode")
        pushTasksToWatch()
    }

    func setTranscriptionModel(_ model: OpenAITranscriptionModel) {
        transcriptionModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "transcriptionModel")
        pushTasksToWatch()
    }

    func refreshTasks() async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        guard !accessToken.isEmpty else {
            statusMessage = "Pega el token mostrado por el puente del Mac"
            isConnected = false
            return
        }
        do {
            let candidates = [configuredBridgeURL].compactMap { $0 }
            var received: [CodexTask]?
            var lastError: Error?
            for candidate in candidates {
                statusMessage = "Conectando con el Mac…"
                do {
                    received = try await MacBridgeClient(baseURL: candidate, token: accessToken).fetchTasks()
                    activeBridgeURL = candidate
                    break
                } catch {
                    lastError = error
                }
            }
            guard let received else { throw lastError ?? URLError(.cannotConnectToHost) }
            tasks = received.sorted { $0.updatedAt > $1.updatedAt }
            tasksRevision = Date().timeIntervalSince1970
            hasLoadedTasks = true
            if let data = try? CodexWatchWire.encode(tasks) {
                UserDefaults.standard.set(data, forKey: Self.cachedTasksKey)
                UserDefaults.standard.set(tasksRevision, forKey: Self.cachedTasksRevisionKey)
            }
            statusMessage = "Conectado al Mac · \(tasks.count) tareas"
            isConnected = true
            pushTasksToWatch()
        } catch {
            statusMessage = "No conectado: \(Self.describe(error))"
            isConnected = false
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "el Mac no respondió a tiempo"
            case .cannotConnectToHost, .cannotFindHost: return "no se encuentra el bridge en la red"
            case .notConnectedToInternet: return "el iPhone no tiene red disponible"
            case .unsupportedURL: return "revisa la IP, el puerto y el método de conexión"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func pushTasksToWatch() {
        guard hasLoadedTasks,
              let session,
              session.activationState == .activated,
              let data = try? CodexWatchWire.encode(tasks) else { return }
        let context: [String: Any] = [
            CodexWatchWire.tasks: data,
            CodexWatchWire.tasksRevision: tasksRevision,
            CodexWatchWire.voiceInputMode: voiceInputMode.rawValue,
            CodexWatchWire.transcriptionModel: transcriptionModel.rawValue
        ]
        try? session.updateApplicationContext(context)
        if session.isReachable {
            session.sendMessage([
                CodexWatchWire.tasksResponse: data,
                CodexWatchWire.tasksRevision: tasksRevision
            ], replyHandler: nil)
        }
        let mode = voiceInputMode.rawValue
        let model = transcriptionModel.rawValue
        if lastDurableTasksData != data
            || lastDurableVoiceInputMode != mode
            || lastDurableTranscriptionModel != model {
            session.transferUserInfo([
                CodexWatchWire.tasksResponse: data,
                CodexWatchWire.tasksRevision: tasksRevision,
                CodexWatchWire.voiceInputMode: mode,
                CodexWatchWire.transcriptionModel: model
            ])
            lastDurableTasksData = data
            lastDurableVoiceInputMode = mode
            lastDurableTranscriptionModel = model
        }
    }

    private func fetchConversation(taskID: String) async throws -> CodexConversation {
        var breaker = conversationBreakers[taskID] ?? OperationCircuitBreaker()
        guard breaker.allowsOperation() else {
            conversationBreakers[taskID] = breaker
            throw NSError(
                domain: "CodexWatch",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Recuperación detenida temporalmente; vuelve a intentarlo en un minuto"]
            )
        }
        if let existing = conversationFetchTasks[taskID] {
            return try await existing.value
        }
        let candidates = [activeBridgeURL, configuredBridgeURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, candidate in
                if !result.contains(candidate) { result.append(candidate) }
            }
        let token = accessToken
        let fetch = Task<CodexConversation, Error> {
            var lastError: Error?
            for candidate in candidates {
                do {
                    return try await MacBridgeClient(baseURL: candidate, token: token)
                        .fetchConversation(taskID: taskID)
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? URLError(.cannotConnectToHost)
        }
        conversationFetchTasks[taskID] = fetch
        defer { conversationFetchTasks[taskID] = nil }
        do {
            let conversation = try await fetch.value
            breaker.recordSuccess()
            conversationBreakers[taskID] = breaker
            if let configuredBridgeURL { activeBridgeURL = configuredBridgeURL }
            return conversation
        } catch {
            breaker.recordFailure()
            conversationBreakers[taskID] = breaker
            throw error
        }
    }

    private func submit(_ command: CodexCommand) async -> CommandReceipt {
        do {
            guard let baseURL = activeBridgeURL ?? configuredBridgeURL else {
                throw URLError(.badURL)
            }
            let client = MacBridgeClient(baseURL: baseURL, token: accessToken)
            let receipt = try await client.submit(command)
            statusMessage = receipt.state == .sent
                ? "Orden enviada a \(command.taskTitle)"
                : receipt.message
            isConnected = true
            monitorReceiptIfNeeded(receipt, taskTitle: command.taskTitle)
            return receipt
        } catch {
            let receipt = CommandReceipt(
                commandID: command.id,
                state: .failed,
                message: "No se pudo enviar: \(Self.describe(error))"
            )
            statusMessage = receipt.message
            isConnected = false
            return receipt
        }
    }

    private func submitNewTask(_ command: NewTaskCommand) async -> CommandReceipt {
        do {
            guard let baseURL = activeBridgeURL ?? configuredBridgeURL else {
                throw URLError(.badURL)
            }
            let receipt = try await MacBridgeClient(baseURL: baseURL, token: accessToken)
                .createTask(command)
            statusMessage = receipt.state == .sent ? "Tarea creada" : receipt.message
            isConnected = true
            if receipt.state == .sent { await refreshTasks() }
            return receipt
        } catch {
            let receipt = CommandReceipt(
                commandID: command.id,
                state: .failed,
                message: "No se pudo crear: \(Self.describe(error))"
            )
            statusMessage = receipt.message
            isConnected = false
            return receipt
        }
    }

    private func submitVoice(_ command: CodexVoiceCommand, audioURL: URL) async {
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let queued = CommandReceipt(
            commandID: command.id,
            state: .queued,
            message: "Transcribiendo en el Mac…"
        )
        sendReceiptToWatch(queued)
        do {
            guard let baseURL = activeBridgeURL ?? configuredBridgeURL else {
                throw URLError(.badURL)
            }
            let audio = try Data(contentsOf: audioURL, options: [.mappedIfSafe])
            let receipt = try await MacBridgeClient(baseURL: baseURL, token: accessToken)
                .submitVoice(command, audio: audio)
            statusMessage = receipt.state == .sent
                ? "Nota de voz enviada a \(command.taskTitle)"
                : receipt.message
            isConnected = true
            sendReceiptToWatch(receipt)
            monitorReceiptIfNeeded(receipt, taskTitle: command.taskTitle)
            await refreshTasks()
        } catch {
            let receipt = CommandReceipt(
                commandID: command.id,
                state: .failed,
                message: "No se pudo enviar: \(Self.describe(error))"
            )
            statusMessage = receipt.message
            sendReceiptToWatch(receipt)
        }
    }

    private func sendReceiptToWatch(_ receipt: CommandReceipt) {
        guard let data = try? CodexWatchWire.encode(receipt), let session else { return }
        if session.isReachable {
            session.sendMessage([CodexWatchWire.commandReceipt: data], replyHandler: nil)
        }
        // Queued updates are transient and can overtake a later terminal update
        // when transferUserInfo deliveries are delayed. Persist only final states.
        if receipt.state != .queued {
            session.transferUserInfo([CodexWatchWire.commandReceipt: data])
        }
    }

    private func monitorReceiptIfNeeded(_ receipt: CommandReceipt, taskTitle: String) {
        guard receipt.state == .queued,
              receiptPollingTasks[receipt.commandID] == nil else { return }
        let commandID = receipt.commandID
        receiptPollingTasks[commandID] = Task { [weak self] in
            defer { self?.receiptPollingTasks[commandID] = nil }
            let delays: [Duration] = [
                .seconds(3), .seconds(5), .seconds(8), .seconds(13),
                .seconds(20), .seconds(30), .seconds(30), .seconds(30)
            ]
            var consecutiveErrors = 0
            for delay in delays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self,
                      let baseURL = activeBridgeURL ?? configuredBridgeURL else { return }
                do {
                    let updated = try await MacBridgeClient(baseURL: baseURL, token: accessToken)
                        .fetchReceipt(commandID: commandID)
                    consecutiveErrors = 0
                    sendReceiptToWatch(updated)
                    switch updated.state {
                    case .queued:
                        statusMessage = updated.message
                    case .sent:
                        statusMessage = "Orden enviada a \(taskTitle)"
                        await refreshTasks()
                        return
                    case .failed:
                        statusMessage = updated.message
                        return
                    }
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        statusMessage = "Consulta detenida para no saturar el puente"
                        return
                    }
                }
            }
        }
    }

    private var configuredBridgeURL: String? {
        guard !bridgeHost.isEmpty, (1...65_535).contains(bridgePort) else { return nil }
        let formattedHost = bridgeHost.contains(":") && !bridgeHost.hasPrefix("[")
            ? "[\(bridgeHost)]"
            : bridgeHost
        return "\(connectionMethod.scheme)://\(formattedHost):\(bridgePort)"
    }
}

extension PhoneRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "CodexWatch activation refresh",
                expirationHandler: nil
            )
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            pushTasksToWatch()
            await refreshTasks()
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        receiveCommand(messageData)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let reply = WatchReplyHandlerBox(replyHandler)
        if let commandData = message[CodexWatchWire.newTaskCommand] as? Data {
            receiveNewTask(commandData, reply: reply)
            return
        }
        if let commandData = message[CodexWatchWire.command] as? Data {
            receiveCommand(commandData, reply: reply)
            return
        }
        if let rawCommandID = message[CodexWatchWire.commandReceiptRequest] as? String,
           let commandID = UUID(uuidString: rawCommandID) {
            Task { @MainActor [weak self] in
                guard let self,
                      let baseURL = activeBridgeURL ?? configuredBridgeURL else {
                    reply.call([:])
                    return
                }
                let backgroundTask = UIApplication.shared.beginBackgroundTask(
                    withName: "CodexWatch receipt lookup",
                    expirationHandler: nil
                )
                defer {
                    if backgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                    }
                }
                do {
                    let receipt = try await MacBridgeClient(baseURL: baseURL, token: accessToken)
                        .fetchReceipt(commandID: commandID)
                    let data = try CodexWatchWire.encode(receipt)
                    reply.call([CodexWatchWire.commandReceipt: data])
                } catch {
                    reply.call([:])
                }
            }
            return
        }
        if message[CodexWatchWire.tasksRequest] as? Bool == true {
            Task { @MainActor [weak self] in
                guard let self else { reply.call([:]); return }
                await refreshTasks()
                guard isConnected,
                      let data = try? CodexWatchWire.encode(tasks) else {
                    reply.call([CodexWatchWire.tasksError: statusMessage])
                    return
                }
                reply.call([
                    CodexWatchWire.tasksResponse: data,
                    CodexWatchWire.tasksRevision: tasksRevision
                ])
            }
            return
        }
        guard let taskID = message[CodexWatchWire.conversationRequest] as? String else {
            reply.call([:])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { reply.call([:]); return }
            do {
                let conversation = try await fetchConversation(taskID: taskID)
                let data = try CodexWatchWire.encode(conversation)
                reply.call([CodexWatchWire.conversationResponse: data])
            } catch {
                reply.call([CodexWatchWire.conversationError: Self.describe(error)])
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo[CodexWatchWire.newTaskCommand] as? Data {
            receiveNewTask(data)
            return
        }
        if let data = userInfo[CodexWatchWire.command] as? Data {
            receiveCommand(data)
            return
        }
        if userInfo[CodexWatchWire.tasksRequest] as? Bool == true {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let backgroundTask = UIApplication.shared.beginBackgroundTask(
                    withName: "CodexWatch task refresh",
                    expirationHandler: nil
                )
                defer {
                    if backgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                    }
                }
                await refreshTasks()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata?[CodexWatchWire.voiceCommand] as? Data,
              let command = try? CodexWatchWire.decode(CodexVoiceCommand.self, from: metadata) else { return }
        guard let copiedURL = Self.copyReceivedVoiceFile(file.fileURL, commandID: command.id) else {
            Task { @MainActor [weak self] in
                self?.sendReceiptToWatch(CommandReceipt(
                    commandID: command.id,
                    state: .failed,
                    message: "El iPhone no pudo guardar el audio recibido"
                ))
            }
            return
        }
        Task { @MainActor [weak self] in
            let backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "CodexWatch voice delivery",
                expirationHandler: nil
            )
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            await self?.submitVoice(command, audioURL: copiedURL)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            pushTasksToWatch()
            await refreshTasks()
        }
    }

    private nonisolated func receiveCommand(
        _ data: Data,
        reply: WatchReplyHandlerBox? = nil
    ) {
        guard let command = try? CodexWatchWire.decode(CodexCommand.self, from: data) else {
            reply?.call([:])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                reply?.call([:])
                return
            }
            let receipt = await submit(command)
            guard let receiptData = try? CodexWatchWire.encode(receipt) else {
                reply?.call([:])
                return
            }
            if let reply {
                reply.call([CodexWatchWire.commandReceipt: receiptData])
            } else {
                sendReceiptToWatch(receipt)
            }
        }
    }

    private nonisolated func receiveNewTask(
        _ data: Data,
        reply: WatchReplyHandlerBox? = nil
    ) {
        guard let command = try? CodexWatchWire.decode(NewTaskCommand.self, from: data) else {
            reply?.call([:])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                reply?.call([:])
                return
            }
            let receipt = await submitNewTask(command)
            guard let receiptData = try? CodexWatchWire.encode(receipt) else {
                reply?.call([:])
                return
            }
            if let reply {
                reply.call([CodexWatchWire.commandReceipt: receiptData])
            } else {
                sendReceiptToWatch(receipt)
            }
        }
    }

    private nonisolated static func copyReceivedVoiceFile(_ source: URL, commandID: UUID) -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReceivedVoiceCommands", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(commandID.uuidString).appendingPathExtension("m4a")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}

private final class WatchReplyHandlerBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func call(_ response: [String: Any]) {
        handler(response)
    }
}

private struct MacBridgeClient: Sendable {
    let baseURL: String
    let token: String

    func fetchTasks() async throws -> [CodexTask] {
        let request = try request(path: "/tasks")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try CodexWatchWire.decode([CodexTask].self, from: data)
    }

    func submit(_ command: CodexCommand) async throws -> CommandReceipt {
        var request = try request(path: "/commands")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try CodexWatchWire.encode(command)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try CodexWatchWire.decode(CommandReceipt.self, from: data)
    }

    func createTask(_ command: NewTaskCommand) async throws -> CommandReceipt {
        var request = try request(path: "/tasks")
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try CodexWatchWire.encode(command)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try CodexWatchWire.decode(CommandReceipt.self, from: data)
    }

    func submitVoice(_ command: CodexVoiceCommand, audio: Data) async throws -> CommandReceipt {
        var request = try request(path: "/voice-commands")
        request.httpMethod = "POST"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(
            try CodexWatchWire.encode(command).base64EncodedString(),
            forHTTPHeaderField: "X-CodexWatch-Voice-Metadata"
        )
        request.httpBody = audio
        request.timeoutInterval = 75
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try CodexWatchWire.decode(CommandReceipt.self, from: data)
    }

    func fetchReceipt(commandID: UUID) async throws -> CommandReceipt {
        let request = try request(path: "/commands/\(commandID.uuidString)")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try CodexWatchWire.decode(CommandReceipt.self, from: data)
    }

    func fetchConversation(taskID: String) async throws -> CodexConversation {
        let request = try request(path: "/tasks/\(taskID)/messages")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try CodexWatchWire.decode(CodexConversation.self, from: data)
    }

    private func request(path: String) throws -> URLRequest {
        let normalized = try validatedBaseURL()
        guard let url = URL(string: normalized + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = path.hasSuffix("/messages")
            ? 12
            : path == "/commands" ? 30 : 5
        request.setValue(token, forHTTPHeaderField: "X-CodexWatch-Token")
        request.setValue(
            CodexWatchWire.companionHTTPIdentifier,
            forHTTPHeaderField: CodexWatchWire.companionHTTPHeader
        )
        request.setValue(UUID().uuidString, forHTTPHeaderField: CodexWatchWire.correlationHTTPHeader)
        request.setValue("iphone-companion", forHTTPHeaderField: CodexWatchWire.originHTTPHeader)
        return request
    }

    private func validatedBaseURL() throws -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host,
              let port = components.port,
              (1...65_535).contains(port),
              scheme == "https" || Self.isPrivateHost(host) else {
            throw URLError(.unsupportedURL)
        }
        let formattedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(formattedHost):\(port)"
    }

    private static func isPrivateHost(_ value: String) -> Bool {
        if value.lowercased().hasSuffix(".local") { return true }
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 127 { return true }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        if octets[0] == 100, (64...127).contains(octets[1]) { return true }
        if octets[0] == 169, octets[1] == 254 { return true }
        return false
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let responseMessage = String(data: data.prefix(500), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "CodexWatch",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: responseMessage?.isEmpty == false
                        ? responseMessage!
                        : "El puente respondió con código \(http.statusCode)"
                ]
            )
        }
    }
}
