import BibleCore
import SwiftUI

/**
 Renders the item-based reader sheets launched from the reader shell.

 `BibleReaderView` decides when a sheet is active and supplies the focused controller. This view
 owns only the sheet content switch and forwards dismiss/navigation side effects through closures.
 */
struct BibleReaderActiveSheetContent: View {
    let sheet: BibleReaderView.ReaderSheet
    let controller: BibleReaderController?
    @Binding var displaySettings: TextDisplaySettings
    @Binding var nightMode: Bool
    @Binding var nightModeMode: String
    let onDismiss: () -> Void
    let onSettingsChanged: () -> Void

    var body: some View {
        switch sheet {
        case .bookmarks:
            NavigationStack {
                BookmarkListView(
                    onNavigate: { book, chapter in
                        onDismiss()
                        controller?.navigateTo(book: book, chapter: chapter)
                    },
                    onOpenStudyPad: { labelId in
                        controller?.loadStudyPadDocument(labelId: labelId)
                    }
                )
            }
        case .settings:
            NavigationStack {
                SettingsView(
                    displaySettings: $displaySettings,
                    nightMode: $nightMode,
                    nightModeMode: $nightModeMode,
                    onSettingsChanged: onSettingsChanged
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "done"), action: onDismiss)
                    }
                }
            }
        case .downloads:
            NavigationStack {
                ModuleBrowserView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done"), action: onDismiss)
                        }
                    }
            }
        case .history:
            NavigationStack {
                HistoryView(
                    bookNameResolver: { osisId in
                        controller?.bookName(forOsisId: osisId)
                    }
                ) { key in
                    onDismiss()
                    _ = controller?.navigateToRef(key)
                }
            }
        case .readingPlans:
            NavigationStack {
                ReadingPlanListView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done"), action: onDismiss)
                        }
                    }
            }
        case .workspaces:
            NavigationStack {
                WorkspaceSelectorView()
            }
        case .about:
            NavigationStack {
                AboutView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done"), action: onDismiss)
                                .accessibilityIdentifier("aboutDoneButton")
                        }
                    }
            }
            .accessibilityIdentifier("aboutSheetScreen")
        }
    }
}
