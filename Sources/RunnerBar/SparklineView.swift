import SwiftUI

// MARK: - SparklineView
/// Mini sparkline graph used in the popover header for CPU and MEM metrics.
/// Draws a filled area chart with gradient fill and an adaptive stroke colour
/// that transitions green → orange → red based on the latest value.
///
/// Phase 2 of the design redesign (#421).
struct SparklineView: View {
    /// Normalised history values in 0–1 range, oldest first.
    let history: [Double]
    /// Current percentage (0–100) used to pick the stroke colour.
    let currentPct: Double

    private var strokeColor: Color {
        DesignTokens.Colors.usage(pct: currentPct)
    }

    var body: some View {
        Canvas { ctx, size in
            guard history.count >= 2 else { return }
            let pts = points(in: size)

            // Gradient fill beneath the line
            var fillPath = Path()
            fillPath.move(to: CGPoint(x: 0, y: size.height))
            for pt in pts { fillPath.addLine(to: pt) }
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.closeSubpath()
            ctx.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [strokeColor.opacity(0.55), strokeColor.opacity(0)]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                )
            )

            // Stroke line on top
            var linePath = Path()
            linePath.move(to: pts[0])
            for pt in pts.dropFirst() { linePath.addLine(to: pt) }
            // Bottom baseline stroke
            var basePath = Path()
            basePath.move(to: CGPoint(x: 0, y: size.height))
            basePath.addLine(to: CGPoint(x: size.width, y: size.height))
            ctx.stroke(linePath, with: .color(strokeColor), lineWidth: 1.5)
            ctx.stroke(basePath, with: .color(strokeColor.opacity(0.2)), lineWidth: 0.5)
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let n = history.count
        return history.enumerated().map { i, v in
            CGPoint(
                x: size.width * CGFloat(i) / CGFloat(n - 1),
                y: size.height * (1 - CGFloat(v))
            )
        }
    }
}
