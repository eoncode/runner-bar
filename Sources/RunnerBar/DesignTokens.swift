import SwiftUI

// MARK: - Design Tokens
// Central source of truth for all visual constants used across RunnerBar views.
// Introduced as part of the new design system (Issue #420 / #403).

enum DesignTokens {

    // MARK: - Status Colors
    enum Color {
        /// Green — success, healthy, low usage
        static let statusGreen   = SwiftUI.Color(hex: "#30d158")
        /// Orange — warning, moderate usage
        static let statusOrange  = SwiftUI.Color(hex: "#ff9f0a")
        /// Red — failure, critical usage
        static let statusRed     = SwiftUI.Color(hex: "#ff453a")
        /// Blue — in-progress, active
        static let statusBlue    = SwiftUI.Color(hex: "#0a84ff")

        // MARK: Row tint backgrounds (status color at low opacity)
        static let tintGreen     = statusGreen.opacity(0.06)
        static let tintOrange    = statusOrange.opacity(0.06)
        static let tintRed       = statusRed.opacity(0.06)
        static let tintBlue      = statusBlue.opacity(0.06)

        // MARK: Sparkline gradient fills (status color semi-transparent)
        static let sparkFillGreen   = statusGreen.opacity(0.55)
        static let sparkFillOrange  = statusOrange.opacity(0.55)
        static let sparkFillRed     = statusRed.opacity(0.55)

        // MARK: UI chrome
        /// Separator / border lines
        static let separator     = SwiftUI.Color.white.opacity(0.08)
        /// Runner / action card border
        static let cardBorder    = SwiftUI.Color.white.opacity(0.06)
        /// Pill badge background (CPU/MEM on runner rows)
        static let pillBg        = SwiftUI.Color.white.opacity(0.08)
        /// Pill badge border
        static let pillBorder    = SwiftUI.Color.white.opacity(0.12)
        /// Secondary label text
        static let labelSecondary = SwiftUI.Color(hex: "#636366")
        /// Tertiary label / chevron
        static let labelTertiary  = SwiftUI.Color(hex: "#3a3a3c")
    }

    // MARK: - Typography
    enum Font {
        /// Standard monospaced body text (commit hashes, runner names, stats)
        static let monoBody: SwiftUI.Font      = .system(size: 13, design: .monospaced)
        /// Small monospaced label (step counts, durations, sub-job meta)
        static let monoSmall: SwiftUI.Font     = .system(size: 11.5, design: .monospaced)
        /// Extra small monospaced (pill badges, branch tags)
        static let monoXSmall: SwiftUI.Font    = .system(size: 11, design: .monospaced)
        /// Header stat value (CPU %, MEM GB)
        static let statValue: SwiftUI.Font     = .system(size: 12.5, weight: .semibold, design: .monospaced)
        /// Header stat label ("CPU", "MEM", "DISK")
        static let statLabel: SwiftUI.Font     = .system(size: 12.5, design: .default)
    }

    // MARK: - Layout
    enum Layout {
        // Padding
        static let panelHPad: CGFloat       = 18
        static let panelVPad: CGFloat       = 13
        static let rowHPad: CGFloat         = 12
        static let rowVPad: CGFloat         = 9
        static let sectionInset: CGFloat    = 8   // horizontal inset for runner/action rows inside panel

        // Spacing
        static let statGroupGap: CGFloat    = 20  // gap between CPU / MEM / DISK groups
        static let statInnerGap: CGFloat    = 8   // gap between label and value within a stat
        static let runnerRowGap: CGFloat    = 10
        static let actionRowGap: CGFloat    = 9

        // Corner radii
        static let cardRadius: CGFloat      = 8
        static let pillRadius: CGFloat      = 20  // fully rounded pill
        static let badgeRadius: CGFloat     = 6

        // Borders
        static let separatorThickness: CGFloat  = 0.5
        static let cardBorderWidth: CGFloat     = 1
        static let leftIndicatorWidth: CGFloat  = 3   // left-side status bar on action rows

        // Sparkline
        static let sparklineWidth: CGFloat  = 44
        static let sparklineHeight: CGFloat = 22
        static let sparklineStroke: CGFloat = 1.6
        static let sparklineSampleCount: Int = 15

        // Status donut
        static let donutSize: CGFloat       = 20
        static let donutStroke: CGFloat     = 2
    }

    // MARK: - Animation
    enum Animation {
        /// Repeating rotation for in-progress donut shimmer
        static let donutSpin = SwiftUI.Animation.linear(duration: 2).repeatForever(autoreverses: false)
        /// Pulse for in-progress donut glow
        static let donutPulse = SwiftUI.Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
    }
}

// MARK: - Color Hex Init
extension SwiftUI.Color {
    /// Initialise a Color from a CSS-style hex string, e.g. "#30d158" or "30d158".
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (1, 1, 1)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

// MARK: - Convenience View Modifiers
extension View {
    /// Apply the standard monospaced body font used across RunnerBar.
    func monoBody() -> some View {
        self.font(DesignTokens.Font.monoBody)
    }

    /// Apply the small monospaced font used for meta labels.
    func monoSmall() -> some View {
        self.font(DesignTokens.Font.monoSmall)
    }

    /// Apply the extra-small monospaced font used for pills and badges.
    func monoXSmall() -> some View {
        self.font(DesignTokens.Font.monoXSmall)
    }
}
