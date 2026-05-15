import SwiftUI

// MARK: - Color(hex:) initializer
// Required by DesignTokens.Colors status constants.
// SwiftUI does not provide a built-in hex string initializer.
extension Color {
    /// Creates a SwiftUI Color from a CSS-style hex string (e.g. "#30D158" or "30D158").
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8)  / 255
        let b = Double( value & 0x0000FF)         / 255
        self.init(red: r, green: g, blue: b)
    }
}

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

        /// Hairline border for card rows.
        ///
        /// Issue #419 spec originally wrote `strokeBorder(Color.white.opacity(0.06))` which
        /// is correct only in dark mode. This token uses `Color.primary.opacity(0.06)` instead
        /// so it adapts correctly to both light and dark appearances — `primary` is white in
        /// dark mode and black in light mode, giving an equivalent visual weight in both.
        /// ❌ Do NOT revert this to a hardcoded `Color.white` — it will look wrong in light mode.
        static let rowBorder: Color = Color.primary.opacity(0.06)

        /// Pill background for CPU/MEM metric badges inside runner rows.
        static let metricPill: Color = Color.primary.opacity(0.07)

        /// Returns a colour that transitions continuously green → orange → red as `pct` rises
        /// from 0 to 100. Uses linear interpolation in RGB space across two segments:
        ///   0–60 %  → green  → orange
        ///   60–100 % → orange → red
        /// This replaces the previous step-function that jumped at 60 / 85.
        static func usage(pct: Double) -> Color {
            let t = max(0, min(100, pct)) / 100.0  // normalise to 0–1
            if t <= 0.6 {
                // green → orange over the first 60 %
                let s = t / 0.6
                return lerp(statusGreen, statusOrange, t: s)
            } else {
                // orange → red over the remaining 40 %
                let s = (t - 0.6) / 0.4
                return lerp(statusOrange, statusRed, t: s)
            }
        }

        /// Linear interpolation between two SwiftUI Colors in sRGB space.
        private static func lerp(_ a: Color, _ b: Color, t: Double) -> Color {
            let u = max(0, min(1, t))
#if canImport(AppKit)
            let ca = NSColor(a).usingColorSpace(.sRGB) ?? .black
            let cb = NSColor(b).usingColorSpace(.sRGB) ?? .black
            var (ar, ag, ab, aa): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            ca.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            cb.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            return Color(
                red:   Double(ar) + (Double(br) - Double(ar)) * u,
                green: Double(ag) + (Double(bg) - Double(ag)) * u,
                blue:  Double(ab) + (Double(bb) - Double(ab)) * u,
                opacity: Double(aa) + (Double(ba) - Double(aa)) * u
            )
#else
            // Fallback: step function (non-macOS targets)
            return u < 0.5 ? a : b
#endif
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
