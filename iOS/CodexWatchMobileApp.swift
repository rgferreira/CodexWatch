import SwiftUI
import WatchConnectivity
import Foundation

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
        case address
        case accessToken
    }

    @EnvironmentObject private var relay: PhoneRelay
    @State private var bridgeURL = ""
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
                    TextField("Dirección", text: $bridgeURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .address)
                        .onSubmit { focusedField = .accessToken }
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
                    .disabled(relay.isConnecting || bridgeURL.isEmpty || accessToken.count != 43)
                    .sensoryFeedback(.impact(weight: .medium), trigger: connectAttempts)
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
                bridgeURL = relay.bridgeURL
                accessToken = relay.accessToken
            }
            .refreshable { await relay.refreshTasks() }
        }
    }

    private func connect() {
        guard !relay.isConnecting, !bridgeURL.isEmpty, accessToken.count == 43 else { return }
        focusedField = nil
        connectAttempts += 1
        relay.configure(baseURL: bridgeURL, accessToken: accessToken)
    }
}

@MainActor
final class PhoneRelay: NSObject, ObservableObject {
    static let shared = PhoneRelay()

    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var statusMessage = "Esperando al puente del Mac"
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var bridgeURL: String
    @Published private(set) var accessToken: String

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private var pollingTask: Task<Void, Never>?
    private var activeBridgeURL: String?
    private static let tokenService = "com.rgferreira.CodexWatch"
    private static let tokenAccount = "bridge-access-token"

    private override init() {
        bridgeURL = UserDefaults.standard.string(forKey: "bridgeURL") ?? ""
        accessToken = (try? SecureTokenStore.load(service: Self.tokenService, account: Self.tokenAccount)) ?? ""
        UserDefaults.standard.removeObject(forKey: "pairingCode")
        super.init()
    }

    func start() {
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

    func configure(baseURL: String, accessToken: String) {
        self.bridgeURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.bridgeURL, forKey: "bridgeURL")
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

    func refreshTasks() async {
        guard !accessToken.isEmpty else {
            statusMessage = "Pega el token mostrado por el puente del Mac"
            isConnected = false
            return
        }
        do {
            let candidates = [bridgeURL].filter { !$0.isEmpty }
            var received: [CodexTask]?
            var lastError: Error?
            for candidate in candidates {
                statusMessage = "Probando ZeroTier…"
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
            case .unsupportedURL: return "usa la URL privada de ZeroTier con el puerto 48720"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func pushTasksToWatch() {
        guard let data = try? CodexWatchWire.encode(tasks) else { return }
        try? session?.updateApplicationContext([CodexWatchWire.tasks: data])
    }

    private func fetchConversation(taskID: String) async throws -> CodexConversation {
        let candidates = [activeBridgeURL, bridgeURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, candidate in
                if !result.contains(candidate) { result.append(candidate) }
            }
        var lastError: Error?
        for candidate in candidates {
            do {
                let conversation = try await MacBridgeClient(baseURL: candidate, token: accessToken)
                    .fetchConversation(taskID: taskID)
                activeBridgeURL = candidate
                return conversation
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func submit(_ command: CodexCommand) {
        Task {
            do {
                let client = MacBridgeClient(baseURL: activeBridgeURL ?? bridgeURL, token: accessToken)
                _ = try await client.submit(command)
                statusMessage = "Orden enviada a \(command.taskTitle)"
            } catch {
                statusMessage = "No se pudo enviar: \(error.localizedDescription)"
            }
        }
    }
}

extension PhoneRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
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
        guard let data = userInfo[CodexWatchWire.command] as? Data else { return }
        receiveCommand(data)
    }

    private nonisolated func receiveCommand(_ data: Data) {
        guard let command = try? CodexWatchWire.decode(CodexCommand.self, from: data) else { return }
        Task { @MainActor [weak self] in self?.submit(command) }
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
        try validate(response)
        return try CodexWatchWire.decode([CodexTask].self, from: data)
    }

    func submit(_ command: CodexCommand) async throws -> CommandReceipt {
        var request = try request(path: "/commands")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try CodexWatchWire.encode(command)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try CodexWatchWire.decode(CommandReceipt.self, from: data)
    }

    func fetchConversation(taskID: String) async throws -> CodexConversation {
        let request = try request(path: "/tasks/\(taskID)/messages")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try CodexWatchWire.decode(CodexConversation.self, from: data)
    }

    private func request(path: String) throws -> URLRequest {
        let normalized = try validatedBaseURL()
        guard let url = URL(string: normalized + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = path.hasSuffix("/messages") ? 12 : 5
        request.setValue(token, forHTTPHeaderField: "X-CodexWatch-Token")
        return request
    }

    private func validatedBaseURL() throws -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host,
              Self.isPrivateIPv4(host),
              let port = components.port,
              port == 48720 else {
            throw URLError(.unsupportedURL)
        }
        return "http://\(host):\(port)"
    }

    private static func isPrivateIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        return false
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "CodexWatch", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "El puente respondió con código \(http.statusCode)"])
        }
    }
}
