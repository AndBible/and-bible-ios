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
    let speakService: SpeakService
    let readingProgressInitialTab: ReadingProgressTab
    let chapterReadHistoryTarget: ChapterReadHistoryTarget?

    let onDismiss: () -> Void

    /**
     Creates active reader sheet content for the currently presented sheet route.

     - Parameters:
       - sheet: Reader sheet route to render.
       - controller: Focused reader controller backing sheet navigation actions.
       - speakService: Reader-owned speech runtime passed to workspace management.
       - readingProgressInitialTab: Initial reading-progress tab for progress routes.
       - chapterReadHistoryTarget: Optional chapter read-history target.
       - onDismiss: Callback used to close the active sheet.

     Side effects:
     - none during initialization

     Failure modes:
     - none; route-specific failures are handled by the rendered child view
     */
    init(
        sheet: BibleReaderView.ReaderSheet,
        controller: BibleReaderController?,
        speakService: SpeakService,
        readingProgressInitialTab: ReadingProgressTab,
        chapterReadHistoryTarget: ChapterReadHistoryTarget?,
        onDismiss: @escaping () -> Void
    ) {
        self.sheet = sheet
        self.controller = controller
        self.speakService = speakService
        self.readingProgressInitialTab = readingProgressInitialTab
        self.chapterReadHistoryTarget = chapterReadHistoryTarget
        self.onDismiss = onDismiss
    }

    var body: some View {
        switch sheet {
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
        case .readingProgress:
            NavigationStack {
                ReadingProgressView(
                    readingStore: controller?.readingProgressStore,
                    memorizationStore: controller?.memorizationProgressStore,
                    initialTab: readingProgressInitialTab,
                    onOpenMemorizeRange: { range in
                        onDismiss()
                        _ = controller?.openMemorizeKJVARange(
                            startOrdinal: range.startOrdinal,
                            endOrdinal: range.endOrdinal
                        )
                    },
                    onOpenChapter: { osisId, chapter in
                        onDismiss()
                        _ = controller?.navigateToRef("\(osisId).\(chapter)")
                    }
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
                WorkspaceSelectorView(speakService: speakService)
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
