import AppKit
import SwiftUI
// swiftlint:disable identifier_name

// MARK: - Hex Color Helper

/// Initialises a SwiftUI `Color` from a 6-digit hex string (with or without leading `#`).
/// Matches the `Color(hex:)` extension called out in the Phase 1 spec.
///
/// Usage:
/// ```swift
/// Color(hex: "#0A84FF")
/// Color(hex: "30D158")
/// ```
extension Color {
    /// Creates a `Color` from a 6-digit RGB hex string.
    /// - Parameter hex: A 6-digit hex string, optionally prefixed with `#`.
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

/// Creates adaptive colors that switch between light and dark appearances.
extension Color {
    /// Creates a color that adapts between light and dark appearance.
    /// Uses NSColor with light/dark appearance variants so SwiftUI picks
    /// the correct value automatically regardless of system appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}

// MARK: - Color Tokens

/// Design-token color extensions used throughout the app.
extension Color {
    // Status colors — same in both appearances
    /// Accent blue — in-progress status color + links, non-status UI accents (#0A84FF)
    static let rbBlue = Color(red: 0.04, green: 0.52, blue: 1.00)
    /// Success green (#30D158)
    static let rbSuccess = Color(red: 0.19, green: 0.82, blue: 0.35)
    /// Warning yellow/orange (#FF9F0A) — queued status color
    static let rbWarning = Color(red: 1.00, green: 0.62, blue: 0.04)
    /// Danger red (#FF453A)
    static let rbDanger = Color(red: 1.00, green: 0.27, blue: 0.23)
    /// Primary accent — alias for rbBlue; used by sparklines and stat chips.
    static let rbAccent = rbBlue

    // Neutral / surface — adaptive light/dark
    // Dark values match the reference design screenshot:
    //   rbSurface        ≈ #1C1C1C  (panel background, white: 0.11)
    //   rbSurfaceElevated ≈ #262626  (card rows, white: 0.15)
    // Light values follow the same relative elevation pattern.
    // ❌ NEVER make these fully transparent — the NSVisualEffectView vibrancy
    //    behind the hosting view causes card content to wash out against the
    //    desktop when surface fills are clear. The PanelChrome draw() method
    //    already adds a near-zero alpha fill (0.01) to keep the backdrop sampler
    //    active; the SwiftUI layer on top should be opaque.
    //    If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    /// Base panel surface color — solid dark fill matching reference design.
    static let rbSurface = Color.adaptive(
        light: Color(white: 0.96),
        dark: Color(white: 0.11)
    )
    /// Elevated card surface — visibly lighter than rbSurface to distinguish rows.
    static let rbSurfaceElevated = Color.adaptive(
        light: Color(white: 0.88),
        dark: Color(white: 0.15)
    )
    /// Subtle border / stroke color.
    static let rbBorderSubtle = Color.adaptive(
        light: Color(white: 0.0).opacity(0.08),
        dark: Color(white: 1.0).opacity(0.06)
    )
    /// Mid-weight border color.
    static let rbBorderMid = Color.adaptive(
        light: Color(white: 0.0).opacity(0.12),
        dark: Color(white: 1.0).opacity(0.10)
    )
    /// Divider line color.
    static let rbDivider = Color.adaptive(
        light: Color(white: 0.0).opacity(0.08),
        dark: Color(white: 1.0).opacity(0.08)
    )

    // Text — adaptive
    /// Primary label text color.
    static let rbTextPrimary = Color.adaptive(
        light: .black,
        dark: .white
    )
    /// Secondary label text color.
    static let rbTextSecondary = Color.adaptive(
        light: Color(white: 0.40),
        dark: Color(white: 0.55)
    )
    /// Tertiary / placeholder text color.
    static let rbTextTertiary = Color.adaptive(
        light: Color(white: 0.58),
        dark: Color(white: 0.39)
    )

    // Tinted row backgrounds (very faint, status-keyed)
    /// Faint yellow row tint for queued rows.
    static let rbYellowTint = rbWarning.opacity(0.08)
    /// Faint blue tint — in-progress row background + non-status blue UI accents.
    static let rbBlueTint = rbBlue.opacity(0.08)
    /// Faint green row tint for success rows.
    static let rbGreenTint = rbSuccess.opacity(0.08)
    /// Faint red row tint for failed rows.
    static let rbRedTint = rbDanger.opacity(0.08)
    /// Faint orange row tint for warning rows.
    static let rbOrangeTint = rbWarning.opacity(0.08)
}

// MARK: - Status helpers

/// Semantic status values used across action rows, donut views, and indicators.
enum RBStatus {
    /// The workflow run is currently executing.
    case inProgress
    /// The workflow run completed successfully.
    case success
    /// The workflow run failed.
    case failed
    /// The workflow run is queued and waiting to start.
    case queued
    /// Status is not determined or not applicable.
    case unknown

    /// The primary display color associated with this status.
    /// Spec (issue #403): queued=yellow, in-progress=blue, failed=red, success=green.
    var color: Color {
        switch self {
        case .inProgress: return .rbBlue     // fix(#419): blue, not yellow
        case .success: return .rbSuccess
        case .failed: return .rbDanger
        case .queued: return .rbWarning      // yellow
        case .unknown: return .rbTextTertiary
        }
    }

    /// The faint row-background tint color associated with this status.
    var tint: Color {
        switch self {
        case .inProgress: return .rbBlueTint  // fix(#419): blue tint for in-progress
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

/// Shared spacing scale used for padding and gaps throughout the app.
enum RBSpacing {
    /// 2pt — hairline gap.
    static let xxs: CGFloat = 2
    /// 4pt — extra-small gap.
    static let xs: CGFloat = 4
    /// 8pt — small gap.
    static let sm: CGFloat = 8
    /// 12pt — medium gap.
    static let md: CGFloat = 12
    /// 16pt — large gap.
    static let lg: CGFloat = 16
    /// 20pt — extra-large gap.
    static let xl: CGFloat = 20
    /// 28pt — double extra-large gap.
    static let xxl: CGFloat = 28
}

/// Shared corner-radius scale used for cards, pills, and indicators.
enum RBRadius {
    /// Full pill radius.
    static let pill: CGFloat = 20
    /// Standard card corner radius.
    static let card: CGFloat = 8
    /// Small element corner radius.
    static let small: CGFloat = 5
    /// Badge corner radius.
    static let badge: CGFloat = 6
    /// Left-side indicator bar radius.
    static let indicator: CGFloat = 2
}

/// Shadow parameters for card-style elevated surfaces.
enum RBShadow {
    /// Shadow opacity for card surfaces.
    static let cardOpacity: Double = 0.35
    /// Shadow blur radius for card surfaces.
    static let cardRadius: CGFloat = 12
    /// Shadow vertical offset for card surfaces.
    static let cardY: CGFloat = 4
}

// MARK: - Typography Tokens

/// Shared font scale used throughout the app.
enum RBFont {
    /// Monospaced caption — used for hashes, timestamps, step counts.
    static let mono: Font = .system(.caption, design: .monospaced)
    /// Monospaced small — used for runner CPU/MEM values.
    static let monoSmall: Font = .system(size: 11, weight: .regular, design: .monospaced)
    /// Monospaced medium bold — runner names, commit titles.
    static let monoBold: Font = .system(size: 13, weight: .semibold, design: .monospaced)
    /// Standard medium-weight label.
    static let label: Font = .system(size: 13, weight: .medium)
    /// Body text — job name in detail rows.
    static let body: Font = .system(size: 12, weight: .regular)
    /// Section key label.
    static let sectionKey: Font = .system(size: 12.5, weight: .regular)
    /// Section header — alias for sectionKey (used in SettingsView).
    static let sectionHeader: Font = sectionKey
    /// Section caption — uppercase section headers in the popover (9pt semibold).
    static let sectionCaption: Font = .system(size: 9, weight: .semibold)
    /// Stat chip label — tiny uppercase label for CPU / MEM / DISK chips (9pt semibold mono).
    static let statLabel: Font = .system(size: 9, weight: .semibold, design: .monospaced)
    /// Stat chip value — monospaced value text next to sparklines (10pt regular mono).
    static let statValue: Font = .system(size: 10, weight: .regular, design: .monospaced)
}

// MARK: - DesignTokens namespace shim
// Provides DesignTokens.Fonts / .Spacing / .Colors expected by older call-sites.

/// Backward-compatibility namespace shim for pre-token call-sites.
enum DesignTokens {
    /// Font tokens exposed via legacy DesignTokens.Fonts namespace.
    enum Fonts {
        /// Monospaced label font (chip labels: "CPU", "MEM", "DISK").
        static let monoLabel: Font = RBFont.monoSmall
        /// Monospaced value font (chip values and elapsed text).
        static let monoStat: Font = RBFont.monoSmall
        /// Standard mono caption (action row labels, job progress, elapsed).
        static let mono: Font = RBFont.mono
    }

    /// Spacing tokens exposed via legacy DesignTokens.Spacing namespace.
    enum Spacing {
        /// Standard horizontal padding for popover rows (= RBSpacing.md).
        static let rowHPad: CGFloat = RBSpacing.md
    }

    /// Color utilities exposed via legacy DesignTokens.Colors namespace.
    enum Colors {
        /// Returns a usage-keyed color: green below 60 %, orange 60–85 %, red above.
        static func usage(pct: Double) -> Color {
            if pct < 60 { return .rbSuccess }
            if pct < 85 { return .rbWarning }
            return .rbDanger
        }
    }
}
// swiftlint:enable identifier_name
