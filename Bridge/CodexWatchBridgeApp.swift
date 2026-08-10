import SwiftUI
import AppKit
import OSLog

@main
struct CodexWatchBridgeApp: App {
    @StateObject private var controller = BridgeController()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text(controller.status).font(.headline)
                Text("Acceso protegido por un token de 256 bits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Button("Copiar token de acceso") { controller.copyAccessToken() }
                Button("Actualizar tareas") { Task { await controller.refreshTasks() } }
                Button("Salir") { NSApplication.shared.terminate(nil) }
            }
            .padding()
        } label: {
            BridgeStatusIcon(isConnected: controller.isReady)
                .help(controller.isReady ? "Codex Watch conectado" : "Codex Watch desconectado")
        }

        Window("Codex Watch Bridge", id: "bridge") {
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
                    }
                    Text("Pega este token en la app del iPhone. Al regenerarlo se desconectarán los dispositivos actuales.")
                        .foregroundStyle(.secondary)
                }
                Text("Tareas disponibles: \(controller.tasks.count)")
                Spacer()
            }
            .padding(24)
            .frame(minWidth: 480, minHeight: 300)
        }
    }
}

@MainActor
final class BridgeController: ObservableObject {
    private static let tokenService = "com.rgferreira.CodexWatchBridge"
    private static let tokenAccount = "bridge-access-token"
    private static let logger = Logger(subsystem: "com.rgferreira.CodexWatchBridge", category: "Bridge")

    @Published private(set) var status = "Iniciando…"
    @Published private(set) var isReady = false
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var accessToken = ""

    private let appServer = CodexAppServerClient()
    private var httpServer: LocalHTTPServer?
    private var retryTask: Task<Void, Never>?
    private var isHTTPReady = false
    private var isCodexReady = false
    private var authenticationLimiter = AuthenticationRateLimiter()

    init() {
        UserDefaults.standard.removeObject(forKey: "pairingCode")
        do {
            accessToken = try SecureTokenStore.loadOrCreate(
                service: Self.tokenService,
                account: Self.tokenAccount
            )
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
            status = "Token renovado · vuelve a pegarlo en el iPhone"
            updateReadiness(preserveStatus: true)
        } catch {
            status = "No se pudo renovar el token: \(error.localizedDescription)"
        }
    }

    func refreshTasks() async {
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
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try appServer.start()
                    if httpServer == nil {
                        let network = try ZeroTierAddressDetector.activeIPv4Network()
                        httpServer = try LocalHTTPServer(allowedIPv4Address: network.address, prefixLength: network.prefixLength, port: 48720, onStateChange: { [weak self] ready, error in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                isHTTPReady = ready
                                if let error {
                                    status = "Error de la red privada: \(error)"
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
                    status = "Reintentando la conexión privada…"
                    isReady = false
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func updateReadiness(preserveStatus: Bool = false) {
        isReady = isHTTPReady && isCodexReady
        if preserveStatus { return }
        if isReady {
            status = "Conectado a Codex · solo por ZeroTier"
        } else if !isHTTPReady && isCodexReady {
            status = "Codex disponible · esperando a ZeroTier…"
        }
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let rejection = authenticate(request) { return rejection }
        if request.path == "/health" { return .json(["status": "ok"]) }

        switch (request.method, request.path) {
        case ("GET", "/tasks"):
            await refreshTasks()
            return .encodable(tasks)
        case ("POST", "/commands"):
            do {
                let command = try CodexWatchWire.decode(CodexCommand.self, from: request.body)
                try await appServer.send(command)
                let receipt = CommandReceipt(commandID: command.id, state: .sent, message: "Orden enviada")
                return .encodable(receipt)
            } catch {
                Self.logger.error("No se pudo enviar una orden: \(error.localizedDescription, privacy: .private)")
                return .serverError()
            }
        default:
            let prefix = "/tasks/"
            let suffix = "/messages"
            if request.method == "GET",
               request.path.hasPrefix(prefix), request.path.hasSuffix(suffix) {
                do {
                    let start = request.path.index(request.path.startIndex, offsetBy: prefix.count)
                    let end = request.path.index(request.path.endIndex, offsetBy: -suffix.count)
                    let taskID = String(request.path[start..<end])
                    guard !taskID.isEmpty else { return .notFound }
                    let messages = try await appServer.recentMessages(threadID: taskID)
                    return .encodable(CodexConversation(taskID: taskID, messages: messages))
                } catch {
                    Self.logger.error("No se pudo recuperar una conversación: \(error.localizedDescription, privacy: .private)")
                    return .serverError()
                }
            }
            return .notFound
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
    let isConnected: Bool

    var body: some View {
        Image(nsImage: Self.makeIcon(color: isConnected ? .systemGreen : .systemRed))
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
