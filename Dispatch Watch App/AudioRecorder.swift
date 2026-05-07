import AVFoundation

@MainActor
class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private var audioRecorder: AVAudioRecorder?
    private let recordingURL: URL
    private var recordingStartTime: Date?

    /// Duration of the current (or most recent) recording, in seconds.
    var lastRecordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    init() {
        recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("dictation.wav")
    }

    /// Start recording. Returns `true` on success, `false` if audio session or recorder setup failed.
    @discardableResult
    func startRecording() -> Bool {
        guard !isRecording else { return false }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            return false
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.record()
            isRecording = true
            recordingStartTime = Date()
            return true
        } catch {
            isRecording = false
            return false
        }
    }

    func stopRecording() -> Data? {
        guard isRecording else { return nil }
        audioRecorder?.stop()
        isRecording = false
        recordingStartTime = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return try? Data(contentsOf: recordingURL)
    }
}
