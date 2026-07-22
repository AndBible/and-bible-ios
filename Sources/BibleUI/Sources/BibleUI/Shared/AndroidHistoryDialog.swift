import SwiftUI

/**
 Renders the reader-owned History surface with Android dialog-window ownership.

 The dialog is deliberately not a SwiftUI sheet: `BibleReaderView` retains presentation state and
 supplies a captured window identity, so a focus change cannot retarget the visible History rows or
 the navigation result. Its only mutable behavior is delegated through `onDismiss` and `onNavigate`.
 */
struct AndroidHistoryDialog: View {
    /// Captured reader window whose persisted History rows are displayed.
    let activeWindowID: UUID

    /// Android `history_for` title including the source workspace and window ordinal.
    let title: String

    /// Maps OSIS IDs to the source pane's active module-aware names.
    let bookNameResolver: (String) -> String?

    /// Closes the app-owned dialog without mutating History.
    let onDismiss: () -> Void

    /// Applies the selected History entry to the captured pane before closing.
    let onNavigate: (String) -> Void

    /// Builds a dimmed, bounded app-owned dialog rather than an adaptive sheet.
    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()

            NavigationStack {
                HistoryView(
                    bookNameResolver: bookNameResolver,
                    onNavigate: onNavigate,
                    activeWindowID: activeWindowID,
                    title: title,
                    allowsDestructiveActions: false,
                    onDismiss: onDismiss
                )
            }
            .frame(maxWidth: 560, maxHeight: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("androidHistoryDialog")
    }
}
