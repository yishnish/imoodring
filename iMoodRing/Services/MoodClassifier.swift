import Foundation

struct MoodResult {
    let transcript: String
    let mood: Mood
    let intensity: Double
}

protocol MoodClassifying: Actor {
    func classify(audio: [Float]) async throws -> MoodResult?
}

actor GemmaMoodClassifier: MoodClassifying {
    private var runner: LlamaRunner?
    private let transcriber = SpeechTranscriber()
    private let inferenceQueue = DispatchQueue(label: "com.nharsh.iMoodRing.inference", qos: .userInitiated)

    private static let moods = Mood.allCases.map(\.rawValue).joined(separator: ", ")

    func requestSpeechAuth() async -> Bool {
        await transcriber.requestAuthorization()
    }

    func load(modelPath: String) throws {
        runner = try LlamaRunner(modelPath: modelPath)
    }

    func classify(audio: [Float]) async throws -> MoodResult? {
        guard let runner else { throw ClassifierError.notLoaded }

        guard let transcript = try await transcriber.transcribe(audio) else { return nil }

        let prompt = buildPrompt(transcript: transcript)
        let capturedRunner = runner

        let raw: String = try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    let result = try capturedRunner.generate(prompt: prompt)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        print("[Classifier] raw output: \(raw)")
        return parse(raw: raw, fallbackTranscript: transcript)
    }

    // MARK: - Private

    // Gemma instruct format: BOS is added by the tokenizer (add_special=true),
    // special tokens like <start_of_turn> are parsed as single tokens (parse_special=true).
    private func buildPrompt(transcript: String) -> String {
        """
        <start_of_turn>user
        Classify the emotional tone of this spoken text.
        Reply with ONLY valid JSON, no other text:
        {"transcript": "...", "mood": "<mood>", "intensity": <0.0-1.0>}
        mood must be exactly one of: \(Self.moods)

        Text: "\(transcript)"<end_of_turn>
        <start_of_turn>model

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
