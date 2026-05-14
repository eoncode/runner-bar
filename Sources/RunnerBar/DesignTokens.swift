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
        static let rowHPad:   CGFloat = 12
        static let rowVPad:   CGFloat = 8
        static let chipHPad:  CGFloat = 8
        static let chipVPad:  CGFloat = 3
        static let cardRadius: CGFloat = 8
    }
}

// MARK: - Color hex init
extension Color {
    /// Convenience initialiser for 6-digit hex strings ("#RRGGBB" or "RRGGBB").
    init(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let scanner = Scanner(string: raw)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
