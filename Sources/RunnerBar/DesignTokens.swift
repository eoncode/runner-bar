import SwiftUI

// MARK: - Design Tokens
/// Central source of truth for all visual constants used across RunnerBar views.
/// Introduced as part of the new design system (Issue #420 / #403).
enum DesignTokens {
    // MARK: - Status Colors
    /// Colour tokens for status states and UI chrome.
    enum Color {
        /// Green — success, healthy, low usage
        static let statusGreen = SwiftUI.Color(hex: "#30d158")
        /// Orange — warning, moderate usage
        static let statusOrange = SwiftUI.Color(hex: "#ff9f0a")
        /// Red — failure, critical usage
        static let statusRed = SwiftUI.Color(hex: "#ff453a")
        /// Blue — in-progress, active
        static let statusBlue = SwiftUI.Color(hex: "#0a84ff")

        // MARK: Row tint backgrounds (status color at low opacity)
        /// Green row tint
        static let tintGreen = statusGreen.opacity(0.06)
        /// Orange row tint
        static let tintOrange = statusOrange.opacity(0.06)
        /// Red row tint
        static let tintRed = statusRed.opacity(0.06)
        /// Blue row tint
        static let tintBlue = statusBlue.opacity(0.06)

        // MARK: Sparkline gradient fills
        /// Green sparkline gradient fill
        static let sparkFillGreen = statusGreen.opacity(0.55)
        /// Orange sparkline gradient fill
        static let sparkFillOrange = statusOrange.opacity(0.55)
        /// Red sparkline gradient fill
        static let sparkFillRed = statusRed.opacity(0.55)

        // MARK: UI chrome
        /// Separator / border lines
        static let separator = SwiftUI.Color.white.opacity(0.08)
        /// Runner / action card border
        static let cardBorder = SwiftUI.Color.white.opacity(0.06)
        /// Pill badge background (CPU/MEM on runner rows)
        static let pillBg = SwiftUI.Color.white.opacity(0.08)
        /// Pill badge border
        static let pillBorder = SwiftUI.Color.white.opacity(0.12)
        /// Secondary label text
        static let labelSecondary = SwiftUI.Color(hex: "#636366")
        /// Tertiary label / chevron
        static let labelTertiary = SwiftUI.Color(hex: "#3a3a3c")

        /// Returns the appropriate status colour for a 0–100 percentage.
        static func statColor(for pct: Double) -> SwiftUI.Color {
            if pct > 85 { return statusRed }
            if pct > 60 { return statusOrange }
            return statusGreen
        }

        /// Returns the accent colour for a given GroupStatus + conclusion.
        static func actionColor(status: GroupStatus, conclusion: String?) -> SwiftUI.Color {
            switch status {
            case .inProgress: return statusBlue
            case .queued: return statusBlue
            case .completed:
                return conclusion == "success" ? statusGreen : statusRed
            }
        }
    }

    // MARK: - Typography
    /// Font tokens for monospaced and stat text.
    enum Font {
        /// Standard monospaced body text (commit hashes, runner names, stats)
        static let monoBody: SwiftUI.Font = .system(size: 13, design: .monospaced)
        /// Small monospaced label (step counts, durations, sub-job meta)
        static let monoSmall: SwiftUI.Font = .system(size: 11.5, design: .monospaced)
        /// Extra small monospaced (pill badges, branch tags)
        static let monoXSmall: SwiftUI.Font = .system(size: 11, design: .monospaced)
        /// Header stat value (CPU %, MEM GB)
        static let statValue: SwiftUI.Font = .system(size: 12.5, weight: .semibold, design: .monospaced)
        /// Header stat label ("CPU", "MEM", "DISK")
        static let statLabel: SwiftUI.Font = .system(size: 12.5, design: .default)
    }

    // MARK: - Layout
    /// Layout constants: padding, spacing, radii, borders, sparkline, donut dimensions.
    enum Layout {
        // Padding
        /// Horizontal padding for the main panel
        static let panelHPad: CGFloat = 18
        /// Vertical padding for the main panel
        static let panelVPad: CGFloat = 13
        /// Horizontal padding for rows
        static let rowHPad: CGFloat = 12
        /// Vertical padding for rows
        static let rowVPad: CGFloat = 9
        /// Horizontal inset for runner/action rows inside panel
        static let sectionInset: CGFloat = 8

        // Spacing
        /// Gap between CPU / MEM / DISK groups
        static let statGroupGap: CGFloat = 20
        /// Gap between label and value within a stat
        static let statInnerGap: CGFloat = 8
        /// Gap between runner row items
        static let runnerRowGap: CGFloat = 10
        /// Gap between action row items
        static let actionRowGap: CGFloat = 9

        // Corner radii
        /// Card corner radius
        static let cardRadius: CGFloat = 8
        /// Fully rounded pill radius
        static let pillRadius: CGFloat = 20
        /// Badge corner radius
        static let badgeRadius: CGFloat = 6

        // Borders
        /// Separator / divider line thickness
        static let separatorThickness: CGFloat = 0.5
        /// Card border line width
        static let cardBorderWidth: CGFloat = 1
        /// Left-side status bar width on action rows
        static let leftIndicatorWidth: CGFloat = 3

        // Sparkline
        /// Sparkline graph width
        static let sparklineWidth: CGFloat = 44
        /// Sparkline graph height
        static let sparklineHeight: CGFloat = 22
        /// Sparkline stroke line width
        static let sparklineStroke: CGFloat = 1.6
        /// Number of samples to keep in sparkline history
        static let sparklineSampleCount: Int = 15

        // Status donut
        /// Donut circle diameter
        static let donutSize: CGFloat = 20
        /// Donut stroke width
        static let donutStroke: CGFloat = 2
    }

    // MARK: - Animation
    /// Animation tokens for in-progress state indicators.
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
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let red, green, blue: UInt64
        switch cleanHex.count {
        case 6:
            (red, green, blue) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (red, green, blue) = (1, 1, 1)
        }
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
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
