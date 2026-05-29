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
    let readingProgressInitialTab: ReadingProgressTab
    let chapterReadHistoryTarget: ChapterReadHistoryTarget?

    /// Initial Downloads search text supplied by Android-compatible `download://` links.
    let downloadsInitialSearchText: String

    /// Startup/default-document mode supplied when the reader opens Downloads for Easy Start.
    let downloadsDefaultDownloadMode: ModuleBrowserDefaultDownloadMode

    let onDismiss: () -> Void
    let onSettingsChanged: () -> Void

    /**
     Creates active reader sheet content for the currently presented sheet route.

     - Parameters:
       - sheet: Reader sheet route to render.
       - controller: Focused reader controller backing sheet navigation actions.
       - displaySettings: Shared text display settings binding for Settings.
       - nightMode: Shared night-mode binding for Settings.
       - nightModeMode: Shared night-mode mode binding for Settings.
       - readingProgressInitialTab: Initial reading-progress tab for progress routes.
       - chapterReadHistoryTarget: Optional chapter read-history target.
       - downloadsInitialSearchText: Initial Downloads filter from Android-compatible links.
       - downloadsDefaultDownloadMode: Optional startup/default-document mode for Easy Start.
       - onDismiss: Callback used to close the active sheet.
       - onSettingsChanged: Callback used after Settings mutates display preferences.

     Side effects:
     - none during initialization

     Failure modes:
     - none; route-specific failures are handled by the rendered child view
     */
    init(
        sheet: BibleReaderView.ReaderSheet,
        controller: BibleReaderController?,
        displaySettings: Binding<TextDisplaySettings>,
        nightMode: Binding<Bool>,
        nightModeMode: Binding<String>,
        readingProgressInitialTab: ReadingProgressTab,
        chapterReadHistoryTarget: ChapterReadHistoryTarget?,
        downloadsInitialSearchText: String,
        downloadsDefaultDownloadMode: ModuleBrowserDefaultDownloadMode = .disabled,
        onDismiss: @escaping () -> Void,
        onSettingsChanged: @escaping () -> Void
    ) {
        self.sheet = sheet
        self.controller = controller
        self._displaySettings = displaySettings
        self._nightMode = nightMode
        self._nightModeMode = nightModeMode
        self.readingProgressInitialTab = readingProgressInitialTab
        self.chapterReadHistoryTarget = chapterReadHistoryTarget
        self.downloadsInitialSearchText = downloadsInitialSearchText
        self.downloadsDefaultDownloadMode = downloadsDefaultDownloadMode
        self.onDismiss = onDismiss
        self.onSettingsChanged = onSettingsChanged
    }

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
                ModuleBrowserView(
                    initialSearchText: downloadsInitialSearchText,
                    defaultDownloadMode: downloadsDefaultDownloadMode
                )
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
        case .readingProgress:
            NavigationStack {
                ReadingProgressView(
                    readingStore: controller?.readingProgressStore,
                    memorizationStore: controller?.memorizationProgressStore,
                    initialTab: readingProgressInitialTab
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "done"), action: onDismiss)
                    }
                }
            }
        case .readingProgressSettings:
            NavigationStack {
                ReadingProgressSettingsView(controller: controller)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done"), action: onDismiss)
                        }
                    }
            }
        case .chapterReadHistory:
            NavigationStack {
                ChapterReadHistoryView(
                    store: controller?.readingProgressStore,
                    target: chapterReadHistoryTarget
                )
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
