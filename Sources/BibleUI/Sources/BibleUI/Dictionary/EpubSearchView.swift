// EpubSearchView.swift -- Android EPUB Search and SearchResults activities

import SwiftUI
import BibleCore

/**
 Presents Android's EPUB Search, SearchResults, and SearchIndex activity lifecycle.

 The route uses the shared app-owned action bar, text input, radio rows, list rows, bottom action
 bars, anchored overflow menu, and search-syntax dialog. It deliberately avoids native iOS
 `NavigationStack`, `List`, `.searchable`, `Picker`, `Menu`, and sheet presentation. Rebuild index
 publishes a new immutable EPUB generation and hands it back to the reader owner before releasing
 the prior generation.

 Inputs:
 - immutable starting EPUB reader and Android-compatible search-mode preferences
 - reader/window palette and explicit Android Up command
 - rebuilt-generation adoption and exact-result selection callbacks

 Output: one full-viewport app-owned activity that transitions between Android lifecycle states

 Side effects:
 - saves search-mode changes, runs FTS queries, and atomically rebuilds an EPUB index on demand
 - invokes the owner when a rebuilt generation or exact result is ready

 Failure modes:
 - empty queries remain on criteria without starting work
 - query/rebuild failures use the shared app-owned error dialog and return to criteria
 - stale rebuilt-generation callbacks fail closed through the owner adoption contract
 */
struct EpubSearchView: View {
    /// Android activity represented inside the shared full-screen host.
    private enum PresentationStage: Equatable {
        case criteria
        case results
        case rebuildPrompt
        case rebuilding
    }

    /// Sendable result from detached EPUB FTS work.
    private enum SearchOutcome: Sendable {
        case success([EpubReader.SearchResult])
        case failure(String)
    }

    /// Sendable result from detached immutable-generation rebuilding.
    private enum RebuildOutcome: Sendable {
        case success(EpubReader)
        case failure(String)
    }

    /// Android-compatible persisted EPUB search-mode adapter.
    let modePreferences: SearchModePreferences

    /// Reader/workspace palette inherited by every activity stage.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Explicit owner command for leaving the complete EPUB Search flow.
    let onBack: () -> Void

    /// Owner guard that adopts only a current, identity-matching rebuilt generation.
    let onAdoptRebuiltReader: (EpubReader) -> Bool

    /// Callback invoked when the user chooses a matching BVA anchor.
    let onSelectResult: (EpubReader.SearchResult) -> Void

    /// EPUB generation used by the active criteria/results lifecycle.
    @State private var searchReader: EpubReader

    /// Current criteria query.
    @State private var searchText = ""

    /// Current anchor-level EPUB search results.
    @State private var results: [EpubReader.SearchResult] = []

    /// Android EPUB Search's phrase/all/any/raw-FTS selection.
    @State private var searchMode: EpubSearchMode

    /// Current Android activity stage.
    @State private var presentationStage: PresentationStage = .criteria

    /// Whether SearchResults is awaiting detached FTS work.
    @State private var isSearching = false

    /// Whether an immutable generation rebuild is still running.
    @State private var isRebuildingIndex = false

    /// Replaceable search task owned by the current criteria/result lifecycle.
    @State private var searchTask: Task<Void, Never>?

    /// Rebuild task intentionally allowed to finish after Continue in background or route dismissal.
    @State private var rebuildTask: Task<Void, Never>?

    /// Shared Android error-dialog message from query, rebuild, or stale owner adoption failure.
    @State private var errorMessage: String?

    /// Whether Android's feature-specific FTS5 help dialog is visible.
    @State private var showsHelp = false

    /// Whether Android's Rebuild index overflow popup is visible.
    @State private var showsOverflow = false

    /// Android requests focus whenever EPUB Search criteria resumes.
    @FocusState private var isSearchFieldFocused: Bool

    /// Appearance used only to configure the shared popup surface.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates one Android EPUB Search lifecycle.

     - Parameters:
       - reader: Immutable EPUB generation active when Search opens.
       - modePreferences: Shared Android search-mode persistence adapter.
       - surfacePalette: Palette inherited from the launching reader window.
       - onBack: Explicit command for leaving the complete Search flow.
       - onAdoptRebuiltReader: Owner guard that replaces the live generation after rebuild.
       - onSelectResult: Exact BVA-anchor navigation callback.
     - Side effects: Reads the persisted search mode during initialization.
     - Failure modes: Missing or unknown settings select Android's raw FTS mode.
     */
    init(
        reader: EpubReader,
        modePreferences: SearchModePreferences,
        surfacePalette: ReaderThemeSurfacePalette,
        onBack: @escaping () -> Void,
        onAdoptRebuiltReader: @escaping (EpubReader) -> Bool,
        onSelectResult: @escaping (EpubReader.SearchResult) -> Void
    ) {
        _searchReader = State(initialValue: reader)
        self.modePreferences = modePreferences
        self.surfacePalette = surfacePalette
        self.onBack = onBack
        self.onAdoptRebuiltReader = onAdoptRebuiltReader
        self.onSelectResult = onSelectResult
        _searchMode = State(initialValue: modePreferences.epubMode())
    }

    /** Builds the shared app-owned activity, popup, dialogs, focus, and task lifetime policy. */
    var body: some View {
        AndroidActivityScreen(
            title: navigationTitle,
            accessibilityIdentifier: "epubSearchTopAppBar",
            palette: surfacePalette,
            onBack: handleActivityBack
        ) {
            activityActions
        } content: {
            activityContent
                .overlay {
                    if showsHelp {
                        AndroidSearchHelpDialog(
                            title: criteriaTitle,
                            documentation: .sqliteFTS5,
                            accessibilityPrefix: "epubSearch",
                            onDismiss: { showsHelp = false }
                        )
                    }
                    if let errorMessage {
                        AndroidDecisionDialog(
                            title: String(
                                localized: "error_executing_search",
                                defaultValue: "Invalid search query"
                            ),
                            message: errorMessage,
                            actions: [
                                .init(
                                    id: "okay",
                                    title: String(localized: "okay", defaultValue: "OK"),
                                    style: .normal
                                ) {
                                    self.errorMessage = nil
                                    presentationStage = .criteria
                                    isSearchFieldFocused = true
                                }
                            ]
                        )
                    }
                }
        }
        .androidAnchoredPopupMenu(
            anchorID: "epubSearchOverflowAnchor",
            isPresented: $showsOverflow,
            menuWidth: 230,
            estimatedMenuHeight: 52,
            accessibilityIdentifier: "epubSearchOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "epubSearchOverflowMenuSurface",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                AndroidPopupMenuRow(
                    title: String(localized: "rebuild_index", defaultValue: "Rebuild index"),
                    accessibilityIdentifier: "epubSearchRebuildIndexAction",
                    isEnabled: !isRebuildingIndex
                ) {
                    showsOverflow = false
                    presentationStage = .rebuildPrompt
                    isSearchFieldFocused = false
                }
            }
        }
        .onAppear {
            if presentationStage == .criteria {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: searchMode) { _, mode in
            modePreferences.saveEpubMode(mode)
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
            // Android's Continue in background contract intentionally retains rebuildTask.
        }
    }

    /// Android action-bar title for criteria, results, or SearchIndex stages.
    private var navigationTitle: String {
        switch presentationStage {
        case .criteria:
            return criteriaTitle
        case .results:
            let format = String(
                localized: "search_with_results2",
                defaultValue: "%1$@ results in %2$@"
            )
            return String(
                format: format,
                locale: .current,
                String(results.count),
                searchReader.initials
            )
        case .rebuildPrompt, .rebuilding:
            return String(localized: "search_index", defaultValue: "Search index")
        }
    }

    /// Android `search_in` title with locale-positioned EPUB abbreviation.
    private var criteriaTitle: String {
        let format = String(localized: "search_in", defaultValue: "Find in %@")
        return String(format: format, locale: .current, searchReader.initials)
    }

    /// Android promoted Help plus overflow commands, visible only on criteria.
    @ViewBuilder
    private var activityActions: some View {
        if presentationStage == .criteria {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivityHelp"),
                accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                accessibilityIdentifier: "epubSearchHelpAction",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showsHelp = true }
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "more_options", defaultValue: "More options"),
                accessibilityIdentifier: "epubSearchOverflowAction",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showsOverflow.toggle() }
            )
            .androidPopupMenuAnchor(id: "epubSearchOverflowAnchor")
        }
    }

    /// Selects the exact Android activity content for the current stage.
    @ViewBuilder
    private var activityContent: some View {
        switch presentationStage {
        case .criteria:
            criteriaContent
        case .results:
            resultsContent
        case .rebuildPrompt:
            rebuildPromptContent
        case .rebuilding:
            rebuildingContent
        }
    }

    /// Android `epub_search.xml`: input, four vertical radio rows, and bottom Search command.
    private var criteriaContent: some View {
        VStack(spacing: 0) {
            AndroidActivityTextInput(
                placeholder: String(localized: "help_search_title", defaultValue: "Search"),
                text: $searchText,
                foregroundColor: surfacePalette.foregroundColor,
                backgroundColor: surfacePalette.controlFillColor,
                borderColor: surfacePalette.inactiveBorderColor,
                accessibilityIdentifier: "epubSearchTextField",
                focus: $isSearchFieldFocused,
                usesSearchSubmitLabel: true,
                onSubmit: performSearch
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchModeRow(
                        title: String(localized: "search_all_words", defaultValue: "All words"),
                        value: .allWords,
                        identifier: "epubSearchAllWordsOption"
                    )
                    searchModeRow(
                        title: String(localized: "search_any_word", defaultValue: "Any word"),
                        value: .anyWords,
                        identifier: "epubSearchAnyWordsOption"
                    )
                    searchModeRow(
                        title: String(localized: "search_phrase", defaultValue: "Phrase"),
                        value: .phrase,
                        identifier: "epubSearchPhraseOption"
                    )
                    searchModeRow(
                        title: String(
                            localized: "search_fts_query",
                            defaultValue: "Raw query syntax"
                        ),
                        value: .fullTextQuery,
                        identifier: "epubSearchRawQueryOption"
                    )
                }
                .padding(5)
            }
            .background(surfacePalette.backgroundColor)

            AndroidActivitySingleActionBar(
                title: String(localized: "search", defaultValue: "Search"),
                backgroundColor: surfacePalette.backgroundColor,
                accentColor: surfacePalette.controlAccentColor,
                disabledColor: surfacePalette.disabledForegroundColor,
                isEnabled: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                accessibilityIdentifier: "epubSearchSubmitButton",
                action: performSearch
            )
        }
    }

    /** Creates one shared AppCompat radio row for Android's EPUB search-mode group. */
    private func searchModeRow(
        title: String,
        value: EpubSearchMode,
        identifier: String
    ) -> some View {
        AndroidRadioRow(
            title: title,
            value: value,
            selection: $searchMode,
            foregroundColor: surfacePalette.foregroundColor,
            secondaryColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor,
            accessibilityIdentifier: identifier
        )
    }

    /// Android `list.xml`: loading/empty/two-line rows plus the persistent Close action.
    private var resultsContent: some View {
        VStack(spacing: 0) {
            Group {
                if isSearching {
                    AndroidActivityLoadingView(
                        message: String(localized: "searching", defaultValue: "Searching…"),
                        palette: surfacePalette,
                        accessibilityIdentifier: "epubSearchResultsLoadingState"
                    )
                } else if results.isEmpty {
                    AndroidActivityEmptyListView(
                        title: String(localized: "empty_list", defaultValue: "No items to display"),
                        palette: surfacePalette,
                        accessibilityIdentifier: "epubSearchResultsEmptyState"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { result in
                                AndroidActivityListRow(
                                    palette: surfacePalette,
                                    accessibilityIdentifier: "epubSearchResultRow::\(result.id)",
                                    action: { onSelectResult(result) }
                                ) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.title)
                                            .font(.system(size: 16))
                                            .lineLimit(1)
                                        highlightedSnippet(result.snippetSegments)
                                            .font(.system(size: 14))
                                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                    .background(surfacePalette.backgroundColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            AndroidActivitySingleActionBar(
                title: String(localized: "close", defaultValue: "Close"),
                backgroundColor: surfacePalette.backgroundColor,
                accentColor: surfacePalette.controlAccentColor,
                disabledColor: surfacePalette.disabledForegroundColor,
                isEnabled: true,
                accessibilityIdentifier: "epubSearchResultsCloseButton",
                action: onBack
            )
        }
    }

    /// Android SearchIndex confirmation activity shown before destructive rebuilding begins.
    private var rebuildPromptContent: some View {
        VStack(spacing: 0) {
            let format = String(
                localized: "rebuild_index_for",
                defaultValue: "Rebuild index for %@?"
            )
            Text(String(format: format, locale: .current, searchReader.title))
                .font(.system(size: 17))
                .foregroundStyle(surfacePalette.foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)

            Spacer(minLength: 0)

            AndroidActivityCommitBar(
                dismissTitle: String(localized: "cancel", defaultValue: "Cancel"),
                commitTitle: String(localized: "rebuild_index_button", defaultValue: "Rebuild"),
                backgroundColor: surfacePalette.backgroundColor,
                accentColor: surfacePalette.controlAccentColor,
                disabledColor: surfacePalette.disabledForegroundColor,
                isCommitEnabled: true,
                accessibilityPrefix: "epubSearchRebuildPrompt",
                onDismiss: {
                    presentationStage = .criteria
                    isSearchFieldFocused = true
                },
                onCommit: beginIndexRebuild
            )
        }
    }

    /// Android SearchIndexProgressStatus activity with Continue in background behavior.
    private var rebuildingContent: some View {
        VStack(spacing: 0) {
            Text(String(
                localized: "task_kill_warning",
                defaultValue: "These long running tasks may terminate if you switch to another application before they finish."
            ))
            .font(.system(size: 16))
            .foregroundStyle(surfacePalette.foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            AndroidActivityLoadingView(
                message: String(localized: "please_wait", defaultValue: "Please wait…"),
                palette: surfacePalette,
                accessibilityIdentifier: "epubSearchRebuildProgress"
            )

            AndroidActivitySingleActionBar(
                title: String(
                    localized: "do_in_background",
                    defaultValue: "Continue in background"
                ),
                backgroundColor: surfacePalette.backgroundColor,
                accentColor: surfacePalette.controlAccentColor,
                disabledColor: surfacePalette.disabledForegroundColor,
                isEnabled: true,
                accessibilityIdentifier: "epubSearchRebuildBackgroundButton"
            ) {
                presentationStage = .criteria
                isSearchFieldFocused = true
            }
        }
    }

    /** Implements Android Up across SearchResults and SearchIndex activity stages. */
    private func handleActivityBack() {
        showsHelp = false
        showsOverflow = false
        switch presentationStage {
        case .criteria:
            onBack()
        case .results, .rebuildPrompt, .rebuilding:
            presentationStage = .criteria
            isSearchFieldFocused = true
        }
    }

    /**
     Executes one trimmed EPUB query and transitions immediately into Android SearchResults.

     - Side effects: Cancels prior query work, snapshots the active immutable reader/mode, runs FTS
       off the main actor, and publishes results or an app-owned error dialog on the main actor.
     - Failure modes: Empty input is ignored; cancellation discards its outcome; compiler/SQLite
       failures return to criteria only after the user acknowledges the visible Android dialog.
     */
    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        let reader = searchReader
        let mode = searchMode
        results = []
        isSearching = true
        isSearchFieldFocused = false
        presentationStage = .results
        searchTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return SearchOutcome.success(
                        try reader.searchResults(query: query, epubMode: mode)
                    )
                } catch {
                    return SearchOutcome.failure(error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let found):
                results = found
                isSearching = false
            case .failure(let message):
                results = []
                isSearching = false
                errorMessage = message
            }
        }
    }

    /**
     Starts Android's explicit Rebuild index operation through immutable generation publication.

     - Side effects: Cancels Search work, enters the progress activity, rebuilds off the main actor,
       then asks the reader owner to adopt and re-render the replacement generation.
     - Failure modes: Filesystem/index errors and stale owner identity present the shared error
       dialog. Continue in background hides only progress; it never cancels publication.
     */
    private func beginIndexRebuild() {
        guard !isRebuildingIndex else { return }
        searchTask?.cancel()
        searchTask = nil
        results = []
        isSearching = false
        isRebuildingIndex = true
        presentationStage = .rebuilding
        let identifier = searchReader.identifier
        rebuildTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return RebuildOutcome.success(
                        try EpubReader.rebuildSearchIndex(identifier: identifier)
                    )
                } catch {
                    return RebuildOutcome.failure(error.localizedDescription)
                }
            }.value
            switch outcome {
            case .success(let rebuiltReader):
                guard onAdoptRebuiltReader(rebuiltReader) else {
                    isRebuildingIndex = false
                    presentationStage = .criteria
                    errorMessage = String(
                        localized: "error_occurred",
                        defaultValue: "An error has occurred"
                    )
                    return
                }
                searchReader = rebuiltReader
                isRebuildingIndex = false
                if presentationStage == .rebuilding {
                    presentationStage = .criteria
                    isSearchFieldFocused = true
                }
            case .failure(let message):
                isRebuildingIndex = false
                presentationStage = .criteria
                errorMessage = message
            }
            rebuildTask = nil
        }
    }

    /**
     Builds source-preserving emphasized EPUB search text from trust-typed segments.

     - Parameter segments: Plain source runs with emphasis derived from per-request SQLite markers.
     - Returns: Original EPUB text with matched runs bolded.
     - Side effects: None.
     - Failure modes: Empty segments render empty text; authored markup remains literal text.
     */
    private func highlightedSnippet(_ segments: [EpubSearchSnippetSegment]) -> Text {
        segments.reduce(Text("")) { result, segment in
            result + Text(segment.text).fontWeight(segment.isEmphasized ? .bold : .regular)
        }
    }
}
