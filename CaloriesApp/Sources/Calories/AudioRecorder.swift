import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var lastFileURL: URL?
    @Published private(set) var inputLevel: Double = 0 // 0...1

    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(44_100)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("rec-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        r.prepareToRecord()
        r.record()
        recorder = r
        lastFileURL = url

        startMeteringLoop()
        isRecording = true
    }

    func stop() {
        recorder?.stop()
        recorder = nil

        stopMeteringLoop()
        inputLevel = 0

        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func startMeteringLoop() {
        stopMeteringLoop()
        inputLevel = 0
        meteringTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let recorder = self.recorder, recorder.isRecording else { break }

                recorder.updateMeters()
                let avg = Self.normalizePower(recorder.averagePower(forChannel: 0))
                let peak = Self.normalizePower(recorder.peakPower(forChannel: 0))
                let level = min(1, max(avg * 0.45, peak * 1.2))

                // Небольшое сглаживание: отклик остаётся быстрым, но без резких рывков.
                if level > self.inputLevel {
                    self.inputLevel = self.inputLevel * 0.15 + level * 0.85
                } else {
                    self.inputLevel = self.inputLevel * 0.15 + level * 0.85
                }

                try? await Task.sleep(nanoseconds: 12_000_000)
            }
        }
    }

    private func stopMeteringLoop() {
        meteringTask?.cancel()
        meteringTask = nil
    }

    private static func normalizePower(_ decibels: Float) -> Double {
        let minDb: Float = -72
        guard decibels.isFinite, decibels > minDb else { return 0 }

        let clamped = min(decibels, 0)
        let linear = pow(10, clamped / 20)
        let floor = pow(10, minDb / 20)
        let normalized = max(0, (linear - floor) / (1 - floor))

        // Гамма-коррекция: тихая речь заметнее в UI.
        return min(1, Double(pow(normalized, 0.35)))
    }
}
