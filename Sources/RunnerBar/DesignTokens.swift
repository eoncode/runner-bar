import SwiftUI

// MARK: - Color Tokens

extension Color {
    // Status colors
    static let rbBlue    = Color(red: 0.04, green: 0.52, blue: 1.00)   // #0A84FF
    static let rbSuccess = Color(red: 0.19, green: 0.82, blue: 0.35)   // #30D158
    static let rbWarning = Color(red: 1.00, green: 0.62, blue: 0.04)   // #FF9F0A
    static let rbDanger  = Color(red: 1.00, green: 0.27, blue: 0.23)   // #FF453A

    // Neutral / surface
    static let rbSurface        = Color(white: 0.11)                   // #1C1C1E
    static let rbSurfaceElevated = Color(white: 0.14)                  // slightly lifted card
    static let rbBorderSubtle   = Color(white: 1.0).opacity(0.06)
    static let rbBorderMid      = Color(white: 1.0).opacity(0.10)
    static let rbDivider        = Color(white: 1.0).opacity(0.08)

    // Text
    static let rbTextPrimary    = Color.white
    static let rbTextSecondary  = Color(white: 0.55)                   // #8C8C8E
    static let rbTextTertiary   = Color(white: 0.39)                   // #636366

    // Tinted row backgrounds (very faint, status-keyed)
    static let rbBlueTint   = rbBlue.opacity(0.05)
    static let rbGreenTint  = rbSuccess.opacity(0.05)
    static let rbRedTint    = rbDanger.opacity(0.05)
    static let rbOrangeTint = rbWarning.opacity(0.05)
}

// MARK: - Status helpers

enum RBStatus {
    case inProgress, success, failed, queued, unknown

    var color: Color {
        switch self {
        case .inProgress: return .rbBlue
        case .success:    return .rbSuccess
        case .failed:     return .rbDanger
        case .queued:     return .rbTextSecondary
        case .unknown:    return .rbTextTertiary
        }
    }

    var tint: Color {
        switch self {
        case .inProgress: return .rbBlueTint
        case .success:    return .rbGreenTint
        case .failed:     return .rbRedTint
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
    static let pill:   CGFloat = 20
    static let card:   CGFloat = 8
    static let small:  CGFloat = 5
    static let badge:  CGFloat = 6
    static let indicator: CGFloat = 2
}

enum RBShadow {
    static let cardOpacity: Double = 0.35
    static let cardRadius:  CGFloat = 12
    static let cardY:       CGFloat = 4
}

// MARK: - Typography Tokens

enum RBFont {
    /// Monospaced caption — used for hashes, timestamps, step counts
    static let mono:      Font = .system(.caption, design: .monospaced)
    /// Monospaced small — used for runner CPU/MEM values
    static let monoSmall: Font = .system(size: 11, weight: .regular, design: .monospaced)
    /// Monospaced medium bold — runner names, commit titles
    static let monoBold:  Font = .system(size: 13, weight: .semibold, design: .monospaced)
    /// Standard label
    static let label:     Font = .system(size: 13, weight: .medium)
    /// Section label / header key
    static let sectionKey: Font = .system(size: 12.5, weight: .regular)
}
