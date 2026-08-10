import AVFAudio
import Combine
import Foundation

@MainActor
final class WatchVoiceRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var recordingURL: URL?

    private var recorder: AVAudioRecorder?
    private var timerTask: Task<Void, Never>?

    override init() {
        super.init()
        removeStaleRecordings()
    }

    deinit {
        timerTask?.cancel()
    }

    func start() async {
        guard state != .recording else { return }
        discard()
        state = .requestingPermission

        guard await microphonePermissionGranted() else {
            state = .failed("Autoriza el micrófono para grabar la orden")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let url = Self.recordingsDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record(forDuration: 30) else {
                throw RecorderError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = url
            duration = 0
            state = .recording
            startTimer()
        } catch {
            state = .failed("No se pudo iniciar la grabación")
            deactivateAudioSession()
        }
    }

    func stop() {
        guard state == .recording else { return }
        recorder?.stop()
        finishRecording(successfully: true)
    }

    func discard() {
        timerTask?.cancel()
        timerTask = nil
        if recorder?.isRecording == true { recorder?.stop() }
        recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        duration = 0
        state = .idle
        deactivateAudioSession()
    }

    func takeRecordingURL() -> URL? {
        guard state == .ready, let recordingURL else { return nil }
        self.recordingURL = nil
        state = .idle
        duration = 0
        return recordingURL
    }

    private func microphonePermissionGranted() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, state == .recording else { return }
                duration = recorder?.currentTime ?? duration
            }
        }
    }

    private func finishRecording(successfully success: Bool) {
        guard state == .recording else { return }
        timerTask?.cancel()
        timerTask = nil
        duration = recorder?.currentTime ?? duration
        recorder = nil
        deactivateAudioSession()

        let fileSize = recordingURL.flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } ?? 0
        guard success,
              let recordingURL,
              duration >= 0.4,
              fileSize > 0 else {
            if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
            self.recordingURL = nil
            state = .failed("La grabación está vacía")
            return
        }
        state = .ready
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func removeStaleRecordings() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: Self.recordingsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified == nil || modified! < cutoff { try? fileManager.removeItem(at: file) }
        }
    }

    private static let recordingsDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceCommands", isDirectory: true)
    }()

    private enum RecorderError: Error {
        case couldNotStart
    }
}

extension WatchVoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishRecording(successfully: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.finishRecording(successfully: false)
        }
    }
}
