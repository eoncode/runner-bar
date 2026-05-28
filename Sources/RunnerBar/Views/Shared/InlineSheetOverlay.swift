// InlineSheetOverlay.swift
// RunnerBar
//
// NSPanel (statusbar app) cannot host SwiftUI .sheet() — it spawns a
// plain, unstyled NSWindow child that ignores the panel's visual style.
//
// .inlineSheet() renders sheet content as an in-process ZStack overlay
// so no child window is ever created. Supports:
//   - isPresented: Binding<Bool>         (flag-based)
//   - item: Binding<Item?>               (item-based, like .sheet(item:))
//
// Usage:
//   myView
//     .inlineSheet(isPresented: $showAddRunner) { AddRunnerSheet(...) }
//     .inlineSheet(item: $selectedEntry)        { entry in ScopeEditSheet(entry) }

import SwiftUI

// MARK: - InlineSheetModifier

/// Overlays sheet content inside the current view hierarchy.
/// No NSWindow child is spawned — safe to use from a borderless NSPanel.
private struct InlineSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                // Scrim
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) { isPresented = false } }
                    .transition(.opacity)

                // Sheet card
                sheetContent()
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal:   .opacity.combined(with: .scale(scale: 0.96))
                        )
                    )
                    .onExitCommand { withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) { isPresented = false } }
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isPresented)
    }
}

// MARK: - InlineSheetItemModifier

/// Item-based variant — mirrors the API of SwiftUI's `.sheet(item:content:)`.
private struct InlineSheetItemModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let sheetContent: (Item) -> SheetContent

    private var isPresented: Bool { item != nil }

    func body(content: Content) -> some View {
        ZStack {
            content
            if let currentItem = item {
                // Scrim
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) { item = nil } }
                    .transition(.opacity)

                // Sheet card
                sheetContent(currentItem)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal:   .opacity.combined(with: .scale(scale: 0.96))
                        )
                    )
                    .onExitCommand { withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) { item = nil } }
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: item?.id)
    }
}

// MARK: - View extensions

extension View {
    /// Presents `content` as an inline overlay instead of a child NSWindow sheet.
    /// Drop-in replacement for `.sheet(isPresented:content:)` inside NSPanel-hosted views.
    func inlineSheet<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.modifier(InlineSheetModifier(isPresented: isPresented, sheetContent: content))
    }

    /// Presents `content` as an inline overlay keyed on an optional `Identifiable` item.
    /// Drop-in replacement for `.sheet(item:content:)` inside NSPanel-hosted views.
    func inlineSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        self.modifier(InlineSheetItemModifier(item: item, sheetContent: content))
    }
}
