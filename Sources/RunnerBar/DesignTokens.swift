import AppKit
import SwiftUI
// swiftlint:disable identifier_name

// MARK: - Hex Color Helper

extension Color {
    /// Initialises a `Color` from a CSS-style hex string (with or without leading `#`).
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
    /// Returns a color that resolves to `light` in light-appearance contexts and `dark` in dark-appearance contexts.
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
    /// Primary blue accent — used for in-progress status indicators and interactive highlights.
    static let rbBlue = Color(red: 0.04, green: 0.52, blue: 1.00)
    /// Green success color — used for completed / passing status.
    static let rbSuccess = Color(red: 0.19, green: 0.82, blue: 0.35)
    /// Amber warning color — used for queued / pending status.
    static let rbWarning = Color(red: 1.00, green: 0.62, blue: 0.04)
    /// Red danger color — used for failed / error status.
    static let rbDanger = Color(red: 1.00, green: 0.27, blue: 0.23)
    /// Primary accent alias — resolves to `rbBlue`.
    static let rbAccent = rbBlue

    // Neutral / surface — semi-transparent so .hudWindow vibrancy shows through.
    //
    // ⚠️ TRANSLUCENCY CONTRACT — DO NOT REMOVE THIS COMMENT.
    // NSVisualEffectView uses .hudWindow (.behindWindow). MUST stay opacity < 1.0.
    // ❌ NEVER set opacity 1.0 — kills vibrancy.
    // ❌ NEVER switch PanelChrome material back to .popover — warm brown tint.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    //
    //   rbSurface         — white: 0.11 @ 0.45  (panel bg)
    //   rbSurfaceElevated — white: 0.15 @ 0.25  (rows — very transparent)

    /// Base panel background surface — semi-transparent to preserve HUD vibrancy.
    static let rbSurface = Color.adaptive(
        light: Color(white: 0.95).opacity(0.88),
        dark: Color(white: 0.11).opacity(0.45)
    )
    /// Elevated row/card surface — slightly lighter than `rbSurface`.
    static let rbSurfaceElevated = Color.adaptive(
        light: Color(white: 0.88).opacity(0.92),
        dark: Color(white: 0.15).opacity(0.25)
    )
    /// Subtle border — low-contrast outline for cards and separators.
    static let rbBorderSubtle = Color.adaptive(
        light: Color(white: 0.0).opacity(0.08),
        dark: Color(white: 1.0).opacity(0.06)
    )
    /// Mid-weight border — slightly more visible than `rbBorderSubtle`.
    static let rbBorderMid = Color.adaptive(
        light: Color(white: 0.0).opacity(0.12),
        dark: Color(white: 1.0).opacity(0.10)
    )
    /// Horizontal rule / section divider color.
    static let rbDivider = Color.adaptive(
        light: Color(white: 0.0).opacity(0.08),
        dark: Color(white: 1.0).opacity(0.08)
    )
    /// Primary text — high contrast body and heading text.
    static let rbTextPrimary = Color.adaptive(
        light: .black,
        dark: .white
    )
    /// Secondary text — reduced-emphasis labels and descriptions.
    static let rbTextSecondary = Color.adaptive(
        light: Color(white: 0.40),
        dark: Color(white: 0.55)
    )
    /// Tertiary text — lowest-emphasis metadata and timestamps.
    static let rbTextTertiary = Color.adaptive(
        light: Color(white: 0.58),
        dark: Color(white: 0.39)
    )

    /// Low-opacity amber tint for row backgrounds in warning/queued state.
    static let rbYellowTint = rbWarning.opacity(0.08)
    /// Low-opacity blue tint for row backgrounds in in-progress state.
    static let rbBlueTint = rbBlue.opacity(0.08)
    /// Low-opacity green tint for row backgrounds in success state.
    static let rbGreenTint = rbSuccess.opacity(0.08)
    /// Low-opacity red tint for row backgrounds in failed/danger state.
    static let rbRedTint = rbDanger.opacity(0.08)
    /// Low-opacity orange tint — alias for `rbYellowTint`.
    static let rbOrangeTint = rbWarning.opacity(0.08)
}

// MARK: - Status helpers

/// Semantic status values used to drive color, tint, and SF Symbol selection across the app.
enum RBStatus {
    /// A job or workflow step that is currently executing.
    case inProgress
    /// A job or workflow step that completed successfully.
    case success
    /// A job or workflow step that failed.
    case failed
    /// A job or workflow step that is waiting to run.
    case queued
    /// An unrecognised or unavailable status.
    case unknown

    /// The primary foreground color associated with this status.
    var color: Color {
        switch self {
        case .inProgress: return .rbBlue
        case .success: return .rbSuccess
        case .failed: return .rbDanger
        case .queued: return .rbWarning
        case .unknown: return .rbTextTertiary
        }
    }

    /// A low-opacity background tint to visually distinguish rows by status.
    var tint: Color {
        switch self {
        case .inProgress: return .rbBlueTint
        case .success: return .rbGreenTint
        case .failed: return .rbRedTint
        case .queued: return .rbYellowTint
        default: return .clear
        }
    }

    /// The SF Symbol name that represents this status.
    var sfSymbol: String {
        switch self {
        case .inProgress: return "arrow.trianglehead.2.clockwise"
        case .success: return "checkmark"
        case .failed: return "xmark"
        case .queued: return "clock"
        case .unknown: return "questionmark"
        }
    }
}

// MARK: - Spacing & Geometry Tokens

/// Fixed spacing constants derived from an 8-pt grid. Use these instead of raw `CGFloat` literals.
enum RBSpacing {
    /// 2 pt — hairline gap between tightly packed elements.
    static let xxs: CGFloat = 2
    /// 4 pt — compact inner padding (e.g. badge insets).
    static let xs: CGFloat = 4
    /// 8 pt — standard small gap.
    static let sm: CGFloat = 8
    /// 12 pt — default row horizontal padding.
    static let md: CGFloat = 12
    /// 16 pt — section-level spacing.
    static let lg: CGFloat = 16
    /// 20 pt — generous section spacing.
    static let xl: CGFloat = 20
    /// 28 pt — large structural spacing.
    static let xxl: CGFloat = 28
}

/// Corner-radius constants for consistent rounding across components.
enum RBRadius {
    /// 20 pt — full pill shape for tags and badges.
    static let pill: CGFloat = 20
    /// 8 pt — standard card corner radius.
    static let card: CGFloat = 8
    /// 5 pt — small card or row corner radius.
    static let small: CGFloat = 5
    /// 6 pt — badge corner radius.
    static let badge: CGFloat = 6
    /// 2 pt — subtle indicator corner radius.
    static let indicator: CGFloat = 2
}

/// Shadow constants used to give cards and panels consistent depth.
enum RBShadow {
    /// Opacity of the card drop shadow.
    static let cardOpacity: Double = 0.35
    /// Blur radius of the card drop shadow.
    static let cardRadius: CGFloat = 12
    /// Vertical offset of the card drop shadow.
    static let cardY: CGFloat = 4
}

// MARK: - Typography Tokens

/// Shared font constants. Prefer these over inline `.system(size:weight:design:)` calls.
enum RBFont {
    /// Caption-sized monospaced font — general-purpose code/metric labels.
    static let mono: Font = .system(.caption, design: .monospaced)
    /// 11 pt regular monospaced — small metric values.
    static let monoSmall: Font = .system(size: 11, weight: .regular, design: .monospaced)
    /// 13 pt semibold monospaced — prominent metric headings.
    static let monoBold: Font = .system(size: 13, weight: .semibold, design: .monospaced)
    /// 13 pt medium — standard row/list label.
    static let label: Font = .system(size: 13, weight: .medium)
    /// 12 pt regular — standard body text inside rows.
    static let body: Font = .system(size: 12, weight: .regular)
    /// 12.5 pt regular — section key labels.
    static let sectionKey: Font = .system(size: 12.5, weight: .regular)
    /// Alias for `sectionKey` — section header labels.
    static let sectionHeader: Font = sectionKey
    /// 9 pt semibold — uppercase section caption badges.
    static let sectionCaption: Font = .system(size: 9, weight: .semibold)
    /// 9 pt semibold monospaced — stat label (CPU, MEM, etc.).
    static let statLabel: Font = .system(size: 9, weight: .semibold, design: .monospaced)
    /// 10 pt regular monospaced — numeric stat value.
    static let statValue: Font = .system(size: 10, weight: .regular, design: .monospaced)
}

// MARK: - DesignTokens namespace shim

/// Backwards-compatibility namespace that delegates to the primary `RBFont`, `RBSpacing`,
/// and `Color` token types. Prefer the `RB*` types directly in new code.
enum DesignTokens {
    /// Font aliases forwarded from `RBFont`.
    enum Fonts {
        /// Monospaced label font — alias for `RBFont.monoSmall`.
        static let monoLabel: Font = RBFont.monoSmall
        /// Monospaced stat font — alias for `RBFont.monoSmall`.
        static let monoStat: Font = RBFont.monoSmall
        /// Caption monospaced font — alias for `RBFont.mono`.
        static let mono: Font = RBFont.mono
    }
    /// Spacing aliases forwarded from `RBSpacing`.
    enum Spacing {
        /// Horizontal row padding — alias for `RBSpacing.md`.
        static let rowHPad: CGFloat = RBSpacing.md
    }
    /// Color helpers forwarded from the `Color` token extensions.
    enum Colors {
        /// Returns a traffic-light color based on a usage percentage (0–100).
        /// - Green below 60 %, amber 60–85 %, red above 85 %.
        static func usage(pct: Double) -> Color {
            if pct < 60 { return .rbSuccess }
            if pct < 85 { return .rbWarning }
            return .rbDanger
        }
    }
}
// swiftlint:enable identifier_name
