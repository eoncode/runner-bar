import SwiftUI

// MARK: - DonutStatusView
/// Phase 4 (#419): Redesigned status indicator for action rows.
/// Three states:
/// - in_progress: animated blue arc ring (trim + spinning AngularGradient)
/// - success: green full-circle stroke + checkmark SF Symbol
/// - failed/other: red full-circle stroke + xmark SF Symbol
/// - queued: dotted blue ring
///
/// ❌ NEVER inline this back into PopoverProgressViews — spec requires a dedicated file.
struct DonutStatusView: View {
    let status: GroupStatus
    let conclusion: String?
    /// Arc progress 0–1 for in-progress state.
    let progress: Double?
    var size: CGFloat = 18

    @State private var arcPhase: Double = 0

    private var isSuccess: Bool { conclusion == "success" }

    var body: some View {
        ZStack {
            switch status {
            case .inProgress:
                inProgressDonut
            case .queued:
                queuedDonut
            case .completed, .success, .failed, .unknown:
                completedDonut
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard status == .inProgress else { return }
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                arcPhase = 360
            }
        }
    }

    /// Animated blue arc for in-progress runs.
    private var inProgressDonut: some View {
        let fraction = progress ?? 0
        return ZStack {
            Circle()
                .stroke(DesignTokens.Colors.statusBlue.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.08, CGFloat(fraction)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            DesignTokens.Colors.statusBlue.opacity(0),
                            DesignTokens.Colors.statusBlue
                        ]),
                        center: .center,
                        startAngle: .degrees(arcPhase),
                        endAngle: .degrees(arcPhase + 300)
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }

    /// Spinning dotted ring for queued.
    private var queuedDonut: some View {
        Circle()
            .stroke(
                DesignTokens.Colors.statusBlue.opacity(0.5),
                style: StrokeStyle(lineWidth: 1.5, dash: [2, 3])
            )
    }

    /// Static ring + SF symbol for completed/success/failed/unknown state.
    private var completedDonut: some View {
        let color = isSuccess ? DesignTokens.Colors.statusGreen : DesignTokens.Colors.statusRed
        let symbol = isSuccess ? "checkmark" : "xmark"
        return ZStack {
            Circle().stroke(color.opacity(0.5), lineWidth: 1.5)
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundColor(color)
        }
    }
}
