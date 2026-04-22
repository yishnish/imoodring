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

    private static let moods = Mood.allCases.map(\.rawValue).joined(separator: ", ")

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

        // LlmInference.generateResponse is synchronous — run off the actor executor
        // to avoid blocking the main queue, while remaining serial within this actor.
        let raw = try inference.generateResponse(inputText: prompt)

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
