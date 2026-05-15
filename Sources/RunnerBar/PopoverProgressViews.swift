// swiftlint:disable file_length
import SwiftUI

// MARK: - PieProgressDot

/// Small animated pie/radial fill indicator used on job rows.
/// Sized to match the existing 8 pt dot footprint so layout is unchanged.
///
/// Behaviour per state:
/// - `progress == nil`   → Spinning indeterminate arc (queued / unknown)
/// - `0 < progress < 1`  → Filled wedge sweeping clockwise, animated on change
/// - `progress == 1`     → Full fill + brief spring scale pulse
/// - `progress == 0`     → Background ring only
///
/// Animation contract:
/// - `displayProgress` shadows `progress` with `.easeInOut(duration:0.4)` —
///   wedge angle interpolates every frame.
/// - `displayColor` shadows `color` with `.easeInOut(duration:0.35)` —
///   color crossfades on state transitions (queued→in-progress→success/fail).
/// - `spinAngle` drives the indeterminate arc via a `.linear(duration:1.2)`
///   repeating animation started in `.onAppear`.
/// - `completionScale` gives a spring pulse when progress reaches 1.0.
///
/// ❌ NEVER change onChange to two-argument form — macOS 13 only supports single-value.
/// ❌ NEVER set displayProgress directly without withAnimation — breaks interpolation.
struct PieProgressDot: View {
    /// Radial fill fraction (0.0–1.0). Nil renders a spinning indeterminate arc.
    let progress: Double?
    /// Wedge fill and ring stroke colour. Animated on change.
    let color: Color
    /// Dot diameter; defaults to 8 to match existing action-row dots.
    var size: CGFloat = 8

    @State private var displayProgress: Double?
    @State private var displayColor: Color = .clear
    @State private var spinAngle: Double = 0
    @State private var completionScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = side / 2
            ZStack {
                Circle()
                    .stroke(displayColor.opacity(0.22), lineWidth: 1)
                    .frame(width: side, height: side)
                if let fraction = displayProgress {
                    if fraction >= 1 {
                        Circle()
                            .fill(displayColor)
                            .frame(width: side, height: side)
                            .scaleEffect(completionScale)
                    } else if fraction > 0 {
                        Path { path in
                            path.move(to: center)
                            path.addArc(
                                center: center,
                                radius: radius,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(-90 + fraction * 360),
                                clockwise: false
                            )
                            path.closeSubpath()
                        }
                        .fill(displayColor)
                    }
                } else {
                    Group {
                        Circle()
                            .stroke(displayColor.opacity(0.15), lineWidth: 1.5)
                            .frame(width: side * 0.85, height: side * 0.85)
                        Path { path in
                            path.addArc(
                                center: CGPoint(x: side / 2, y: side / 2),
                                radius: side * 0.85 / 2,
                                startAngle: .degrees(0),
                                endAngle: .degrees(130),
                                clockwise: false
                            )
                        }
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    displayColor.opacity(0.0),
                                    displayColor.opacity(0.9)
                                ]),
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(130)
                            ),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .frame(width: side * 0.85, height: side * 0.85)
                    }
                    .rotationEffect(.degrees(spinAngle))
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            displayProgress = progress
            displayColor = color
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                spinAngle = 360
            }
        }
        .onChange(of: progress) { newValue in
            withAnimation(.easeInOut(duration: 0.4)) { displayProgress = newValue }
            if let value = newValue, value >= 1.0 {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { completionScale = 1.28 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { completionScale = 1.0 }
                }
            }
        }
        .onChange(of: color) { newColor in
            withAnimation(.easeInOut(duration: 0.35)) { displayColor = newColor }
        }
    }
}

// MARK: - StatusDonutView

/// New design-system status indicator for action rows.
/// Replaces PieProgressDot at the action-row level (PieProgressDot is kept for inline job rows).
///
/// Three visual states:
/// - `.success`    — solid green donut ring + checkmark SF Symbol
/// - `.failure`    — solid red donut ring + xmark SF Symbol
/// - `.inProgress` — blue arc (0→1 fraction) + animated shimmer background ring
/// - `.queued`     — pulsing semi-transparent blue full ring (no arc fill)
///
/// Size is driven by `DesignTokens.Layout.donutSize` (20pt) and
/// `DesignTokens.Layout.donutStroke` (2pt).
///
/// ❌ NEVER change onChange to two-argument form — macOS 13 compat.
struct StatusDonutView: View {
    let status: GroupStatus
    let conclusion: String?
    /// Progress fraction 0–1 for in-progress state. Nil = indeterminate.
    let progress: Double?

    @State private var shimmerAngle: Double = 0
    @State private var pulseOpacity: Double = 0.35
    @State private var displayProgress: Double = 0

    private let size:   CGFloat = DesignTokens.Layout.donutSize
    private let stroke: CGFloat = DesignTokens.Layout.donutStroke

    var body: some View {
        ZStack {
            switch status {
            case .completed:
                completedDonut
            case .inProgress:
                inProgressDonut
            case .queued:
                queuedDonut
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            displayProgress = progress ?? 0
            // Shimmer: slow continuous rotation on the background arc
            withAnimation(DesignTokens.Animation.donutSpin) { shimmerAngle = 360 }
            // Pulse: opacity breathe for queued state
            withAnimation(DesignTokens.Animation.donutPulse) { pulseOpacity = 0.7 }
        }
        .onChange(of: progress) { newValue in
            withAnimation(.easeInOut(duration: 0.4)) { displayProgress = newValue ?? 0 }
        }
    }

    // MARK: - Completed donut (success / failure / other)
    @ViewBuilder
    private var completedDonut: some View {
        let isSuccess = conclusion == "success"
        let color: Color = isSuccess ? DesignTokens.Color.statusGreen : DesignTokens.Color.statusRed
        let icon  = isSuccess ? "checkmark" : "xmark"
        // Outer solid ring
        Circle()
            .strokeBorder(color, lineWidth: stroke)
            .background(Circle().fill(color.opacity(0.12)))
        // SF Symbol icon centred
        Image(systemName: icon)
            .font(.system(size: size * 0.44, weight: .bold))
            .foregroundColor(color)
    }

    // MARK: - In-progress donut (animated arc + shimmer)
    @ViewBuilder
    private var inProgressDonut: some View {
        let color = DesignTokens.Color.statusBlue
        // Shimmer background track — slow rotating angular gradient
        Circle()
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: [
                        color.opacity(0.08),
                        color.opacity(0.22),
                        color.opacity(0.08)
                    ]),
                    center: .center
                ),
                lineWidth: stroke
            )
            .rotationEffect(.degrees(shimmerAngle))
        // Progress arc — draws 0→1 clockwise from 12-o'clock
        Circle()
            .trim(from: 0, to: CGFloat(displayProgress))
            .stroke(
                color,
                style: StrokeStyle(lineWidth: stroke, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
        // Central fraction label when progress is meaningful
        if displayProgress > 0.04 {
            Text(String(format: "%.0f", displayProgress * 100))
                .font(.system(size: size * 0.32, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        } else {
            // No progress yet — show a small activity dot
            Circle()
                .fill(color.opacity(0.6))
                .frame(width: size * 0.25, height: size * 0.25)
        }
    }

    // MARK: - Queued donut (pulsing ring)
    @ViewBuilder
    private var queuedDonut: some View {
        let color = DesignTokens.Color.statusBlue
        Circle()
            .strokeBorder(color.opacity(pulseOpacity), lineWidth: stroke)
        Image(systemName: "clock")
            .font(.system(size: size * 0.4))
            .foregroundColor(color.opacity(pulseOpacity))
    }
}

// MARK: - RelativeTimeFormatter

/// Formats a `Date` into a compact relative string like `"3m ago"`, `"1h ago"`, `"2d ago"`.
enum RelativeTimeFormatter {
    static func string(from date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:        return "just now"
        case ..<3_600:     return "\(Int(seconds / 60))m ago"
        case ..<172_800:   return "\(Int(seconds / 3_600))h ago"
        default:           return "\(Int(seconds / 86_400))d ago"
        }
    }
}

// MARK: - ActionGroup + progressFraction

extension ActionGroup {
    var progressFraction: Double? {
        switch groupStatus {
        case .queued:     return nil
        case .completed:  return 1.0
        case .inProgress:
            guard jobsTotal > 0 else { return nil }
            return Double(jobsDone) / Double(jobsTotal)
        }
    }
}

// MARK: - ActiveJob + progressFraction

extension ActiveJob {
    var progressFraction: Double? {
        switch status {
        case "queued":    return nil
        case "completed": return 1.0
        default:
            guard !steps.isEmpty else { return nil }
            let done = steps.filter { $0.conclusion != nil }.count
            return Double(done) / Double(steps.count)
        }
    }
}
// swiftlint:enable file_length
