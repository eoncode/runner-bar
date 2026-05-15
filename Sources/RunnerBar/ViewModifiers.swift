// swiftlint:disable all
import SwiftUI

extension View {
    func rbCardStyle() -> some View {
        self.modifier(RBCardModifier())
    }
    func rbRowStyle(isSelected: Bool = false) -> some View {
        self.modifier(RBRowModifier(isSelected: isSelected))
    }
    func rbHoverEffect() -> some View {
        self.modifier(RBHoverModifier())
    }
}

struct RBCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DesignTokens.Spacing.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                    .fill(DesignTokens.Colors.cardBackground)
                    .shadow(color: DesignTokens.Shadow.cardColor,
                            radius: DesignTokens.Shadow.cardRadius,
                            x: 0, y: DesignTokens.Shadow.cardY)
            )
    }
}

struct RBRowModifier: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.rowHPad)
            .padding(.vertical, DesignTokens.Spacing.rowVPad)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                    .fill(isSelected
                        ? DesignTokens.Colors.selectedRowBackground
                        : DesignTokens.Colors.rowBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                            .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5)
                    )
            )
    }
}

struct RBHoverModifier: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .onHover { isHovered = $0 }
    }
}
