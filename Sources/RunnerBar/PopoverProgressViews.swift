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
/// ❌ NEVER change onChange to two-argument form — macOS 13 only supports single-value.
/// ❌ NEVER set displayProgress directly without withAnimation — breaks interpolation.
struct PieProgressDot: View {
    let progress: Double?
    let color: Color
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

// MARK: - LeftIndicatorPill
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
/// ❌ NEVER use a fixed pixel width for the fill — drive it from GeometryReader.
/// ❌ NEVER remove the Capsule clip shape — it gives rounded end-caps.
struct SubJobProgressBar: View {
    let fraction: Double?
    let color: Color
    var width: CGFloat = 90
    var height: CGFloat = 3

    /// fix(#441 bug4): start at 0 (leading edge) not -1 so there is no
    /// layout flash before onAppear fires the animation.
    @State private var shimmerOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(color.opacity(0.15))
                .frame(width: width, height: height)
            if let frac = fraction {
                Capsule()
                    .fill(color)
                    .frame(width: max(height, CGFloat(frac) * width), height: height)
                    .animation(.easeInOut(duration: 0.35), value: frac)
            } else {
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
                        shimmerOffset = 0
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
        switch typedGroupStatus {
        case .queued:     return nil
        case .completed, .failed, .success:  return 1.0
        case .inProgress:
            guard jobsTotal > 0 else { return nil }
            return Double(jobsDone) / Double(jobsTotal)
        case .unknown:    return nil
        }
    }
}

// ActiveJob.progressFraction lives in ActiveJob.swift
