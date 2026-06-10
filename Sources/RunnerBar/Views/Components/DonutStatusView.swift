// DonutStatusView.swift
// RunnerBar
import SwiftUI

// MARK: - DonutStatusView
/// Replaces the PieProgressDot for the action row status indicator.
/// Three visual states:
/// - in_progress : animated rotating shimmer arc (blue) + arc trim from 0 to progress
/// - success     : full green circle stroke + checkmark SF Symbol
/// - failed      : full red circle stroke + xmark SF Symbol
/// - queued      : revolving amber glow ring (idle liveness indicator)
///
/// Animation contract:
/// - In-progress background ring uses `@State rotationAngle` driven by
///   `.linear(duration: 2).repeatForever(autoreverses: false)`.
/// - Queued ring uses `@State queuedRotation` driven by
///   `.linear(duration: 3).repeatForever(autoreverses: false)` — slower to
///   remain visually distinct from the in-progress shimmer.
/// - Progress arc uses `trim(from: 0, to: fraction)` animated with `.easeInOut`.
/// - Both rotation angles are reset to 0 before re-arming to avoid a SwiftUI
///   no-op when the status re-enters the same state (target already == 360).
///
/// ### Re-arm strategy — why no bool flag guard
/// An alternative pattern would track animation liveness with a `@State Bool`
/// (e.g. `queuedAnimationActive`) and skip the reset when the animation is already
/// running, to prevent a visible snap-to-zero on rapid re-entry. We intentionally
/// do NOT use that pattern here. A `.queued → inProgress → queued` round-trip
/// requires at minimum one full GitHub API poll cycle (several seconds) — by which
/// point the `repeatForever` ring has completed many revolutions and `queuedRotation`
/// has already wrapped back to its internal start position. The snap is therefore a
/// zero-degree correction in practice, not a visible jump. The bool-flag adds two
/// extra `@State` properties, two extra reset paths in `onChange`, and extra
/// Periphery tracking surface for no perceptible visual benefit in this polling-driven
/// context.
///
/// Do NOT remove the repeatForever animations -- they are liveness indicators.
/// Do NOT start rotation for states that do not own the animation -- wastes CPU/GPU.
struct DonutStatusView: View {
    /// The workflow/job status this donut reflects.
    let status: RBStatus
    /// Progress fraction 0.0-1.0 for in-progress state; ignored for other states.
    var progress: Double = 0
    /// Outer ring diameter in points.
    var size: CGFloat = 16

    /// Current rotation angle for the in-progress shimmer ring.
    @State private var rotationAngle: Double = 0
    /// Current rotation angle for the queued glow ring.
    @State private var queuedRotation: Double = 0
    /// Animated copy of `progress` updated via `withAnimation(.easeInOut)` for smooth arc trim.
    @State private var displayProgress: Double = 0

    /// Stroke width derived from the outer diameter (11% of `size`).
    private var strokeWidth: CGFloat { size * 0.11 }

    /// Creates a `DonutStatusView`.
    init(status: RBStatus, progress: Double = 0, size: CGFloat = 16) {
        self.status = status
        self.progress = progress
        self.size = size
    }

    /// Renders the donut ring, switching between in-progress, terminal, and queued states.
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
            startQueuedAnimationIfNeeded()
        }
        .onChange(of: progress) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                displayProgress = max(0, min(1, progress))
            }
        }
        .onChange(of: status) { _, _ in
            startRotationIfNeeded()
            startQueuedAnimationIfNeeded()
        }
    }

    /// Starts the `repeatForever` in-progress shimmer rotation.
    /// Resets `rotationAngle` to 0 first so re-entry after a status round-trip
    /// does not produce a SwiftUI no-op (target already 360).
    /// Safe to call multiple times — guard ensures it only runs for `.inProgress`.
    private func startRotationIfNeeded() {
        guard status == .inProgress else { return }
        rotationAngle = 0
        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
            rotationAngle = 360
        }
    }

    /// Starts the `repeatForever` queued-glow rotation.
    /// Resets `queuedRotation` to 0 first so re-entry (e.g. re-queued after failure)
    /// does not produce a SwiftUI no-op (target already 360).
    /// Runs at 3 s/revolution — slower than in-progress — so the two states stay
    /// visually distinct. Safe to call multiple times.
    private func startQueuedAnimationIfNeeded() {
        guard status == .queued else { return }
        queuedRotation = 0
        withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
            queuedRotation = 360
        }
    }

    /// Animated in-progress ring: faint shimmer background + blue arc trim.
    private var inProgressRing: some View {
        ZStack {
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
            Circle()
                .trim(from: 0, to: CGFloat(displayProgress))
                .stroke(Color.rbBlue, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
        }
    }

    /// Queued state ring: revolving amber angular-gradient glow over a dimmed base stroke.
    /// The sweep rotates at 3 s/revolution driven by `queuedRotation`.
    private var queuedRing: some View {
        ZStack {
            Circle()
                .stroke(Color.rbWarning.opacity(0.25), lineWidth: strokeWidth)
                .frame(width: size, height: size)
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [Color.rbWarning.opacity(0.0), Color.rbWarning.opacity(0.30)],
                        center: .center
                    ),
                    lineWidth: strokeWidth
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(queuedRotation))
        }
    }

    /// Terminal state (success/failed): solid colored ring + SF Symbol in the centre.
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
