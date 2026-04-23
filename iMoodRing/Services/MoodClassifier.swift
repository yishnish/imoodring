import Foundation
import MediaPipeTasksGenAI

struct MoodResult {
    let transcript: String
    let mood: Mood
    let intensity: Double
}

// Protocol isolates the MediaPipe dependency — swap for LiteRT-LM audio when Swift SDK ships.
protocol MoodClassifying: Actor {
    func classify(audio: [Float]) async throws -> MoodResult?
}

actor GemmaMoodClassifier: MoodClassifying {
    private var inference: LlmInference?
    private let transcriber = SpeechTranscriber()
    // Serial GCD queue for inference: LiteRT's internal thread pool conflicts with
    // Swift's cooperative thread pool, causing a libpthread abort on first inference.
    // Running on a plain GCD queue lets LiteRT initialize its threads normally.
    private let inferenceQueue = DispatchQueue(label: "com.nharsh.iMoodRing.inference", qos: .userInitiated)

    private static let moods = Mood.allCases.map(\.rawValue).joined(separator: ", ")

    func requestSpeechAuth() async -> Bool {
        await transcriber.requestAuthorization()
    }

    func load(modelPath: String) throws {
        // LlmInference is deprecated in favour of LiteRT-LM; migrate when Swift SDK ships.
        let options = LlmInference.Options(modelPath: modelPath)
        options.maxTokens = 150
        inference = try LlmInference(options: options)
    }

    func classify(audio: [Float]) async throws -> MoodResult? {
        guard let inference else { throw ClassifierError.notLoaded }

        guard let transcript = try await transcriber.transcribe(audio) else { return nil }

        let prompt = buildPrompt(transcript: transcript)

        let capturedInference = inference
        let raw: String = try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    let result = try capturedInference.generateResponse(inputText: prompt)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return parse(raw: raw, fallbackTranscript: transcript)
    }

    // MARK: - Private

    private func buildPrompt(transcript: String) -> String {
        """
        Classify the emotional tone of this spoken text.
        Reply with ONLY valid JSON, no other text:
        {"transcript": "...", "mood": "<mood>", "intensity": <0.0-1.0>}
        mood must be exactly one of: \(Self.moods)

        Text: "\(transcript)"
        """
    }

    private func parse(raw: String, fallbackTranscript: String) -> MoodResult? {
        guard let range = raw.range(of: #"\{[\s\S]*?\}"#, options: .regularExpression),
              let data = raw[range].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let mood = Mood.from(json["mood"] as? String ?? "")
        let intensity = max(0, min(1, json["intensity"] as? Double ?? 0.5))
        let transcript = json["transcript"] as? String ?? fallbackTranscript
        return MoodResult(transcript: transcript, mood: mood, intensity: intensity)
    }
}

enum ClassifierError: Error {
    case notLoaded
}
