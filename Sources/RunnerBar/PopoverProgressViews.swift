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

    /// Animated shadow of `progress`. Drives the wedge Path angle.
    @State private var displayProgress: Double? = nil
    /// Animated shadow of `color`. Drives fill + stroke colour with a crossfade.
    @State private var displayColor: Color = .clear
    /// Current rotation angle for the indeterminate spinning arc (degrees).
    @State private var spinAngle: Double = 0
    /// Scale factor for the completion pulse. 1.0 → 1.25 → 1.0 on reaching 100%.
    @State private var completionScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            let side   = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = side / 2

            ZStack {
                // --- Background ring (always visible) ---
                Circle()
                    .stroke(displayColor.opacity(0.22), lineWidth: 1)
                    .frame(width: side, height: side)

                if let fraction = displayProgress {
                    if fraction >= 1 {
                        // Full fill + completion scale pulse
                        Circle()
                            .fill(displayColor)
                            .frame(width: side, height: side)
                            .scaleEffect(completionScale)

                    } else if fraction > 0 {
                        // Filled wedge from 12-o’clock sweeping clockwise
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
                    // fraction == 0: background ring only

                } else {
                    // Indeterminate: spinning arc segment (~120° sweep)
                    // Uses a Group + rotationEffect driven by spinAngle.
                    // The arc is drawn as a stroked open path rather than a fill
                    // so it looks like a spinner, not a wedge.
                    Group {
                        // Thin background track
                        Circle()
                            .stroke(displayColor.opacity(0.15), lineWidth: 1.5)
                            .frame(width: side * 0.85, height: side * 0.85)

                        // Spinning arc head
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
        // MARK: - Lifecycle
        .onAppear {
            // Seed both display values instantly (no animation) on first render.
            displayProgress = progress
            displayColor    = color
            // Start the indeterminate spinner — always running.
            // It only shows when displayProgress == nil, so the rotation is
            // harmless when the wedge is visible.
            // ❌ NEVER use .easeInOut here — must be .linear + repeatForever.
            withAnimation(
                .linear(duration: 1.2)
                .repeatForever(autoreverses: false)
            ) {
                spinAngle = 360
            }
        }
        // Animate wedge angle when progress changes.
        // ❌ macOS 13 compat: single-value onChange only.
        .onChange(of: progress) { newValue in
            withAnimation(.easeInOut(duration: 0.4)) {
                displayProgress = newValue
            }
            // Trigger completion pulse when reaching 100%.
            if let v = newValue, v >= 1.0 {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) {
                    completionScale = 1.28
                }
                // Settle back to normal size after the pulse.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        completionScale = 1.0
                    }
                }
            }
        }
        // Animate color crossfade on state transitions (queued→in-progress→success/fail).
        // ❌ macOS 13 compat: single-value onChange only.
        .onChange(of: color) { newColor in
            withAnimation(.easeInOut(duration: 0.35)) {
                displayColor = newColor
            }
        }
    }
}

// MARK: - RelativeTimeFormatter

/// Formats a `Date` into a compact relative string like `"3m ago"`, `"1h ago"`, `"2d ago"`.
///
/// Intended for one-off formatting in row views; not observation-based —
/// callers should refresh on a suitable timer tick.
enum RelativeTimeFormatter {
    /// Returns a short relative string for the interval between `date` and `now`.
    /// Returns `"just now"` for intervals < 60 s, `"Nm ago"` < 60 min,
    /// `"Nh ago"` < 48 h, and `"Nd ago"` otherwise.
    static func string(from date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:      return "just now"
        case ..<3_600:   return "\(Int(seconds / 60))m ago"
        case ..<172_800: return "\(Int(seconds / 3_600))h ago"
        default:         return "\(Int(seconds / 86_400))d ago"
        }
    }
}

// MARK: - ActionGroup + progressFraction

/// Adds a pie-progress fraction property to `ActionGroup` for use with `PieProgressDot`.
extension ActionGroup {
    /// Radial fill fraction (0.0–1.0). Returns `nil` while queued or when no jobs are available.
    var progressFraction: Double? {
        switch groupStatus {
        case .queued:
            return nil
        case .completed:
            return 1.0
        case .inProgress:
            guard jobsTotal > 0 else { return nil }
            return Double(jobsDone) / Double(jobsTotal)
        }
    }
}

// MARK: - ActiveJob + progressFraction

/// Adds a pie-progress fraction property to `ActiveJob` for use with `PieProgressDot`.
extension ActiveJob {
    /// Radial fill fraction (0.0–1.0). Returns `nil` while queued or when no steps are available.
    var progressFraction: Double? {
        switch status {
        case "queued":
            return nil
        case "completed":
            return 1.0
        default:
            guard !steps.isEmpty else { return nil }
            let done = steps.filter { $0.conclusion != nil }.count
            return Double(done) / Double(steps.count)
        }
    }
}
