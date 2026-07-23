// AndroidAdaptiveDialogScrollView.swift -- Intrinsic-height Android dialog scrolling

import SwiftUI

/**
 Sizes Android dialog content to its natural height until the available vertical space is exhausted.

 Android `AlertDialog` measures a short message at its intrinsic height and introduces scrolling only
 when the content no longer fits the window. A plain SwiftUI `ScrollView` greedily accepts the full
 proposal and makes every short dialog appear nearly full-screen. This shared primitive preserves
 Android's measurement contract for every app-owned help surface.

 Inputs: one caller-owned vertical content hierarchy

 Output: intrinsic-height content when it fits, otherwise a bounded scroll container

 Side effects: exposes scrolling gestures only when the content exceeds the available height

 Failure modes: none; the enclosing `AndroidDialogWindow` remains the geometry and clipping owner
 */
struct AndroidAdaptiveDialogScrollView<Content: View>: View {
    /// Semantic dialog body rendered in both the intrinsic and overflow candidates.
    private let content: Content

    /**
     Creates an adaptive Android dialog body without measuring or rendering it eagerly.

     - Parameter content: Vertical content whose natural height should be retained when possible.
     - Side effects: none.
     - Failure modes: none.
     */
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /**
     Selects the intrinsic candidate when it fits and the scrollable candidate otherwise.

     `ViewThatFits` receives the finite proposal supplied by `AndroidDialogWindow`. The first
     candidate reports its complete vertical ideal size, so it is rejected only when Android would
     need a scrolling message region.

     - Returns: Natural-height or overflow-scrolling dialog content.
     - Side effects: none until the overflow candidate receives a user scroll gesture.
     - Failure modes: none.
     */
    var body: some View {
        ViewThatFits(in: .vertical) {
            content
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                content
            }
        }
    }
}
