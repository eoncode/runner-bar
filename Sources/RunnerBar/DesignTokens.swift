import SwiftUI

// MARK: - DesignTokens
/// Central style constants for the RunnerBar redesign (#421).
/// All phases source colours, fonts and spacing from here — never hardcode.
enum DesignTokens {

    // MARK: Colors
    enum Colors {
        // Status
        static let statusGreen:  Color = Color(hex: "#30D158")
        static let statusOrange: Color = Color(hex: "#FF9F0A")
        static let statusRed:    Color = Color(hex: "#FF453A")
        static let statusBlue:   Color = Color(hex: "#0A84FF")

        // Row chrome
        /// Subtle elevated background for card rows (light/dark adaptive).
        static let rowBackground: Color = Color.primary.opacity(0.04)
        /// Hairline border on card rows.
        static let rowBorder:     Color = Color.primary.opacity(0.06)
        /// Pill background for CPU/MEM metric badges inside runner rows.
        static let metricPill:    Color = Color.primary.opacity(0.07)

        // Usage thresholds — mirrors legacy usageColor logic
        static func usage(pct: Double) -> Color {
            if pct > 85 { return statusRed    }
            if pct > 60 { return statusOrange }
            return statusGreen
        }
    }

    // MARK: Fonts
    enum Fonts {
        /// Monospaced caption for hashes, metrics, elapsed times.
        static let mono:      Font = .system(size: 11, design: .monospaced)
        /// Slightly larger monospaced for primary stat values in the header.
        static let monoStat:  Font = .system(size: 12, weight: .semibold, design: .monospaced)
        /// Tiny monospaced label (e.g. "CPU", "MEM").
        static let monoLabel: Font = .system(size: 10, weight: .semibold, design: .monospaced)
    }

    // MARK: Spacing
    enum Spacing {
        /// Horizontal padding inside chip / pill components.
        static let chipHPad:   CGFloat = 6
        /// Horizontal padding for standard row content.
        static let rowHPad:    CGFloat = 12
        /// Corner radius for card-row backgrounds.
        static let cardRadius: CGFloat = 7
    }
}

// MARK: - Color Token Aliases
extension Color {
    static let rbBlue:            Color = DesignTokens.Colors.statusBlue
    static let rbSuccess:         Color = DesignTokens.Colors.statusGreen
    static let rbWarning:         Color = DesignTokens.Colors.statusOrange
    static let rbDanger:          Color = DesignTokens.Colors.statusRed
    static let rbSurfaceElevated: Color = Color.primary.opacity(0.04)
    static let rbBorderSubtle:    Color = Color.primary.opacity(0.06)
    static let rbTextTertiary:    Color = Color.secondary
    static let rbTextSecondary:   Color = Color.secondary
}

// MARK: - Font Token Aliases
enum RBFont {
    static let mono:      Font = DesignTokens.Fonts.mono
    static let monoSmall: Font = .system(size: 10, design: .monospaced)
    static let monoStat:  Font = DesignTokens.Fonts.monoStat
    static let monoLabel: Font = DesignTokens.Fonts.monoLabel
}

// MARK: - Spacing Token Aliases
enum RBSpacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = DesignTokens.Spacing.chipHPad
    static let md:  CGFloat = DesignTokens.Spacing.rowHPad
}

// MARK: - Radius Token Aliases
enum RBRadius {
    static let small:     CGFloat = 5
    static let card:      CGFloat = DesignTokens.Spacing.cardRadius
    static let indicator: CGFloat = 3
}

// MARK: - Status Token Alias
enum RBStatus {
    case success
    case failure
    case inProgress
    case queued
    case unknown

    var color: Color {
        switch self {
        case .success:              return .rbSuccess
        case .failure:              return .rbDanger
        case .inProgress, .queued:  return .rbBlue
        case .unknown:              return .secondary
        }
    }

    var tint: Color {
        switch self {
        case .success:    return Color.rbSuccess.opacity(0.04)
        case .failure:    return Color.rbDanger.opacity(0.04)
        case .inProgress: return Color.rbBlue.opacity(0.04)
        case .queued:     return Color.rbBlue.opacity(0.02)
        case .unknown:    return Color.clear
        }
    }
}
