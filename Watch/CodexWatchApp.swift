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
  @State private var isCreatingTask = false

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
      .navigationDestination(isPresented: $isCreatingTask) {
        NewTaskView()
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { isCreatingTask = true } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("Crear nueva tarea")
        }
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

private struct NewTaskView: View {
  @EnvironmentObject private var relay: WatchRelay
  @Environment(\.dismiss) private var dismiss

  @State private var prompt = ""
  @State private var selectedProjectPath = ""
  @State private var commandID: UUID?

  private var projectPaths: [String] {
    relay.tasks
      .sorted { $0.updatedAt > $1.updatedAt }
      .compactMap(\.projectPath)
      .reduce(into: [String]()) { paths, path in
        if !path.isEmpty, !paths.contains(path) { paths.append(path) }
      }
  }

  private var receipt: CommandReceipt? {
    guard let commandID else { return nil }
    return relay.commandReceipts[commandID]
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if !projectPaths.isEmpty {
          Picker("Proyecto", selection: $selectedProjectPath) {
            Text("Sin proyecto").tag("")
            ForEach(projectPaths, id: \.self) { path in
              Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
            }
          }
        }

        TextFieldLink(prompt: Text("Describe la nueva tarea")) {
          Label(prompt.isEmpty ? "Dictar petición" : "Volver a dictar", systemImage: "mic.fill")
        } onSubmit: {
          prompt = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .buttonStyle(.borderedProminent)

        if !prompt.isEmpty {
          Text(prompt)
            .font(.body)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

          Button("Crear tarea") {
            let projectPath = selectedProjectPath.isEmpty ? nil : selectedProjectPath
            commandID = relay.createTask(
              NewTaskCommand(prompt: prompt, projectPath: projectPath)
            )
            WKInterfaceDevice.current().play(.click)
          }
          .tint(.green)
          .disabled(receipt?.state == .queued)
        }

        if let receipt {
          switch receipt.state {
          case .queued:
            HStack {
              ProgressView()
              Text(receipt.message).font(.caption2)
            }
          case .sent:
            Label(receipt.message, systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.green)
          case .failed:
            Label(receipt.message, systemImage: "xmark.circle.fill")
              .font(.caption2)
              .foregroundStyle(.red)
          }
        }
      }
    }
    .navigationTitle("Nueva tarea")
    .onAppear {
      if selectedProjectPath.isEmpty { selectedProjectPath = projectPaths.first ?? "" }
    }
    .task(id: commandID) {
      guard let commandID else { return }
      while !Task.isCancelled,
        relay.commandReceipts[commandID]?.state == .queued
      {
        relay.refreshReceipt(commandID)
        do {
          try await Task.sleep(for: .seconds(3))
        } catch {
          return
        }
      }
    }
    .onChange(of: receipt?.state) { _, state in
      guard state == .sent else { return }
      WKInterfaceDevice.current().play(.success)
      relay.refreshTasks()
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        dismiss()
      }
    }
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

  @StateObject private var recorder = WatchVoiceRecorder()
  @State private var commandID: UUID?
  @State private var transcript = ""
  @State private var hasPositionedInitialMessages = false

  private var recentMessages: [CodexMessage] {
    relay.conversations[task.id] ?? []
  }

  private var receipt: CommandReceipt? {
    guard let commandID else { return nil }
    return relay.commandReceipts[commandID]
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          Text("Últimos mensajes")
            .font(.caption.bold())
            .foregroundStyle(.secondary)

          if recentMessages.isEmpty {
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
            } else {
              Text("No hay mensajes disponibles")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          } else {
            LazyVStack(alignment: .leading, spacing: 7) {
              ForEach(recentMessages) { message in
                ConversationMessageView(message: message)
              }
            }
          }

          Divider()

          voiceComposer

          Color.clear
            .frame(height: 1)
            .id(ScrollAnchor.composer)
        }
      }
      .onAppear {
        if !recentMessages.isEmpty {
          hasPositionedInitialMessages = true
          proxy.scrollTo(ScrollAnchor.composer, anchor: .bottom)
        }
      }
      .onChange(of: recentMessages.count) { _, count in
        guard count > 0, !hasPositionedInitialMessages else { return }
        hasPositionedInitialMessages = true
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
    .task(id: relay.updatedAt(for: task.id, fallback: task.updatedAt)) {
      relay.loadConversationIfNeeded(
        for: task.id,
        updatedAt: relay.updatedAt(for: task.id, fallback: task.updatedAt)
      )
    }
    .task(id: commandID) {
      guard let commandID else { return }
      while !Task.isCancelled,
        relay.commandReceipts[commandID]?.state == .queued
      {
        relay.refreshReceipt(commandID)
        do {
          try await Task.sleep(for: .seconds(3))
        } catch {
          return
        }
      }
    }
    .onDisappear { recorder.discard() }
    .onChange(of: receipt?.state) { _, state in
      guard state == .sent else { return }
      WKInterfaceDevice.current().play(.success)
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        dismiss()
      }
    }
  }

  @ViewBuilder
  private var voiceComposer: some View {
    if relay.voiceInputMode == .watchDictation {
      watchDictationComposer
    } else {
      openAIComposer
    }
  }

  @ViewBuilder
  private var watchDictationComposer: some View {
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
        commandID = relay.send(CodexCommand(task: task, text: transcript))
        WKInterfaceDevice.current().play(.click)
      }
      .tint(.green)
      .disabled(receipt?.state == .queued)
    }

    if let receipt {
      switch receipt.state {
      case .queued:
        HStack {
          ProgressView()
          Text(receipt.message).font(.caption2)
        }
      case .sent:
        Label(receipt.message, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      case .failed:
        Label(receipt.message, systemImage: "xmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private var openAIComposer: some View {
    switch recorder.state {
    case .idle:
      Button {
        Task { await recorder.start() }
      } label: {
        Label("Grabar para OpenAI", systemImage: "mic.fill")
      }
      .buttonStyle(.borderedProminent)

    case .requestingPermission:
      HStack {
        ProgressView()
        Text("Preparando micrófono…")
          .font(.caption)
      }

    case .recording:
      Button {
        recorder.stop()
      } label: {
        Label("Detener · \(formattedDuration)", systemImage: "stop.fill")
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)

    case .ready:
      Label("\(relay.transcriptionModel.displayName) · \(formattedDuration)", systemImage: "waveform")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Enviar nota de voz") {
        guard let url = recorder.takeRecordingURL(),
              let identifier = relay.sendVoice(task: task, fileURL: url) else { return }
        commandID = identifier
        WKInterfaceDevice.current().play(.click)
      }
      .tint(.green)
      Button("Volver a grabar") { recorder.discard() }
        .font(.caption)

    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption2)
        .foregroundStyle(.orange)
      Button("Intentar de nuevo") { recorder.discard() }
    }

    if let receipt {
      switch receipt.state {
      case .queued:
        HStack {
          ProgressView()
          Text(receipt.message).font(.caption2)
        }
      case .sent:
        Label(receipt.message, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      case .failed:
        Label(receipt.message, systemImage: "xmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
  }

  private var formattedDuration: String {
    let seconds = max(0, Int(recorder.duration.rounded()))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
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

private struct CachedConversation: Codable {
  let messages: [CodexMessage]
  let updatedAt: Date
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
  @Published private(set) var commandReceipts: [UUID: CommandReceipt] = [:]
  @Published private(set) var voiceInputMode: VoiceInputMode = .watchDictation
  @Published private(set) var transcriptionModel: OpenAITranscriptionModel = .gptTranscribe

  private let session: WCSession? = WCSession.isSupported() ? .default : nil
  private var lastQueuedTaskRequest: Date?
  private var latestTasksRevision = UserDefaults.standard.double(forKey: "latestTasksRevision")
  private var conversationRevisions: [String: Date] = [:]
  private static let cachedConversationsKey = "cachedConversations"

  private override init() {
    super.init()
    guard let data = UserDefaults.standard.data(forKey: Self.cachedConversationsKey),
      let cached = try? CodexWatchWire.decode([String: CachedConversation].self, from: data)
    else { return }
    conversations = cached.mapValues(\.messages)
    conversationRevisions = cached.mapValues(\.updatedAt)
  }

  func start() {
    guard session?.delegate == nil else { return }
    session?.delegate = self
    session?.activate()
    if let data = session?.receivedApplicationContext[CodexWatchWire.tasks] as? Data {
      applyTasks(
        data,
        revision: session?.receivedApplicationContext[CodexWatchWire.tasksRevision] as? TimeInterval
      )
    }
    applyVoiceSettings(
      inputModeRawValue: session?.receivedApplicationContext[CodexWatchWire.voiceInputMode] as? String,
      modelRawValue: session?.receivedApplicationContext[CodexWatchWire.transcriptionModel] as? String
    )
  }

  func send(_ command: CodexCommand) -> UUID {
    commandReceipts[command.id] = CommandReceipt(
      commandID: command.id,
      state: .queued,
      message: "Enviando al Mac…"
    )
    guard let data = try? CodexWatchWire.encode(command),
          let session,
          session.activationState == .activated else {
      commandReceipts[command.id] = CommandReceipt(
        commandID: command.id,
        state: .failed,
        message: "El Watch no está conectado con el iPhone"
      )
      return command.id
    }
    if session.isReachable {
      let replyHandler = WatchCommandReplyHandler(
        commandID: command.id,
        commandData: data,
        session: session
      )
      session.sendMessage(
        [CodexWatchWire.command: data],
        replyHandler: replyHandler.receive,
        errorHandler: replyHandler.fail
      )
    } else {
      session.transferUserInfo([CodexWatchWire.command: data])
      commandReceipts[command.id] = CommandReceipt(
        commandID: command.id,
        state: .queued,
        message: "Pendiente de que responda el iPhone…"
      )
    }
    return command.id
  }

  func createTask(_ command: NewTaskCommand) -> UUID {
    commandReceipts[command.id] = CommandReceipt(
      commandID: command.id,
      state: .queued,
      message: "Creando en Codex…"
    )
    guard let data = try? CodexWatchWire.encode(command),
          let session,
          session.activationState == .activated else {
      commandReceipts[command.id] = CommandReceipt(
        commandID: command.id,
        state: .failed,
        message: "El Watch no está conectado con el iPhone"
      )
      return command.id
    }
    if session.isReachable {
      let replyHandler = WatchCommandReplyHandler(
        commandID: command.id,
        commandData: data,
        messageKey: CodexWatchWire.newTaskCommand,
        session: session
      )
      session.sendMessage(
        [CodexWatchWire.newTaskCommand: data],
        replyHandler: replyHandler.receive,
        errorHandler: replyHandler.fail
      )
    } else {
      session.transferUserInfo([CodexWatchWire.newTaskCommand: data])
      commandReceipts[command.id] = CommandReceipt(
        commandID: command.id,
        state: .queued,
        message: "Pendiente de que responda el iPhone…"
      )
    }
    return command.id
  }

  func sendVoice(task: CodexTask, fileURL: URL) -> UUID? {
    guard let session, session.activationState == .activated else {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
    let command = CodexVoiceCommand(task: task, transcriptionModel: transcriptionModel)
    guard let metadata = try? CodexWatchWire.encode(command) else {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
    commandReceipts[command.id] = CommandReceipt(
      commandID: command.id,
      state: .queued,
      message: "Enviando audio al iPhone…"
    )
    session.transferFile(fileURL, metadata: [CodexWatchWire.voiceCommand: metadata])
    return command.id
  }

  func refreshReceipt(_ commandID: UUID) {
    guard let session, session.activationState == .activated, session.isReachable else { return }
    let replyHandler = WatchReceiptReplyHandler(commandID: commandID)
    session.sendMessage(
      [CodexWatchWire.commandReceiptRequest: commandID.uuidString],
      replyHandler: replyHandler.receive,
      errorHandler: replyHandler.fail
    )
  }

  func refreshTasks() {
    guard !isRefreshingTasks else { return }
    guard let session, session.activationState == .activated else {
      taskRefreshError = "Conectando con el iPhone…"
      return
    }
    isRefreshingTasks = true
    taskRefreshError = nil
    guard session.isReachable else {
      if lastQueuedTaskRequest.map({ Date().timeIntervalSince($0) > 45 }) ?? true {
        lastQueuedTaskRequest = Date()
        session.transferUserInfo([CodexWatchWire.tasksRequest: true])
      }
      isRefreshingTasks = false
      taskRefreshError = "Actualización en segundo plano pendiente"
      return
    }
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

  func updatedAt(for taskID: String, fallback: Date) -> Date {
    tasks.first(where: { $0.id == taskID })?.updatedAt ?? fallback
  }

  func loadConversationIfNeeded(for taskID: String, updatedAt revision: Date) {
    if let loadedRevision = conversationRevisions[taskID], loadedRevision >= revision { return }
    guard !loadingConversations.contains(taskID) else { return }
    guard let session, session.isReachable else {
      if conversations[taskID]?.isEmpty != false {
        conversationErrors[taskID] = "Abre Codex Watch en el iPhone"
      }
      return
    }
    loadingConversations.insert(taskID)
    conversationErrors[taskID] = nil
    let replyHandler = WatchConversationReplyHandler(taskID: taskID, revision: revision)
    session.sendMessage(
      [CodexWatchWire.conversationRequest: taskID],
      replyHandler: replyHandler.receive,
      errorHandler: replyHandler.fail
    )
  }

  fileprivate func finishConversation(
    _ conversation: CodexConversation,
    for taskID: String,
    revision: Date
  ) {
    loadingConversations.remove(taskID)
    conversationErrors[taskID] = nil
    conversations[taskID] = conversation.messages
    conversationRevisions[taskID] = revision
    persistConversations()

    let newestRevision = updatedAt(for: taskID, fallback: revision)
    if newestRevision > revision {
      loadConversationIfNeeded(for: taskID, updatedAt: newestRevision)
    }
  }

  fileprivate func failConversation(for taskID: String, message: String) {
    loadingConversations.remove(taskID)
    conversationErrors[taskID] = message
  }

  fileprivate func finishTaskRefresh(_ data: Data, revision: TimeInterval?) {
    isRefreshingTasks = false
    taskRefreshError = nil
    applyTasks(data, revision: revision)
  }

  fileprivate func applyCommandReceipt(_ data: Data) {
    guard let receipt = try? CodexWatchWire.decode(CommandReceipt.self, from: data) else { return }
    commandReceipts[receipt.commandID] = receipt
  }

  fileprivate func setCommandReceipt(_ receipt: CommandReceipt) {
    commandReceipts[receipt.commandID] = receipt
  }

  fileprivate func failTaskRefresh(_ message: String) {
    isRefreshingTasks = false
    taskRefreshError = message
  }

  private func applyTasks(_ data: Data, revision: TimeInterval?) {
    if let revision {
      guard revision >= latestTasksRevision else { return }
      latestTasksRevision = revision
      UserDefaults.standard.set(revision, forKey: "latestTasksRevision")
    } else if latestTasksRevision > 0 {
      return
    }
    guard let decoded = try? CodexWatchWire.decode([CodexTask].self, from: data) else { return }
    tasks = decoded.sorted { $0.updatedAt > $1.updatedAt }
    isRefreshingTasks = false
    taskRefreshError = nil
    lastQueuedTaskRequest = nil

    if let mostRecentTask = tasks.first {
      loadConversationIfNeeded(
        for: mostRecentTask.id,
        updatedAt: mostRecentTask.updatedAt
      )
    }
  }

  private func persistConversations() {
    var cached: [String: CachedConversation] = [:]
    for (taskID, revision) in conversationRevisions
      .sorted(by: { $0.value > $1.value })
      .prefix(12)
    {
      guard let messages = conversations[taskID] else { continue }
      cached[taskID] = CachedConversation(messages: messages, updatedAt: revision)
    }
    guard let data = try? CodexWatchWire.encode(cached) else { return }
    UserDefaults.standard.set(data, forKey: Self.cachedConversationsKey)
  }

  private func applyVoiceSettings(inputModeRawValue: String?, modelRawValue: String?) {
    if let inputModeRawValue, let mode = VoiceInputMode(rawValue: inputModeRawValue) {
      voiceInputMode = mode
    }
    if let modelRawValue, let model = OpenAITranscriptionModel(rawValue: modelRawValue) {
      transcriptionModel = model
    }
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
    let tasksData = applicationContext[CodexWatchWire.tasks] as? Data
    let tasksRevision = applicationContext[CodexWatchWire.tasksRevision] as? TimeInterval
    let inputMode = applicationContext[CodexWatchWire.voiceInputMode] as? String
    let transcriptionModel = applicationContext[CodexWatchWire.transcriptionModel] as? String
    Task { @MainActor [weak self] in
      if let tasksData { self?.applyTasks(tasksData, revision: tasksRevision) }
      self?.applyVoiceSettings(inputModeRawValue: inputMode, modelRawValue: transcriptionModel)
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    let tasksData = message[CodexWatchWire.tasksResponse] as? Data
    let tasksRevision = message[CodexWatchWire.tasksRevision] as? TimeInterval
    let receiptData = message[CodexWatchWire.commandReceipt] as? Data
    Task { @MainActor [weak self] in
      if let tasksData { self?.applyTasks(tasksData, revision: tasksRevision) }
      if let receiptData { self?.applyCommandReceipt(receiptData) }
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    let tasksData = userInfo[CodexWatchWire.tasksResponse] as? Data
    let tasksRevision = userInfo[CodexWatchWire.tasksRevision] as? TimeInterval
    let inputMode = userInfo[CodexWatchWire.voiceInputMode] as? String
    let transcriptionModel = userInfo[CodexWatchWire.transcriptionModel] as? String
    let receiptData = userInfo[CodexWatchWire.commandReceipt] as? Data
    Task { @MainActor [weak self] in
      if let tasksData { self?.applyTasks(tasksData, revision: tasksRevision) }
      self?.applyVoiceSettings(
        inputModeRawValue: inputMode,
        modelRawValue: transcriptionModel
      )
      if let receiptData { self?.applyCommandReceipt(receiptData) }
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    guard session.isReachable else { return }
    Task { @MainActor [weak self] in self?.refreshTasks() }
  }

  nonisolated func session(
    _ session: WCSession,
    didFinish fileTransfer: WCSessionFileTransfer,
    error: Error?
  ) {
    let fileURL = fileTransfer.file.fileURL
    let metadata = fileTransfer.file.metadata?[CodexWatchWire.voiceCommand] as? Data
    Task { @MainActor [weak self] in
      defer { try? FileManager.default.removeItem(at: fileURL) }
      guard let error,
            let metadata,
            let command = try? CodexWatchWire.decode(CodexVoiceCommand.self, from: metadata) else { return }
      self?.commandReceipts[command.id] = CommandReceipt(
        commandID: command.id,
        state: .failed,
        message: "No se pudo transferir el audio: \(error.localizedDescription)"
      )
    }
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
    let revision = reply[CodexWatchWire.tasksRevision] as? TimeInterval
    Task { @MainActor in WatchRelay.shared.finishTaskRefresh(data, revision: revision) }
  }

  func fail(_ error: Error) {
    Task { @MainActor in WatchRelay.shared.failTaskRefresh("iPhone no disponible") }
  }
}

private final class WatchReceiptReplyHandler: @unchecked Sendable {
  private let commandID: UUID

  init(commandID: UUID) {
    self.commandID = commandID
  }

  func receive(_ reply: [String: Any]) {
    guard let data = reply[CodexWatchWire.commandReceipt] as? Data else { return }
    Task { @MainActor in WatchRelay.shared.applyCommandReceipt(data) }
  }

  func fail(_ error: Error) {
    // A later poll will retry when the iPhone is reachable again.
  }
}

private final class WatchConversationReplyHandler: @unchecked Sendable {
  private let taskID: String
  private let revision: Date

  init(taskID: String, revision: Date) {
    self.taskID = taskID
    self.revision = revision
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
    Task { @MainActor [taskID, revision] in
      WatchRelay.shared.finishConversation(
        conversation,
        for: taskID,
        revision: revision
      )
    }
  }

  func fail(_ error: Error) {
    Task { @MainActor [taskID] in
      WatchRelay.shared.failConversation(for: taskID, message: "iPhone no disponible")
    }
  }
}

private final class WatchCommandReplyHandler: @unchecked Sendable {
  private let commandID: UUID
  private let commandData: Data
  private let messageKey: String
  private let session: WCSession

  init(
    commandID: UUID,
    commandData: Data,
    messageKey: String = CodexWatchWire.command,
    session: WCSession
  ) {
    self.commandID = commandID
    self.commandData = commandData
    self.messageKey = messageKey
    self.session = session
  }

  func receive(_ reply: [String: Any]) {
    guard let data = reply[CodexWatchWire.commandReceipt] as? Data else {
      Task { @MainActor [commandID] in
        WatchRelay.shared.setCommandReceipt(CommandReceipt(
          commandID: commandID,
          state: .failed,
          message: "El iPhone no confirmó el envío"
        ))
      }
      return
    }
    Task { @MainActor in WatchRelay.shared.applyCommandReceipt(data) }
  }

  func fail(_ error: Error) {
    session.transferUserInfo([messageKey: commandData])
    Task { @MainActor [commandID] in
      WatchRelay.shared.setCommandReceipt(CommandReceipt(
        commandID: commandID,
        state: .queued,
        message: "Envío en segundo plano pendiente…"
      ))
    }
  }
}
