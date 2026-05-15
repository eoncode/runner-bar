// swiftlint:disable all
import SwiftUI

struct HierarchyConnectorLine: View {
    var color: Color = Color.secondary.opacity(0.3)
    var lineWidth: CGFloat = 1
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let midX = geo.size.width / 2
                path.move(to: CGPoint(x: midX, y: 0))
                path.addLine(to: CGPoint(x: midX, y: geo.size.height))
            }
            .stroke(color, lineWidth: lineWidth)
        }
    }
}
