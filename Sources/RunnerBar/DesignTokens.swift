import AppKit
import SwiftUI
// swiftlint:disable identifier_name

// MARK: - Hex Color Helper

extension Color {
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(cleaned, radix: 16) ?? 0
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Adaptive Color Helper

extension Color {
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}

// MARK: - Color Tokens

extension Color {
    static let rbBlue    = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let rbSuccess = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let rbWarning = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let rbDanger  = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let rbAccent  = rbBlue

    // Neutral / surface — semi-transparent so .hudWindow vibrancy shows through.
    //
    // ⚠️ TRANSLUCENCY CONTRACT — DO NOT REMOVE THIS COMMENT.
    // NSVisualEffectView uses .hudWindow (.behindWindow). MUST stay opacity < 1.0.
    // ❌ NEVER set opacity 1.0 — kills vibrancy.
    // ❌ NEVER switch PanelChrome material back to .popover — warm brown tint.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    //
    //   rbSurface         — white: 0.06 @ 0.45
    //   rbSurfaceElevated — white: 0.09 @ 0.50

    static let rbSurface = Color.adaptive(
        light: Color(white: 0.95).opacity(0.88),
        dark:  Color(white: 0.06).opacity(0.45)
    )
    static let rbSurfaceElevated = Color.adaptive(
        light: Color(white: 0.88).opacity(0.92),
        dark:  Color(white: 0.09).opacity(0.50)
    )
    static let rbBorderSubtle = Color.adaptive(
        light: Color(white: 0.0).opacity(0.08),
        dark:  Color(white: 1.0).opacity(0.06)
    )
    static let rbBorderMid = Color.adaptive(
        light: Color(white: 0.0).opacity(0.12),
        dark:  Color(white: 1.0).opacity(0.10)
    )
    static let rbDivider = Color.adaptive(
        light: Color(white: 0.0).opacity(0.08),
        dark:  Color(white: 1.0).opacity(0.08)
    )
    static let rbTextPrimary = Color.adaptive(
        light: .black,
        dark:  .white
    )
    static let rbTextSecondary = Color.adaptive(
        light: Color(white: 0.40),
        dark:  Color(white: 0.55)
    )
    static let rbTextTertiary = Color.adaptive(
        light: Color(white: 0.58),
        dark:  Color(white: 0.39)
    )

    static let rbYellowTint = rbWarning.opacity(0.08)
    static let rbBlueTint   = rbBlue.opacity(0.08)
    static let rbGreenTint  = rbSuccess.opacity(0.08)
    static let rbRedTint    = rbDanger.opacity(0.08)
    static let rbOrangeTint = rbWarning.opacity(0.08)
}

// MARK: - Status helpers

enum RBStatus {
    case inProgress, success, failed, queued, unknown

    var color: Color {
        switch self {
        case .inProgress: return .rbBlue
        case .success:    return .rbSuccess
        case .failed:     return .rbDanger
        case .queued:     return .rbWarning
        case .unknown:    return .rbTextTertiary
        }
    }

    var tint: Color {
        switch self {
        case .inProgress: return .rbBlueTint
        case .success:    return .rbGreenTint
        case .failed:     return .rbRedTint
        case .queued:     return .rbYellowTint
        default:          return .clear
        }
    }

    var sfSymbol: String {
        switch self {
        case .inProgress: return "arrow.trianglehead.2.clockwise"
        case .success:    return "checkmark"
        case .failed:     return "xmark"
        case .queued:     return "clock"
        case .unknown:    return "questionmark"
        }
    }
}

// MARK: - Spacing & Geometry Tokens

enum RBSpacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 28
}

enum RBRadius {
    static let pill:      CGFloat = 20
    static let card:      CGFloat = 8
    static let small:     CGFloat = 5
    static let badge:     CGFloat = 6
    static let indicator: CGFloat = 2
}

enum RBShadow {
    static let cardOpacity: Double  = 0.35
    static let cardRadius:  CGFloat = 12
    static let cardY:       CGFloat = 4
}

// MARK: - Typography Tokens

enum RBFont {
    static let mono:           Font = .system(.caption, design: .monospaced)
    static let monoSmall:      Font = .system(size: 11, weight: .regular,  design: .monospaced)
    static let monoBold:       Font = .system(size: 13, weight: .semibold, design: .monospaced)
    static let label:          Font = .system(size: 13, weight: .medium)
    static let body:           Font = .system(size: 12, weight: .regular)
    static let sectionKey:     Font = .system(size: 12.5, weight: .regular)
    static let sectionHeader:  Font = sectionKey
    static let sectionCaption: Font = .system(size: 9,  weight: .semibold)
    static let statLabel:      Font = .system(size: 9,  weight: .semibold, design: .monospaced)
    static let statValue:      Font = .system(size: 10, weight: .regular,  design: .monospaced)
}

// MARK: - DesignTokens namespace shim

enum DesignTokens {
    enum Fonts {
        static let monoLabel: Font = RBFont.monoSmall
        static let monoStat:  Font = RBFont.monoSmall
        static let mono:      Font = RBFont.mono
    }
    enum Spacing {
        static let rowHPad: CGFloat = RBSpacing.md
    }
    enum Colors {
        static func usage(pct: Double) -> Color {
            if pct < 60 { return .rbSuccess }
            if pct < 85 { return .rbWarning }
            return .rbDanger
        }
    }
}
// swiftlint:enable identifier_name
