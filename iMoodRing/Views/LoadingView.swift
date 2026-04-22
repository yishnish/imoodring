import SwiftUI

struct LoadingView: View {
    let progress: Double
    let label: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .tracking(2.6)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.45))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.1))
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: geo.size.width * max(0, min(1, progress)))
                        .animation(.linear(duration: 0.25), value: progress)
                }
            }
            .frame(height: 2)

            HStack {
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 10, weight: .regular))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.25))
        }
        .frame(width: 260)
    }
}
