import SwiftUI

/**
 Full-screen reader-owned shell for Android-style passage selection.

 Android opens book/chapter/verse selection as a dark full-screen chooser activity with its own
 toolbar. The reader still owns presentation state on iOS, so this shell supplies only the
 full-screen surface, background, and transition while `BookChooserView` owns internal navigation,
 menu actions, and dismissal.
 */
struct ReaderPassageChooserOverlay<ChooserContent: View>: View {
    /// Chooser content, normally a `NavigationStack` hosting `BookChooserView`.
    let chooserContent: () -> ChooserContent

    /**
     Creates a full-screen passage chooser overlay.

     - Parameter chooserContent: Full-screen chooser content.
     - Side effects: none. Dismissal is driven by hosted controls.
     - Failure modes: none.
     */
    init(
        @ViewBuilder chooserContent: @escaping () -> ChooserContent
    ) {
        self.chooserContent = chooserContent
    }

    /// Renders the full-screen dark chooser surface.
    var body: some View {
        chooserContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PassageChooserSurfacePalette.background.swiftUIColor.ignoresSafeArea())
            .transition(.move(edge: .leading))
            .accessibilityIdentifier("passageChooserFullScreenSurface")
    }
}
