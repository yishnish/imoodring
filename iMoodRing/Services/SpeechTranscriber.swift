import Speech
import AVFoundation

actor SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer?

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
            recognizer.recognitionTask(with: request) { result, error in
                guard !didResume else { return }
                if let error {
                    didResume = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    didResume = true
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespaces)
                    let wordCount = text.split(separator: " ").count
                    continuation.resume(returning: wordCount >= minimumWords ? text : nil)
                }
            }
        }
    }
}
