// DesignTokens.swift
// RunnerBar
import AppKit
import SwiftUI

// MARK: - Spacing

/// Spacing scale used across the RunnerBar design system.
enum RBSpacing {
    /// Extra-small spacing (4 pt).
    static let xs: CGFloat  = 4
    /// Small spacing (6 pt).
    static let sm: CGFloat  = 6
    /// Medium spacing (10 pt).
    static let md: CGFloat  = 10
    /// Large spacing (16 pt).
    static let lg: CGFloat  = 16
    /// Extra-large spacing (24 pt).
    static let xl: CGFloat  = 24
}

// MARK: - Radius

/// Corner-radius scale used across the RunnerBar design system.
enum RBRadius {
    /// Small radius (6 pt) — used for compact chips and tags.
    static let small: CGFloat = 6
    /// Card radius (10 pt) — used for row cards and panels.
    static let card: CGFloat  = 10
}

// MARK: - Typography

/// Typography helpers used across the RunnerBar design system.
enum RBFont {
    /// Section-header font: caption weight semibold, uppercased.
    static let sectionHeader: Font = .system(size: 10, weight: .semibold)
        .uppercaseSmallCaps()
}

// MARK: - Adaptive Color helper

extension Color {
    /// Returns a color that switches between `light` and `dark` based on the current
    /// colour scheme by embedding both variants into an `NSColor`.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.name == .darkAqua
                || appearance.name == .vibrantDark
                || appearance.name == .accessibilityHighContrastDarkAqua
                || appearance.name == .accessibilityHighContrastVibrantDark
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}

// MARK: - Surface & Border tokens

extension Color {
    // Design token notes:
    //
    // ❌ NEVER switch PanelChrome material back to .popover — warm brown tint.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    //
    // macOS 26+ (Liquid Glass):
    //   On macOS 26 the NSGlassEffectView provides blur/tint itself.
    //   Surface fills must be near-zero so they don't fight the glass backdrop.
    //   rbSurface         — near-zero (glass handles translucency)
    //   rbSurfaceElevated — near-zero (glass handles translucency)
    //
    // macOS < 26 (HUD vibrancy — unchanged):
    //   rbSurface         — white: 0.11 @ 0.45  (panel bg)
    //   rbSurfaceElevated — white: 0.15 @ 0.25  (rows — very transparent)

    /// Base panel background surface.
    /// On macOS 26+ returns near-zero opacity — `NSGlassEffectView` provides the translucency.
    /// On macOS < 26 returns the original HUD-tuned value.
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

    /// Elevated row/card surface.
    /// On macOS 26+ returns near-zero opacity — `NSGlassEffectView` provides the translucency.
    /// On macOS < 26 returns the original HUD-tuned value.
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
    /// On macOS 26+ light-mode opacity is raised slightly (0.12) to match
    /// the thin specular border idiom of Liquid Glass.
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

    /// Mid border — slightly stronger outline.
    /// On macOS 26+ light-mode opacity is raised to 0.14 for Liquid Glass specular edge.
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
    /// Secondary text — medium contrast labels and captions.
    static let rbTextSecondary = Color.adaptive(
        light: Color(white: 0.35),
        dark: Color(white: 0.65)
    )
    /// Tertiary text — lowest contrast; used for hints and placeholders.
    static let rbTextTertiary = Color.adaptive(
        light: Color(white: 0.55),
        dark: Color(white: 0.45)
    )
    /// Accent blue — interactive elements and focus rings.
    static let rbAccent  = Color.rbBlue
    /// Blue — used for in-progress status and accent.
    static let rbBlue    = Color.adaptive(light: Color(red: 0.0, green: 0.48, blue: 1.0),
                                          dark:  Color(red: 0.3, green: 0.64, blue: 1.0))
    /// Success green — completed / passing status.
    static let rbSuccess = Color.adaptive(light: Color(red: 0.18, green: 0.64, blue: 0.18),
                                          dark:  Color(red: 0.25, green: 0.80, blue: 0.25))
    /// Danger red — failed / error status.
    static let rbDanger  = Color.adaptive(light: Color(red: 0.85, green: 0.18, blue: 0.18),
                                          dark:  Color(red: 1.00, green: 0.35, blue: 0.35))
    /// Warning amber — queued / caution status.
    static let rbWarning = Color.adaptive(light: Color(red: 0.80, green: 0.55, blue: 0.05),
                                          dark:  Color(red: 1.00, green: 0.75, blue: 0.20))
    /// Orange tint overlay — subtle amber fill for warning backgrounds.
    public static let rbOrangeTint = rbWarning.opacity(0.08)
}

// MARK: - Shadow Tokens

/// Shadow tokens for card/row drop shadows.
/// On macOS 26+ shadows are softer and more diffuse to complement Liquid Glass.
/// On macOS < 26 values match the original design.
enum RBShadow {
    /// Drop-shadow opacity for card/row elements.
    /// Returns 0.18 on macOS 26+ (glass panels need a lighter shadow) and 0.35 on earlier OS versions.
    static var cardOpacity: Double {
        if #available(macOS 26, *) { return 0.18 } else { return 0.35 }
    }

    /// Drop-shadow blur radius for card/row elements, in points.
    /// Returns 18 pt on macOS 26+ (softer, more diffuse) and 12 pt on earlier OS versions.
    static var cardRadius: CGFloat {
        if #available(macOS 26, *) { return 18 } else { return 12 }
    }
}

// MARK: - Status helpers

/// Semantic status values used to drive color, tint, and SF Symbol selection across the app.
enum RBStatus: String, Equatable {
    /// Workflow is actively running.
    case inProgress = "in_progress"
    /// Workflow run has succeeded.
    case success
    /// Workflow run has failed.
    case failed
    /// Workflow run is waiting to start.
    case queued
    /// Status is unknown or not yet fetched.
    case unknown

    /// The semantic color for this status.
    var color: Color {
        switch self {
        case .inProgress: return .rbBlue
        case .success:    return .rbSuccess
        case .failed:     return .rbDanger
        case .queued:     return .rbWarning
        case .unknown:    return .rbTextTertiary
        }
    }

    /// The SF Symbol name that represents this status.
    var symbol: String {
        switch self {
        case .inProgress: return "arrow.trianglehead.2.clockwise"
        case .success:    return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        case .queued:     return "clock.fill"
        case .unknown:    return "questionmark.circle"
        }
    }
}
