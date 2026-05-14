import SwiftUI

// MARK: - PieProgressDot

/// Small animated pie/radial fill indicator used on action and job rows.
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

    // MARK: Animated state
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
/// Phase 4: Redesigned status indicator for action rows.
/// Three states:
/// - in_progress: animated blue arc ring (trim + spinning AngularGradient)
/// - success: green circle stroke + checkmark SF Symbol
/// - failed/other: red circle stroke + xmark SF Symbol
///
/// Part of redesign plan tracked in #421.
struct StatusDonutView: View {
    let status: GroupStatus
    let conclusion: String?
    /// Arc progress 0–1 for in-progress state.
    let progress: Double?
    var size: CGFloat = 18

    @State private var arcPhase: Double = 0

    private var isSuccess: Bool { conclusion == "success" }
    private var isInProgress: Bool { status == .inProgress }
    private var isQueued: Bool { status == .queued }

    var body: some View {
        ZStack {
            switch status {
            case .inProgress:
                inProgressDonut
            case .queued:
                queuedDonut
            case .completed:
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
            // Background track
            Circle()
                .stroke(DesignTokens.Colors.statusBlue.opacity(0.18), lineWidth: 2)
            // Animated AngularGradient "alive" ring
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

    /// Static ring + SF symbol for completed state.
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

// MARK: - LeftIndicatorPill
/// Phase 4: Tappable left-edge pill that expands/collapses inline job rows.
/// Leading corners are rounded, trailing corners are square (UnevenRoundedRectangle
/// requires macOS 14; we use a custom shape for macOS 13 compat).
///
/// Part of redesign plan tracked in #421.
struct LeftIndicatorPill: View {
    let color: Color
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            LeadingRoundedRect(radius: 3)
                .fill(color)
                .frame(width: 4)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

/// Rectangle with rounded leading corners only (macOS 13-compatible).
private struct LeadingRoundedRect: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - SubJobProgressBar
/// Phase 5: Thin horizontal Capsule progress bar for sub-job rows.
///
/// Renders a 90×3 pt track with a filled Capsule overlay driven by `fraction` (0–1).
/// When `fraction` is nil (queued / indeterminate), the bar shows a shimmer sweep.
///
/// Color follows `DesignTokens.Colors`:
///   - in-progress → statusBlue
///   - success     → statusGreen
///   - failed      → statusRed
///   - queued      → statusBlue at 0.5 opacity
///
/// ❌ NEVER use a fixed pixel width for the fill — drive it from GeometryReader.
/// ❌ NEVER remove the Capsule clip shape — it gives rounded end-caps.
struct SubJobProgressBar: View {
    /// Fill fraction 0–1. Nil = indeterminate shimmer.
    let fraction: Double?
    /// Bar accent color (use DesignTokens.Colors.status*).
    let color: Color
    /// Total bar width in points. Defaults to 90.
    var width: CGFloat = 90
    /// Bar height in points. Defaults to 3.
    var height: CGFloat = 3

    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        ZStack(alignment: .leading) {
            // Track
            Capsule()
                .fill(color.opacity(0.15))
                .frame(width: width, height: height)
            if let frac = fraction {
                // Determinate fill
                Capsule()
                    .fill(color)
                    .frame(width: max(height, CGFloat(frac) * width), height: height)
                    .animation(.easeInOut(duration: 0.35), value: frac)
            } else {
                // Indeterminate: sliding shimmer block
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                color.opacity(0.0),
                                color.opacity(0.7),
                                color.opacity(0.0)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.4, height: height)
                    .offset(x: shimmerOffset * width)
                    .clipped()
                    .onAppear {
                        withAnimation(
                            .linear(duration: 1.4)
                            .repeatForever(autoreverses: false)
                        ) {
                            shimmerOffset = 1.2
                        }
                    }
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
    }
}

// MARK: - RelativeTimeFormatter

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
