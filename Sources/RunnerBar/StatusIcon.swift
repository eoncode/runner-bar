import AppKit

// MARK: - StatusIcon
//
// Draws a 16×16 menu bar icon that encodes both runner health AND job progress
// as a pie-chart arc — implementing issue #241.
//
// VISUAL RULES:
//
// 1. RING BACKGROUND: always drawn as a thin dimmed circle (stroke only).
//
// 2. ARC FILL (progress sweep):
//    - Starts at 12-o'clock (90°), sweeps clockwise.
//    - Fraction = completedJobs / totalJobs (non-dimmed jobs only).
//    - 0 jobs / all queued  → empty ring (no arc).
//    - all completed        → full circle fill.
//    - fraction in between  → partial arc sweep.
//
// 3. COLOUR:
//    - Any in_progress jobs present  → systemOrange arc
//    - All completed / success        → systemGreen arc
//    - Any failure                    → systemRed arc
//    - No jobs / all offline          → systemGray dot (legacy solid circle)
//
// 4. isTemplate = false — colours are meaningful, never discarded by AppKit.
//
// ❌ NEVER change isTemplate to true — it strips colour.
// ❌ NEVER remove the ring background — it anchors the icon when arc is thin.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

/// Builds the menu bar icon from runner aggregate status + live job counts.
///
/// - Parameters:
///   - status:         Overall runner health (`.allOnline`, `.someOffline`, `.allOffline`).
///   - totalJobs:      Count of non-dimmed jobs currently tracked.
///   - completedJobs:  Count of those jobs whose `status == "completed"`.
func makeStatusIcon(
    for status: AggregateStatus,
    totalJobs: Int = 0,
    completedJobs: Int = 0
) -> NSImage {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { rect in
        let center  = CGPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 6.0
        let lineW:  CGFloat = 1.5

        // --- Determine arc colour ---
        let arcColor: NSColor
        if totalJobs == 0 {
            // No live jobs — fall back to runner-health colour (solid dot legacy style)
            switch status {
            case .allOnline:   arcColor = .systemGreen
            case .someOffline: arcColor = .systemOrange
            case .allOffline:  arcColor = .systemRed
            }
            arcColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            return true
        } else {
            switch status {
            case .allOffline:  arcColor = .systemRed
            case .someOffline: arcColor = .systemOrange
            case .allOnline:   arcColor = .systemGreen
            }
        }

        // --- Ring background (faint) ---
        arcColor.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath()
        ring.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 360
        )
        ring.lineWidth = lineW
        ring.stroke()

        // --- Progress arc ---
        let fraction: CGFloat = totalJobs > 0
            ? min(1.0, CGFloat(completedJobs) / CGFloat(totalJobs))
            : 0

        guard fraction > 0 else { return true }

        arcColor.setStroke()
        arcColor.setFill()

        if fraction >= 1.0 {
            // Full circle fill
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
        } else {
            // Partial arc: start at 12-o'clock (90°), sweep clockwise.
            // NSBezierPath uses counter-clockwise convention with flipped=false,
            // so clockwise sweep = startAngle > endAngle (or use negative sweep).
            let startAngle: CGFloat = 90
            let endAngle:   CGFloat = 90 - (fraction * 360)
            let arc = NSBezierPath()
            arc.move(to: center)
            arc.appendArc(
                withCenter: center,
                radius: radius - lineW * 0.5,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: true
            )
            arc.close()
            arc.fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}
