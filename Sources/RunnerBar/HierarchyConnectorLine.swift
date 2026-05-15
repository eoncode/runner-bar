import SwiftUI

// MARK: - HierarchyConnectorLine
/// Fix #7: draws a clean L-shaped connector from the parent action row down through
/// each sub-job row, matching the reference design.
/// A vertical line runs down the left edge; a short horizontal tick branches right
/// into each job row at its vertical midpoint.
struct HierarchyConnectorLine: View {
    /// Number of job rows the connector should span.
    let jobCount: Int
    /// Approximate height of each job row (padding + cap + card) in points.
    private let rowHeight: CGFloat = 28
    /// X position of the vertical line (left indent).
    private let lineX: CGFloat = 12
    /// Length of the horizontal tick into each row.
    private let tickLen: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            let topY: CGFloat = rowHeight / 2
            let bottomY = topY + CGFloat(jobCount - 1) * rowHeight

            // Vertical spine
            path.move(to: CGPoint(x: lineX, y: topY))
            path.addLine(to: CGPoint(x: lineX, y: bottomY))

            // Horizontal ticks per row
            for i in 0..<jobCount {
                let midY = topY + CGFloat(i) * rowHeight
                path.move(to: CGPoint(x: lineX, y: midY))
                path.addLine(to: CGPoint(x: lineX + tickLen, y: midY))
            }

            ctx.stroke(
                path,
                with: .color(Color.secondary.opacity(0.3)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: lineX + tickLen + 4,
               height: CGFloat(jobCount) * rowHeight)
        .allowsHitTesting(false)
    }
}
