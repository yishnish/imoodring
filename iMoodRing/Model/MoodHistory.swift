import Foundation

struct MoodChunk {
    let mood: Mood
    let intensity: Double
    let timestamp: Date
}

@Observable
final class MoodHistory {
    private(set) var chunks: [MoodChunk] = []
    private let recentCount = 5

    var isEmpty: Bool { chunks.isEmpty }

    func add(mood: Mood, intensity: Double) {
        chunks.append(MoodChunk(
            mood: mood,
            intensity: max(0, min(1, intensity)),
            timestamp: Date()
        ))
    }

    var recent: [MoodChunk] {
        Array(chunks.suffix(recentCount))
    }

    // Fraction of session each mood occupied (values sum to 1)
    var proportions: [(mood: Mood, fraction: Double)] {
        guard !chunks.isEmpty else { return [(.neutral, 1.0)] }
        var counts: [Mood: Int] = [:]
        for chunk in chunks { counts[chunk.mood, default: 0] += 1 }
        let total = Double(chunks.count)
        return counts
            .map { (mood: $0.key, fraction: Double($0.value) / total) }
            .filter { $0.fraction > 0 }
            .sorted { $0.mood.rawValue < $1.mood.rawValue }
    }
}
