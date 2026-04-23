import Speech
import AVFoundation

actor SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer?
    private var mockIndex = 0

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
        recognizer?.defaultTaskHint = .dictation
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // Transcribes a Float32 PCM buffer (mono, 16 kHz) on-device.
    // Returns nil when no speech is detected or transcript is too short.
    func transcribe(_ audio: [Float], sampleRate: Double = 16_000, minimumWords: Int = 3) async throws -> String? {
        #if targetEnvironment(simulator)
        // SFSpeechRecognizer fails to initialize in the simulator (missing ASR asset).
        // Return a rotating mock so the full LLM → ring pipeline can be exercised.
        return nextMock()
        #else
        return try await recognizeOnDevice(audio: audio, sampleRate: sampleRate, minimumWords: minimumWords)
        #endif
    }

    // MARK: - Simulator mock

    #if targetEnvironment(simulator)
    private static let mockTranscripts = [
        "I'm feeling really happy and excited about everything today",
        "This whole situation is so frustrating, nothing is going right",
        "Everything feels calm and peaceful, I'm totally relaxed",
        "I'm feeling pretty sad about what happened earlier today",
        "That news made me really angry and completely upset",
        "I feel so tense and anxious, I can't stop worrying",
        "I don't really feel much of anything right now",
    ]

    private func nextMock() -> String {
        let t = Self.mockTranscripts[mockIndex % Self.mockTranscripts.count]
        mockIndex += 1
        return t
    }
    #endif

    // MARK: - Real recognition (device only)

    #if !targetEnvironment(simulator)
    private func recognizeOnDevice(audio: [Float], sampleRate: Double, minimumWords: Int) async throws -> String? {
        guard let recognizer, recognizer.isAvailable else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count))
        else { return nil }

        pcmBuffer.frameLength = AVAudioFrameCount(audio.count)
        if let ch = pcmBuffer.floatChannelData?[0] {
            audio.withUnsafeBufferPointer { ptr in
                ch.initialize(from: ptr.baseAddress!, count: audio.count)
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = false
        request.append(pcmBuffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var recognitionTask: SFSpeechRecognitionTask?

            // Guard against the recognition service hanging (e.g. silent chunk).
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !didResume else { return }
                didResume = true
                recognitionTask?.cancel()
                continuation.resume(returning: nil)
            }

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                timeout.cancel()
                guard !didResume else { return }
                didResume = true
                if let error {
                    let code = (error as NSError).code
                    if code == 3 || code == 216 || code == 1110 || code == NSUserCancelledError {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespaces)
                    let wordCount = text.split(separator: " ").count
                    continuation.resume(returning: wordCount >= minimumWords ? text : nil)
                } else {
                    // nil result + nil error: task ended without producing output
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    #endif
}
