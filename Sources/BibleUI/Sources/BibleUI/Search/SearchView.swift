// SearchView.swift — Full-text search with FTS5 index support
//
// Matches Android's search UX: checks for search index, prompts creation if
// missing, shows progress during indexing, then enables fast FTS5 searching.

import SwiftUI
import BibleCore
import SwordKit

/// One-shot UI-test launch query consumed by Search regardless of which presenter opens it.
enum UITestSearchQuerySeed {
    private static var didConsume = false

    static func consume() -> String? {
        guard !didConsume,
              let query = resolveLaunchQuery()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return nil
        }
        didConsume = true
        return query
    }

    private static func resolveLaunchQuery() -> String? {
        if let environmentQuery = ProcessInfo.processInfo.environment["UITEST_SEARCH_QUERY"] {
            return environmentQuery
        }

        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-UITEST_SEARCH_QUERY") else {
            return nil
        }

        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        return arguments[valueIndex]
    }
}

/**
 Full-text search interface with index management, scope filters, and multi-translation support.

 State machine:
 - `checkingIndex`: inspect whether the active module already has an FTS index
 - `needsIndex`: prompt the user to create the index
 - `creatingIndex`: show live progress from `SearchIndexService`
 - `ready`: render search options and results

 Data dependencies:
 - `swordModule` provides the primary SWORD search target and compatibility fallback
 - `searchIndexSourceRegistry` resolves SWORD and Android-compatible SQLite selections exactly
 - `searchIndexService` provides FTS index presence checks, index creation, and indexed search
 - `installedBibleModules`, `currentBook`, and `currentOsisBookId` define search scopes and
   translation-selection behavior

 Side effects:
 - `onAppear` seeds initial module selection, applies `initialQuery`, and triggers the index check
 - `startIndexCreation()` launches asynchronous index creation through `SearchIndexService`
 - `performSearch()` owns one replaceable search task and publishes only its latest generation
 - index creation uses an independent replaceable task and generation guard
 - query, option, module, navigation, and dismissal changes cancel work they make obsolete
 - `navigateTo(_:)` notifies the caller and dismisses Search with the active presentation mechanism
 */
public struct SearchView: View {
    /// Callback invoked when the user selects a search hit and wants to navigate to it.
    let onNavigate: ((SearchNavigationTarget) -> Bool)?

    /// Callback that opens every visible result match in Android's dedicated links window.
    let onOpenResultsInWindow: ((SearchGroupedResults) -> Bool)?

    /// Explicit Android Up command supplied by the owning reader destination.
    let onDismiss: (() -> Void)?

    /// Reference resolver invoked before a submitted value is treated as full-text search syntax.
    let onOpenReference: ((String) -> Bool)?

    /// Primary Sword module whose search index and results drive the screen.
    var swordModule: SwordModule?

    /// Sword manager used to resolve additional modules for translation or Strong's searches.
    var swordManager: SwordManager?

    /// Optional FTS index service used for index existence checks, creation, and indexed search.
    var searchIndexService: SearchIndexService?

    /// Immutable SWORD-first registry used to open selected backend-neutral index sources exactly.
    var searchIndexSourceRegistry: BibleSearchIndexSourceRegistry?

    /// Installed Bible modules available for multi-translation search selection.
    var installedBibleModules: [ModuleInfo]

    /// Registry-backed persistence for Android's selected Search translations preference.
    var selectionPreferences: SearchSelectionPreferences?

    /// Whether this presentation was opened by Android's Strong's Find All action.
    var isStrongsFindAll: Bool

    /// Reader/workspace-owned palette shared with every app-owned Search activity surface.
    var surfacePalette: ReaderThemeSurfacePalette

    /// Current user-visible book name used for the "current book" scope label and fallback navigation.
    var currentBook: String

    /// Current OSIS book identifier used to build SWORD scope expressions.
    var currentOsisBookId: String

    /// Current state of the search/index lifecycle.
    @State private var viewState: ViewState = .checkingIndex

    /// User-entered search text, also seeded from `initialQuery` when present.
    @State private var query = ""

    /// Whether a background search task is currently running.
    @State private var isSearching = false

    /// Canonically grouped result set shared by text and Strong's searches.
    @State private var groupedResults: SearchGroupedResults?

    /// Explicit query/index failure shown independently from a valid zero-result outcome.
    @State private var searchFailureMessage: String?

    /// Replaceable full-text/Strong's task owned by this presentation.
    @State private var searchTask: Task<Void, Never>?

    /// Normalized query represented by the current loading, result, or failure state.
    @State private var representedSearchQuery: String?

    /// Replaceable selected-module index-creation task owned by this presentation.
    @State private var indexTask: Task<Void, Never>?

    /// Latest search generation permitted to publish result, failure, and loading state.
    @State private var searchRequestGate = LatestSearchRequestGate()

    /// Latest index generation permitted to publish readiness or failure state.
    @State private var indexRequestGate = LatestSearchRequestGate()

    /// Word-match mode controlling FTS query decoration and fallback search semantics.
    @State private var wordMode: SearchWordMode = .allWords

    /// Selected search scope (whole Bible, testament, or current book).
    @State private var scopeOption: ScopeChoice = .wholeBible

    /// Presents the translation picker for multi-module search selection.
    @State private var showTranslationPicker = false

    /// Presents Android Search's feature-specific help AlertDialog.
    @State private var showSearchHelp = false

    /// Presents the Search criteria action-bar overflow popup.
    @State private var showSearchOverflow = false

    /// Distinguishes Android's criteria and SearchResults activities without native iOS routing.
    @State private var presentationStage: PresentationStage = .criteria

    /// Canonical result group identities expanded through Android's arrow-only control.
    @State private var expandedResultGroupIDs: Set<String> = []

    /// Primary document whose existing index must be deleted before Android's rebuild flow.
    @State private var forcedRebuildModuleName: String?

    /// Whether successful index validation/creation should continue into SearchResults.
    @State private var resumesSearchAfterIndex = false

    /// Installed module names selected for indexed multi-translation search.
    @State private var selectedModules: Set<String> = []

    /// Persisted module order retained separately from picker membership.
    @State private var selectedModuleOrder: [String] = []

    /// Draft module names edited inside the Android-style translation picker before OK commits.
    @State private var pendingTranslationSelection: Set<String> = []

    /// Whether the system search field currently owns focus.
    @FocusState private var isSearchFieldFocused: Bool

    /// Current system color scheme used for Android-dialog surface colors.
    @Environment(\.colorScheme) private var colorScheme

    /// Navigation-title summary of the most recent search results.
    @State private var resultSummary: String = ""

    /// Dismiss action for popping Search after result navigation.
    @Environment(\.dismiss) private var dismiss

    /**
     High-level search/index lifecycle states that drive the visible UI.
     */
    enum ViewState {
        /// Verifies whether the active module already has a searchable index.
        case checkingIndex

        /// Prompts the user to build an index for the named module.
        case needsIndex(moduleName: String, moduleDescription: String)

        /// Shows progress while `SearchIndexService` is building one or more indexes.
        case creatingIndex

        /// Shows search controls and current results.
        case ready

        /// Shows a retryable index failure without exposing a stale or absent index as ready.
        case indexFailure(moduleName: String, moduleDescription: String, message: String)
    }

    /// Search scope choices exposed in the options panel.
    enum ScopeChoice: Hashable {
        /// Search across the entire Bible.
        case wholeBible

        /// Search only the Old Testament range.
        case oldTestament

        /// Search only the New Testament range.
        case newTestament

        /// Search only the currently focused book.
        case currentBook
    }

    /** App-owned activity stage corresponding to Android Search and SearchResults. */
    enum PresentationStage: Equatable {
        /// Search criteria activity with field, radio groups, translation chooser, and submit.
        case criteria

        /// SearchResults activity with grouped verse matches and result-specific app-bar actions.
        case results
    }

    /// Optional initial query to auto-populate and execute (e.g. from "Find all occurrences").
    private var initialQuery: String

    /**
     Creates the search view for one primary module and optional index service.

     - Parameters:
       - swordModule: Primary module to search and to use for index checks.
       - swordManager: Manager used to resolve additional modules for multi-search or Strong's.
       - searchIndexService: Optional index service providing FTS-backed search and indexing.
       - searchIndexSourceRegistry: SWORD-first source snapshot for exact backend resolution.
       - installedBibleModules: Installed Bible modules available to the translation picker.
       - currentBook: Current user-visible book name for the current-book search scope.
       - currentOsisBookId: Current OSIS book identifier for SWORD scope construction.
       - selectionPreferences: Registry-backed selected-translation persistence.
       - isStrongsFindAll: Whether this presentation must use Android's isolated Strong's-capable
         selection and preference key.
       - surfacePalette: Reader/workspace-owned activity and content palette.
       - initialQuery: Optional query to prefill and auto-run on appear.
       - onOpenReference: Resolver invoked before full-text query compilation.
       - onNavigate: Callback returning true only when the selected hit was opened successfully.
       - onOpenResultsInWindow: Callback returning true after the complete grouped result set opens
         in Android's links window.
       - onDismiss: Explicit Android Up command supplied by the reader destination.
     - Note: Initialization has no side effects. Index checks and optional auto-search begin in
       `onAppear`.
     */
    init(
        swordModule: SwordModule? = nil,
        swordManager: SwordManager? = nil,
        searchIndexService: SearchIndexService? = nil,
        searchIndexSourceRegistry: BibleSearchIndexSourceRegistry? = nil,
        installedBibleModules: [ModuleInfo] = [],
        currentBook: String = "Genesis",
        currentOsisBookId: String = "Gen",
        selectionPreferences: SearchSelectionPreferences? = nil,
        isStrongsFindAll: Bool = false,
        surfacePalette: ReaderThemeSurfacePalette,
        initialQuery: String = "",
        onOpenReference: ((String) -> Bool)? = nil,
        onNavigate: ((SearchNavigationTarget) -> Bool)? = nil,
        onOpenResultsInWindow: ((SearchGroupedResults) -> Bool)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.swordModule = swordModule
        self.swordManager = swordManager
        self.searchIndexService = searchIndexService
        self.searchIndexSourceRegistry = searchIndexSourceRegistry
        self.installedBibleModules = installedBibleModules
        self.currentBook = currentBook
        self.currentOsisBookId = currentOsisBookId
        self.selectionPreferences = selectionPreferences
        self.isStrongsFindAll = isStrongsFindAll
        self.surfacePalette = surfacePalette
        self.initialQuery = initialQuery
        self.onOpenReference = onOpenReference
        self.onNavigate = onNavigate
        self.onOpenResultsInWindow = onOpenResultsInWindow
        self.onDismiss = onDismiss
    }

    /**
     Preserves the package's public standalone Search initializer with the global default palette.

     Reader-owned production routing uses the internal palette-aware initializer above. External
     package clients retain the original API and never need access to the reader's internal palette
     value type.
     */
    public init(
        swordModule: SwordModule? = nil,
        swordManager: SwordManager? = nil,
        searchIndexService: SearchIndexService? = nil,
        searchIndexSourceRegistry: BibleSearchIndexSourceRegistry? = nil,
        installedBibleModules: [ModuleInfo] = [],
        currentBook: String = "Genesis",
        currentOsisBookId: String = "Gen",
        selectionPreferences: SearchSelectionPreferences? = nil,
        isStrongsFindAll: Bool = false,
        initialQuery: String = "",
        onOpenReference: ((String) -> Bool)? = nil,
        onNavigate: ((SearchNavigationTarget) -> Bool)? = nil
    ) {
        self.init(
            swordModule: swordModule,
            swordManager: swordManager,
            searchIndexService: searchIndexService,
            searchIndexSourceRegistry: searchIndexSourceRegistry,
            installedBibleModules: installedBibleModules,
            currentBook: currentBook,
            currentOsisBookId: currentOsisBookId,
            selectionPreferences: selectionPreferences,
            isStrongsFindAll: isStrongsFindAll,
            surfacePalette: .standard,
            initialQuery: initialQuery,
            onOpenReference: onOpenReference,
            onNavigate: onNavigate,
            onOpenResultsInWindow: nil,
            onDismiss: nil
        )
    }

    /**
     Builds the search UI for the current `viewState`.

     The body switches between Android's Search and SearchResults activities, keeps index lifecycle
     content inside that same app-owned shell, and presents shared popup/dialog components.
     */
    public var body: some View {
        AndroidActivityScreen(
            title: navigationTitle,
            accessibilityIdentifier: "searchActivityAppBar",
            palette: surfacePalette,
            onBack: handleActivityBack
        ) {
            searchActivityActions
        } content: {
            searchActivityContent
                .overlay(alignment: .topLeading) {
                    // Export Search state through a tiny dedicated element so UI tests do not have
                    // to snapshot the full Search container while result lists are changing.
                    searchStateExport
                }
                .overlay {
                    if showTranslationPicker {
                        translationPickerOverlay
                    }
                    if showSearchHelp {
                        AndroidSearchHelpDialog(
                            title: navigationTitle,
                            onDismiss: { showSearchHelp = false }
                        )
                    }
                }
            }
        .androidAccessibilityIdentityMarker(
            label: navigationTitle,
            accessibilityIdentifier: "searchScreen",
            accessibilityValue: searchAccessibilityValue,
            surfaceColor: surfacePalette.backgroundColor
        )
        .androidAnchoredPopupMenu(
            anchorID: "searchOverflowAnchor",
            isPresented: $showSearchOverflow,
            menuWidth: 230,
            estimatedMenuHeight: 52,
            accessibilityIdentifier: "searchOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "searchOverflowMenuSurface",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                if presentationStage == .results {
                    AndroidPopupMenuRow(
                        title: String(localized: "open_in_window", defaultValue: "Open in window"),
                        accessibilityIdentifier: "searchOpenResultsInWindowAction"
                    ) {
                        showSearchOverflow = false
                        openResultsInWindow()
                    }
                } else {
                    AndroidPopupMenuRow(
                        title: String(localized: "rebuild_index", defaultValue: "Rebuild index"),
                        accessibilityIdentifier: "searchRebuildIndexAction"
                    ) {
                        showSearchOverflow = false
                        beginRebuildIndexFlow()
                    }
                }
            }
        }
        .onAppear {
            restoreSelectedModules()
            let seededInitialQuery = initialQuery.isEmpty ? (UITestSearchQuerySeed.consume() ?? "") : initialQuery
            let didApplySeed = applyInitialQueryIfNeeded(seededInitialQuery)
            checkIndex(autoSearchWhenReady: didApplySeed)
        }
        .onChange(of: initialQuery) { _, newValue in
            let didApply = applyInitialQueryIfNeeded(newValue)
            if didApply {
                checkIndex(autoSearchWhenReady: true)
            }
        }
        .onChange(of: query) { _, newValue in
            guard Self.shouldInvalidateSearch(
                representedQuery: representedSearchQuery,
                changedQuery: newValue
            ) else {
                return
            }
            cancelSearchWork(clearPublishedState: true)
            self.representedSearchQuery = nil
        }
        .onChange(of: selectedModules) { _, _ in
            checkIndex(autoSearchWhenReady: presentationStage == .results)
        }
        .onDisappear(perform: cancelAllAsyncWork)
    }

    /// Android activity title derived from index lifecycle and criteria/results stage.
    private var navigationTitle: String {
        switch viewState {
        case .needsIndex, .creatingIndex, .indexFailure:
            return String(localized: "search_index")
        case .ready:
            if presentationStage == .results, !resultSummary.isEmpty {
                return resultSummary
            }
            if let mod = swordModule {
                let format = String(
                    localized: "search_in",
                    defaultValue: "Find in %@"
                )
                return String(format: format, locale: .current, mod.info.name)
            }
            return String(localized: "search")
        case .checkingIndex:
            return String(localized: "search")
        }
    }

    /** Chooses Search criteria, SearchResults, or index lifecycle content inside the shared shell. */
    @ViewBuilder
    private var searchActivityContent: some View {
        switch viewState {
        case .checkingIndex:
            ProgressView(String(localized: "search_checking_index"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsIndex(let moduleName, let moduleDescription):
            indexPromptView(moduleName: moduleName, moduleDescription: moduleDescription)
        case .creatingIndex:
            indexProgressView
        case .ready:
            if presentationStage == .results {
                searchResultsContent
            } else {
                searchContent
            }
        case .indexFailure(let moduleName, let moduleDescription, let message):
            indexFailureView(
                moduleName: moduleName,
                moduleDescription: moduleDescription,
                message: message
            )
        }
    }

    /** Renders Android Search or SearchResults app-bar commands in source menu order. */
    @ViewBuilder
    private var searchActivityActions: some View {
        if case .ready = viewState {
            if presentationStage == .results {
                AndroidActivityTopAppBarIconTextActionButton(
                    title: selectedTranslationSummaryLabel,
                    icon: .asset("SearchDocuments"),
                    accessibilityLabel: String(localized: "choose_translations", defaultValue: "Choose translations"),
                    accessibilityIdentifier: "searchResultsTranslationPickerButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: openTranslationPicker
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "more_options", defaultValue: "More options"),
                    accessibilityIdentifier: "searchResultsOverflowAction",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: { showSearchOverflow.toggle() }
                )
                .androidPopupMenuAnchor(id: "searchOverflowAnchor")
            } else {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityHelp"),
                    accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                    accessibilityIdentifier: "searchHelpAction",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: { showSearchHelp = true }
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "more_options", defaultValue: "More options"),
                    accessibilityIdentifier: "searchOverflowAction",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: { showSearchOverflow.toggle() }
                )
                .androidPopupMenuAnchor(id: "searchOverflowAnchor")
            }
        }
    }

    /** Implements Android Up across nested SearchIndex and SearchResults activity states. */
    private func handleActivityBack() {
        if presentationStage == .results {
            presentationStage = .criteria
            return
        }
        closeSearch()
    }

    /** Closes the reader-owned Search destination through its explicit owner or SwiftUI fallback. */
    private func closeSearch() {
        cancelAllAsyncWork()
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    /// Android persistence lane used by this Search presentation.
    private var selectionContext: SearchTranslationSelectionContext {
        isStrongsFindAll ? .strongsFindAll : .standard
    }

    /// Installed modules Android permits this Search presentation to select.
    private var candidateSearchModules: [ModuleInfo] {
        SearchTranslationSelectionPolicy.candidateModules(
            from: installedBibleModules,
            isStrongsFindAll: isStrongsFindAll
        )
    }

    /**
     Resolves the primary module used when no persisted selection remains valid.

     Manual Search falls back to the active Bible. Strong's Find All first keeps an active
     Strong's-capable Bible, then prefers an already indexed Strong's Bible before the first
     installed eligible module, matching `SwordDocumentFacade.defaultBibleWithStrongs`.

     - Returns: Eligible fallback module initials, or `nil` when no Search candidate exists.
     - Side effects: Reads index readiness from `SearchIndexService` for Strong's fallback ranking.
     - Failure modes: Missing active metadata and an empty eligible inventory return `nil`.
     */
    private var fallbackSearchModuleName: String? {
        SearchTranslationSelectionPolicy.fallbackModuleName(
            currentModuleName: swordModule?.info.name,
            candidateModules: candidateSearchModules,
            isStrongsFindAll: isStrongsFindAll,
            isIndexed: { searchIndexService?.hasStrongsIndex(for: $0) ?? false }
        )
    }

    /**
     Returns selected modules in the execution and display order Android uses for this flow.

     Standard Search retains the existing primary-first, abbreviation-sorted contract. Strong's
     Find All preserves the order restored from its separate preference and never injects or moves
     a non-Strong's active Bible.

     - Returns: Eligible selected module initials in deterministic Android order.
     - Side effects: None.
     - Failure modes: An empty effective selection returns an empty array so index checking can
       surface the unavailable-module state instead of searching an unrelated Bible.
     */
    private var orderedSelectedModuleNames: [String] {
        if isStrongsFindAll {
            return SearchTranslationSelectionPolicy.strongsOrderedSelection(
                selectedModuleNames: selectedModules,
                rememberedOrder: selectedModuleOrder,
                candidateModules: candidateSearchModules
            )
        }
        return Self.androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: selectedModules,
            primaryModuleName: swordModule?.info.name,
            installedModules: candidateSearchModules
        )
    }

    /// Primary-first picker argument used only by manual Search.
    private var pickerPrimaryModuleName: String? {
        isStrongsFindAll ? nil : swordModule?.info.name
    }

    /**
     Deterministic XCUITest summary of the current Search screen state.

     The UI harness reads this compact value instead of walking volatile SwiftUI search-field and
     result-list hierarchies while searches rerun.

     - Returns: A semicolon-delimited state string containing lifecycle, activity stage, query,
       result, option, and focus tokens.
     - Side effects: none.
     - Failure modes: This computed export cannot fail; missing or renamed tokens break only the
       UI-test contract that consumes the value.
     */
    private var searchAccessibilityValue: String {
        let stateToken: String = switch viewState {
        case .checkingIndex: "checkingIndex"
        case .needsIndex: "needsIndex"
        case .creatingIndex: "creatingIndex"
        case .ready: "ready"
        case .indexFailure: "indexFailure"
        }
        let stageToken = presentationStage == .results ? "results" : "criteria"
        let resultCount = groupedResults?.totalHitCount ?? 0
        let baseState = "state=\(stateToken);stage=\(stageToken);query=\(query);searching=\(isSearching);results=\(resultCount);scope=\(searchScopeToken(for: scopeOption));wordMode=\(searchWordModeToken(for: wordMode));searchFieldFocused=\(isSearchFieldFocused);\(searchAccessibilityTranslationPickerToken)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }
        return "\(baseState);\(searchAccessibilitySelectionToken);\(searchAccessibilityGroupToken);rows=\(searchAccessibilityRowsToken)"
    }

    /// Stable selected-translation token exported for UI automation.
    private var searchAccessibilitySelectionToken: String {
        "selectedModules=\(selectedModules.sorted().joined(separator: ","));selectedModuleOrder=\(orderedSelectedModuleNames.joined(separator: ","))"
    }

    /**
     User-visible selected translation summary shown on the Search translation picker button.

     Android renders the committed selected translations as a comma-separated abbreviation list after
     moving the primary document to the front. iOS uses the same helper as search execution so the
     visible control, request order, and grouped result order cannot drift independently.

     - Returns: Ordered abbreviations such as `KJV, WEB`, or a localized fallback label when
       no module can be resolved.
     - Side effects: none.
     - Failure modes: Empty selection and missing primary module metadata produce the generic
       `search_translations` fallback instead of a malformed empty button.
     */
    private var selectedTranslationSummaryLabel: String {
        guard !orderedSelectedModuleNames.isEmpty else {
            return String(localized: "search_translations", defaultValue: "Translations")
        }
        return orderedSelectedModuleNames.joined(separator: ", ")
    }

    /**
     Builds the Android Search selected-translation summary label.

     Android shows the committed translation abbreviations as a comma-separated list after moving
     the active document to the front. This helper keeps the visible button label aligned with the
     same ordering helper used by search execution and grouped result summaries.

     - Parameters:
       - selectedModuleNames: Committed Search module abbreviations.
       - primaryModuleName: Current reader/search module abbreviation, preferred first.
       - installedModules: Installed Bible modules used to derive Android dialog order.
       - fallbackLabel: Localized label shown when no module can be resolved.
     - Returns: Ordered abbreviations such as `KJV, WEB`, or `fallbackLabel` for an empty
       effective selection.
     - Side effects: none.
     - Failure modes: Empty selection and missing primary module metadata return the supplied
       fallback instead of a malformed empty label.
     */
    nonisolated static func androidSelectedTranslationSummaryLabel(
        selectedModuleNames: Set<String>,
        primaryModuleName: String?,
        installedModules: [ModuleInfo],
        fallbackLabel: String
    ) -> String {
        let orderedModules = androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: selectedModuleNames,
            primaryModuleName: primaryModuleName,
            installedModules: installedModules
        )
        guard !orderedModules.isEmpty else {
            return fallbackLabel
        }
        return orderedModules.joined(separator: ", ")
    }

    /**
     Stable translation-picker presentation token exported for UI automation.
     *
     - Returns: `translationPicker=open` while Search is presenting the custom picker overlay, otherwise
       `translationPicker=closed`.
     - Side effects: none.
     - Failure modes: This computed token does not fail.
     */
    private var searchAccessibilityTranslationPickerToken: String {
        "translationPicker=\(showTranslationPicker ? "open" : "closed")"
    }

    /// Stable grouped-result totals exported for UI automation.
    private var searchAccessibilityGroupToken: String {
        Self.searchAccessibilityGroupToken(for: groupedResults)
    }

    /**
     Serializes successful grouped counts and explicit per-module failures for Search UI automation.

     - Parameter groupedResults: Current production grouped result, or `nil` before a query completes.
     - Returns: Stable semicolon-delimited group, hit, count, and failed-module tokens.
     - Side effects: None.
     - Failure modes: Missing results emit `none` sentinels; empty successes or failures emit empty values.
     */
    nonisolated static func searchAccessibilityGroupToken(
        for groupedResults: SearchGroupedResults?
    ) -> String {
        guard let groupedResults else {
            return "groupedTotal=none;groupedCounts=none;groupedFailures=none"
        }
        let counts = groupedResults.moduleCounts
            .map { "\($0.moduleName):\($0.count)" }
            .joined(separator: ",")
        let failures = groupedResults.moduleFailures
            .map(\.moduleName)
            .joined(separator: ",")
        return "groupedTotal=\(groupedResults.groups.count);groupedHitTotal=\(groupedResults.totalHitCount);groupedCounts=\(counts);groupedFailures=\(failures)"
    }

    /// Compact dedicated state export used by the UI harness instead of the full Search container.
    @ViewBuilder
    private var searchStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(searchAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("searchStateExport")
                .accessibilityLabel("searchStateExport")
                .accessibilityValue(searchAccessibilityValue)
        }
    }

    /// Stable selectable search-result row tokens exported for UI automation.
    private var searchAccessibilityRowsToken: String {
        (groupedResults?.groups ?? [])
            .prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .flatMap { group in
                group.matches.enumerated().map { index, hit in
                    let identifier = index == 0
                        ? searchResultIdentifier(for: group)
                        : searchModuleResultIdentifier(for: hit)
                    return "|\(identifier)|"
                }
            }
            .joined(separator: ",")
    }

    // MARK: - Index Prompt

    /**
     Builds the prompt shown when the active module needs an FTS index before search can proceed.

     - Parameters:
       - moduleName: Module identifier used for index creation bookkeeping.
       - moduleDescription: User-visible description shown in the prompt text.
     */
    private func indexPromptView(moduleName: String, moduleDescription: String) -> some View {
        VStack(spacing: 0) {
            Text(indexPromptMessage(moduleName: moduleName, moduleDescription: moduleDescription))
                .font(.system(size: 17))
                .foregroundStyle(surfacePalette.foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)

            Spacer()

            AndroidActivityCommitBar(
                dismissTitle: String(localized: "cancel"),
                commitTitle: forcedRebuildModuleName == moduleName
                    ? String(localized: "rebuild_index_button", defaultValue: "Rebuild")
                    : String(localized: "index_create", defaultValue: "Create"),
                backgroundColor: surfacePalette.backgroundColor,
                accentColor: surfacePalette.controlAccentColor,
                disabledColor: surfacePalette.disabledForegroundColor,
                isCommitEnabled: true,
                accessibilityPrefix: "searchIndex",
                onDismiss: cancelIndexPrompt,
                onCommit: startIndexCreation
            )
        }
    }

    /** Resolves Android's create/rebuild prompt with a locale-safe `%@` substitution. */
    private func indexPromptMessage(moduleName: String, moduleDescription: String) -> String {
        let format = forcedRebuildModuleName == moduleName
            ? String(localized: "rebuild_index_for", defaultValue: "Rebuild index for %@?")
            : String(localized: "create_index_for", defaultValue: "Create index for %@?")
        return String(format: format, locale: .current, moduleDescription)
    }

    /** Returns from Android's SearchIndex activity to preserved Search criteria without closing it. */
    private func cancelIndexPrompt() {
        cancelIndexWork()
        forcedRebuildModuleName = nil
        resumesSearchAfterIndex = false
        presentationStage = .criteria
        viewState = .ready
    }

    /**
     Builds the retryable failure state shown when index creation or verification fails.

     - Parameters:
       - moduleName: Durable module abbreviation used when retrying index creation.
       - moduleDescription: User-visible module name associated with the failure.
       - message: Concrete failure returned by the index service or module resolver.
     - Returns: A blocking error surface with Retry and Cancel actions.
     - Side effects: Retry re-enters `startIndexCreation()`; Cancel invalidates outstanding work and dismisses Search.
     - Failure modes: The view itself cannot fail and never transitions to `.ready` implicitly.
     */
    private func indexFailureView(
        moduleName: String,
        moduleDescription: String,
        message: String
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(String(localized: "error_occurred", defaultValue: "Search index failed"))
                    .font(.headline)
                Text(moduleDescription)
                    .font(.subheadline.weight(.medium))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            Spacer()

            HStack(spacing: 28) {
                Button(String(localized: "cancel")) {
                    if forcedRebuildModuleName != nil {
                        cancelIndexPrompt()
                    } else {
                        closeSearch()
                    }
                }
                .foregroundStyle(.secondary)

                Button(String(localized: "retry", defaultValue: "Retry")) {
                    viewState = .needsIndex(
                        moduleName: moduleName,
                        moduleDescription: moduleDescription
                    )
                    startIndexCreation()
                }
                .fontWeight(.semibold)
            }
            .padding(.bottom, 36)
        }
        .accessibilityIdentifier("searchIndexFailure")
        .accessibilityValue("module=\(moduleName);message=\(message)")
    }

    // MARK: - Index Progress

    /// Progress view shown while `SearchIndexService` builds one or more module indexes.
    private var indexProgressView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Text(String(localized: "search_indexing_message"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let service = searchIndexService {
                    VStack(spacing: 8) {
                        Text(
                            String(
                                format: String(
                                    localized: "creating_index_for",
                                    defaultValue: "Creating index for %@…"
                                ),
                                locale: .current,
                                service.indexingModule
                            )
                        )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if !service.indexingKey.isEmpty {
                            Text(service.indexingKey)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        ProgressView(value: service.indexProgress)
                            .tint(.accentColor)
                            .padding(.horizontal, 24)
                    }
                } else {
                    ProgressView()
                }
            }

            Spacer()
            Spacer()
        }
    }

    // MARK: - Search Content

    /// Main search UI shown once the view reaches the `.ready` state.
    private var searchContent: some View {
        VStack(spacing: 0) {
            searchCriteriaForm
            searchSubmitButton
        }
    }

    /// Stable app-owned query field used for both user input and UI automation.
    private var searchQueryBar: some View {
        AndroidActivityTextInput(
            placeholder: String(
                localized: "type_text_or_bible_reference",
                defaultValue: "Type text or Bible reference"
            ),
            text: Binding(
                get: { query },
                set: { newValue in
                    guard query != newValue else { return }
                    query = newValue
                    cancelSearchWork(clearPublishedState: true)
                }
            ),
            foregroundColor: surfacePalette.foregroundColor,
            backgroundColor: surfacePalette.controlFillColor,
            borderColor: surfacePalette.inactiveBorderColor,
            accessibilityIdentifier: "searchQueryField",
            focus: $isSearchFieldFocused,
            usesSearchSubmitLabel: true,
            usesLiteralInputBehavior: true,
            onSubmit: {
                isSearchFieldFocused = false
                performSearch()
            }
        )
        .onAppear {
            if UITestRuntimeConfiguration.shouldAutofocusSearchField {
                DispatchQueue.main.async {
                    isSearchFieldFocused = true
                }
            }
        }
    }

    // MARK: - Search Criteria Form

    /// Android-style Search criteria form shown above inline results.
    private var searchCriteriaForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchQueryBar

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 16) {
                        searchScopeRadioGroup
                        searchWordModeRadioGroup
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    searchTranslationsSection
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchOptionsPanel")
        .accessibilityValue("visible")
    }

    /// Android search-scope radio group.
    private var searchScopeRadioGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "search_bible_section_group_prompt", defaultValue: "Bible section"))
                .font(.caption)
                .foregroundStyle(surfacePalette.secondaryForegroundColor)

            searchRadioRow(
                label: String(localized: "search_scope_all", defaultValue: "All Bible"),
                isSelected: scopeOption == .wholeBible,
                identifier: searchScopeIdentifier(for: .wholeBible)
            ) {
                scopeOption = .wholeBible
            }

            searchRadioRow(
                label: String(localized: "search_scope_ot", defaultValue: "Old Testament"),
                isSelected: scopeOption == .oldTestament,
                identifier: searchScopeIdentifier(for: .oldTestament)
            ) {
                scopeOption = .oldTestament
            }

            searchRadioRow(
                label: String(localized: "search_scope_nt", defaultValue: "New Testament"),
                isSelected: scopeOption == .newTestament,
                identifier: searchScopeIdentifier(for: .newTestament)
            ) {
                scopeOption = .newTestament
            }

            searchRadioRow(
                label: currentBook,
                isSelected: scopeOption == .currentBook,
                identifier: searchScopeIdentifier(for: .currentBook)
            ) {
                scopeOption = .currentBook
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchScopeStrip")
    }

    /// Android word-matching radio group.
    private var searchWordModeRadioGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "search_words_group_prompt", defaultValue: "Words"))
                .font(.caption)
                .foregroundStyle(surfacePalette.secondaryForegroundColor)

            ForEach(SearchWordMode.allCases, id: \.self) { mode in
                searchRadioRow(
                    label: mode.rawValue,
                    isSelected: wordMode == mode,
                    identifier: "searchWordModeButton::\(searchWordModeToken(for: mode))"
                ) {
                    wordMode = mode
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    /// Android translations selector row.
    private var searchTranslationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "search_translations", defaultValue: "Translations"))
                .font(.caption)
                .foregroundStyle(surfacePalette.secondaryForegroundColor)

            Button {
                openTranslationPicker()
            } label: {
                HStack(spacing: 10) {
                    Text(selectedTranslationSummaryLabel)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil")
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("searchTranslationPickerButton")
            .accessibilityValue("\(searchAccessibilitySelectionToken);\(searchAccessibilityTranslationPickerToken)")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(surfacePalette.inactiveBorderColor)
                .frame(height: 1)
        }
    }

    /// Android-style bottom submit button for executing Search criteria.
    private var searchSubmitButton: some View {
        AndroidActivitySingleActionBar(
            title: String(localized: "search", defaultValue: "Search"),
            backgroundColor: surfacePalette.backgroundColor,
            accentColor: surfacePalette.controlAccentColor,
            disabledColor: surfacePalette.disabledForegroundColor,
            isEnabled: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            accessibilityIdentifier: "searchSubmitButton"
        ) {
            isSearchFieldFocused = false
            performSearch()
        }
    }

    /**
     Builds an Android-style radio row used by Search criteria groups.

     - Parameters:
       - label: User-visible option label.
       - isSelected: Whether this option is the active value.
       - identifier: Stable UI automation identifier for the row.
       - action: Mutation performed when the row is tapped.
     */
    private func searchRadioRow(
        label: String,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AndroidRadioRow(
            title: label,
            value: true,
            selection: Binding(
                get: { isSelected },
                set: { shouldSelect in
                    guard shouldSelect else { return }
                    action()
                }
            ),
            foregroundColor: surfacePalette.foregroundColor,
            secondaryColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor,
            titleFont: .system(size: 15),
            accessibilityIdentifier: identifier
        )
    }

    /**
     Returns a stable accessibility identifier for one Search scope selector.
     *
     * - Parameter choice: Scope value represented by the button.
     * - Returns: Identifier formatted as `searchScopeButton::<scope>`.
     * - Side effects: none.
     * - Failure modes: none.
     */
    private func searchScopeIdentifier(for choice: ScopeChoice) -> String {
        "searchScopeButton::\(searchScopeToken(for: choice))"
    }

    /**
     Returns the stable exported token for one Search scope choice.
     *
     * - Parameter choice: Scope value to serialize for accessibility state and identifiers.
     * - Returns: Deterministic lowercase token for the scope.
     * - Side effects: none.
     * - Failure modes: none.
     */
    private func searchScopeToken(for choice: ScopeChoice) -> String {
        switch choice {
        case .wholeBible:
            return "wholeBible"
        case .oldTestament:
            return "oldTestament"
        case .newTestament:
            return "newTestament"
        case .currentBook:
            return "currentBook"
        }
    }

    /**
     Returns the stable exported token for one Search word-matching mode.
     *
     * - Parameter mode: Word-mode value to serialize for accessibility state.
     * - Returns: Deterministic lowercase token for the word mode.
     * - Side effects: none.
     * - Failure modes: none.
     */
    private func searchWordModeToken(for mode: SearchWordMode) -> String {
        switch mode {
        case .allWords:
            return "allWords"
        case .anyWord:
            return "anyWord"
        case .phrase:
            return "phrase"
        }
    }

    // MARK: - Results Sections

    /**
     Renders Android's distinct SearchResults activity body without native `List` ownership.

     Loading, failure, empty, and grouped states share the owner palette and scroll container.
     Results never remain inline beneath the Search criteria form.
     */
    private var searchResultsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isSearching {
                    ProgressView(String(localized: "search_searching"))
                        .tint(surfacePalette.controlAccentColor)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else if let searchFailureMessage {
                    Text(searchFailureMessage)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .accessibilityIdentifier("searchExecutionFailure")
                } else if let groupedResults {
                    groupedResultsSection(groupedResults)
                } else {
                    Text(String(localized: "no_results"))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                }
            }
        }
        .background(surfacePalette.backgroundColor)
        .accessibilityIdentifier("searchResultsList")
    }

    /**
     Builds Android's verse-grouped result UI for text and Strong's searches.

     - Parameter grouped: Canonical verse groups with module-preserving matches and summary counts.
     - Returns: Sections containing successful module counts, explicit module failures, and one
       expandable-equivalent match group per canonical verse.
     - Side effects: Selecting a module match calls `navigateTo(_:)` with that exact hit.
     - Failure modes: Empty result collections render no sections; the caller owns the empty state.
     */
    private func groupedResultsSection(_ grouped: SearchGroupedResults) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if !grouped.moduleFailures.isEmpty {
                ForEach(grouped.moduleFailures) { failure in
                    HStack(alignment: .top, spacing: 10) {
                        AndBibleIconView(name: "ActivityErrorOutline", size: 24)
                            .foregroundStyle(Color.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(failure.moduleName)
                                .font(.system(size: 16, weight: .semibold))
                            Text(failure.message)
                                .font(.system(size: 14))
                                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        }
                    }
                    .padding(12)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "searchModuleFailure::\(sanitizedAccessibilitySegment(failure.moduleName))"
                    )
                    searchResultDivider
                }
            }

            if grouped.groups.isEmpty {
                Text(String(localized: "no_results"))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ForEach(grouped.groups) { group in
                    searchResultGroup(group)
                    searchResultDivider
                }
            }

            if grouped.isTruncated {
                Text(String(
                    localized: "search_results_truncated",
                    defaultValue: "More than 5,000 results were found in at least one translation."
                ))
                .font(.system(size: 14))
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .padding(12)
                .accessibilityIdentifier("searchResultsTruncated")
            }
        }
    }

    /**
     Builds Android `multi_search_result_item`: tappable header, translation pills, and arrow-only
     expansion for multi-translation verses.

     - Parameter group: Canonical verse and ordered module matches to render.
     - Returns: Unframed grouped rows preserving module identity through user selection.
     - Side effects: A module row invokes `navigateTo(_:)` with the selected module hit.
     - Failure modes: A malformed empty group renders only its canonical reference and no action.
     */
    private func searchResultGroup(_ group: SearchGroupedVerseResult) -> some View {
        let isSingleMatch = group.matches.count == 1
        let isExpanded = expandedResultGroupIDs.contains(group.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if !isSingleMatch {
                    Button {
                        toggleResultExpansion(group.id)
                    } label: {
                        AndBibleIconView(name: "SearchExpand", size: 24)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isExpanded
                            ? String(localized: "collapse", defaultValue: "Collapse")
                            : String(localized: "expand", defaultValue: "Expand")
                    )
                    .accessibilityIdentifier("searchResultExpand::\(sanitizedAccessibilitySegment(group.displayReference))")
                }

                if let firstMatch = group.matches.first {
                    Button(action: { navigateTo(firstMatch) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                isSingleMatch
                                    ? "\(group.displayReference) (\(firstMatch.moduleName))"
                                    : group.displayReference
                            )
                            .font(.system(size: 17))
                            .foregroundStyle(surfacePalette.foregroundColor)

                            Text(SearchIndexService.cleanText(firstMatch.snippet))
                                .font(.system(size: 14))
                                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                                .lineLimit(isSingleMatch ? nil : 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(searchResultIdentifier(for: group))
                }
            }

            if !isSingleMatch {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(group.matches) { hit in
                            Button(action: { navigateTo(hit) }) {
                                Text(hit.moduleName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(surfacePalette.foregroundColor)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(
                                        surfacePalette.controlFillColor,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(searchModuleResultIdentifier(for: hit))
                        }
                    }
                    .padding(.leading, 40)
                }
            }

            if !isSingleMatch, isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.matches) { hit in
                        Button(action: { navigateTo(hit) }) {
                            (
                                Text("\(hit.moduleName): ").bold()
                                    + Text(SearchIndexService.cleanText(hit.snippet))
                            )
                                .font(.system(size: 15))
                                .foregroundStyle(surfacePalette.foregroundColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("searchExpandedResult::\(sanitizedAccessibilitySegment(hit.id))")
                    }
                }
                .padding(.leading, 40)
                .padding(.top, 4)
            }
        }
        .padding(12)
    }

    /// Palette-owned divider shared by SearchResults rows and partial-failure rows.
    private var searchResultDivider: some View {
        Rectangle()
            .fill(surfacePalette.inactiveBorderColor)
            .frame(height: 1)
    }

    /** Toggles only the arrow-owned expansion state for one multi-translation verse. */
    private func toggleResultExpansion(_ groupID: String) {
        if expandedResultGroupIDs.contains(groupID) {
            expandedResultGroupIDs.remove(groupID)
        } else {
            expandedResultGroupIDs.insert(groupID)
        }
    }

    /**
     Returns the stable accessibility identifier for one result row.

     - Parameter group: Search group whose verse reference should back the identifier.
     - Returns: Identifier formatted as `searchResultRow::<sanitized reference>`.
     */
    private func searchResultIdentifier(for group: SearchGroupedVerseResult) -> String {
        "searchResultRow::\(sanitizedAccessibilitySegment(group.displayReference))"
    }

    /** Returns a stable module-specific identifier for non-primary matches in a verse group. */
    private func searchModuleResultIdentifier(for hit: SearchModuleHit) -> String {
        let reference = "\(hit.displayBook) \(hit.identity.chapter):\(hit.identity.verse)"
        return "searchResultModuleRow::\(sanitizedAccessibilitySegment(reference))::\(sanitizedAccessibilitySegment(hit.moduleName))"
    }

    /**
     Returns an accessibility-safe token derived from user-visible text.

     - Parameter value: Raw string that may contain spaces or punctuation.
     - Returns: Alphanumeric identifier segment with non-word runs normalized to underscores.
     */
    private func sanitizedAccessibilitySegment(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "_",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: - Translation Picker

    /** Presents Android `Dialogs.multiselect` through the shared dialog window and checkbox rows. */
    private var translationPickerOverlay: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "searchTranslationPickerOverlay",
            onOutsideTap: cancelTranslationPicker
        ) {
            AndroidMultiselectDialogContent(
                title: String(localized: "choose_translations", defaultValue: "Choose translations"),
                rows: searchTranslationPickerRows,
                selectedIDs: $pendingTranslationSelection,
                isBusy: false,
                accessibilityIdentifier: "searchTranslationPickerDialog",
                accessibilityPrefix: "searchTranslationPicker",
                onCancel: cancelTranslationPicker,
                onConfirm: { orderedModuleNames in
                    pendingTranslationSelection = Set(orderedModuleNames)
                    commitTranslationPickerSelection()
                }
            )
        }
    }

    /**
     Builds exact ordered rows for the reusable Android multiselect component.

     - Returns: Abbreviation-sorted module identities with Android's index-status suffix.
     - Side effects: Reads index readiness without mutating Search state.
     - Failure modes: Missing readiness is represented as not indexed, matching Search's fail-closed
       index gate.
     */
    private var searchTranslationPickerRows: [AndroidMultiselectDialogRow<String>] {
        Self.androidSortedTranslationModules(candidateSearchModules).map { module in
            AndroidMultiselectDialogRow(
                id: module.name,
                title: Self.androidTranslationPickerLabel(
                    for: module,
                    isIndexed: isTranslationModuleIndexed(module.name),
                    unindexedStatus: String(
                        localized: "search_index_not_created",
                        defaultValue: "Search index not created"
                    )
                ),
                accessibilityIdentifier: "searchTranslationRow::\(sanitizedAccessibilitySegment(module.name))"
            )
        }
    }

    /**
     Opens the Search translation picker with a draft that mirrors Android prechecked rows.

     Android loads the existing saved/current selection before presenting the multiselect dialog,
     then lets the dialog mutate temporary checked state until an action is pressed. This method
     seeds that draft from the committed iOS Search selection and the current primary module.

     Side effects:
     - clears Search field focus so the dialog is not obscured by the keyboard
     - mutates `pendingTranslationSelection`
     - sets `showTranslationPicker` to present the overlay

     Failure modes:
     - if no committed selection and no primary module exist, the draft is empty and OK will leave
       the committed Search selection unchanged.
     */
    private func openTranslationPicker() {
        isSearchFieldFocused = false
        let draftState = SearchTranslationPickerDraftState.opened(
            selectedModuleNames: selectedModules,
            primaryModuleName: pickerPrimaryModuleName,
            installedModules: candidateSearchModules
        )
        pendingTranslationSelection = draftState.pendingSelection
        showTranslationPicker = draftState.isPresented
    }

    /**
     Dismisses the Search translation picker without committing the draft selection.

     Android's dialog Cancel path returns an empty result and leaves the existing selected
     translations untouched. iOS mirrors that by clearing only the draft state.

     Side effects:
     - clears `pendingTranslationSelection`
     - sets `showTranslationPicker` to false
     */
    private func cancelTranslationPicker() {
        let draftState = SearchTranslationPickerDraftState(
            isPresented: showTranslationPicker,
            pendingSelection: pendingTranslationSelection
        ).cancelled()
        pendingTranslationSelection = draftState.pendingSelection
        showTranslationPicker = draftState.isPresented
    }

    /**
     Commits the Search translation picker draft according to Android's non-empty result contract.

     Android ignores an empty selected result, including the case where the user presses OK after
     toggling all rows off. This method preserves the previous selection for empty drafts, otherwise
     it commits the draft while preserving the primary module first for downstream search ordering.

     Side effects:
     - may mutate `selectedModules`
     - clears the draft and dismisses the overlay
     - triggers the existing `selectedModules` change observer when the committed set changes
     */
    private func commitTranslationPickerSelection() {
        let shouldCommitSelection = !pendingTranslationSelection.isEmpty
        let result = SearchTranslationPickerDraftState(
            isPresented: showTranslationPicker,
            pendingSelection: pendingTranslationSelection
        ).committedSelection(
            previousModuleNames: selectedModules,
            primaryModuleName: pickerPrimaryModuleName,
            installedModules: candidateSearchModules
        )
        let orderedSelection = result.orderedModuleNames
        if shouldCommitSelection, !orderedSelection.isEmpty {
            selectedModules = Set(orderedSelection)
            selectedModuleOrder = orderedSelection
            selectionPreferences?.saveSelection(orderedSelection, context: selectionContext)
        }
        pendingTranslationSelection = result.draftState.pendingSelection
        showTranslationPicker = result.draftState.isPresented
    }

    /**
     Restores Android's persisted Search translation selection for the installed module set.

     The persisted order is retained by `SearchSelectionPreferences`; this view stores membership in
     a `Set` and reuses `androidOrderedSelectedSearchModuleNames` whenever request order matters.

     - Side effects: Reads the shared settings store and updates `selectedModules`.
     - Failure modes: Missing persistence or a stale selection falls back to the installed primary
       module. No unavailable module is retained.
     */
    private func restoreSelectedModules() {
        let installedNames = candidateSearchModules.map(\.name)
        let primaryName = fallbackSearchModuleName
        let restored = selectionPreferences?.loadSelection(
            installedModuleNames: installedNames,
            primaryModuleName: primaryName,
            context: selectionContext
        ) ?? primaryName.map { [$0] } ?? []
        selectedModules = Set(restored)
        selectedModuleOrder = restored
    }

    /**
     Resolves whether one module has a completed Search index for picker labeling.

     Android appends "Search index not created" when JSword reports an index status other than
     done. A missing iOS index service is not treated as indexed because Search has no compatible
     fallback query engine.

     - Parameter moduleName: SWORD module abbreviation to inspect.
     - Returns: `true` when the module should render without the unindexed suffix.
     - Side effects: Reads Search index metadata through `SearchIndexService`.
     */
    private func isTranslationModuleIndexed(_ moduleName: String) -> Bool {
        guard let source = resolveSearchIndexSource(named: moduleName) else { return false }
        return searchIndexService?.hasIndex(for: source.searchIndexSourceIdentity) ?? false
    }

    // MARK: - Navigation

    /**
     Forwards the selected result and dismisses Search only after exact navigation succeeds.

     - Parameter hit: Selected search result.
     - Side effects: Cancels Search work and dismisses the presentation after caller confirmation.
     - Failure modes: A missing callback or rejected target leaves Search and its results visible.
     */
    private func navigateTo(_ hit: SearchModuleHit) {
        guard onNavigate?(SearchNavigationTarget(hit: hit)) == true else { return }
        closeSearch()
    }

    /** Opens the complete currently displayed result set in Android's dedicated links window. */
    private func openResultsInWindow() {
        guard let groupedResults,
              onOpenResultsInWindow?(groupedResults) == true else {
            return
        }
        closeSearch()
    }

    // MARK: - Index Management

    /**
     Opens Android's SearchIndex activity state for the current primary document.

     The existing index is not deleted until the explicit Rebuild action. Cancel therefore returns
     to unchanged Search criteria, matching Android's separate activity lifecycle.
     */
    private func beginRebuildIndexFlow() {
        guard let moduleName = fallbackSearchModuleName,
              resolveSearchIndexSource(named: moduleName) != nil else {
            let name = fallbackSearchModuleName ?? String(localized: "search", defaultValue: "Search")
            viewState = .indexFailure(
                moduleName: name,
                moduleDescription: moduleDescription(for: name),
                message: String(
                    localized: "error_occurred",
                    defaultValue: "An error has occurred"
                )
            )
            return
        }
        forcedRebuildModuleName = moduleName
        presentationStage = .criteria
        viewState = .needsIndex(
            moduleName: moduleName,
            moduleDescription: moduleDescription(for: moduleName)
        )
    }

    /**
     Checks whether the selected search target modules already have indexes.

     Android checks every selected translation's JSword index before launching text or Strong's
     searches. iOS applies the same selected-module list and prompts for the first missing index.

     Side effects:
     - mutates `viewState` to `.ready`, `.needsIndex`, or `.indexFailure`
     - resumes the explicitly submitted or externally seeded search when the UI becomes ready
     - reads index availability from `SearchIndexService`

     Failure modes:
     - a missing index service or empty effective module selection becomes an explicit retryable
       failure instead of exposing Search as ready
     */
    private func checkIndex(autoSearchWhenReady: Bool) {
        cancelSearchWork(clearPublishedState: true)
        cancelIndexWork()
        resumesSearchAfterIndex = autoSearchWhenReady
        let fallbackModuleName = fallbackSearchModuleName ?? swordModule?.info.name ?? "Search"
        guard let service = searchIndexService else {
            viewState = .indexFailure(
                moduleName: fallbackModuleName,
                moduleDescription: moduleDescription(for: fallbackModuleName),
                message: SearchIndexError.databaseUnavailable(
                    operation: "checking selected translations"
                ).localizedDescription
            )
            return
        }

        let moduleNames = orderedSelectedModuleNames
        guard !moduleNames.isEmpty else {
            viewState = .indexFailure(
                moduleName: fallbackModuleName,
                moduleDescription: moduleDescription(for: fallbackModuleName),
                message: isStrongsFindAll
                    ? String(
                        localized: "no_indexed_bible_with_strongs_ref",
                        defaultValue: "You must download a Bible containing Strong's numbers and build its index via Search"
                    )
                    : "No installed Bible translation is available for Search."
            )
            return
        }

        guard let selectedSources = resolveSearchIndexSources(named: moduleNames) else {
            viewState = .indexFailure(
                moduleName: fallbackModuleName,
                moduleDescription: moduleDescription(for: fallbackModuleName),
                message: "A selected translation could not be opened for index verification."
            )
            return
        }

        let requirement = Self.indexRequirement(for: query)
        if let missingModuleName = service.modulesNeedingIndex(
            from: selectedSources.map { $0.source.searchIndexSourceIdentity },
            requirement: requirement
        ).first?.moduleName {
            viewState = .needsIndex(
                moduleName: missingModuleName,
                moduleDescription: moduleDescription(for: missingModuleName)
            )
        } else {
            viewState = .ready
            resumeSearchAfterIndexIfNeeded()
        }
    }

    /**
     Resolves a user-visible description for one installed module name.

     - Parameter moduleName: SWORD module abbreviation to describe.
     - Returns: Module description when available, otherwise the module abbreviation.
     */
    private func moduleDescription(for moduleName: String) -> String {
        if let info = installedBibleModules.first(where: { $0.name == moduleName }) {
            return info.description.isEmpty ? info.name : info.description
        }
        if let mod = swordModule, mod.info.name == moduleName {
            return mod.info.description.isEmpty ? mod.info.name : mod.info.description
        }
        if let mod = swordManager?.module(named: moduleName) {
            return mod.info.description.isEmpty ? mod.info.name : mod.info.description
        }
        return moduleName
    }

    /**
     Auto-executes a search once the view becomes ready and a non-empty query is already present.

     This covers both externally seeded queries and text the user entered while the view was still
     waiting on index readiness.
     */
    private func resumeSearchAfterIndexIfNeeded() {
        let shouldResume = resumesSearchAfterIndex
        resumesSearchAfterIndex = false
        if shouldResume, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            performSearch()
        }
    }

    /**
     Seeds the query field from an externally provided initial query when it changes meaningfully.

     - Parameter value: Proposed initial query passed in from the presenting screen.
     - Returns: `true` when the helper updated the visible query field, otherwise `false`.
     - Side effects:
     *   - mutates `query` when `value` is non-empty and differs from the current field content
     - Failure modes:
     *   - ignores empty values and duplicate assignments so repeated parent re-renders do not
     *     restart the search loop unnecessarily
     */
    private func applyInitialQueryIfNeeded(_ value: String) -> Bool {
        guard !value.isEmpty, query != value else { return false }
        query = value
        return true
    }

    /**
     Starts asynchronous index creation for the modules required by the current query.

     Text and Strong's searches index the same selected translations, matching Android's pre-search
     `IndexStatus.DONE` gate. Once every requested index is built and verified, the view becomes
     ready and resumes an initial query.

     Side effects:
     - mutates `viewState` to `.creatingIndex` and later back to `.ready`
     - queries `SearchIndexService` and the backend-neutral registry for sources requiring indexes
     - launches asynchronous index creation work for each queued module

     Failure modes:
     - a missing service, unresolved selected module, thrown creation error, or failed post-create
       verification transitions to `.indexFailure` and never exposes stale Search results
     */
    private func startIndexCreation() {
        if let forcedRebuildModuleName {
            startForcedIndexRebuild(moduleName: forcedRebuildModuleName)
            return
        }
        cancelSearchWork(clearPublishedState: true)
        cancelIndexWork()
        let fallbackModuleName = fallbackSearchModuleName ?? swordModule?.info.name ?? "Search"
        guard let service = searchIndexService else {
            viewState = .indexFailure(
                moduleName: fallbackModuleName,
                moduleDescription: moduleDescription(for: fallbackModuleName),
                message: SearchIndexError.databaseUnavailable(
                    operation: "creating selected translation indexes"
                ).localizedDescription
            )
            return
        }

        let selectedNames = orderedSelectedModuleNames
        guard let selectedSources = resolveSearchIndexSources(named: selectedNames) else {
            viewState = .indexFailure(
                moduleName: fallbackModuleName,
                moduleDescription: moduleDescription(for: fallbackModuleName),
                message: "A selected translation could not be opened for indexing."
            )
            return
        }
        let requirement = Self.indexRequirement(for: query)
        let missingIdentities = service.modulesNeedingIndex(
            from: selectedSources.map { $0.source.searchIndexSourceIdentity },
            requirement: requirement
        )
        let missingNames = missingIdentities.map(\.moduleName)
        var sourcesToIndex: [(source: any BibleSearchIndexSource, name: String)] = []
        for identity in missingIdentities {
            guard let source = selectedSources.first(where: {
                $0.name == identity.moduleName
                    && $0.source.searchIndexSourceIdentity == identity
            })?.source else {
                viewState = .indexFailure(
                    moduleName: identity.moduleName,
                    moduleDescription: moduleDescription(for: identity.moduleName),
                    message: "The selected translation could not be opened for indexing."
                )
                return
            }
            sourcesToIndex.append((source, identity.moduleName))
        }

        let requestToken = indexRequestGate.begin()
        viewState = .creatingIndex

        indexTask = Task {
            var activeModuleName = missingNames.first ?? fallbackModuleName
            do {
                for item in sourcesToIndex {
                    try Task.checkCancellation()
                    activeModuleName = item.name
                    try await service.createIndex(source: item.source)
                    try Task.checkCancellation()
                    guard indexRequestGate.accepts(requestToken) else { return }
                    guard service.modulesNeedingIndex(
                        from: [item.source.searchIndexSourceIdentity],
                        requirement: requirement
                    ).isEmpty else {
                        throw SearchIndexError.indexVerificationFailed(moduleName: item.name)
                    }
                }
                try Task.checkCancellation()
                guard indexRequestGate.accepts(requestToken) else { return }
                indexTask = nil
                viewState = .ready
                resumeSearchAfterIndexIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                guard indexRequestGate.accepts(requestToken), !Task.isCancelled else { return }
                indexTask = nil
                viewState = .indexFailure(
                    moduleName: activeModuleName,
                    moduleDescription: moduleDescription(for: activeModuleName),
                    message: error.localizedDescription
                )
            }
        }
    }

    /**
     Deletes and recreates one existing primary-document index after explicit Android confirmation.

     - Parameter moduleName: Exact current document initials captured when the rebuild flow opened.
     - Side effects: Deletes only that generated index, recreates it from the exact source snapshot,
       verifies readiness, and returns to preserved Search criteria.
     - Failure modes: Missing service/source, cancellation, build errors, and failed verification
       transition to the existing retryable index failure state; source content is never deleted.
     */
    private func startForcedIndexRebuild(moduleName: String) {
        cancelSearchWork(clearPublishedState: true)
        cancelIndexWork()
        guard let service = searchIndexService,
              let source = resolveSearchIndexSource(named: moduleName) else {
            forcedRebuildModuleName = nil
            viewState = .indexFailure(
                moduleName: moduleName,
                moduleDescription: moduleDescription(for: moduleName),
                message: SearchIndexError.databaseUnavailable(
                    operation: "rebuilding \(moduleName)"
                ).localizedDescription
            )
            return
        }

        let requestToken = indexRequestGate.begin()
        viewState = .creatingIndex
        indexTask = Task {
            do {
                await service.deleteIndex(for: moduleName)
                try Task.checkCancellation()
                guard indexRequestGate.accepts(requestToken) else { return }
                try await service.createIndex(source: source)
                try Task.checkCancellation()
                guard indexRequestGate.accepts(requestToken) else { return }
                guard service.hasIndex(for: source.searchIndexSourceIdentity) else {
                    throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
                }
                indexTask = nil
                forcedRebuildModuleName = nil
                presentationStage = .criteria
                viewState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard indexRequestGate.accepts(requestToken), !Task.isCancelled else { return }
                indexTask = nil
                forcedRebuildModuleName = moduleName
                viewState = .indexFailure(
                    moduleName: moduleName,
                    moduleDescription: moduleDescription(for: moduleName),
                    message: error.localizedDescription
                )
            }
        }
    }

    /**
     Resolves one selected backend without substituting the active or another translation.

     - Parameter moduleName: Persisted selected initials or JSword-compatible full name.
     - Returns: Exact SWORD/SQLite source from the presentation snapshot, with the historical SWORD
       fallback retained for standalone Search construction.
     - Side effects: None.
     - Failure modes: Missing, stale, and category-incompatible identities return nil.
     */
    private func resolveSearchIndexSource(
        named moduleName: String
    ) -> (any BibleSearchIndexSource)? {
        if let searchIndexSourceRegistry {
            return searchIndexSourceRegistry.source(named: moduleName)
        }
        if swordModule?.info.name == moduleName {
            return swordModule
        }
        return swordManager?.module(named: moduleName)
    }

    /**
     Resolves every selected module to one exact source snapshot without fallback substitution.

     - Parameter moduleNames: Ordered selected module initials.
     - Returns: Ordered source/name pairs, or `nil` if any selected identity is unavailable.
     - Side effects: None; source metadata may read bounded filesystem attributes for fingerprinting.
     - Failure modes: Missing or colliding stale selections fail the complete readiness operation.
     */
    private func resolveSearchIndexSources(
        named moduleNames: [String]
    ) -> [(name: String, source: any BibleSearchIndexSource)]? {
        var resolved: [(name: String, source: any BibleSearchIndexSource)] = []
        resolved.reserveCapacity(moduleNames.count)
        for moduleName in moduleNames {
            guard let source = resolveSearchIndexSource(named: moduleName),
                  source.searchIndexModuleInfo.name == moduleName else {
                return nil
            }
            resolved.append((moduleName, source))
        }
        return resolved
    }

    // MARK: - Search Execution

    /**
     Executes the current search query using indexed Strong's lookup or indexed full-text search.

     The method snapshots current view state, then performs the potentially expensive work in a
     detached task so UI updates remain responsive. Results are marshalled back to the main actor.

     Side effects:
     - asks the reader reference parser to consume a recognized Bible reference before text search
     - clears current results and marks the view as actively searching
     - snapshots search configuration and dispatches background work in a detached task
     - publishes result hits, summaries, and final loading state back on the main actor

     Failure modes:
     - if the trimmed query is empty, the method returns without starting a search
     - a missing index service or selected translation becomes an explicit search failure
     - Lucene/FTS syntax and analyzer failures remain visible rather than becoming empty results
     - zero-hit searches are treated as a valid outcome and update the UI with empty results rather than an error
     */
    private func performSearch() {
        cancelSearchWork(clearPublishedState: false)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            clearPublishedSearchState()
            return
        }
        if onOpenReference?(trimmedQuery) == true {
            closeSearch()
            return
        }
        representedSearchQuery = trimmedQuery
        presentationStage = .results
        expandedResultGroupIDs.removeAll()

        guard let currentSearchIndexService = searchIndexService else {
            groupedResults = nil
            resultSummary = ""
            searchFailureMessage = SearchIndexError.databaseUnavailable(
                operation: "executing Search"
            ).localizedDescription
            isSearching = false
            return
        }

        isSearching = true
        groupedResults = nil
        searchFailureMessage = nil
        resultSummary = ""

        let currentQuery = trimmedQuery
        let currentWordMode = wordMode
        let currentScope = scopeOption
        let currentSelectedModules = orderedSelectedModuleNames
        guard let currentSelectedSources = resolveSearchIndexSources(named: currentSelectedModules) else {
            groupedResults = nil
            resultSummary = ""
            searchFailureMessage = "A selected translation could not be opened for Search."
            isSearching = false
            return
        }
        let currentSourceIdentities = currentSelectedSources.map {
            $0.source.searchIndexSourceIdentity
        }
        let osisBookId = currentOsisBookId
        let strongsQueryOptions = StrongsSearchSupport.normalizedQueryOptions(for: currentQuery)
        let indexedScope = Self.indexedScope(for: currentScope, osisBookId: osisBookId)

        let indexRequirement = Self.indexRequirement(for: currentQuery)
        if let missingModuleName = currentSearchIndexService.modulesNeedingIndex(
            from: currentSourceIdentities,
            requirement: indexRequirement
        ).first?.moduleName {
            groupedResults = nil
            resultSummary = ""
            searchFailureMessage = nil
            isSearching = false
            viewState = .needsIndex(
                moduleName: missingModuleName,
                moduleDescription: moduleDescription(for: missingModuleName)
            )
            resumesSearchAfterIndex = true
            return
        }

        let requestToken = searchRequestGate.begin()
        searchTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                guard !currentSelectedModules.isEmpty else {
                    throw SearchIndexError.indexUnavailable(moduleName: "selected translations")
                }

                let grouped: SearchGroupedResults
                if let strongsQueryOptions {
                    grouped = try currentSearchIndexService.searchStrongsMultiple(
                        canonicalTokens: strongsQueryOptions.canonicalStrongTokens,
                        sourceIdentities: currentSourceIdentities,
                        scope: indexedScope
                    )
                } else {
                    grouped = try currentSearchIndexService.searchMultiple(
                        query: currentQuery,
                        sourceIdentities: currentSourceIdentities,
                        wordMode: currentWordMode,
                        scope: indexedScope
                    )
                }
                try Task.checkCancellation()

                await MainActor.run {
                    guard searchRequestGate.accepts(requestToken), !Task.isCancelled else { return }
                    searchTask = nil
                    groupedResults = grouped
                    let translationCount = grouped.moduleCounts.count
                    if translationCount == 1 {
                        resultSummary = String(
                            localized: "\(grouped.groups.count) verses in 1 translation"
                        )
                    } else {
                        resultSummary = String(
                            localized: "\(grouped.groups.count) verses in \(translationCount) translations"
                        )
                    }
                    searchFailureMessage = nil
                    isSearching = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard searchRequestGate.accepts(requestToken), !Task.isCancelled else { return }
                    searchTask = nil
                    groupedResults = nil
                    resultSummary = ""
                    searchFailureMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    /** Cancels and invalidates the current search generation. */
    private func cancelSearchWork(clearPublishedState: Bool) {
        searchTask?.cancel()
        searchTask = nil
        searchRequestGate.invalidate()
        isSearching = false
        if clearPublishedState {
            clearPublishedSearchState()
        }
    }

    /** Cancels and invalidates the current index-creation generation. */
    private func cancelIndexWork() {
        indexTask?.cancel()
        indexTask = nil
        indexRequestGate.invalidate()
    }

    /** Clears results and errors that no longer describe the current Search input. */
    private func clearPublishedSearchState() {
        groupedResults = nil
        resultSummary = ""
        searchFailureMessage = nil
        isSearching = false
    }

    /** Cancels every asynchronous lane owned by this Search presentation. */
    private func cancelAllAsyncWork() {
        cancelSearchWork(clearPublishedState: false)
        cancelIndexWork()
    }

    // MARK: - Helpers

    /** Returns whether edited query text invalidates the currently represented Search state. */
    nonisolated static func shouldInvalidateSearch(
        representedQuery: String?,
        changedQuery: String
    ) -> Bool {
        guard let representedQuery else { return false }
        return changedQuery.trimmingCharacters(in: .whitespacesAndNewlines) != representedQuery
    }

    /** Selects the index facet required by the normalized Search query. */
    nonisolated static func indexRequirement(for query: String) -> SearchIndexRequirement {
        StrongsSearchSupport.normalizedQueryOptions(for: query) == nil ? .text : .strongs
    }

    /**
     Sorts Search translation picker modules using Android's abbreviation ordering.

     Android builds the Search translation multiselect with
     `SwordDocumentFacade.bibles.sortedBy { it.abbreviation }`. The iOS picker and commit helpers
     use this shared function so row order, select-all order, and result grouping do not depend on
     installer order or `Set` iteration.

     - Parameter modules: Installed Bible modules available to Search.
     - Returns: Modules sorted by their SWORD abbreviation (`ModuleInfo.name`).
     - Side effects: none.
     - Failure modes: Duplicate module names retain Swift's sort stability expectations only for
       equal keys; installed SWORD modules should have unique abbreviations.
     */
    nonisolated static func androidSortedTranslationModules(_ modules: [ModuleInfo]) -> [ModuleInfo] {
        modules.sorted { lhs, rhs in
            lhs.name < rhs.name
        }
    }

    /**
     Resolves selected Search module names in Android commit/search order.

     Android collects selected rows from the abbreviation-sorted dialog and then moves the current
     document to the front with `ensurePrimaryDocumentFirst()`. This function provides the same
     deterministic order for Search requests, grouped-result summaries, and UI-test state exports.

     - Parameters:
       - selectedModuleNames: Committed module abbreviations selected for Search.
       - primaryModuleName: Current reader/search module abbreviation, preferred first when present.
       - installedModules: Installed Bible modules used to derive Android dialog order.
     - Returns: Selected module abbreviations with the primary module first, followed by remaining
       selected modules in Android abbreviation order and unknown selections alphabetically.
     - Side effects: none.
     - Failure modes: If `selectedModuleNames` is empty and no primary exists, returns an empty
       array so callers can preserve their existing no-selection fallback.
     */
    nonisolated static func androidOrderedSelectedSearchModuleNames(
        selectedModuleNames: Set<String>,
        primaryModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> [String] {
        var effectiveSelection = selectedModuleNames
        if effectiveSelection.isEmpty, let primaryModuleName {
            effectiveSelection.insert(primaryModuleName)
        }

        var orderedNames = androidSortedTranslationModules(installedModules)
            .map(\.name)
            .filter { effectiveSelection.contains($0) }

        let unknownNames = effectiveSelection.subtracting(orderedNames).sorted()
        orderedNames.append(contentsOf: unknownNames)

        if let primaryModuleName,
           let primaryIndex = orderedNames.firstIndex(of: primaryModuleName) {
            orderedNames.remove(at: primaryIndex)
            orderedNames.insert(primaryModuleName, at: 0)
        }

        return orderedNames
    }

    /**
     Applies Android's Search translation dialog commit rule to a picker draft.

     Android's positive button returns checked rows, but `Search.showTranslationSelector` only
     commits when that result is non-empty. This helper keeps iOS OK-with-no-selection equivalent
     to Android's ignored empty result while still returning a deterministic module order for
     non-empty commits.

     - Parameters:
       - previousModuleNames: Currently committed Search selection.
       - draftModuleNames: Draft checked rows from the open picker dialog.
       - primaryModuleName: Current reader/search module abbreviation, preferred first.
       - installedModules: Installed Bible modules used to derive Android dialog order.
     - Returns: Ordered effective selection: draft when non-empty, otherwise previous selection.
     - Side effects: none.
     - Failure modes: If both previous and draft selections are empty and no primary exists, returns
       an empty array.
     */
    nonisolated static func androidCommittedTranslationSelection(
        previousModuleNames: Set<String>,
        draftModuleNames: Set<String>,
        primaryModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> [String] {
        let effectiveSelection = draftModuleNames.isEmpty ? previousModuleNames : draftModuleNames
        return androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: effectiveSelection,
            primaryModuleName: primaryModuleName,
            installedModules: installedModules
        )
    }

    /**
     Builds the Android Search translation picker row label for one module.

     Android renders each row as "ABBR - Name" and appends the localized
     `search_index_not_created` text in parentheses when the module lacks a completed index. iOS
     keeps that exact information model while allowing the caller to supply localized status text.

     - Parameters:
       - module: Installed Bible module metadata for the row.
       - isIndexed: Whether Search can treat the module as index-ready.
       - unindexedStatus: Localized status suffix for modules without an index.
     - Returns: User-visible row label matching Android's abbreviation, description, and index
       readiness semantics.
     - Side effects: none.
     - Failure modes: Empty descriptions fall back to the module abbreviation to avoid rendering an
       incomplete "ABBR - " label.
     */
    nonisolated static func androidTranslationPickerLabel(
        for module: ModuleInfo,
        isIndexed: Bool,
        unindexedStatus: String
    ) -> String {
        let moduleName = module.description.isEmpty ? module.name : module.description
        let baseLabel = "\(module.name) - \(moduleName)"
        guard !isIndexed else { return baseLabel }
        return "\(baseLabel) (\(unindexedStatus))"
    }

    /** Converts the UI scope into the canonical fields persisted by the FTS index. */
    nonisolated private static func indexedScope(
        for choice: ScopeChoice,
        osisBookId: String
    ) -> SearchCanonicalScope {
        switch choice {
        case .wholeBible: return .wholeBible
        case .oldTestament: return .oldTestament
        case .newTestament: return .newTestament
        case .currentBook: return .currentBook(osisBookId: osisBookId)
        }
    }

}
