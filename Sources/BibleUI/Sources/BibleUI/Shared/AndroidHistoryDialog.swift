import SwiftUI

/**
 Renders the reader-owned History dialog with Android dialog-window ownership.

 The dialog is deliberately not a SwiftUI sheet: `BibleReaderView` retains presentation state and
 supplies a captured window identity, so a focus change cannot retarget the visible History rows or
 the navigation result. Its only mutable behavior is delegated through `onDismiss` and `onNavigate`.
 */
struct AndroidHistoryDialog: View {
    /// Current palette mode selects the Android dialog surface color.
    @Environment(\.colorScheme) private var colorScheme

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

    /// Builds a bounded dialog whose dimmed backdrop dismisses it without changing History.
    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidHistoryDialog",
            onOutsideTap: onDismiss
        ) {
            AndroidDialogScaffold(title: title, showsActionRegion: false) {
                HistoryView(
                    bookNameResolver: bookNameResolver,
                    onNavigate: onNavigate,
                    activeWindowID: activeWindowID
                )
            } actions: {
                EmptyView()
            }
        }
    }
}
