// EpubBrowserView.swift — Table of Contents browser for EPUB files

import SwiftUI
import BibleCore

/**
 Table-of-contents browser for one installed EPUB.

 The view loads TOC entries from the selected `EpubReader` and lets the caller navigate with the
 numeric general-book key Android persists.

 Data dependencies:
 - `reader` provides EPUB metadata and TOC entries
 - `surfacePalette` is inherited from the launching reader window
 - `onBack` owns Android Up and empty-TOC completion
 - `onSelectKey` notifies the parent when the user chooses one TOC target

 Side effects:
 - loads the TOC when the view appears
 - invokes the reader-owned Back action from the Android activity bar
 - follows Android's null-selection fallback to the first indexed content key for an empty TOC
 */
struct EpubBrowserView: View {
    /// Reader for the EPUB whose TOC is being browsed.
    let reader: EpubReader

    /// Reader/workspace palette inherited by this Android activity.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Explicit Android Up and finish command owned by the reader destination.
    let onBack: () -> Void

    /// Callback invoked when the user chooses a numeric/composite general-book key.
    let onSelectKey: (String) -> Void

    /// Loaded table-of-contents entries for the EPUB.
    @State private var tocEntries: [EpubReader.TOCEntry] = []

    /// Whether the TOC is still loading.
    @State private var isLoading = true

    /**
     Creates an Android general-book chooser for one EPUB generation.

     - Parameters:
       - reader: Immutable EPUB generation whose TOC is shown.
       - surfacePalette: Palette inherited from the launching reader window.
       - onBack: Explicit Android Up and finish command.
       - onSelectKey: Callback for an exact EPUB general-book key.
     - Side effects: None during initialization.
     - Failure modes: None; an empty TOC is resolved when the task loads.
     */
    init(
        reader: EpubReader,
        surfacePalette: ReaderThemeSurfacePalette,
        onBack: @escaping () -> Void,
        onSelectKey: @escaping (String) -> Void
    ) {
        self.reader = reader
        self.surfacePalette = surfacePalette
        self.onBack = onBack
        self.onSelectKey = onSelectKey
    }

    /** Builds Android's loading or flat TOC list and applies its empty-TOC fallback. */
    var body: some View {
        AndroidActivityScreen(
            title: String(localized: "general_book", defaultValue: "Book"),
            accessibilityIdentifier: "epubBrowserTopAppBar",
            palette: surfacePalette,
            onBack: onBack,
            actions: { EmptyView() }
        ) {
            Group {
                if isLoading {
                    AndroidActivityLoadingView(
                        message: String(localized: "epub_loading_toc"),
                        palette: surfacePalette,
                        accessibilityIdentifier: "epubBrowserLoadingState"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tocEntries, id: \.ordinal) { entry in
                                AndroidActivityListRow(
                                    palette: surfacePalette,
                                    accessibilityIdentifier: "epubBrowserRow::\(entry.ordinal)",
                                    action: { onSelectKey(entry.key) }
                                ) {
                                    Text(entry.title)
                                        .font(.system(size: 16))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .background(surfacePalette.backgroundColor)
                }
            }
            .task {
                let entries = reader.tableOfContents()
                tocEntries = entries
                isLoading = false
                guard entries.isEmpty else { return }
                if let firstKey = reader.firstKey() {
                    onSelectKey(firstKey)
                }
                onBack()
            }
        }
    }
}
