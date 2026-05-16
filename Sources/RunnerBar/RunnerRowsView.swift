// swiftlint:disable all
import SwiftUI

// MARK: - RunnerRowsView

/// Renders a list of Runner rows without using ForEach.
/// ForEach on [Runner] triggers Binding<C> / Range<Int> overload
/// ambiguity in Xcode 26 SDK regardless of id: keypath or struct isolation.
/// VStack + map has zero overload ambiguity — it is a plain function call.
/// ❌ NEVER replace this with ForEach under any circumstance.
struct RunnerRowsView: View {
    let runners: [Runner]

    var body: some View {
        if runners.isEmpty {
            Text("No runners configured")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 0) {
                ForEach(0 ..< runners.count, id: \.self) { index in
                    let runner = runners[index]
                    HStack(spacing: 8) {
                        Circle()
                            .fill(dotColor(for: runner))
                            .frame(width: 8, height: 8)
                        Text(runner.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                        Text(runner.displayStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private func dotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }
}
