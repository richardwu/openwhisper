import SwiftUI

struct WaveformView: View {
    let levels: [Float]
    private let barCount = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.spring(response: 0.15, dampingFraction: 0.7), value: barHeight(for: index))
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 40

        guard !levels.isEmpty else { return minHeight }

        // Map bar index to levels array
        let levelIndex = Int(Float(index) / Float(barCount) * Float(levels.count))
        let clampedIndex = min(levelIndex, levels.count - 1)
        let level = levels[clampedIndex]

        // Normalize: typical RMS for speech is 0.01-0.2, amplify for visual effect
        let normalized = min(CGFloat(level) * 12, 1.0)
        return minHeight + normalized * (maxHeight - minHeight)
    }
}
