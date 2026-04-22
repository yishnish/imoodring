import SwiftUI

struct DebugOverlayView: View {
    let chunkCount: Int
    let mood: Mood?
    let intensity: Double
    let transcript: String
    let isProcessing: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(isProcessing ? "processing" : "listening")
                .font(.system(size: 10, weight: .regular))
                .tracking(2.2)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.3))

            if let mood {
                Text("\(mood.rawValue)  \(Int(intensity * 100))%")
                    .font(.system(size: 14, weight: .medium))
                    .tracking(1.3)
                    .foregroundStyle(mood.color)
            }

            if !transcript.isEmpty {
                let snippet = transcript.count > 80
                    ? "…" + transcript.suffix(80)
                    : transcript
                Text(snippet)
                    .font(.system(size: 11, weight: .regular))
                    .italic()
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Text("\(chunkCount) chunk\(chunkCount == 1 ? "" : "s")")
                .font(.system(size: 9, weight: .regular))
                .tracking(1.9)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.15))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 300)
    }
}
