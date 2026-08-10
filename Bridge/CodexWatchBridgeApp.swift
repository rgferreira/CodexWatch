import SwiftUI

@main
struct CodexWatchBridgeApp: App {
    @StateObject private var controller = BridgeController()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text(controller.status).font(.headline)
                Text("Código: \(controller.pairingCode)")
                    .font(.system(.body, design: .monospaced))
                Divider()
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
                    HStack {
                        Text(controller.pairingCode).font(.system(.title, design: .monospaced).bold())
                        Spacer()
                        Button("Generar otro") { controller.regeneratePairingCode() }
                    }
                    Text("Introduce este código en la app del iPhone.")
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
    @Published private(set) var status = "Iniciando…"
    @Published private(set) var isReady = false
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var pairingCode: String

    private let appServer = CodexAppServerClient()
    private var httpServer: LocalHTTPServer?
    private var retryTask: Task<Void, Never>?
    private var isHTTPReady = false
    private var isCodexReady = false

    init() {
        if let saved = UserDefaults.standard.string(forKey: "pairingCode") {
            pairingCode = saved
        } else {
            pairingCode = Self.makePairingCode()
            UserDefaults.standard.set(pairingCode, forKey: "pairingCode")
        }

        Task { await start() }
    }

    func regeneratePairingCode() {
        pairingCode = Self.makePairingCode()
        UserDefaults.standard.set(pairingCode, forKey: "pairingCode")
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
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try appServer.start()
                    if httpServer == nil {
                        httpServer = try LocalHTTPServer(port: 48720, onStateChange: { [weak self] ready, error in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                isHTTPReady = ready
                                if let error { status = "Error de red: \(error)" }
                                updateReadiness()
                            }
                        }) { [weak self] request in
                            guard let self else { return .serverError("Puente no disponible") }
                            return await self.handle(request)
                        }
                    }
                    await refreshTasks()
                    if isReady { return }
                } catch {
                    status = "Reintentando conexión con Codex…"
                    isReady = false
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func updateReadiness() {
        isReady = isHTTPReady && isCodexReady
        if isReady {
            status = "Conectado a Codex · puerto 48720"
        } else if !isHTTPReady && isCodexReady {
            status = "Codex disponible · iniciando red…"
        }
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/health" { return .json(["status": "ok"]) }
        guard request.headers["x-codexwatch-token"] == pairingCode else { return .unauthorized }

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
                return .serverError(error.localizedDescription)
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
                    return .serverError(error.localizedDescription)
                }
            }
            return .notFound
        }
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
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
