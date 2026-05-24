// DonutStatusView.swift
// RunnerBar
import SwiftUI

// MARK: - DonutStatusView
/// Replaces the PieProgressDot for the action row status indicator.
/// Three visual states:
/// - in_progress : animated rotating shimmer arc (blue) + arc trim from 0 → progress
/// - success     : full green circle stroke + checkmark SF Symbol
/// - failed      : full red circle stroke + xmark SF Symbol
/// - queued      : solid yellow circle stroke
///
/// Animation contract:
/// - In-progress background ring uses `@State rotationAngle` driven by
///   `.linear(duration: 2).repeatForever(autoreverses: false)` — reassures the
///   user the row hasn't frozen.
/// - Progress arc uses `trim(from: 0, to: fraction)` animated with `.easeInOut`.
/// - Color transitions use `.easeInOut(duration: 0.35)`.
///
/// ❌ NEVER remove the repeatForever animation — it is the liveness indicator.
/// ❌ NEVER start the rotation for non-.inProgress states — it wastes CPU/GPU.
struct DonutStatusView: View {
    /// The status constant.
    let status: RBStatus
    /// Progress fraction 0.0–1.0 for in-progress state. Ignored for other states.
    var progress: Double = 0
    /// The size property.
    var size: CGFloat = 16

    /// The rotationAngle property.
    @State private var rotationAngle: Double = 0
    /// The displayProgress property.
    @State private var displayProgress: Double = 0

    /// The strokeWidth property.
    private var strokeWidth: CGFloat { size * 0.11 }
    /// Inner ring diameter derived from the outer size. // periphery:ignore
    private var innerSize: CGFloat { size * 0.82 }

    /// The body property.
    var body: some View {
        ZStack {
            switch status {
            case .inProgress:
                inProgressRing
            case .success:
                terminalRing(color: .rbSuccess, symbol: "checkmark")
            case .failed:
                terminalRing(color: .rbDanger, symbol: "xmark")
            case .queued:
                queuedRing
            default:
                Circle()
                    .stroke(Color.rbTextTertiary.opacity(0.3), lineWidth: strokeWidth)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            displayProgress = max(0, min(1, progress))
            startRotationIfNeeded()
        }
        // Single-argument form for macOS 13 compatibility.
        .onChange(of: progress) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                displayProgress = max(0, min(1, progress))
            }
        }
        // Start rotation if we transition into .inProgress after appearing
        // (e.g. queued → inProgress). No-op for any other transition.
        .onChange(of: status) { _ in
            startRotationIfNeeded()
        }
    }

    // MARK: - Helpers
    /// Starts the repeatForever rotation animation only when status is .inProgress.
    /// Safe to call multiple times — SwiftUI deduplicates identical in-flight
    /// animations on the same state variable.
    private func startRotationIfNeeded() {
        guard status == .inProgress else { return }
        withAnimation(
            .linear(duration: 2)
            .repeatForever(autoreverses: false)
        ) {
            rotationAngle = 360
        }
    }

    // MARK: - Sub-views
    /// Animated in-progress ring: faint shimmer background + blue arc trim.
    private var inProgressRing: some View {
        ZStack {
            // Shimmer background ring
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [Color.rbBlue.opacity(0.0), Color.rbBlue.opacity(0.25)],
                        center: .center
                    ),
                    lineWidth: strokeWidth
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotationAngle))
            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(displayProgress))
                .stroke(
                    Color.rbBlue,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
        }
    }

    /// Queued ring: solid yellow stroke — spec: queued = yellow.
    /// fix(#419): was dashed blue, corrected to solid rbWarning.
    private var queuedRing: some View {
        Circle()
            .stroke(Color.rbWarning, lineWidth: strokeWidth)
            .frame(width: size, height: size)
    }

    /// Terminal state (success/failed): solid ring + SF Symbol centre.
    private func terminalRing(color: Color, symbol: String) -> some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: strokeWidth)
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Preview
#if DEBUG
#Preview {
    HStack(spacing: 16) {
        DonutStatusView(status: .inProgress, progress: 0.6, size: 20)
        DonutStatusView(status: .success, size: 20)
        DonutStatusView(status: .failed, size: 20)
        DonutStatusView(status: .queued, size: 20)
    }
    .padding(20)
    .background(Color.rbSurface)
}
#endif
