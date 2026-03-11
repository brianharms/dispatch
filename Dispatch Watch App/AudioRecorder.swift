import AVFoundation

@MainActor
class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private var audioRecorder: AVAudioRecorder?
    private let recordingURL: URL

    init() {
        recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("dictation.wav")
    }

    func startRecording() {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            return
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
        } catch {
            isRecording = false
        }
    }

    func stopRecording() -> Data? {
        guard isRecording else { return nil }
        audioRecorder?.stop()
        isRecording = false
        return try? Data(contentsOf: recordingURL)
    }
}
