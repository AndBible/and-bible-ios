import SwiftUI

/**
 Shared left-side drawer presentation shell for reader-owned drawer surfaces.

 Android presents the main reader drawer as a left-origin drawer with a dimmed reading surface.
 Passage selection is also a reader-owned navigation surface, so `BibleReaderView` uses this shell
 for both the hamburger drawer and the passage chooser instead of maintaining separate dimmer,
 width, background, and transition behavior. The shell owns presentation chrome and dismissal;
 caller content remains responsible for internal navigation and actions.
 */
struct ReaderSideDrawerOverlay<DrawerContent: View>: View {
    /// System color scheme available to callers that need scheme-aware drawer content.
    let colorScheme: ColorScheme

    /// Accessibility identifier applied to the dimmed dismiss target.
    let dismissAreaIdentifier: String

    /// Action invoked when the user taps outside the drawer.
    let onDismiss: () -> Void

    /// Drawer content builder receiving the Android-compatible drawer width.
    let drawerContent: (CGFloat) -> DrawerContent

    /**
     Creates a shared reader side-drawer overlay.

     - Parameters:
       - colorScheme: Current color scheme. Stored so all reader drawer surfaces receive the same
         environmental input used by the hamburger drawer.
       - dismissAreaIdentifier: Stable identifier for UI tests and accessibility debugging.
       - onDismiss: Callback for dismissing the owning presentation state.
       - drawerContent: Content builder that receives the computed drawer width.
     */
    init(
        colorScheme: ColorScheme,
        dismissAreaIdentifier: String,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder drawerContent: @escaping (CGFloat) -> DrawerContent
    ) {
        self.colorScheme = colorScheme
        self.dismissAreaIdentifier = dismissAreaIdentifier
        self.onDismiss = onDismiss
        self.drawerContent = drawerContent
    }

    /// Builds the dimmed full-screen overlay and left drawer content.
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .accessibilityIdentifier(dismissAreaIdentifier)

                let drawerWidth = Self.drawerWidth(for: proxy.size.width)

                drawerContent(drawerWidth)
                    .frame(width: drawerWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(drawerBackground)
                    .transition(.move(edge: .leading))
            }
        }
    }

    /// Reader drawer background aligned with Android's drawer surface and current app theme.
    private var drawerBackground: Color {
        #if os(iOS)
        return colorScheme == .dark
            ? Color(red: 48.0 / 255.0, green: 48.0 / 255.0, blue: 48.0 / 255.0)
            : Color(uiColor: .systemBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /**
     Computes the reader drawer width used by Android-style left drawer surfaces.

     - Parameter availableWidth: Full reader surface width.
     - Returns: Width clamped to the existing hamburger-drawer range.
     */
    static func drawerWidth(for availableWidth: CGFloat) -> CGFloat {
        min(306, max(252, availableWidth * 0.756))
    }
}
