import AppKit

// MARK: - StatusIcon
//
// Draws a 16×16 menu bar icon that mirrors the PieProgressDot style used in
// the main popover rows — implementing issue #241.
//
// VISUAL RULES (must match PieProgressDot in PopoverProgressViews.swift):
//
// 1. BACKGROUND: always a filled dark circle at low opacity.
//    Same as PieProgressDot’s background ring but filled, not stroked.
//
// 2. PIE WEDGE (progress fill):
//    - Starts at 12-o’clock (90° in NSBezierPath coords), sweeps clockwise.
//    - Fraction = completedJobs / totalJobs (non-dimmed jobs only).
//    - fraction == 0    → background circle only (jobs queued / not started).
//    - 0 < fraction < 1 → filled pie wedge (move → arc → close → fill).
//    - fraction >= 1    → full filled circle.
//
// 3. NO JOBS: legacy solid dot coloured by runner health (allOnline/someOffline/allOffline).
//
// 4. COLOUR per runner health:
//    - allOnline   → systemGreen
//    - someOffline → systemOrange
//    - allOffline  → systemRed
//
// 5. isTemplate = false — colours are meaningful.
//    ❌ NEVER set isTemplate = true — strips colour.
//    ❌ NEVER use stroke-only ring — must match PieProgressDot filled wedge style.
//    ❌ NEVER remove background fill — dot needs a solid base.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT.

/// Builds the menu bar icon from runner aggregate status + live job counts.
///
/// Visual style matches `PieProgressDot` in `PopoverProgressViews.swift`:
/// faint filled background circle + solid filled pie wedge from 12-o’clock clockwise.
///
/// - Parameters:
///   - status:         Overall runner health.
///   - totalJobs:      Count of non-dimmed jobs currently tracked.
///   - completedJobs:  Count of those jobs whose `status == "completed"`.
func makeStatusIcon(
    for status: AggregateStatus,
    totalJobs: Int = 0,
    completedJobs: Int = 0
) -> NSImage {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { rect in
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 6.5

        // Colour from runner health
        let arcColor: NSColor
        switch status {
        case .allOnline:   arcColor = .systemGreen
        case .someOffline: arcColor = .systemOrange
        case .allOffline:  arcColor = .systemRed
        }

        // No live jobs → legacy solid dot
        if totalJobs == 0 {
            arcColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            return true
        }

        // Background: faint filled circle (mirrors PieProgressDot’s 0.22-opacity ring)
        arcColor.withAlphaComponent(0.22).setFill()
        let bg = NSBezierPath()
        bg.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        bg.fill()

        let fraction = min(1.0, max(0, CGFloat(completedJobs) / CGFloat(totalJobs)))
        guard fraction > 0 else { return true }  // 0% → background only

        arcColor.setFill()

        if fraction >= 1.0 {
            // 100% → full filled circle
            let full = NSBezierPath()
            full.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            full.fill()
        } else {
            // Pie wedge: move to center → arc → close → fill
            // NSBezierPath: 0° = 3-o’clock, angles counter-clockwise.
            // 12-o’clock = 90°. clockwise: true sweeps CW (decreasing angle).
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - (fraction * 360),
                clockwise: true
            )
            wedge.close()
            wedge.fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}
