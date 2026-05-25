// DesignTokens.swift
// RunnerBar
import AppKit
import SwiftUI

// MARK: - Adaptive Color Helper

/// Helpers for creating appearance-adaptive `Color` values that respond to light/dark mode.
extension Color {
    /// Returns a color that resolves to `light` in light-appearance contexts and `dark` in dark-appearance contexts.
    /// Covers all dark-family appearances including vibrant dark and high-contrast variants.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil) { appearance in
            let darkMatches: [NSAppearance.Name] = [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]
            return darkMatches.contains(appearance.bestMatch(from: darkMatches + [.aqua])!)
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}

// MARK: - Color Tokens

/// Semantic color tokens used throughout RunnerBar for status, surface, and text styling.
extension Color {
    /// Primary blue accent — adaptive light/dark pair for in-progress status indicators.
    static let rbBlue = Color.adaptive(
        light: Color(red: 0.0, green: 0.48, blue: 1.0),
        dark:  Color(red: 0.3, green: 0.64, blue: 1.0)
    )
    /// Green success color — adaptive light/dark pair for completed / passing status.
    static let rbSuccess = Color.adaptive(
        light: Color(red: 0.18, green: 0.64, blue: 0.18),
        dark:  Color(red: 0.25, green: 0.80, blue: 0.25)
    )
    /// Amber warning color — adaptive light/dark pair for queued / pending status.
    static let rbWarning = Color.adaptive(
        light: Color(red: 0.80, green: 0.55, blue: 0.05),
        dark: Color(red: 1.0, green: 0.75, blue: 0.20)
    )
    /// Red danger color — adaptive light/dark pair for failed / error status.
    static let rbDanger = Color.adaptive(
        light: Color(red: 0.85, green: 0.18, blue: 0.18),
        dark: Color(red: 1.0, green: 0.35, blue: 0.35)
    )
    /// Primary accent alias — resolves to `rbBlue`.
    static let rbAccent = rbBlue

    // MARK: Surface & Border Tokens
    //
    // DESIGN TOKEN NOTE:
    // On macOS 26+ the panel chrome uses NSGlassEffectView which provides its own
    // backdrop blur and tinting. Surface tokens must use near-zero opacity so the
    // glass layer shows through. Pre-26 values use the existing vibrancy opacities.
    //
    // ⚠️ TRANSLUCENCY CONTRACT — DO NOT REMOVE THIS COMMENT.
    // NSVisualEffectView uses .hudWindow (.behindWindow). MUST stay opacity < 1.0.
    // ❌ NEVER set opacity 1.0 — kills vibrancy.
    // ❌ NEVER switch PanelChrome material back to .popover — warm brown tint.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.

    /// Base panel background surface.
    /// macOS 26+: near-zero opacity so glass backdrop shows through.
    /// Pre-26: standard vibrancy opacities.
    static var rbSurface: Color {
        if #available(macOS 26, *) {
            return Color.adaptive(
                light: Color(white: 0.95).opacity(0.04),
                dark:  Color(white: 0.11).opacity(0.04)
            )
        } else {
            return Color.adaptive(
                light: Color(white: 0.95).opacity(0.88),
                dark:  Color(white: 0.11).opacity(0.45)
            )
        }
    }

    /// Elevated row/card surface — slightly lighter than `rbSurface`.
    /// macOS 26+: near-zero opacity so glass backdrop shows through.
    /// Pre-26: standard vibrancy opacities.
    static var rbSurfaceElevated: Color {
        if #available(macOS 26, *) {
            return Color.adaptive(
                light: Color(white: 0.88).opacity(0.05),
                dark:  Color(white: 0.15).opacity(0.05)
            )
        } else {
            return Color.adaptive(
                light: Color(white: 0.88).opacity(0.92),
                dark:  Color(white: 0.15).opacity(0.25)
            )
        }
    }

    /// Subtle border — low-contrast outline for cards and separators.
    /// macOS 26+: light opacity bumped to 0.12 for better visibility on glass.
    static var rbBorderSubtle: Color {
        if #available(macOS 26, *) {
            return Color.adaptive(
                light: Color(white: 0.0).opacity(0.12),
                dark:  Color(white: 1.0).opacity(0.06)
            )
        } else {
            return Color.adaptive(
                light: Color(white: 0.0).opacity(0.08),
                dark:  Color(white: 1.0).opacity(0.06)
            )
        }
    }

    /// Mid-weight border — slightly stronger than `rbBorderSubtle`.
    /// Use for component outlines that need more definition on glass.
    static var rbBorderMid: Color {
        if #available(macOS 26, *) {
            return Color.adaptive(
                light: Color(white: 0.0).opacity(0.14),
                dark:  Color(white: 1.0).opacity(0.10)
            )
        } else {
            return Color.adaptive(
                light: Color(white: 0.0).opacity(0.10),
                dark:  Color(white: 1.0).opacity(0.08)
            )
        }
    }

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
    public static let rbYellowTint = rbWarning.opacity(0.08)
    /// Low-opacity blue tint for row backgrounds in in-progress state.
    public static let rbBlueTint = rbBlue.opacity(0.08)
    /// Low-opacity green tint for row backgrounds in success state.
    public static let rbGreenTint = rbSuccess.opacity(0.08)
    /// Low-opacity red tint for row backgrounds in failed/danger state.
    public static let rbRedTint = rbDanger.opacity(0.08)
    /// Low-opacity orange tint — alias for `rbYellowTint`.
    public static let rbOrangeTint = rbWarning.opacity(0.08)
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
    public var tint: Color {
        switch self {
        case .inProgress: return .rbBlueTint
        case .success: return .rbGreenTint
        case .failed: return .rbRedTint
        case .queued: return .rbYellowTint
        default: return .clear
        }
    }

    /// The SF Symbol name that represents this status.
    public var sfSymbol: String {
        switch self {
        case .inProgress: return "arrow.trianglehead.2.clockwise"
        case .success: return "checkmark"
        case .failed: return "xmark"
        case .queued: return "clock"
        case .unknown: return "questionmark"
        }
    }
}

// MARK: - Shadow Tokens

/// Adaptive shadow constants for card and panel elevation.
/// macOS 26+ uses softer, larger shadows to complement the glass material.
enum RBShadow {
    /// Shadow opacity for card backgrounds.
    /// macOS 26+: 0.18 (softer on glass); pre-26: 0.35.
    static var cardOpacity: Double {
        if #available(macOS 26, *) { return 0.18 } else { return 0.35 }
    }
    /// Shadow blur radius for card backgrounds.
    /// macOS 26+: 18 pt (larger, diffuse); pre-26: 12 pt.
    static var cardRadius: CGFloat {
        if #available(macOS 26, *) { return 18 } else { return 12 }
    }
}

// MARK: - Spacing & Geometry Tokens

/// Fixed spacing constants derived from an 8-pt grid. Use these instead of raw `CGFloat` literals.
enum RBSpacing {
    /// 2 pt — hairline gap between tightly packed elements.
    static let xxs: CGFloat = 2
    /// 4 pt — compact inner padding (e.g. badge insets).
    static let xs: CGFloat = 4
    /// 6 pt — tight gap between related elements.
    static let sm: CGFloat = 6
    /// 8 pt — standard label/row gap. Compat alias for xs+sm region.
    static let label: CGFloat = 8
    /// 10 pt — default row horizontal padding.
    static let md: CGFloat = 10
    /// 16 pt — section-level spacing.
    static let lg: CGFloat = 16
    /// 24 pt — large inter-section gap.
    static let xl: CGFloat = 24
}

/// Corner-radius constants for consistent rounding across components.
enum RBRadius {
    /// 10 pt — standard card corner radius.
    static let card: CGFloat = 10
    /// 6 pt — small card or row corner radius.
    static let small: CGFloat = 6
}

// MARK: - Typography Tokens

/// Shared font constants. Prefer these over inline `.system(size:weight:design:)` calls.
enum RBFont {
    /// Caption-sized monospaced font — general-purpose code/metric labels.
    static let mono: Font = .system(.caption, design: .monospaced)
    /// 11 pt regular monospaced — small metric values.
    static let monoSmall: Font = .system(size: 11, weight: .regular, design: .monospaced)
    /// 13 pt medium — standard row/list label.
    static let label: Font = .system(size: 13, weight: .medium)
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
        /// Caption monospaced font — alias for `RBFont.mono`.
        static let mono: Font = RBFont.mono
    }
    /// Spacing aliases forwarded from `RBSpacing`.
    enum Spacing {
        /// Horizontal row padding — alias for `RBSpacing.md`.
        static let rowHPad: CGFloat = RBSpacing.md
    }
    /// Radius aliases forwarded from `RBRadius`.
    enum Radius {
        /// Card corner radius — alias for `RBRadius.card`.
        static let card: CGFloat = RBRadius.card
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
