import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct CodexWatchApp: App {
  @StateObject private var relay = WatchRelay.shared

  var body: some Scene {
    WindowGroup {
      TaskPickerView()
        .environmentObject(relay)
        .onAppear { relay.start() }
    }
  }
}

struct TaskPickerView: View {
  @EnvironmentObject private var relay: WatchRelay

  var body: some View {
    NavigationStack {
      Group {
        if relay.tasks.isEmpty {
          ContentUnavailableView(
            "Sin tareas", systemImage: "iphone.and.arrow.forward",
            description: Text(relay.taskRefreshError ?? "Actualizando desde Codex…"))
        } else {
          List {
            if let error = relay.taskRefreshError {
              Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            ForEach(relay.tasks.sorted { $0.updatedAt > $1.updatedAt }) { task in
              NavigationLink(value: task) {
                HStack(spacing: 6) {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).lineLimit(2)
                    Text(task.updatedAt, style: .relative)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 2)
                  TaskStateView(state: task.state)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Tareas")
      .navigationDestination(for: CodexTask.self) { task in
        VoiceCommandView(task: task)
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if relay.isRefreshingTasks {
            ProgressView()
              .controlSize(.mini)
          } else {
            Button { relay.refreshTasks() } label: {
              Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Actualizar tareas")
          }
        }
      }
    }
    .task { await relay.refreshTasksContinuously() }
  }
}

private struct TaskStateView: View {
  let state: CodexTask.State

  var body: some View {
    switch state {
    case .working:
      ProgressView()
        .controlSize(.mini)
        .tint(.green)
        .accessibilityLabel("Codex trabajando")
    case .needsAttention:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
        .accessibilityLabel("Necesita atención")
    case .idle, .unknown:
      EmptyView()
    }
  }
}

struct VoiceCommandView: View {
  private enum ScrollAnchor: Hashable {
    case composer
  }

  @EnvironmentObject private var relay: WatchRelay
  @Environment(\.dismiss) private var dismiss
  let task: CodexTask

  @State private var transcript = ""
  @State private var sent = false

  private var recentMessages: [CodexMessage] {
    relay.conversations[task.id] ?? []
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          Text("Últimos mensajes")
            .font(.caption.bold())
            .foregroundStyle(.secondary)

          if relay.loadingConversations.contains(task.id) {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          } else if let error = relay.conversationErrors[task.id] {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption2)
              .foregroundStyle(.orange)
          } else if recentMessages.isEmpty {
            Text("No hay mensajes disponibles")
              .font(.caption2)
              .foregroundStyle(.secondary)
          } else {
            LazyVStack(alignment: .leading, spacing: 7) {
              ForEach(recentMessages) { message in
                ConversationMessageView(message: message)
              }
            }
          }

          Divider()

          TextFieldLink(prompt: Text("Di la orden que quieres enviar a Codex")) {
            Label(transcript.isEmpty ? "Dictar orden" : "Volver a dictar", systemImage: "mic.fill")
          } onSubmit: {
            transcript = $0
          }
          .buttonStyle(.borderedProminent)

          if !transcript.isEmpty {
            Text(transcript)
              .font(.body)
              .padding(8)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            Button("Enviar") {
              relay.send(CodexCommand(task: task, text: transcript))
              WKInterfaceDevice.current().play(.success)
              sent = true
            }
            .tint(.green)
          }

          if sent {
            Label("Enviado", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .onAppear {
                Task {
                  try? await Task.sleep(for: .seconds(1))
                  dismiss()
                }
              }
          }

          Color.clear
            .frame(height: 1)
            .id(ScrollAnchor.composer)
        }
      }
      .onAppear {
        if !recentMessages.isEmpty {
          proxy.scrollTo(ScrollAnchor.composer, anchor: .bottom)
        }
      }
      .onChange(of: recentMessages.count) { _, count in
        guard count > 0 else { return }
        withAnimation(.easeOut(duration: 0.25)) {
          proxy.scrollTo(ScrollAnchor.composer, anchor: .bottom)
        }
      }
    }
    .navigationTitle("")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        MarqueeTitle(text: task.title)
          .frame(width: 120, height: 24)
      }
    }
    .task { relay.loadConversation(for: task.id) }
  }

}

private struct MarqueeTitle: View {
  let text: String

  @State private var textWidth: CGFloat = 0
  @State private var startedAt = Date()

  private let gap: CGFloat = 24
  private let speed: CGFloat = 24
  private let pause: TimeInterval = 1.2

  var body: some View {
    GeometryReader { container in
      if textWidth > container.size.width {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
          let distance = textWidth + gap
          let travelTime = TimeInterval(distance / speed)
          let cycleTime = pause + travelTime
          let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
          let position = elapsed.truncatingRemainder(dividingBy: cycleTime)
          let offset =
            position < pause
            ? CGFloat.zero
            : -min(distance, CGFloat(position - pause) * speed)

          HStack(spacing: gap) {
            measuredTitle
            title
          }
          .offset(x: offset)
        }
      } else {
        measuredTitle
          .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .clipped()
    .onAppear { startedAt = Date() }
    .onPreferenceChange(MarqueeTitleWidthKey.self) { textWidth = $0 }
    .accessibilityLabel(text)
  }

  private var title: some View {
    Text(text)
      .font(.headline)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }

  private var measuredTitle: some View {
    title.background {
      GeometryReader { proxy in
        Color.clear.preference(key: MarqueeTitleWidthKey.self, value: proxy.size.width)
      }
    }
  }
}

private struct MarqueeTitleWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct ConversationMessageView: View {
  let message: CodexMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(message.role == .user ? "Tú" : "Codex")
        .font(.caption2.bold())
        .foregroundStyle(message.role == .user ? .cyan : .purple)
      Text(verbatim: message.text)
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
  }
}

@MainActor
final class WatchRelay: NSObject, ObservableObject {
  static let shared = WatchRelay()
  @Published private(set) var tasks: [CodexTask] = []
  @Published private(set) var conversations: [String: [CodexMessage]] = [:]
  @Published private(set) var loadingConversations: Set<String> = []
  @Published private(set) var conversationErrors: [String: String] = [:]
  @Published private(set) var isRefreshingTasks = false
  @Published private(set) var taskRefreshError: String?

  private let session: WCSession? = WCSession.isSupported() ? .default : nil

  func start() {
    guard session?.delegate == nil else { return }
    session?.delegate = self
    session?.activate()
    if let data = session?.receivedApplicationContext[CodexWatchWire.tasks] as? Data {
      applyTasks(data)
    }
  }

  func send(_ command: CodexCommand) {
    guard let data = try? CodexWatchWire.encode(command), let session else { return }
    if session.isReachable {
      session.sendMessageData(data, replyHandler: nil) { _ in
        session.transferUserInfo([CodexWatchWire.command: data])
      }
    } else {
      session.transferUserInfo([CodexWatchWire.command: data])
    }
  }

  func refreshTasks() {
    guard !isRefreshingTasks else { return }
    guard let session, session.activationState == .activated, session.isReachable else {
      taskRefreshError = "iPhone no disponible"
      return
    }
    isRefreshingTasks = true
    taskRefreshError = nil
    let replyHandler = WatchTasksReplyHandler()
    session.sendMessage(
      [CodexWatchWire.tasksRequest: true],
      replyHandler: replyHandler.receive,
      errorHandler: replyHandler.fail
    )
  }

  func refreshTasksContinuously() async {
    refreshTasks()
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(10))
      } catch {
        return
      }
      refreshTasks()
    }
  }

  func loadConversation(for taskID: String) {
    guard conversations[taskID] == nil, !loadingConversations.contains(taskID) else { return }
    guard let session, session.isReachable else {
      conversationErrors[taskID] = "Abre Codex Watch en el iPhone"
      return
    }
    loadingConversations.insert(taskID)
    conversationErrors[taskID] = nil
    let replyHandler = WatchConversationReplyHandler(taskID: taskID)
    session.sendMessage(
      [CodexWatchWire.conversationRequest: taskID],
      replyHandler: replyHandler.receive,
      errorHandler: replyHandler.fail
    )
  }

  fileprivate func finishConversation(_ conversation: CodexConversation, for taskID: String) {
    loadingConversations.remove(taskID)
    conversationErrors[taskID] = nil
    conversations[taskID] = conversation.messages
  }

  fileprivate func failConversation(for taskID: String, message: String) {
    loadingConversations.remove(taskID)
    conversationErrors[taskID] = message
  }

  fileprivate func finishTaskRefresh(_ data: Data) {
    isRefreshingTasks = false
    taskRefreshError = nil
    applyTasks(data)
  }

  fileprivate func failTaskRefresh(_ message: String) {
    isRefreshingTasks = false
    taskRefreshError = message
  }

  private func applyTasks(_ data: Data) {
    guard let decoded = try? CodexWatchWire.decode([CodexTask].self, from: data) else { return }
    tasks = decoded.sorted { $0.updatedAt > $1.updatedAt }
  }
}

extension WatchRelay: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard activationState == .activated, error == nil else { return }
    Task { @MainActor [weak self] in self?.refreshTasks() }
  }

  nonisolated func session(
    _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    guard let data = applicationContext[CodexWatchWire.tasks] as? Data else { return }
    Task { @MainActor [weak self] in self?.applyTasks(data) }
  }
}

private final class WatchTasksReplyHandler: @unchecked Sendable {
  func receive(_ reply: [String: Any]) {
    if let error = reply[CodexWatchWire.tasksError] as? String, !error.isEmpty {
      Task { @MainActor in WatchRelay.shared.failTaskRefresh(error) }
      return
    }
    guard let data = reply[CodexWatchWire.tasksResponse] as? Data, !data.isEmpty else {
      Task { @MainActor in
        WatchRelay.shared.failTaskRefresh("No se pudieron actualizar las tareas")
      }
      return
    }
    Task { @MainActor in WatchRelay.shared.finishTaskRefresh(data) }
  }

  func fail(_ error: Error) {
    Task { @MainActor in WatchRelay.shared.failTaskRefresh("iPhone no disponible") }
  }
}

private final class WatchConversationReplyHandler: @unchecked Sendable {
  private let taskID: String

  init(taskID: String) {
    self.taskID = taskID
  }

  func receive(_ reply: [String: Any]) {
    if let error = reply[CodexWatchWire.conversationError] as? String, !error.isEmpty {
      Task { @MainActor [taskID] in
        WatchRelay.shared.failConversation(for: taskID, message: error)
      }
      return
    }
    guard let data = reply[CodexWatchWire.conversationResponse] as? Data,
      !data.isEmpty,
      let conversation = try? CodexWatchWire.decode(CodexConversation.self, from: data)
    else {
      Task { @MainActor [taskID] in
        WatchRelay.shared.failConversation(
          for: taskID, message: "No se pudieron cargar los mensajes")
      }
      return
    }
    Task { @MainActor [taskID] in
      WatchRelay.shared.finishConversation(conversation, for: taskID)
    }
  }

  func fail(_ error: Error) {
    Task { @MainActor [taskID] in
      WatchRelay.shared.failConversation(for: taskID, message: "iPhone no disponible")
    }
  }
}
