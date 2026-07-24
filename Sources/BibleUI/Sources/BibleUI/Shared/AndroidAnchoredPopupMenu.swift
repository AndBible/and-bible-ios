// AndroidAnchoredPopupMenu.swift -- Shared app-owned popup anchoring and dismissal

import SwiftUI

/// Collects named control bounds for app-owned Android dropdown and overflow placement.
private struct AndroidPopupAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [String: Anchor<CGRect>],
        nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private extension View {
    /** Marks this control as the origin for a named app-owned popup. */
    func androidPopupAnchor(id: String) -> some View {
        anchorPreference(key: AndroidPopupAnchorPreferenceKey.self, value: .bounds) { [id: $0] }
    }
}

/**
 Adds Android-style anchored popup presentation to an application-owned screen.

 The modifier resolves a named control's bounds after layout, chooses above/below placement based
 on available space, supplies a full-screen outside-tap dismissal layer, and renders caller content
 without invoking native `Menu`, `Picker`, `popover`, or sheet presentation.
 */
private struct AndroidAnchoredPopupMenuModifier<Popup: View>: ViewModifier {
    let anchorID: String
    @Binding var isPresented: Bool
    let menuWidth: CGFloat
    let estimatedMenuHeight: CGFloat
    let accessibilityIdentifier: String
    let popup: Popup

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(AndroidPopupAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if isPresented, let anchor = anchors[anchorID] {
                    let anchorRect = proxy[anchor]
                    let menuOrigin = resolvedOrigin(anchorRect: anchorRect, containerSize: proxy.size)
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { isPresented = false }
                            .accessibilityIdentifier("\(accessibilityIdentifier)DismissalLayer")

                        popup
                            .frame(width: menuWidth)
                            .offset(x: menuOrigin.x, y: menuOrigin.y)
                    }
                }
            }
        }
    }

    /** Chooses Android dropdown placement while keeping the menu inside the app-owned viewport. */
    private func resolvedOrigin(anchorRect: CGRect, containerSize: CGSize) -> CGPoint {
        let margin: CGFloat = 8
        let maximumX = max(margin, containerSize.width - menuWidth - margin)
        let x = min(max(anchorRect.minX, margin), maximumX)
        let spaceBelow = containerSize.height - anchorRect.maxY - margin
        let proposedY = spaceBelow >= estimatedMenuHeight
            ? anchorRect.maxY + 4
            : anchorRect.minY - estimatedMenuHeight - 4
        let maximumY = max(margin, containerSize.height - estimatedMenuHeight - margin)
        return CGPoint(x: x, y: min(max(proposedY, margin), maximumY))
    }
}

extension View {
    /**
     Registers this view as a named popup anchor.

     - Parameter id: Stable identifier shared with `androidAnchoredPopupMenu`.
     - Returns: The original view with a layout anchor preference.
     - Side effects: none.
     - Failure modes: Duplicate identifiers resolve to the latest layout value.
     */
    func androidPopupMenuAnchor(id: String) -> some View {
        androidPopupAnchor(id: id)
    }

    /**
     Presents caller-owned popup content relative to a named control anchor.

     - Parameters:
       - anchorID: Identifier registered by `androidPopupMenuAnchor`.
       - isPresented: Caller-owned visibility state.
       - menuWidth: Desired popup width.
       - estimatedMenuHeight: Height used to choose safe above/below placement.
       - accessibilityIdentifier: Stable identifier for the popup and dismissal layer.
       - popup: Shared popup surface and rows supplied by the feature.
     - Returns: The screen with an app-owned anchored overlay.
     - Side effects: Outside taps set `isPresented` to false.
     - Failure modes: A missing anchor renders no popup and retains caller state.
     */
    func androidAnchoredPopupMenu<Popup: View>(
        anchorID: String,
        isPresented: Binding<Bool>,
        menuWidth: CGFloat,
        estimatedMenuHeight: CGFloat,
        accessibilityIdentifier: String,
        @ViewBuilder popup: () -> Popup
    ) -> some View {
        modifier(AndroidAnchoredPopupMenuModifier(
            anchorID: anchorID,
            isPresented: isPresented,
            menuWidth: menuWidth,
            estimatedMenuHeight: estimatedMenuHeight,
            accessibilityIdentifier: accessibilityIdentifier,
            popup: popup()
        ))
    }
}
