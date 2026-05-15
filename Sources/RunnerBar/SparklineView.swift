// swiftlint:disable all
import SwiftUI

struct SparklineView: View {
    let values: [Double]
    var color: Color = .rbBlue
    var lineWidth: CGFloat = 1.5

    private var normalized: [Double] {
        let mn = values.min() ?? 0
        let mx = values.max() ?? 1
        guard mx > mn else { return values.map { _ in 0.5 } }
        return values.map { ($0 - mn) / (mx - mn) }
    }

    var body: some View {
        GeometryReader { geo in
            let pts = normalized
            let w   = geo.size.width
            let h   = geo.size.height
            if pts.count >= 2 {
                Path { path in
                    for (i, v) in pts.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(pts.count - 1)
                        let y = h * (1.0 - CGFloat(v))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else      { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
