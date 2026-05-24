// SparklineView.swift
// RunnerBar
import SwiftUI

// MARK: - SparklineView
/// Compact line-chart sparkline rendered on a transparent background
/// so the GlassCard surface of the parent stat tile shows through.
struct SparklineView: View {
    /// Data points to render, expected in chronological order.
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let min = values.min() ?? 0
            let max = values.max() ?? 1
            let range = max - min > 0 ? max - min : 1
            let step = values.count > 1 ? w / CGFloat(values.count - 1) : w

            Path { path in
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * step
                    let y = h - CGFloat((v - min) / range) * h
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.rbBlue.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .background(Color.clear)
    }
}
