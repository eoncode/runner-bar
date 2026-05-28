// InlineSheetOverlay.swift
// RunnerBar
//
// Replaces SwiftUI's .sheet() modifier for borderless NSPanel-based statusbar apps.
//
// Problem: .sheet() spawns a child NSWindow. Child windows inherit styling from their
// parent, producing unstyled rectangles inside a custom borderless NSPanel.
//
// Solution: render sheet content inline as a ZStack overlay — scrim + animated content
// card — entirely within the existing NSPanel. No child window is ever created.
//
// Usage:
//   // Bool binding
//   .inlineSheet(isPresented: $showMySheet) { MySheetView() }
//
//   // Identifiable item binding
//   .inlineSheet(item: $selectedItem) { item in MySheetView(item: item) }

import SwiftUI

// MARK: - InlineSheetModifier (Bool)

/// Overlays a sheet within the current view hierarchy using a ZStack.
/// No child NSWindow is created — safe for borderless NSPanel statusbar apps.
private struct InlineSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> SheetContent

    func body(content outerContent: Content) -> some View {
        ZStack {
            outerContent
            if isPresented {
                sheetLayer
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isPresented)
    }

    private var sheetLayer: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            content()
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.22), radius: 24, x: 0, y: 8)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal:   .opacity.combined(with: .scale(scale: 0.96))
                    )
                )
        }
    }
}

// MARK: - InlineSheetItemModifier (Identifiable item)

/// Identifiable-item variant. Presents whenever `item` is non-nil; dismisses by setting it to nil.
private struct InlineSheetItemModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let content: (Item) -> SheetContent

    func body(content outerContent: Content) -> some View {
        ZStack {
            outerContent
            if let item {
                sheetLayer(for: item)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: item?.id)
    }

    private func sheetLayer(for item: Item) -> some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { self.item = nil }

            content(item)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.22), radius: 24, x: 0, y: 8)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal:   .opacity.combined(with: .scale(scale: 0.96))
                    )
                )
        }
    }
}

// MARK: - View convenience extensions

extension View {
    /// Presents `content` as an inline overlay sheet (no child NSWindow).
    ///
    /// - Parameters:
    ///   - isPresented: Controls visibility of the sheet.
    ///   - content: The view to display as the sheet body.
    func inlineSheet<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(InlineSheetModifier(isPresented: isPresented, content: content))
    }

    /// Presents `content` as an inline overlay sheet when `item` is non-nil (no child NSWindow).
    ///
    /// - Parameters:
    ///   - item: Optional identifiable value. Sheet is shown when non-nil.
    ///   - content: Builder receiving the unwrapped item.
    func inlineSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(InlineSheetItemModifier(item: item, content: content))
    }
}
