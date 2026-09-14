import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct CodexWatchApp: App {
  @StateObject private var relay = WatchRelay.shared
  private let automatedDemo = ProcessInfo.processInfo.arguments.contains("--codexwatch-autodemo")

  var body: some Scene {
    WindowGroup {
      if automatedDemo {
        AutomatedDemoView()
      } else {
        TaskPickerView()
          .environmentObject(relay)
          .onAppear { relay.start() }
      }
    }
  }
}

private struct AutomatedDemoView: View {
  @State private var phase = 0
  @State private var landingTarget = 0
  @State private var conversationTarget = 0

  private let tasks = [
    "Prepare the Aurora launch", "Polish the iPhone onboarding",
    "Weekly trends briefing", "Episode 12 script",
    "August executive dashboard", "Companion security review",
    "Ideas for the next release", "Public website copy"
  ]

  var body: some View {
    Group {
      if phase <= 2 || phase == 8 {
        landing
      } else if phase <= 7 {
        conversation
      } else if phase == 10 {
        projectPicker
      } else {
        newTask
      }
    }
    .task { await play() }
  }

  private var landing: some View {
    VStack(spacing: 4) {
      HStack {
        demoCircleButton("plus")
        Spacer()
        Text("Tasks").font(.headline)
        Spacer()
        demoCircleButton("arrow.clockwise")
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 7) {
            ForEach(Array(tasks.enumerated()), id: \.offset) { index, title in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(title).font(.body).lineLimit(2)
                  Text(index == 0 ? "1 min" : "\(index * 4 + 3) min")
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                if index == 0 || index == 4 { ProgressView().controlSize(.mini).tint(.green) }
                if index == 2 {
                  Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
              }
              .padding(9)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
              .id(index)
            }
          }
        }
        .onChange(of: landingTarget) { _, value in
          withAnimation(.easeInOut(duration: 1.4)) {
            proxy.scrollTo(value, anchor: value == 0 ? .top : .center)
          }
        }
      }
    }
    .padding(.horizontal, 4)
  }

  private var conversation: some View {
    Group {
      if phase <= 4 {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              Text("Prepare the Aurora launch")
                .font(.headline).lineLimit(1)
              if phase == 3 {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
              } else {
                Text("Recent messages").font(.caption.bold()).foregroundStyle(.secondary)
                demoMessage("You", "Is the beta launch plan ready?", .cyan).id(0)
                demoMessage("Codex", "Yes. The build passed every test and deployment is ready.", .purple).id(1)
                demoMessage("You", "Check the complete experience from the Watch.", .cyan).id(2)
                demoMessage("Codex", "Navigation, dictation and task creation are ready.", .purple).id(3)
              }
            }
          }
          .onChange(of: conversationTarget) { _, value in
            withAnimation(.easeInOut(duration: 1.6)) {
              proxy.scrollTo(value, anchor: value == 0 ? .top : .bottom)
            }
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Prepare the Aurora launch").font(.headline).lineLimit(1)
          Text("Recent messages").font(.caption.bold()).foregroundStyle(.secondary)
          demoMessage("Codex", "Deployment is ready.", .purple)
          if phase == 5 {
            HStack(spacing: 7) {
              Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
              Text("Listening…").font(.headline)
            }
            .frame(maxWidth: .infinity).padding(12)
            .background(.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
          } else {
            Text("Add a final accessibility check before release.")
              .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            if phase == 6 {
              Label("Send", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity).padding(8)
                .background(.green, in: Capsule())
            } else {
              Label("Command sent to Codex", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
            }
          }
        }
      }
    }
  }

  private var projectPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Project").font(.headline).frame(maxWidth: .infinity)
      Label("No project", systemImage: "folder")
        .padding(10).background(.blue.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
      Label("Aurora", systemImage: "folder.fill").padding(10)
      Label("CodexWatch", systemImage: "folder.fill").padding(10)
    }
  }

  private var newTask: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 9) {
        Text("New task").font(.headline).frame(maxWidth: .infinity)
        Label(phase >= 11 ? "No project" : "Aurora", systemImage: "folder")
          .padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        if phase >= 11 {
          Text("Create a concise release summary for the team.")
            .lineLimit(2)
            .font(.body)
            .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
          if phase == 11 {
            Text("Create task").frame(maxWidth: .infinity).padding(8)
              .background(.green, in: Capsule())
          } else {
            Label("Task created in Codex", systemImage: "checkmark.circle.fill")
              .font(.caption).foregroundStyle(.green)
          }
        } else {
          Label("Dictate request", systemImage: "mic.fill")
            .frame(maxWidth: .infinity).padding(8).background(.blue, in: Capsule())
        }
      }
    }
  }

  private func demoCircleButton(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.title3).frame(width: 42, height: 42)
      .background(.quaternary, in: Circle())
  }

  private func demoMessage(_ role: String, _ text: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(role).font(.caption2.bold()).foregroundStyle(color)
      Text(text).font(.caption)
    }
    .padding(7).frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
  }

  private func play() async {
    try? await Task.sleep(for: .seconds(3)); landingTarget = 3
    try? await Task.sleep(for: .seconds(2)); landingTarget = 7
    try? await Task.sleep(for: .seconds(3)); landingTarget = 4
    try? await Task.sleep(for: .seconds(2)); landingTarget = 0
    try? await Task.sleep(for: .seconds(3)); phase = 3
    try? await Task.sleep(for: .seconds(3)); phase = 4; conversationTarget = 0
    try? await Task.sleep(for: .seconds(2)); conversationTarget = 3
    let remainder: [(Int, Double)] = [
      (5, 4), (6, 5), (7, 4), (8, 3), (9, 3), (10, 4), (11, 5), (12, 5)
    ]
    for (next, seconds) in remainder {
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.35)) { phase = next }
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
          VStack(spacing: 8) {
            CloudTransportStatusView()
            ContentUnavailableView(
              "Sin tareas", systemImage: "tray",
              description: Text(relay.taskRefreshError ?? "Actualizando desde Codex…"))
          }
        } else {
          List {
            CloudTransportStatusView()
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
      .navigationTitle(relay.isDemoMode ? "Tasks" : "Tareas")
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
    .alert(
      "Activar conexión directa",
      isPresented: Binding(
        get: { relay.pendingCloudPairingCode != nil },
        set: { _ in }
      )
    ) {
      Button("Coincide · Activar") { relay.approveCloudPairing() }
      Button("Cancelar", role: .cancel) { relay.cancelCloudPairing() }
    } message: {
      Text("Comprueba en el Mac el código \(relay.pendingCloudPairingCode ?? "").")
    }
  }
}

private struct CloudTransportStatusView: View {
  @EnvironmentObject private var relay: WatchRelay

  var body: some View {
    Label(
      relay.cloudTransportStatus,
      systemImage: relay.isCloudTransportActive ? "cloud.fill" : "cloud.slash.fill"
    )
    .font(.caption2)
    .foregroundStyle(relay.isCloudTransportActive ? .green : .orange)
    .lineLimit(2)
    .accessibilityLabel("Conexión directa: \(relay.cloudTransportStatus)")
  }
}

private struct NewTaskView: View {
  @EnvironmentObject private var relay: WatchRelay
  @Environment(\.dismiss) private var dismiss

  @State private var prompt = ""
  @State private var projectSelection = ProjectSelectionState()
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

  private var selectedProjectName: String {
    guard !projectSelection.selectedPath.isEmpty else {
      return relay.isDemoMode ? "No project" : "Sin proyecto"
    }
    return URL(fileURLWithPath: projectSelection.selectedPath).lastPathComponent
  }

  private var selectedProjectPath: Binding<String> {
    Binding(
      get: { projectSelection.selectedPath },
      set: { projectSelection.select($0) }
    )
  }

  var body: some View {
    List {
      Section(relay.isDemoMode ? "Project" : "Proyecto") {
        NavigationLink {
          ProjectSelectionView(
            projectPaths: projectPaths,
            selection: selectedProjectPath
          )
        } label: {
          Label {
            Text(selectedProjectName)
              .lineLimit(2)
          } icon: {
            Image(systemName: projectSelection.selectedPath.isEmpty ? "folder" : "folder.fill")
          }
        }
        .accessibilityLabel("Proyecto: \(selectedProjectName)")
      }

      Section(relay.isDemoMode ? "Request" : "Petición") {
        TextFieldLink(prompt: Text(relay.isDemoMode ? "Describe the new task" : "Describe la nueva tarea")) {
          Label(
            prompt.isEmpty
              ? (relay.isDemoMode ? "Dictate request" : "Dictar petición")
              : (relay.isDemoMode ? "Dictate again" : "Volver a dictar"),
            systemImage: "mic.fill")
        } onSubmit: {
          prompt = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .buttonStyle(.borderedProminent)

        if !prompt.isEmpty {
          Text(prompt)
            .font(.body)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

          Button(relay.isDemoMode ? "Create task" : "Crear tarea") {
            let projectPath = projectSelection.selectedPath.isEmpty
              ? nil
              : projectSelection.selectedPath
            commandID = relay.createTask(
              NewTaskCommand(prompt: prompt, projectPath: projectPath)
            )
            WKInterfaceDevice.current().play(.click)
          }
          .tint(.green)
          .disabled(receipt?.state == .queued)
        }
      }

      if let receipt {
        Section(relay.isDemoMode ? "Status" : "Estado") {
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
    .navigationTitle(relay.isDemoMode ? "New task" : "Nueva tarea")
    .onAppear {
      projectSelection.initializeIfNeeded(projectPaths: projectPaths)
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

private struct ProjectSelectionView: View {
  @EnvironmentObject private var relay: WatchRelay
  let projectPaths: [String]
  @Binding var selection: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      projectButton(
        title: relay.isDemoMode ? "No project" : "Sin proyecto",
        path: "", systemImage: "folder")
      ForEach(projectPaths, id: \.self) { path in
        projectButton(
          title: URL(fileURLWithPath: path).lastPathComponent,
          path: path,
          systemImage: "folder.fill"
        )
      }
    }
    .navigationTitle(relay.isDemoMode ? "Project" : "Proyecto")
  }

  private func projectButton(title: String, path: String, systemImage: String) -> some View {
    Button {
      selection = path
      WKInterfaceDevice.current().play(.click)
      dismiss()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .foregroundStyle(.blue)
        Text(title)
          .lineLimit(2)
        Spacer(minLength: 2)
        if selection == path {
          Image(systemName: "checkmark")
            .foregroundStyle(.green)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
  @State private var confirmsDuplicateCommand = false

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
          Text(relay.isDemoMode ? "Recent messages" : "Últimos mensajes")
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
              Text(relay.isDemoMode ? "No messages available" : "No hay mensajes disponibles")
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
        if commandID == nil, let pending = relay.latestPendingTextCommand(taskID: task.id) {
          commandID = pending.command.id
        }
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
    .alert("Ya hay una orden idéntica pendiente", isPresented: $confirmsDuplicateCommand) {
      Button("Enviar otra de todos modos") {
        commandID = relay.send(
          CodexCommand(task: task, text: transcript),
          allowingDuplicate: true
        )
        WKInterfaceDevice.current().play(.click)
      }
      Button("Cancelar", role: .cancel) {}
    } message: {
      Text("La orden anterior todavía no ha terminado. Solo se creará otra si lo confirmas.")
    }
  }

  @ViewBuilder
  private var voiceComposer: some View {
    if relay.shouldUseWatchDictation {
      watchDictationComposer
    } else {
      openAIComposer
    }
  }

  @ViewBuilder
  private var watchDictationComposer: some View {
    TextFieldLink(prompt: Text(relay.isDemoMode ? "Say what you want Codex to do" : "Di la orden que quieres enviar a Codex")) {
      Label(
        transcript.isEmpty
          ? (relay.isDemoMode ? "Dictate command" : "Dictar orden")
          : (relay.isDemoMode ? "Dictate again" : "Volver a dictar"),
        systemImage: "mic.fill")
    } onSubmit: {
      transcript = $0
    }
    .buttonStyle(.borderedProminent)

    if !transcript.isEmpty {
      Text(transcript)
        .font(.body)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

      if relay.pendingTextCommand(taskID: task.id, text: transcript) != nil {
        Button(relay.isDemoMode ? "Send another" : "Enviar otra orden") {
          confirmsDuplicateCommand = true
        }
        .tint(.orange)
      } else {
        Button(relay.isDemoMode ? "Send" : "Enviar") {
          commandID = relay.send(CodexCommand(task: task, text: transcript))
          WKInterfaceDevice.current().play(.click)
        }
        .tint(.green)
        .disabled(receipt?.state == .queued)
      }
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
  @EnvironmentObject private var relay: WatchRelay
  let message: CodexMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(message.role == .user ? (relay.isDemoMode ? "You" : "Tú") : "Codex")
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
  @Published private(set) var pendingCloudPairingCode: String?
  @Published private(set) var cloudTransportStatus = "Sin conexión directa"
  @Published private(set) var isCloudTransportActive = false
  @Published private(set) var companionReachable = false

  private let session: WCSession? = WCSession.isSupported() ? .default : nil
  let isDemoMode = ProcessInfo.processInfo.arguments.contains("--codexwatch-demo")
  private var lastQueuedTaskRequest: Date?
  private var latestTasksRevision = UserDefaults.standard.double(forKey: "latestTasksRevision")
  private var conversationRevisions: [String: Date] = [:]
  private var pendingCloudPairingOffer: CloudRelayPairingOffer?
  private var cloudClient: WatchCloudRelayClient?
  private var cloudReceiveTask: Task<Void, Never>?
  private var pendingTaskRequestID: UUID?
  private var pendingConversationRequests: [UUID: (taskID: String, revision: Date)] = [:]
  private var pairingRequestInFlight = false
  private var lastCloudRoundTripAt: Date?
  private static let cachedConversationsKey = "cachedConversations"
  private static let pendingTextCommandOutboxKey = "pendingTextCommandOutbox"
  private var pendingTextCommandOutbox = PendingTextCommandOutbox()

  var shouldUseWatchDictation: Bool {
    voiceInputMode == .watchDictation
  }

  private override init() {
    super.init()
    if isDemoMode {
      prepareDemo()
      return
    }
    if let data = UserDefaults.standard.data(forKey: Self.pendingTextCommandOutboxKey),
      let outbox = try? CodexWatchWire.decode(PendingTextCommandOutbox.self, from: data)
    {
      pendingTextCommandOutbox = outbox
      commandReceipts = Dictionary(
        uniqueKeysWithValues: outbox.intents.map { ($0.command.id, $0.receipt) }
      )
    }
    if let data = UserDefaults.standard.data(forKey: Self.cachedConversationsKey),
      let cached = try? CodexWatchWire.decode([String: CachedConversation].self, from: data)
    {
      conversations = cached.mapValues(\.messages)
      conversationRevisions = cached.mapValues(\.updatedAt)
    }
  }

  func start() {
    guard !isDemoMode else { return }
    guard session?.delegate == nil else { return }
    session?.delegate = self
    session?.activate()
    companionReachable = session?.isReachable == true
    configureExistingCloudTransport()
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

  func send(_ command: CodexCommand, allowingDuplicate: Bool = false) -> UUID {
    if !allowingDuplicate,
      let existing = pendingTextCommandOutbox.matching(
        taskID: command.taskID,
        text: command.text
      )
    {
      commandReceipts[existing.command.id] = existing.receipt
      return existing.command.id
    }
    let initialReceipt = CommandReceipt(
      commandID: command.id,
      state: .queued,
      message: isDemoMode ? "Sending to Codex…" : "Enviando al Mac…"
    )
    setCommandReceipt(initialReceipt, for: command)
    if isDemoMode {
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(850))
        guard let self else { return }
        conversations[command.taskID, default: []].append(CodexMessage(
          id: "demo-user-\(command.id.uuidString)",
          role: .user,
          text: command.text,
          createdAt: Date()
        ))
        setCommandReceipt(CommandReceipt(
          commandID: command.id,
          state: .sent,
          message: "Command sent to Codex"
        ))
      }
      return command.id
    }
    guard let data = try? CodexWatchWire.encode(command) else {
      setCommandReceipt(CommandReceipt(
        commandID: command.id,
        state: .failed,
        message: "No se pudo preparar la orden"
      ))
      return command.id
    }
    if let cloudClient {
      Task { [weak self] in
        do {
          try await cloudClient.send(command)
          guard let self else { return }
          setCommandReceipt(CommandReceipt(
            commandID: command.id,
            state: .queued,
            message: "Enviada directamente por HTTPS…"
          ))
          cloudTransportStatus = "Conexión directa activa"
        } catch {
          guard let self else { return }
          isCloudTransportActive = false
          cloudTransportStatus = "HTTPS directo falló · usando iPhone"
          setCommandReceipt(CommandReceipt(
            commandID: command.id,
            state: .queued,
            message: "HTTPS directo falló; probando con el iPhone…"
          ))
          sendThroughCompanion(commandID: command.id, data: data)
        }
      }
      return command.id
    }
    sendThroughCompanion(commandID: command.id, data: data)
    return command.id
  }

  private func sendThroughCompanion(commandID: UUID, data: Data) {
    guard let session, session.activationState == .activated else {
      setCommandReceipt(CommandReceipt(
        commandID: commandID,
        state: .failed,
        message: "El Watch no está conectado con el iPhone"
      ))
      return
    }
    if session.isReachable {
      let replyHandler = WatchCommandReplyHandler(
        commandID: commandID,
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
      setCommandReceipt(CommandReceipt(
        commandID: commandID,
        state: .queued,
        message: "Pendiente de que responda el iPhone…"
      ))
    }
  }

  func createTask(_ command: NewTaskCommand) -> UUID {
    commandReceipts[command.id] = CommandReceipt(
      commandID: command.id,
      state: .queued,
      message: isDemoMode ? "Creating in Codex…" : "Creando en Codex…"
    )
    if isDemoMode {
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(900))
        guard let self else { return }
        let task = CodexTask(
          id: "demo-new-\(command.id.uuidString)",
          title: command.prompt,
          preview: command.prompt,
          projectPath: command.projectPath,
          updatedAt: Date(),
          state: .working
        )
        tasks.insert(task, at: 0)
        conversations[task.id] = [CodexMessage(
          id: "demo-new-message-\(command.id.uuidString)",
          role: .user,
          text: command.prompt,
          createdAt: Date()
        )]
        conversationRevisions[task.id] = task.updatedAt
        commandReceipts[command.id] = CommandReceipt(
          commandID: command.id,
          state: .sent,
          message: "Task created in Codex"
        )
      }
      return command.id
    }
    guard let data = try? CodexWatchWire.encode(command) else {
      commandReceipts[command.id] = CommandReceipt(
        commandID: command.id,
        state: .failed,
        message: "No se pudo preparar la nueva tarea"
      )
      return command.id
    }
    if let cloudClient {
      Task { [weak self] in
        do {
          try await cloudClient.createTask(command)
          self?.commandReceipts[command.id] = CommandReceipt(
            commandID: command.id,
            state: .queued,
            message: "Creando directamente por HTTPS…"
          )
        } catch {
          guard let self else { return }
          isCloudTransportActive = false
          cloudTransportStatus = "HTTPS directo falló · usando iPhone"
          sendNewTaskThroughCompanion(commandID: command.id, data: data)
        }
      }
      return command.id
    }
    sendNewTaskThroughCompanion(commandID: command.id, data: data)
    return command.id
  }

  private func sendNewTaskThroughCompanion(commandID: UUID, data: Data) {
    guard let session, session.activationState == .activated else {
      commandReceipts[commandID] = CommandReceipt(
        commandID: commandID,
        state: .failed,
        message: "Sin conexión HTTPS directa ni iPhone"
      )
      return
    }
    if session.isReachable {
      let replyHandler = WatchCommandReplyHandler(
        commandID: commandID,
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
      commandReceipts[commandID] = CommandReceipt(
        commandID: commandID,
        state: .queued,
        message: "Pendiente de que responda el iPhone…"
      )
    }
  }

  func sendVoice(task: CodexTask, fileURL: URL) -> UUID? {
    let command = CodexVoiceCommand(task: task, transcriptionModel: transcriptionModel)
    guard let metadata = try? CodexWatchWire.encode(command) else {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
    commandReceipts[command.id] = CommandReceipt(
      commandID: command.id,
      state: .queued,
      message: cloudClient == nil ? "Enviando audio al iPhone…" : "Enviando audio directamente…"
    )
    if let cloudClient {
      Task { [weak self] in
        do {
          let audio = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
          try await cloudClient.sendVoice(command, audio: audio)
          try? FileManager.default.removeItem(at: fileURL)
          self?.commandReceipts[command.id] = CommandReceipt(
            commandID: command.id,
            state: .queued,
            message: "Audio enviado directamente; transcribiendo…"
          )
        } catch {
          guard let self else { return }
          isCloudTransportActive = false
          cloudTransportStatus = "Falló el audio HTTPS directo"
          try? FileManager.default.removeItem(at: fileURL)
          commandReceipts[command.id] = CommandReceipt(
            commandID: command.id,
            state: .failed,
            message: "Audio HTTPS fallido: \(error.localizedDescription)"
          )
        }
      }
      return command.id
    }
    sendVoiceThroughCompanion(command: command, metadata: metadata, fileURL: fileURL)
    return command.id
  }

  private func sendVoiceThroughCompanion(
    command: CodexVoiceCommand,
    metadata: Data,
    fileURL: URL
  ) {
    guard let session,
          session.activationState == .activated,
          companionReachable else {
      try? FileManager.default.removeItem(at: fileURL)
      commandReceipts[command.id] = CommandReceipt(
        commandID: command.id,
        state: .failed,
        message: "Sin conexión HTTPS directa ni iPhone"
      )
      return
    }
    commandReceipts[command.id] = CommandReceipt(
      commandID: command.id,
      state: .queued,
      message: "Enviando audio al iPhone…"
    )
    session.transferFile(fileURL, metadata: [CodexWatchWire.voiceCommand: metadata])
  }

  func refreshReceipt(_ commandID: UUID) {
    guard !isDemoMode else { return }
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
    if isDemoMode {
      isRefreshingTasks = true
      taskRefreshError = nil
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(650))
        self?.isRefreshingTasks = false
      }
      return
    }
    if let cloudClient {
      isRefreshingTasks = true
      taskRefreshError = nil
      let requestID = UUID()
      pendingTaskRequestID = requestID
      Task { [weak self] in
        do {
          try await cloudClient.requestTasks(requestID: requestID)
          try await Task.sleep(for: .seconds(30))
          guard let self, pendingTaskRequestID == requestID else { return }
          pendingTaskRequestID = nil
          isRefreshingTasks = false
          if companionReachable {
            cloudTransportStatus = "HTTPS sin respuesta · usando iPhone"
            refreshTasksThroughCompanion()
          } else {
            taskRefreshError = "El Mac no respondió por HTTPS"
          }
        } catch {
          guard let self, pendingTaskRequestID == requestID else { return }
          pendingTaskRequestID = nil
          isRefreshingTasks = false
          if companionReachable {
            cloudTransportStatus = "HTTPS directo falló · usando iPhone"
            refreshTasksThroughCompanion()
          } else {
            taskRefreshError = "Sin conexión HTTPS directa ni iPhone"
          }
        }
      }
      return
    }
    refreshTasksThroughCompanion()
  }

  private func refreshTasksThroughCompanion() {
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
    if isDemoMode { return }
    if let loadedRevision = conversationRevisions[taskID], loadedRevision >= revision { return }
    guard !loadingConversations.contains(taskID) else { return }
    if let cloudClient {
      loadingConversations.insert(taskID)
      conversationErrors[taskID] = nil
      let requestID = UUID()
      pendingConversationRequests[requestID] = (taskID, revision)
      Task { [weak self] in
        do {
          try await cloudClient.requestConversation(
            requestID: requestID,
            taskID: taskID,
            revision: revision
          )
          try await Task.sleep(for: .seconds(30))
          guard let self,
                let pending = pendingConversationRequests.removeValue(forKey: requestID) else { return }
          loadingConversations.remove(pending.taskID)
          if companionReachable {
            cloudTransportStatus = "HTTPS sin respuesta · usando iPhone"
            loadConversationThroughCompanion(
              taskID: pending.taskID,
              revision: pending.revision
            )
          } else {
            conversationErrors[pending.taskID] = "El Mac no respondió por HTTPS"
          }
        } catch {
          guard let self,
                let pending = pendingConversationRequests.removeValue(forKey: requestID) else { return }
          loadingConversations.remove(pending.taskID)
          if companionReachable {
            cloudTransportStatus = "HTTPS directo falló · usando iPhone"
            loadConversationThroughCompanion(
              taskID: pending.taskID,
              revision: pending.revision
            )
          } else {
            conversationErrors[pending.taskID] = "Sin conexión HTTPS directa ni iPhone"
          }
        }
      }
      return
    }
    loadConversationThroughCompanion(taskID: taskID, revision: revision)
  }

  private func loadConversationThroughCompanion(taskID: String, revision: Date) {
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
    setCommandReceipt(receipt)
  }

  fileprivate func setCommandReceipt(_ receipt: CommandReceipt) {
    commandReceipts[receipt.commandID] = receipt
    pendingTextCommandOutbox.apply(receipt)
    persistPendingTextCommandOutbox()
  }

  private func setCommandReceipt(_ receipt: CommandReceipt, for command: CodexCommand) {
    commandReceipts[receipt.commandID] = receipt
    pendingTextCommandOutbox.record(command, receipt: receipt)
    persistPendingTextCommandOutbox()
  }

  func latestPendingTextCommand(taskID: String) -> PendingTextCommandOutbox.Intent? {
    pendingTextCommandOutbox.latest(taskID: taskID)
  }

  func pendingTextCommand(taskID: String, text: String) -> PendingTextCommandOutbox.Intent? {
    pendingTextCommandOutbox.matching(taskID: taskID, text: text)
  }

  private func persistPendingTextCommandOutbox() {
    guard let data = try? CodexWatchWire.encode(pendingTextCommandOutbox) else { return }
    UserDefaults.standard.set(data, forKey: Self.pendingTextCommandOutboxKey)
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

  func cancelCloudPairing() {
    pendingCloudPairingOffer = nil
    pendingCloudPairingCode = nil
    pairingRequestInFlight = false
    try? CloudRelayKeyStore.deletePendingOffer(role: "watch")
  }

  func approveCloudPairing() {
    guard let offer = pendingCloudPairingOffer ?? (try? CloudRelayKeyStore.loadPendingOffer(role: "watch")),
          let session,
          session.activationState == .activated else {
      cloudTransportStatus = "Abre el Companion para terminar el pairing"
      return
    }
    let approval = CloudRelayPairingApproval(
      pairingID: offer.configuration.pairingID,
      watchDeviceID: offer.watchDeviceID,
      watchPublicKey: offer.watchPublicKey,
      authenticationCode: offer.authenticationCode
    )
    guard let data = try? CodexWatchWire.encode(approval) else { return }
    cloudTransportStatus = "Confirmando con el Mac…"
    if session.isReachable {
      let handler = WatchCloudPairingApprovalReplyHandler(offer: offer)
      session.sendMessage(
        [CodexWatchWire.cloudPairingApproval: data],
        replyHandler: handler.receive,
        errorHandler: handler.fail
      )
    } else {
      session.transferUserInfo([CodexWatchWire.cloudPairingApproval: data])
      cloudTransportStatus = "Confirmación pendiente del iPhone…"
    }
  }

  fileprivate func requestCloudPairingIfNeeded() {
    guard cloudClient == nil,
          pendingCloudPairingOffer == nil,
          !pairingRequestInFlight,
          let session,
          session.activationState == .activated else { return }
    do {
      let identity = try CloudRelayKeyStore.loadOrCreateIdentity(role: "watch")
      let request = CloudRelayPairingRequest(
        watchDeviceID: identity.deviceID,
        watchPublicKey: try CloudRelayProtocol.publicKey(for: identity.privateKey)
      )
      pairingRequestInFlight = true
      let data = try CodexWatchWire.encode(request)
      if session.isReachable {
        let handler = WatchCloudPairingOfferReplyHandler()
        session.sendMessage(
          [CodexWatchWire.cloudPairingRequest: data],
          replyHandler: handler.receive,
          errorHandler: handler.fail
        )
      } else {
        session.transferUserInfo([CodexWatchWire.cloudPairingRequest: data])
        cloudTransportStatus = "Pairing pendiente del iPhone…"
      }
    } catch {
      cloudTransportStatus = "No se pudo preparar el pairing"
    }
  }

  fileprivate func receiveCloudPairingOffer(_ data: Data) {
    pairingRequestInFlight = false
    do {
      let offer = try CodexWatchWire.decode(CloudRelayPairingOffer.self, from: data)
      let identity = try CloudRelayKeyStore.loadOrCreateIdentity(role: "watch")
      let publicKey = try CloudRelayProtocol.publicKey(for: identity.privateKey)
      guard offer.watchDeviceID == identity.deviceID,
            offer.watchPublicKey == publicKey,
            offer.authenticationCode == CloudRelayProtocol.shortAuthenticationString(
              pairingID: offer.configuration.pairingID,
              firstPublicKey: publicKey,
              secondPublicKey: offer.macPublicKey
            ) else {
        throw CloudRelayProtocol.ProtocolError.authenticationFailed
      }
      pendingCloudPairingOffer = offer
      try CloudRelayKeyStore.savePendingOffer(offer, role: "watch")
      pendingCloudPairingCode = offer.authenticationCode
      cloudTransportStatus = "Confirma el código con el Mac"
    } catch {
      cloudTransportStatus = "La oferta de pairing no es válida"
    }
  }

  fileprivate func finishCloudPairing(
    resultData: Data,
    offer: CloudRelayPairingOffer
  ) {
    do {
      let result = try CodexWatchWire.decode(CloudRelayPairingResult.self, from: resultData)
      guard result.accepted, result.pairingID == offer.configuration.pairingID else {
        throw CloudRelayProtocol.ProtocolError.authenticationFailed
      }
      let identity = try CloudRelayKeyStore.loadOrCreateIdentity(role: "watch")
      let pairing = CloudRelayProtocol.PairingMaterial(
        pairingID: result.pairingID,
        deviceID: identity.deviceID,
        privateKey: identity.privateKey,
        peerPublicKey: offer.macPublicKey,
        approvedAt: Date()
      )
      try CloudRelayKeyStore.savePairing(pairing, role: "watch")
      try CloudRelayKeyStore.saveTransport(offer.configuration, role: "watch")
      CloudRelayKeyStore.setActivePairingID(result.pairingID, role: "watch")
      pendingCloudPairingOffer = nil
      pendingCloudPairingCode = nil
      try? CloudRelayKeyStore.deletePendingOffer(role: "watch")
      configureExistingCloudTransport()
    } catch {
      cloudTransportStatus = "No se pudo guardar el pairing"
    }
  }

  fileprivate func failCloudPairing(_ message: String) {
    pairingRequestInFlight = false
    cloudTransportStatus = message
  }

  private func configureExistingCloudTransport() {
    guard cloudClient == nil else { return }
    do {
      let material: (
        pairing: CloudRelayProtocol.PairingMaterial,
        transport: CloudRelayTransportConfiguration
      )?
      if let pairingID = CloudRelayKeyStore.loadActivePairingID(role: "watch"),
         let pairing = try CloudRelayKeyStore.loadPairing(role: "watch", pairingID: pairingID),
         pairing.isApproved,
         let transport = try CloudRelayKeyStore.loadTransport(role: "watch", pairingID: pairingID),
         transport.pairingID == pairingID {
        material = (pairing, transport)
      } else {
        material = try CloudRelayKeyStore.recoverApprovedPairing(role: "watch")
      }
      guard let material else {
        CloudRelayKeyStore.setActivePairingID(nil, role: "watch")
        isCloudTransportActive = false
        cloudTransportStatus = "Conexión directa sin emparejar"
        pairingRequestInFlight = false
        requestCloudPairingIfNeeded()
        return
      }
      let client = try WatchCloudRelayClient(
        configuration: material.transport,
        pairing: material.pairing
      )
      cloudClient = client
      isCloudTransportActive = false
      cloudTransportStatus = "Conexión directa preparada"
      startCloudReceiveLoop(client)
    } catch {
      CloudRelayKeyStore.setActivePairingID(nil, role: "watch")
      cloudClient = nil
      isCloudTransportActive = false
      cloudTransportStatus = "Conexión directa dañada · reemparejando"
      pairingRequestInFlight = false
      requestCloudPairingIfNeeded()
    }
  }

  private func startCloudReceiveLoop(_ client: WatchCloudRelayClient) {
    cloudReceiveTask?.cancel()
    cloudReceiveTask = Task { [weak self] in
      var delay: UInt64 = 2
      var lastHeartbeatSentAt = Date.distantPast
      while !Task.isCancelled {
        do {
          if Date().timeIntervalSince(lastHeartbeatSentAt) >= 45 {
            _ = try await client.sendHeartbeat()
            lastHeartbeatSentAt = Date()
          }
          let events = try await client.receiveOnce(waitSeconds: 20)
          guard let self else { return }
          for event in events { applyCloudEvent(event) }
          if let lastCloudRoundTripAt,
             Date().timeIntervalSince(lastCloudRoundTripAt) <= 90 {
            isCloudTransportActive = true
            cloudTransportStatus = "Conexión directa activa"
          } else {
            isCloudTransportActive = false
            cloudTransportStatus = "Worker accesible · esperando al Mac"
          }
          delay = 2
        } catch is CancellationError {
          return
        } catch {
          self?.isCloudTransportActive = false
          self?.cloudTransportStatus = "HTTPS sin respuesta · reintentando"
          try? await Task.sleep(for: .seconds(delay))
          delay = min(delay * 2, 30)
        }
      }
    }
  }

  private func applyCloudEvent(_ event: WatchCloudRelayClient.Event) {
    switch event {
    case .receipt(let receipt):
      setCommandReceipt(receipt)
    case .tasks(let response):
      guard pendingTaskRequestID == response.requestID,
            let data = try? CodexWatchWire.encode(response.tasks) else { return }
      pendingTaskRequestID = nil
      applyTasks(data, revision: response.revision.timeIntervalSince1970)
    case .conversation(let response):
      guard let pending = pendingConversationRequests.removeValue(
        forKey: response.requestID
      ), pending.taskID == response.conversation.taskID else { return }
      finishConversation(
        response.conversation,
        for: pending.taskID,
        revision: response.revision
      )
    case .readFailure(let failure):
      switch failure.kind {
      case .tasks where pendingTaskRequestID == failure.requestID:
        pendingTaskRequestID = nil
        isRefreshingTasks = false
        taskRefreshError = failure.message
      case .conversation:
        guard let pending = pendingConversationRequests.removeValue(
          forKey: failure.requestID
        ) else { return }
        failConversation(for: pending.taskID, message: failure.message)
      default:
        break
      }
    case .heartbeatAck:
      lastCloudRoundTripAt = Date()
      isCloudTransportActive = true
      cloudTransportStatus = "Conexión directa activa"
    }
  }

  private func prepareDemo() {
    let now = Date()
    tasks = [
      CodexTask(
        id: "demo-launch", title: "Prepare the Aurora launch",
        preview: "Review the launch plan and the remaining blockers.",
        projectPath: "/Demo/Aurora", updatedAt: now.addingTimeInterval(-45), state: .working),
      CodexTask(
        id: "demo-design", title: "Polish the iPhone onboarding",
        preview: "Simplify connection and status messages.",
        projectPath: "/Demo/CodexWatch", updatedAt: now.addingTimeInterval(-180), state: .idle),
      CodexTask(
        id: "demo-research", title: "Weekly trends briefing",
        preview: "Prepare five actionable takeaways.",
        projectPath: "/Demo/Research", updatedAt: now.addingTimeInterval(-420), state: .needsAttention),
      CodexTask(
        id: "demo-podcast", title: "Episode 12 script",
        preview: "Turn the notes into a twenty-minute outline.",
        projectPath: "/Demo/Studio", updatedAt: now.addingTimeInterval(-900), state: .idle),
      CodexTask(
        id: "demo-dashboard", title: "August executive dashboard",
        preview: "Add metrics and prepare the mobile view.",
        projectPath: "/Demo/Analytics", updatedAt: now.addingTimeInterval(-1_800), state: .working),
      CodexTask(
        id: "demo-security", title: "Companion security review",
        preview: "Check transport, tokens and network exposure.",
        projectPath: "/Demo/CodexWatch", updatedAt: now.addingTimeInterval(-3_600), state: .idle),
      CodexTask(
        id: "demo-ideas", title: "Ideas for the next release",
        preview: "Prioritize improvements for Watch and Vision Pro.",
        projectPath: nil, updatedAt: now.addingTimeInterval(-7_200), state: .idle),
      CodexTask(
        id: "demo-copy", title: "Public website copy",
        preview: "Give the product story a sharper voice.",
        projectPath: "/Demo/Website", updatedAt: now.addingTimeInterval(-10_800), state: .idle)
    ]

    conversations["demo-launch"] = [
      CodexMessage(
        id: "demo-launch-1", role: .user,
        text: "Is the beta launch plan ready?",
        createdAt: now.addingTimeInterval(-420)),
      CodexMessage(
        id: "demo-launch-2", role: .assistant,
        text: "Yes. The build passed every test and deployment is ready.",
        createdAt: now.addingTimeInterval(-360)),
      CodexMessage(
        id: "demo-launch-3", role: .user,
        text: "Please verify the complete experience from the Watch as well.",
        createdAt: now.addingTimeInterval(-240)),
      CodexMessage(
        id: "demo-launch-4", role: .assistant,
        text: "Done. Navigation, dictation, sending and task creation all work correctly.",
        createdAt: now.addingTimeInterval(-120))
    ]
    for task in tasks {
      conversationRevisions[task.id] = task.updatedAt
      if conversations[task.id] == nil {
        conversations[task.id] = [
          CodexMessage(
            id: "\(task.id)-1", role: .user, text: task.preview,
            createdAt: task.updatedAt.addingTimeInterval(-90)),
          CodexMessage(
            id: "\(task.id)-2", role: .assistant,
            text: "Understood. I am working on it and will let you know when it is ready.",
            createdAt: task.updatedAt)
        ]
      }
    }
  }
}

extension WatchRelay: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard activationState == .activated, error == nil else { return }
    let isReachable = session.isReachable
    Task { @MainActor [weak self] in
      self?.companionReachable = isReachable
      self?.refreshTasks()
      self?.requestCloudPairingIfNeeded()
    }
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
    let pairingOfferData = userInfo[CodexWatchWire.cloudPairingOffer] as? Data
    let pairingResultData = userInfo[CodexWatchWire.cloudPairingResult] as? Data
    Task { @MainActor [weak self] in
      if let tasksData { self?.applyTasks(tasksData, revision: tasksRevision) }
      self?.applyVoiceSettings(
        inputModeRawValue: inputMode,
        modelRawValue: transcriptionModel
      )
      if let receiptData { self?.applyCommandReceipt(receiptData) }
      if let pairingOfferData { self?.receiveCloudPairingOffer(pairingOfferData) }
      if let pairingResultData,
         let offer = self?.pendingCloudPairingOffer
            ?? (try? CloudRelayKeyStore.loadPendingOffer(role: "watch")) {
        self?.finishCloudPairing(resultData: pairingResultData, offer: offer)
      }
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    let isReachable = session.isReachable
    Task { @MainActor [weak self] in
      self?.companionReachable = isReachable
      guard isReachable else { return }
      self?.refreshTasks()
      self?.requestCloudPairingIfNeeded()
    }
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

private final class WatchCloudPairingOfferReplyHandler: @unchecked Sendable {
  func receive(_ reply: [String: Any]) {
    guard let data = reply[CodexWatchWire.cloudPairingOffer] as? Data else {
      fail(URLError(.badServerResponse))
      return
    }
    Task { @MainActor in WatchRelay.shared.receiveCloudPairingOffer(data) }
  }

  func fail(_ error: Error) {
    Task { @MainActor in
      WatchRelay.shared.failCloudPairing("Abre el Companion para activar HTTPS")
    }
  }
}

private final class WatchCloudPairingApprovalReplyHandler: @unchecked Sendable {
  private let offer: CloudRelayPairingOffer

  init(offer: CloudRelayPairingOffer) {
    self.offer = offer
  }

  func receive(_ reply: [String: Any]) {
    guard let data = reply[CodexWatchWire.cloudPairingResult] as? Data else {
      fail(URLError(.badServerResponse))
      return
    }
    Task { @MainActor [offer] in
      WatchRelay.shared.finishCloudPairing(resultData: data, offer: offer)
    }
  }

  func fail(_ error: Error) {
    Task { @MainActor in
      WatchRelay.shared.failCloudPairing("No se pudo confirmar el pairing")
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
