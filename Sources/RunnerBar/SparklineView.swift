import SwiftUI

// MARK: - SparklineView
/// A mini sparkline graph using Path: polyline stroke + gradient fill.
/// Color shifts green → orange → red based on the current value threshold.
/// Fill uses .opacity(0.85) so it blends in both light and dark mode.
struct SparklineView: View {
    /// History ring buffer — ordered oldest→newest, values 0–100.
    let history: [Double]
    /// Current value used to determine the theme color (0–100).
    let currentPct: Double

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Gradient fill
                fillPath(in: geo.size)
                    .fill(
                        LinearGradient(
                            colors: [themeColor.opacity(0.85), themeColor.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                // Stroke line
                strokePath(in: geo.size)
                    .stroke(themeColor, lineWidth: 1.5)
            }
        }
    }

    // MARK: - Helpers

    private var themeColor: Color {
        if currentPct > 85 { return .rbDanger }
        if currentPct > 60 { return .rbWarning }
        return .rbSuccess
    }

    /// Builds the open polyline path for stroking.
    private func strokePath(in size: CGSize) -> Path {
        Path { path in
            let points = normalised(in: size)
            guard !points.isEmpty else { return }
            path.move(to: points[0])
            for pt in points.dropFirst() {
                path.addLine(to: pt)
            }
        }
    }

    /// Builds the closed path (drop to bottom) for gradient fill.
    private func fillPath(in size: CGSize) -> Path {
        Path { path in
            let points = normalised(in: size)
            guard !points.isEmpty else { return }
            path.move(to: CGPoint(x: points[0].x, y: size.height))
            path.addLine(to: points[0])
            for pt in points.dropFirst() {
                path.addLine(to: pt)
            }
            path.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            path.closeSubpath()
        }
    }

    /// Converts history values (0–100) to CGPoints scaled to the view size.
    private func normalised(in size: CGSize) -> [CGPoint] {
        guard history.count > 1 else {
            let val = history.first ?? 0
            let y = size.height - CGFloat(val / 100.0) * size.height
            return [
                CGPoint(x: 0, y: y),
                CGPoint(x: size.width, y: y)
            ]
        }
        let count = history.count
        return history.enumerated().map { idx, val in
            let x = CGFloat(idx) / CGFloat(count - 1) * size.width
            let y = size.height - CGFloat(val / 100.0) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Preview
#if DEBUG
#Preview {
    HStack(spacing: 12) {
        SparklineView(history: [10, 20, 35, 30, 55, 60, 45, 70, 65, 80], currentPct: 80)
            .frame(width: 60, height: 20)
        SparklineView(history: [40, 50, 60, 55, 65, 70, 68, 75, 80, 90], currentPct: 90)
            .frame(width: 60, height: 20)
        SparklineView(history: [5, 10, 8, 12, 9, 11, 10, 13, 10, 12], currentPct: 12)
            .frame(width: 60, height: 20)
    }
    .padding()
}
#endif
