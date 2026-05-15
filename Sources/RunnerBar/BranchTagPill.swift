// swiftlint:disable all
import SwiftUI

struct BranchTagPill: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
            .lineLimit(1)
    }
}
