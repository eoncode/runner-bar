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
            ctx.stroke(basePath, with: .color(strokeColor.opacity(0.25)), lineWidth: 0.5)
            ctx.stroke(linePath, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .opacity(0.85) // Slight transparency so it blends with dark/light bg
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let count = history.count
        return history.enumerated().map { idx, val in
            let x = size.width * CGFloat(idx) / CGFloat(count - 1)
            let y = size.height * CGFloat(1.0 - min(max(val, 0), 1))
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - DiskPillView
/// Pill-shaped badge showing disk free space percentage.
/// Semi-transparent fill + hairline stroke, adapts colour to usage level.
///
/// Phase 2 of the design redesign (#421).
struct DiskPillView: View {
    let freePct: Double
    let usedGB: Int
    let totalGB: Int

    private var usedPct: Double { 100 - freePct }
    private var pillColor: Color { DesignTokens.Colors.usage(pct: usedPct) }

    var body: some View {
        HStack(spacing: 3) {
            Text(String(format: "%d/%dGB", usedGB, totalGB))
                .font(DesignTokens.Fonts.monoStat)
                .foregroundColor(pillColor)
                .lineLimit(1)
            Text(String(format: "(%d%%)", Int(freePct.rounded())))
                .font(DesignTokens.Fonts.mono)
                .foregroundColor(pillColor.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.Spacing.chipHPad)
        .padding(.vertical, DesignTokens.Spacing.chipVPad)
        .background(
            Capsule()
                .fill(pillColor.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(pillColor.opacity(0.35), lineWidth: 0.5)
        )
    }
}
