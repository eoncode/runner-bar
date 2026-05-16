// swiftlint:disable all
import SwiftUI

// MARK: - RunnerRowsView

/// Renders runner rows without ANY use of SwiftUI ForEach on [Runner].
/// All ForEach overloads resolve to Binding<C> in this SDK/compiler version.
/// ForEach(runners.indices) iterates Int indices; runnerRow helper receives
/// a plain Runner value with no type-context ambiguity.
/// ❌ NEVER reintroduce ForEach(runners) or ForEach(runners, id:) here.
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
                ForEach(runners.indices, id: \.self) { i in
                    runnerRow(runners[i])
                }
            }
        }
    }

    private func runnerRow(_ runner: Runner) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor(for: runner))
                .frame(width: 8, height: 8)
            Text(runner.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            Text(runner.busy ? "busy" : runner.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func dotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }
}
