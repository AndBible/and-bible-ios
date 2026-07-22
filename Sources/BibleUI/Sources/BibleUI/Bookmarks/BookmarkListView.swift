// BookmarkListView.swift — Bookmark list screen

import SwiftUI
import SwiftData
import BibleCore

/**
 Verse reference resolved from a bookmark ordinal.

 Bookmark rows are built from persisted SwiftData records, but those records store ordinals in the
 Android-compatible KJVA columns used by backup/restore. The reader can still inject a resolver
 backed by SWORD's `VerseKey` for legacy rows whose KJVA columns only mirror source ordinals.
 */
public struct BookmarkListVerseReference: Sendable, Equatable {
    /// One-based chapter number.
    public let chapter: Int

    /// One-based verse number.
    public let verse: Int

    /**
     Creates a resolved bookmark verse reference.

     - Parameters:
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     */
    public init(chapter: Int, verse: Int) {
        self.chapter = chapter
        self.verse = verse
    }
}

/**
 Displays a searchable, filterable, and sortable list of Bible and generic bookmarks from SwiftData.

 `BookmarkListView` is the main bookmark-browser surface. It keeps note-bearing Bible and generic
 bookmarks in list membership, supports Android's persisted note/search and sort controls, and
 emits exact typed navigation targets. It also imports and exports Android's bookmark CSV contract.

 Data dependencies:
 - `modelContext` is used for bookmark deletion
 - `bibleBookmarks` queries all `BibleBookmark` records for in-memory filtering and sorting
 - `genericBookmarks` queries all `GenericBookmark` records for in-memory filtering and sorting
 - `labels` queries all labels so the view can build filter chips and label-manager entry points

 Side effects:
 - deleting rows, CSV import, or context-menu deletions mutate SwiftData and save immediately
 - sort, note visibility, and CSV column choices persist through `AppPreferenceRegistry`
 - opening the label manager or label assignment changes bookmark-list navigation route state
 - selecting a bookmark dismisses through the caller-provided navigation callback rather than
   performing navigation directly inside the list
 */
public struct BookmarkListView: View {
    /// Bookmark-list destinations that should stay inside the app-owned bookmark browser stack.
    private enum BookmarkListRoute: Identifiable, Hashable {
        /// Manage the full set of user labels.
        case labelManager

        /// Assign labels to the selected bookmark.
        case labelAssignment(UUID)

        /// Stable route identity for SwiftUI navigation.
        var id: String {
            switch self {
            case .labelManager:
                return "labelManager"
            case .labelAssignment(let bookmarkId):
                return "labelAssignment::\(bookmarkId.uuidString)"
            }
        }
    }

    /// SwiftData context used for bookmark deletion and save operations.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss action for closing the bookmark sheet.
    @Environment(\.dismiss) private var dismiss

    /// Raw Bible bookmark query used as part of the source set for filtering and sorting.
    @Query(sort: \BibleBookmark.createdAt, order: .reverse) private var bibleBookmarks: [BibleBookmark]

    /// Raw generic bookmark query used as part of the source set for filtering and sorting.
    @Query(sort: \GenericBookmark.createdAt, order: .reverse) private var genericBookmarks: [GenericBookmark]

    /// Raw label query used to build filter chips and label-management affordances.
    @Query(sort: \BibleCore.Label.name) private var labels: [BibleCore.Label]

    /// Current bookmark sort order.
    @State private var sortOrder: BookmarkSortOrder = .bibleOrder

    /// Android's persisted note-preview/search visibility preference.
    @State private var showNotes = true

    /// Selected label filter, or `nil` when showing all labels.
    @State private var selectedLabelId: UUID?

    /// Android note-search text applied only while note previews are enabled.
    @State private var searchText = ""

    /// Current bookmark-list route for label management or label assignment.
    @State private var activeBookmarkListRoute: BookmarkListRoute?

    /// Current visible navigation or CSV outcome message.
    @State private var presentedMessage: BookmarkListPresentedMessage?

    /// Whether Android CSV import's document picker is presented.
    @State private var showCSVImporter = false

    /// Whether Android CSV export's column selector is presented.
    @State private var showCSVColumnSelector = false

    /// Whether the destination picker is writing `csvExportDocument`.
    @State private var showCSVExporter = false

    /// Selected Android CSV columns, restored from the unchecked-column preference before export.
    @State private var selectedCSVColumns = Set(AndroidBookmarkCSVColumn.allCases)

    /// Immutable encoded document handed to SwiftUI's export picker.
    @State private var csvExportDocument: BookmarkCSVTransferDocument?

    /// Legacy callback retained only until the parent reader adopts exact typed navigation.
    var onNavigate: ((String, Int) -> Void)?

    /// Exact Bible/generic navigation callback for Android-parity reader wiring.
    var onNavigateTarget: ((BookmarkNavigationTarget) throws -> Void)?

    /// Optional callback used to open a study pad for a selected label.
    var onOpenStudyPad: ((UUID) -> Void)?

    /// Optional SWORD-backed resolver for Bible bookmark ordinals.
    var bibleOrdinalResolver: ((String, Int) -> BookmarkListVerseReference?)?

    /**
     Optional resolver mapping a stored KJVA ordinal into the active module's versification for
     display (Android renders list rows in the current Bible's versification). Exact navigation
     uses `onNavigateTarget` independently of this presentation-only resolver.
     */
    var activeReferenceResolver: ((Int) -> (bookName: String, reference: BookmarkListVerseReference)?)?

    /// Whether the list should expose sheet-style explicit dismiss chrome.
    private let showsDismissButton: Bool

    /**
     Creates the bookmark list view.

     - Parameters:
       - onNavigate: Legacy source-compatible callback; exact navigation does not invoke it.
       - onNavigateTarget: Exact typed callback preferred over the legacy chapter-only callback.
       - onOpenStudyPad: Callback invoked when the user wants to open a selected label's study pad.
       - bibleOrdinalResolver: Optional resolver that maps `(bookName, ordinal)` to a concrete
         chapter/verse for legacy row display using the active Bible versification.
       - activeReferenceResolver: Optional resolver that maps a stored KJVA ordinal to the active
         module's versification (book name plus chapter/verse) for display only.
       - showsDismissButton: Whether to show the sheet-style Done button; app-owned destination
         routes rely on navigation-stack back chrome instead.
     */
    public init(
        onNavigate: ((String, Int) -> Void)? = nil,
        onNavigateTarget: ((BookmarkNavigationTarget) throws -> Void)? = nil,
        onOpenStudyPad: ((UUID) -> Void)? = nil,
        bibleOrdinalResolver: ((String, Int) -> BookmarkListVerseReference?)? = nil,
        activeReferenceResolver: ((Int) -> (bookName: String, reference: BookmarkListVerseReference)?)? = nil,
        showsDismissButton: Bool = true
    ) {
        self.onNavigate = onNavigate
        self.onNavigateTarget = onNavigateTarget
        self.onOpenStudyPad = onOpenStudyPad
        self.bibleOrdinalResolver = bibleOrdinalResolver
        self.activeReferenceResolver = activeReferenceResolver
        self.showsDismissButton = showsDismissButton
    }

    /**
     Bookmarks after label filtering, note-aware text filtering, and sort application.
     */
    private var filteredBookmarks: [BookmarkListItem] {
        BookmarkListProjection.filteredItems(
            bookmarkListItems,
            selectedLabelId: selectedLabelId,
            searchText: searchText,
            sortOrder: sortOrder,
            showNotes: showNotes
        )
    }

    /// Bookmark rows that belong in the native bookmark browser before label/search filtering.
    private var bookmarkListItems: [BookmarkListItem] {
        let bibleItems = bibleBookmarks.map {
                BookmarkListItem(
                    bibleBookmark: $0,
                    ordinalResolver: bibleOrdinalResolver,
                    activeReferenceResolver: activeReferenceResolver
                )
            }
        let genericItems = genericBookmarks.map(BookmarkListItem.init(genericBookmark:))
        return bibleItems + genericItems
    }

    /// User-created labels that should appear in the filter strip.
    private var userLabels: [BibleCore.Label] {
        labels.filter { $0.isRealLabel }
    }

    /**
     Builds the bookmark list screen, empty state, and related navigation destinations.
     */
    public var body: some View {
        Group {
            if bookmarkListItems.isEmpty {
                ContentUnavailableView(
                    String(localized: "no_bookmarks"),
                    systemImage: "bookmark",
                    description: Text(String(localized: "no_bookmarks_description"))
                )
                .accessibilityIdentifier("bookmarkListScreen")
                .accessibilityValue(bookmarkListAccessibilityValue)
            } else {
                bookmarkList
                    .accessibilityIdentifier("bookmarkListScreen")
                    .accessibilityValue(bookmarkListAccessibilityValue)
            }
        }
        .overlay(alignment: .topLeading) {
            bookmarkListStateExport
        }
        .navigationTitle(String(localized: "bookmarks"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                        .accessibilityIdentifier("bookmarkListDoneButton")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button {
                        activeBookmarkListRoute = .labelManager
                    } label: {
                        Image(systemName: "tag")
                    }
                    sortMenu
                    bookmarkActionsMenu
                }
            }
        }
        .navigationDestination(item: $activeBookmarkListRoute) { route in
            bookmarkListDestination(route)
        }
        .onAppear(perform: restoreBookmarkListPreferences)
        .onChange(of: sortOrder) { _, value in
            SettingsStore(modelContext: modelContext).setString(.bookmarkSortOrder, value: value.rawValue)
        }
        .onChange(of: showNotes) { _, value in
            if !value { searchText = "" }
            SettingsStore(modelContext: modelContext).setBool(.bookmarkShowNotes, value: value)
        }
        .sheet(isPresented: $showCSVColumnSelector) {
            BookmarkCSVColumnSelectionView(
                selectedColumns: $selectedCSVColumns,
                onExport: prepareCSVExport,
                onCancel: { showCSVColumnSelector = false }
            )
        }
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: BookmarkCSVTransferDocument.readableContentTypes,
            allowsMultipleSelection: false,
            onCompletion: importCSVSelection
        )
        .fileExporter(
            isPresented: $showCSVExporter,
            document: csvExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: csvExportFileName,
            onCompletion: completeCSVExport
        )
        .alert(item: $presentedMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text(String(localized: "ok", defaultValue: "OK")))
            )
        }
    }

    /// Builds app-owned bookmark-list destinations without introducing nested iOS sheets.
    @ViewBuilder
    private func bookmarkListDestination(_ route: BookmarkListRoute) -> some View {
        switch route {
        case .labelManager:
            LabelManagerView(onOpenStudyPad: onOpenStudyPad != nil ? { labelId in
                activeBookmarkListRoute = nil
                onOpenStudyPad?(labelId)
            } : nil)
        case .labelAssignment(let bookmarkId):
            LabelAssignmentView(
                bookmarkId: bookmarkId,
                onDismiss: { activeBookmarkListRoute = nil }
            )
        }
    }

    /// Main list content once at least one bookmark exists.
    private var bookmarkList: some View {
        List {
            // Label filter chips
            if !userLabels.isEmpty {
                labelFilterSection
            }

            if showNotes {
                bookmarkSearchSection
            }

            // Bookmark list
            ForEach(filteredBookmarks) { bookmark in
                BookmarkRow(
                    bookmark: bookmark,
                    showNotes: showNotes,
                    onSelect: { navigate(to: bookmark) },
                    onEditLabels: { activeBookmarkListRoute = .labelAssignment(bookmark.id) }
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteBookmark(bookmark)
                    } label: {
                        SwiftUI.Label(String(localized: "delete"), systemImage: "trash")
                    }
                    .accessibilityIdentifier("bookmarkListDeleteButton::\(bookmark.accessibilitySegment)")
                }
                .contextMenu {
                    Button {
                        activeBookmarkListRoute = .labelAssignment(bookmark.id)
                    } label: {
                        SwiftUI.Label(String(localized: "edit_labels"), systemImage: "tag")
                    }
                    Button(role: .destructive) {
                        deleteBookmark(bookmark)
                    } label: {
                        SwiftUI.Label(String(localized: "delete"), systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deleteBookmarks)
        }
    }

    /**
     Visible bookmark search control that mirrors Android's in-content bookmark search layout.

     Android's `Bookmarks` activity owns an `EditText` under the label selector instead of relying
     on action-bar search chrome. Keeping this as a normal list row makes the filter reachable when
     the bookmark list is hosted inside the reader's app-owned destination stack, where SwiftUI's
     navigation `.searchable` chrome is not reliably exposed.
     */
    private var bookmarkSearchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                #if os(iOS)
                TextField(String(localized: "search_bookmarks"), text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("bookmarkListSearchField")
                #else
                TextField(String(localized: "search_bookmarks"), text: $searchText)
                    .accessibilityIdentifier("bookmarkListSearchField")
                #endif

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bookmarkListClearSearchButton")
                    .accessibilityLabel(String(localized: "clear"))
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Stable bookmark-list state exported for UI automation, including route presentation flags.
    private var bookmarkListAccessibilityValue: String {
        BookmarkListProjection.accessibilityValue(
            for: filteredBookmarks,
            selectedLabelId: selectedLabelId,
            labels: labels,
            searchText: searchText,
            isAssigningLabels: bookmarkListIsAssigningLabels,
            includeRowTokens: UITestRuntimeConfiguration.enablesDetailedAccessibilityExports,
            rowTokenLimit: UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit
        )
    }

    /// Whether the bookmark-list route is currently showing label assignment.
    private var bookmarkListIsAssigningLabels: Bool {
        if case .labelAssignment = activeBookmarkListRoute {
            return true
        }
        return false
    }

    /// Compact hidden state probe used by UI tests instead of snapshotting the live list surface.
    @ViewBuilder
    private var bookmarkListStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(bookmarkListAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("bookmarkListStateExport")
                .accessibilityValue(bookmarkListAccessibilityValue)
        }
    }

    /// Stable token for the currently selected bookmark label filter.
    private var bookmarkListSelectedLabelAccessibilityToken: String {
        BookmarkListProjection.selectedLabelToken(
            selectedLabelId: selectedLabelId,
            labels: labels
        )
    }

    /// Sort-order menu shown in the navigation bar.
    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "sort"), selection: $sortOrder) {
                SwiftUI.Label(
                    String(localized: "sort_bible_order"),
                    systemImage: "arrow.up"
                )
                    .tag(BookmarkSortOrder.bibleOrder)
                    .accessibilityIdentifier("bookmarkListSortOption::bibleOrder")
                SwiftUI.Label(
                    String(localized: "sort_bible_order"),
                    systemImage: "arrow.down"
                )
                    .tag(BookmarkSortOrder.bibleOrderDesc)
                    .accessibilityIdentifier("bookmarkListSortOption::bibleOrderDesc")
                SwiftUI.Label(
                    String(localized: "sort_date_created"),
                    systemImage: "arrow.up"
                )
                    .tag(BookmarkSortOrder.createdAt)
                    .accessibilityIdentifier("bookmarkListSortOption::createdAt")
                SwiftUI.Label(
                    String(localized: "sort_date_created"),
                    systemImage: "arrow.down"
                )
                    .tag(BookmarkSortOrder.createdAtDesc)
                    .accessibilityIdentifier("bookmarkListSortOption::createdAtDesc")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("bookmarkListSortMenu")
    }

    /// Android bookmark presentation and CSV transfer commands.
    private var bookmarkActionsMenu: some View {
        Menu {
            Toggle(
                String(localized: "show_notes", defaultValue: "Show notes"),
                isOn: $showNotes
            )
            .accessibilityIdentifier("bookmarkListShowNotesToggle")

            Divider()

            Button {
                showCSVImporter = true
            } label: {
                SwiftUI.Label(
                    String(
                        format: String(localized: "import_items", defaultValue: "Import %@"),
                        "CSV"
                    ),
                    systemImage: "square.and.arrow.down"
                )
            }
            .accessibilityIdentifier("bookmarkListImportCSVButton")

            Button {
                presentCSVColumnSelector()
            } label: {
                SwiftUI.Label(
                    String(
                        format: String(localized: "export_something", defaultValue: "Export %@"),
                        "CSV"
                    ),
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(filteredBookmarks.allSatisfy { !$0.isBibleBookmark })
            .accessibilityIdentifier("bookmarkListExportCSVButton")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("bookmarkListActionsMenu")
    }

    /**
     Restores Android's durable sort, note-preview, and unchecked CSV-column preferences.

     - Side effects: Mutates local SwiftUI state from `SettingsStore`.
     - Failure modes: Unknown sort strings fall back to Android's Bible-order default; unknown CSV
       columns are ignored so newer Android exports do not hide supported columns.
     */
    private func restoreBookmarkListPreferences() {
        let settings = SettingsStore(modelContext: modelContext)
        sortOrder = BookmarkSortOrder(rawValue: settings.getString(.bookmarkSortOrder)) ?? .bibleOrder
        showNotes = settings.getBool(.bookmarkShowNotes)
        let unchecked = Set(settings.getStringSet(.bookmarkCSVUncheckedColumns))
        selectedCSVColumns = Set(AndroidBookmarkCSVColumn.allCases.filter {
            !unchecked.contains($0.rawValue)
        })
    }

    /** Opens Android's export-column selector with the persisted selection. */
    private func presentCSVColumnSelector() {
        restoreBookmarkListPreferences()
        showCSVColumnSelector = true
    }

    /**
     Encodes the visible Bible subset and advances from column selection to destination selection.

     - Side effects: Persists unchecked columns and populates the export document state.
     - Failure modes: Encoding failures are shown in an alert and do not open the destination picker.
     */
    private func prepareCSVExport() {
        let settings = SettingsStore(modelContext: modelContext)
        let unchecked = AndroidBookmarkCSVColumn.allCases
            .filter { !selectedCSVColumns.contains($0) }
            .map(\.rawValue)
        settings.setStringSet(.bookmarkCSVUncheckedColumns, values: unchecked)

        let bookmarks = filteredBookmarks.compactMap { item -> BibleBookmark? in
            guard case .bible(let bookmark) = item.source else { return nil }
            return bookmark
        }
        do {
            let data = try AndroidBookmarkCSVCodec.encode(
                bookmarks: bookmarks,
                selectedColumns: selectedCSVColumns
            )
            csvExportDocument = BookmarkCSVTransferDocument(data: data)
            showCSVColumnSelector = false
            showCSVExporter = true
        } catch {
            showCSVColumnSelector = false
            presentedMessage = .error(error.localizedDescription)
        }
    }

    /** Handles one document-picker result and commits a valid CSV file atomically. */
    private func importCSVSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let summary = try AndroidBookmarkCSVTransferService(
                modelContext: modelContext
            ).importCSV(data)
            presentedMessage = .success(String.localizedStringWithFormat(
                String(
                    localized: "csv_import_success",
                    defaultValue: "Import completed: %1$ld created, %2$ld updated"
                ),
                summary.created,
                summary.updated
            ))
        } catch {
            presentedMessage = .error(error.localizedDescription)
        }
    }

    /** Converts the export picker's terminal result into a visible success or failure message. */
    private func completeCSVExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            let count = filteredBookmarks.filter(\.isBibleBookmark).count
            presentedMessage = .success(String.localizedStringWithFormat(
                String(
                    localized: "csv_export_success",
                    defaultValue: "Exported %ld bookmarks to CSV"
                ),
                count
            ))
        case .failure(let error):
            presentedMessage = .error(error.localizedDescription)
        }
        csvExportDocument = nil
    }

    /// Timestamped Android-compatible default filename for the destination picker.
    private var csvExportFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "bible_bookmarks_\(formatter.string(from: Date())).csv"
    }

    /// Horizontal label-filter chips plus the selected-label study-pad action.
    private var labelFilterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: String(localized: "all"),
                        chipColor: .secondary,
                        isSelected: selectedLabelId == nil,
                        accessibilityIdentifier: "bookmarkListFilterChip::all"
                    ) {
                        selectedLabelId = nil
                    }

                    ForEach(userLabels) { label in
                        FilterChip(
                            title: label.name,
                            chipColor: Color(argbInt: label.color),
                            isSelected: selectedLabelId == label.id,
                            accessibilityIdentifier: "bookmarkListFilterChip::\(bookmarkListAccessibilitySegment(label.name))"
                        ) {
                            selectedLabelId = (selectedLabelId == label.id) ? nil : label.id
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            // Show "Open StudyPad" when a label is selected
            if let labelId = selectedLabelId,
               let label = userLabels.first(where: { $0.id == labelId }),
               onOpenStudyPad != nil {
                Button {
                    onOpenStudyPad?(labelId)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "book")
                        Text(String(localized: "open_studypad_for_label \(label.name)"))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color(argbInt: label.color))
                }
                .accessibilityIdentifier(
                    "bookmarkListOpenStudyPadButton::\(bookmarkListAccessibilitySegment(label.name))"
                )
            }
        }
    }

    /**
     Deletes the currently visible bookmarks at the given filtered-list offsets.

     - Parameter offsets: Index offsets from `filteredBookmarks`.
     */
    private func deleteBookmarks(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredBookmarks[$0] }
        _ = try? BookmarkListMutation.deleteItems(toDelete, in: modelContext)
    }

    /**
     Deletes one bookmark from the list and persists the mutation.

     - Parameter bookmark: Bookmark row selected for deletion.
     - Side effects:
       - deletes the provided bookmark from SwiftData
       - saves the resulting bookmark collection immediately
     - Failure modes:
       - silently discards save failures because the list has no retry UI for destructive actions
     */
    private func deleteBookmark(_ bookmark: BookmarkListItem) {
        _ = try? BookmarkListMutation.deleteItems([bookmark], in: modelContext)
    }

    /**
     Emits one exact bookmark destination and dismisses only after successful parent handling.

     The legacy Bible callback remains temporarily source-compatible for the parent reader but is
     never invoked. Parent integration must provide `onNavigateTarget` so exact verses, source
     versification, and generic keys remain intact end to end.

     - Parameter bookmark: Selected normalized bookmark row.
     - Side effects: Invokes a navigation callback, may dismiss the list, or presents an error.
     - Failure modes: Corrupt targets, missing generic handlers, and parent mapping failures remain
       visible and keep the bookmark list open.
     */
    private func navigate(to bookmark: BookmarkListItem) {
        guard let target = bookmark.exactNavigationTarget else {
            presentedMessage = .error(
                bookmark.navigationError?.localizedDescription ?? String(
                    localized: "error_occurred",
                    defaultValue: "An error has occurred"
                )
            )
            return
        }
        if let onNavigateTarget {
            do {
                try onNavigateTarget(target)
                dismiss()
            } catch {
                presentedMessage = .error(error.localizedDescription)
            }
            return
        }

        presentedMessage = .error(String(
            localized: "error_occurred",
            defaultValue: "An error has occurred"
        ))
    }

    /**
     Converts bookmark ordinals into a human-readable verse reference string.

     - Parameter bookmark: Bookmark whose ordinals should be rendered for the list UI.
     - Returns: Reference text like `Genesis 1:1`, `Genesis 1:1-3`, or `Genesis 1:31-2:1`.
     */
    static func verseReference(
        for bookmark: BibleBookmark,
        ordinalResolver: ((String, Int) -> BookmarkListVerseReference?)? = nil,
        activeReferenceResolver: ((Int) -> (bookName: String, reference: BookmarkListVerseReference)?)? = nil
    ) -> String {
        // Prefer the active module's versification for Android-parity display; exact navigation is
        // emitted separately through the typed target contract.
        let resolve: (Int) -> (bookName: String, reference: BookmarkListVerseReference)? = { ordinal in
            activeReferenceResolver?(ordinal) ?? kjvaVerseReference(ordinal: ordinal)
        }
        if let start = resolve(bookmark.kjvOrdinalStart) {
            let effectiveKJVEnd = bookmark.kjvOrdinalEnd > bookmark.kjvOrdinalStart
                ? bookmark.kjvOrdinalEnd
                : bookmark.kjvOrdinalStart
            let end = resolve(effectiveKJVEnd) ?? start
            return formattedBibleReference(
                startBookName: start.bookName,
                startReference: start.reference,
                endBookName: end.bookName,
                endReference: end.reference
            )
        }

        let legacyBookName = bookmark.book?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveEnd = bookmark.ordinalEnd > 0 ? bookmark.ordinalEnd : bookmark.ordinalStart
        if !legacyBookName.isEmpty,
           let startReference = ordinalResolver?(legacyBookName, bookmark.ordinalStart),
           let endReference = ordinalResolver?(legacyBookName, effectiveEnd) {
            return formattedBibleReference(
                startBookName: legacyBookName,
                startReference: startReference,
                endBookName: legacyBookName,
                endReference: endReference
            )
        }
        return String(
            localized: "error_occurred",
            defaultValue: "An error has occurred"
        )
    }

    /**
     Resolves a stored Android-compatible KJVA ordinal for bookmark-list display and navigation.

     - Parameter ordinal: Persisted KJVA verse ordinal.
     - Returns: Display book name and chapter/verse reference, or `nil` for invalid ordinals.
     - Side effects: None.
     - Failure modes: Unknown ordinals return `nil` so legacy fallback paths can handle older rows.
     */
    fileprivate static func kjvaVerseReference(
        ordinal: Int
    ) -> (bookName: String, reference: BookmarkListVerseReference)? {
        guard let reference = JSwordKJVAVersification.verseReference(ordinal: ordinal) else {
            return nil
        }
        return (
            bookName: JSwordKJVAVersification.longBookName(osisId: reference.osisId) ?? reference.osisId,
            reference: BookmarkListVerseReference(chapter: reference.chapter, verse: reference.verse)
        )
    }

    /**
     Formats a Bible bookmark range using JSword-style same-chapter and cross-chapter shorthand.

     - Parameters:
       - startBookName: Display name for the start book.
       - startReference: Start chapter/verse reference.
       - endBookName: Display name for the end book.
       - endReference: End chapter/verse reference.
     - Returns: User-visible bookmark reference text.
     - Side effects: None.
     - Failure modes: None.
     */
    fileprivate static func formattedBibleReference(
        startBookName: String,
        startReference: BookmarkListVerseReference,
        endBookName: String,
        endReference: BookmarkListVerseReference
    ) -> String {
        if startBookName == endBookName, endReference == startReference {
            return "\(startBookName) \(startReference.chapter):\(startReference.verse)"
        } else if startBookName == endBookName, endReference.chapter == startReference.chapter {
            return "\(startBookName) \(startReference.chapter):\(startReference.verse)-\(endReference.verse)"
        } else if startBookName == endBookName {
            return "\(startBookName) \(startReference.chapter):\(startReference.verse)-\(endReference.chapter):\(endReference.verse)"
        } else {
            return "\(startBookName) \(startReference.chapter):\(startReference.verse)-\(endBookName) \(endReference.chapter):\(endReference.verse)"
        }
    }

    /**
     Converts a generic bookmark target into user-visible list text.

     - Parameter bookmark: Generic bookmark whose module/key should be rendered.
     - Returns: Reference text like `UITESTDICT: Entry 1`.
     */
    static func genericReference(for bookmark: GenericBookmark) -> String {
        let module = bookmark.bookInitials.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = bookmark.key.trimmingCharacters(in: .whitespacesAndNewlines)
        if module.isEmpty {
            return key.isEmpty ? "Unknown" : key
        }
        if key.isEmpty {
            return module
        }
        return "\(module): \(key)"
    }

}

/**
 Pure BookmarkList filtering, sorting, and accessibility-state projection.

 `BookmarkListView` owns SwiftUI rendering and navigation. This helper owns the data projection
 that Android parity depends on: label filtering, note-only search while notes are shown, sort
 order, and the compact state exported for UI automation. Keeping it separate lets package tests
 protect the contract without launching the app.
 */
enum BookmarkListProjection {
    /**
     Applies the same filter and sort pipeline used by the visible bookmark list.

     - Parameters:
       - items: Normalized bookmark rows before UI filtering.
       - selectedLabelId: Optional selected label chip.
       - searchText: Current note-search query.
       - sortOrder: Active Android-compatible bookmark sort order.
       - showNotes: Whether Android's note preview and note-search mode is enabled.
     - Returns: Rows in the order the bookmark list should render.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func filteredItems(
        _ items: [BookmarkListItem],
        selectedLabelId: UUID?,
        searchText: String,
        sortOrder: BookmarkSortOrder,
        showNotes: Bool = true
    ) -> [BookmarkListItem] {
        var result = items

        if let selectedLabelId {
            result = result.filter { $0.labels.contains { $0.id == selectedLabelId } }
        }

        if showNotes, !searchText.isEmpty {
            result = result.filter {
                $0.searchableText.localizedCaseInsensitiveContains(searchText)
            }
        }

        var bibleItems = result.filter(\.isBibleBookmark)
        let genericItems = result.filter { !$0.isBibleBookmark }.sorted(by: genericBookmarkPrecedes)

        switch sortOrder {
        case .bibleOrder:
            bibleItems.sort { bibleDocumentOrderPrecedes($0, $1, ascending: true) }
        case .bibleOrderDesc:
            bibleItems.sort { bibleDocumentOrderPrecedes($0, $1, ascending: false) }
        case .createdAt:
            bibleItems.sort { compareItems($0, $1, by: \.createdAt, ascending: true) }
        case .createdAtDesc:
            bibleItems.sort { compareItems($0, $1, by: \.createdAt, ascending: false) }
        case .lastUpdated:
            bibleItems.sort { compareItems($0, $1, by: \.lastUpdatedOn, ascending: true) }
        case .orderNumber:
            if let selectedLabelId {
                bibleItems.sort { lhs, rhs in
                    let lhsOrder = lhs.orderNumber(for: selectedLabelId) ?? -1
                    let rhsOrder = rhs.orderNumber(for: selectedLabelId) ?? -1
                    if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                    return bibleDocumentOrderPrecedes(lhs, rhs, ascending: true)
                }
            } else {
                bibleItems.sort { bibleDocumentOrderPrecedes($0, $1, ascending: true) }
            }
        }

        return bibleItems + genericItems
    }

    /**
     Compares Bible rows using Android's KJVA ordinal and text-offset ordering.

     - Parameters:
       - lhs: Left-hand Bible row.
       - rhs: Right-hand Bible row.
       - ascending: Whether ordinal and non-null offset values increase or decrease.
     - Returns: `true` when `lhs` precedes `rhs` in Android Bible order.
     - Side effects: None.
     - Failure modes: Non-Bible rows sort by stable UUID only; callers normally pre-filter them.
     */
    private static func bibleDocumentOrderPrecedes(
        _ lhs: BookmarkListItem,
        _ rhs: BookmarkListItem,
        ascending: Bool
    ) -> Bool {
        guard case .bible(let lhsBookmark) = lhs.source,
              case .bible(let rhsBookmark) = rhs.source else {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if lhsBookmark.kjvOrdinalStart != rhsBookmark.kjvOrdinalStart {
            return ascending
                ? lhsBookmark.kjvOrdinalStart < rhsBookmark.kjvOrdinalStart
                : lhsBookmark.kjvOrdinalStart > rhsBookmark.kjvOrdinalStart
        }
        if lhsBookmark.startOffset != rhsBookmark.startOffset {
            switch (lhsBookmark.startOffset, rhsBookmark.startOffset) {
            case (nil, _?): return true
            case (_?, nil): return false
            case let (lhsOffset?, rhsOffset?):
                return ascending ? lhsOffset < rhsOffset : lhsOffset > rhsOffset
            case (nil, nil): break
            }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /**
     Compares generic rows using Android's fixed `bookInitials, key` query order.

     - Parameters:
       - lhs: Left-hand generic row.
       - rhs: Right-hand generic row.
     - Returns: `true` when `lhs` precedes `rhs`, with UUID as a deterministic duplicate tie-breaker.
     - Side effects: None.
     - Failure modes: Non-generic rows sort by stable UUID only; callers normally pre-filter them.
     */
    private static func genericBookmarkPrecedes(
        _ lhs: BookmarkListItem,
        _ rhs: BookmarkListItem
    ) -> Bool {
        guard case .generic(let lhsBookmark) = lhs.source,
              case .generic(let rhsBookmark) = rhs.source else {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if lhsBookmark.bookInitials != rhsBookmark.bookInitials {
            return lhsBookmark.bookInitials < rhsBookmark.bookInitials
        }
        if lhsBookmark.key != rhsBookmark.key {
            return lhsBookmark.key < rhsBookmark.key
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /**
     Builds the compact accessibility state exported by the visible bookmark list.

     - Parameters:
       - items: Already-filtered rows in render order.
       - selectedLabelId: Optional selected label chip.
       - labels: All labels available to the bookmark list.
       - searchText: Current in-content search query.
       - isAssigningLabels: Whether the label-assignment destination is active.
       - includeRowTokens: Whether detailed row tokens should be appended.
       - rowTokenLimit: Maximum number of row tokens to include when enabled.
     - Returns: A stable semicolon-delimited state string consumed by tests.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func accessibilityValue(
        for items: [BookmarkListItem],
        selectedLabelId: UUID?,
        labels: [BibleCore.Label],
        searchText: String,
        isAssigningLabels: Bool,
        includeRowTokens: Bool,
        rowTokenLimit: Int
    ) -> String {
        let baseState = [
            "count=\(items.count)",
            "selectedLabel=\(selectedLabelToken(selectedLabelId: selectedLabelId, labels: labels))",
            "query=\(bookmarkListAccessibilitySegment(searchText))",
            "labelAssignment=\(isAssigningLabels ? "true" : "false")",
        ].joined(separator: ";")
        guard includeRowTokens else {
            return baseState
        }

        let rowTokens = items.prefix(rowTokenLimit).map {
            "|\($0.accessibilitySegment)|"
        }.joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
    }

    /**
     Resolves the selected label token used by BookmarkList state export.

     - Parameters:
       - selectedLabelId: Optional selected label chip.
       - labels: All labels available to the bookmark list.
     - Returns: `all` when no selected label exists, otherwise the sanitized label name.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func selectedLabelToken(
        selectedLabelId: UUID?,
        labels: [BibleCore.Label]
    ) -> String {
        guard let selectedLabelId,
              let label = labels.first(where: { $0.id == selectedLabelId })
        else {
            return "all"
        }
        return bookmarkListAccessibilitySegment(label.name)
    }

    /**
     Compares two projected rows by one primary key and stable deterministic tiebreakers.

     - Parameters:
       - lhs: Left-hand bookmark row.
       - rhs: Right-hand bookmark row.
       - keyPath: Comparable row property to use as the primary sort key.
       - ascending: Whether the primary key should sort ascending or descending.
     - Returns: `true` when `lhs` should appear before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func compareItems<Value: Comparable>(
        _ lhs: BookmarkListItem,
        _ rhs: BookmarkListItem,
        by keyPath: KeyPath<BookmarkListItem, Value>,
        ascending: Bool
    ) -> Bool {
        let lhsValue = lhs[keyPath: keyPath]
        let rhsValue = rhs[keyPath: keyPath]
        if lhsValue == rhsValue {
            if lhs.reference == rhs.reference {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.reference < rhs.reference
        }
        return ascending ? lhsValue < rhsValue : lhsValue > rhsValue
    }
}

/**
 Persists destructive BookmarkList row actions outside the SwiftUI view boundary.

 `BookmarkListView` owns rendering, swipe actions, and context menus. This helper owns the
 side-effecting mutation contract used by those gestures so package tests can verify destructive
 persistence without launching the full app and reopening the list.

 Inputs:
 - normalized `BookmarkListItem` rows whose source models belong to the supplied `ModelContext`
 - the `ModelContext` that should persist the deletion

 Outputs:
 - the number of rows deleted

 Side effects:
 - deletes backing `BibleBookmark` and `GenericBookmark` models from SwiftData
 - saves the context once after every requested row has been marked for deletion

 Failure modes:
 - rethrows SwiftData save failures to package tests; the visible UI intentionally discards errors
   because destructive row gestures do not expose a retry surface
 */
enum BookmarkListMutation {
    /**
     Deletes the backing models for the supplied bookmark-list rows and saves the context once.

     - Parameters:
       - items: Normalized bookmark rows selected by the visible list.
       - modelContext: SwiftData context that owns each row's backing model.
     - Returns: Number of rows marked for deletion before the save.
     - Side effects: Deletes backing bookmark models from SwiftData and saves the context.
     - Throws: Any SwiftData save error produced after deleting the requested rows.
     */
    @discardableResult
    static func deleteItems(_ items: [BookmarkListItem], in modelContext: ModelContext) throws -> Int {
        for item in items {
            switch item.source {
            case .bible(let bibleBookmark):
                modelContext.delete(bibleBookmark)
            case .generic(let genericBookmark):
                modelContext.delete(genericBookmark)
            }
        }
        try modelContext.save()
        return items.count
    }
}

// MARK: - UUID Identifiable for sheet(item:)

/// Retroactive `Identifiable` conformance so raw `UUID` values can drive `sheet(item:)`.
extension UUID: @retroactive Identifiable {
    /// Retroactive `Identifiable` conformance value for SwiftUI sheet presentation.
    public var id: UUID { self }
}

// MARK: - Bookmark List Item

/// Normalized row data for Bible and generic bookmarks shown in `BookmarkListView`.
struct BookmarkListItem: Identifiable {
    /// Original SwiftData model backing the row.
    enum Source {
        case bible(BibleBookmark)
        case generic(GenericBookmark)
    }

    /// Stable bookmark identifier shared by the row and label-assignment sheet.
    let id: UUID

    /// Original SwiftData model backing the row.
    let source: Source

    /// User-visible reference text.
    let reference: String

    /// Text searched by the bookmark list search field.
    let searchableText: String

    /// Bookmark creation timestamp.
    let createdAt: Date

    /// Bookmark last-updated timestamp.
    let lastUpdatedOn: Date

    /// Optional icon identifier.
    let customIcon: String?

    /// Optional note preview text.
    let noteText: String

    /// Labels assigned to the bookmark.
    let labels: [BibleCore.Label]

    /// Exact Bible or generic destination emitted to the parent reader.
    let exactNavigationTarget: BookmarkNavigationTarget?

    /// Fail-closed reason why `exactNavigationTarget` could not be created.
    let navigationError: BookmarkNavigationTargetError?

    /// Legacy chapter-only target retained for source compatibility with existing package tests.
    let navigationTarget: (bookName: String, chapter: Int)?

    /// Identifier-safe row reference segment used by UI automation.
    var accessibilitySegment: String {
        bookmarkListAccessibilitySegment(reference)
    }

    /// Whether this row belongs to Android's Bible-first bookmark result partition.
    var isBibleBookmark: Bool {
        if case .bible = source { return true }
        return false
    }

    /**
     Returns the StudyPad junction order for one selected label.

     - Parameter labelID: Label whose junction controls Android `ORDER_NUMBER` sorting.
     - Returns: Persisted junction order, or `nil` when the row is not attached to that label.
     - Side effects: None.
     - Failure modes: Missing/deleted relationships return `nil`.
     */
    func orderNumber(for labelID: UUID) -> Int? {
        switch source {
        case .bible(let bookmark):
            return bookmark.bookmarkToLabels?.first { $0.label?.id == labelID }?.orderNumber
        case .generic(let bookmark):
            return bookmark.bookmarkToLabels?.first { $0.label?.id == labelID }?.orderNumber
        }
    }

    /// Creates a normalized row for one Bible bookmark.
    init(
        bibleBookmark bookmark: BibleBookmark,
        ordinalResolver: ((String, Int) -> BookmarkListVerseReference?)? = nil,
        activeReferenceResolver: ((Int) -> (bookName: String, reference: BookmarkListVerseReference)?)? = nil
    ) {
        let reference = BookmarkListView.verseReference(
            for: bookmark,
            ordinalResolver: ordinalResolver,
            activeReferenceResolver: activeReferenceResolver
        )
        let noteText = bookmark.notes?.notes ?? ""
        self.id = bookmark.id
        self.source = .bible(bookmark)
        self.reference = reference
        self.searchableText = noteText
        self.createdAt = bookmark.createdAt
        self.lastUpdatedOn = bookmark.lastUpdatedOn
        self.customIcon = bookmark.customIcon
        self.noteText = noteText
        self.labels = bookmark.bookmarkToLabels?.compactMap { $0.label }.sorted { $0.name < $1.name } ?? []
        do {
            self.exactNavigationTarget = try BookmarkNavigationTargetResolver.resolve(bookmark)
            self.navigationError = nil
        } catch let error as BookmarkNavigationTargetError {
            self.exactNavigationTarget = nil
            self.navigationError = error
        } catch {
            self.exactNavigationTarget = nil
            self.navigationError = .invalidBibleOrdinals(
                start: bookmark.kjvOrdinalStart,
                end: bookmark.kjvOrdinalEnd
            )
        }

        // This projection exists only until the parent adopts `onNavigateTarget`; it never guesses.
        if let target = activeReferenceResolver?(bookmark.kjvOrdinalStart)
            ?? BookmarkListView.kjvaVerseReference(ordinal: bookmark.kjvOrdinalStart) {
            self.navigationTarget = (
                bookName: target.bookName,
                chapter: target.reference.chapter
            )
        } else {
            self.navigationTarget = nil
        }
    }

    /// Creates a normalized row for one generic bookmark.
    init(genericBookmark bookmark: GenericBookmark) {
        let reference = BookmarkListView.genericReference(for: bookmark)
        let noteText = bookmark.notes?.notes ?? ""
        self.id = bookmark.id
        self.source = .generic(bookmark)
        self.reference = reference
        self.searchableText = noteText
        self.createdAt = bookmark.createdAt
        self.lastUpdatedOn = bookmark.lastUpdatedOn
        self.customIcon = bookmark.customIcon
        self.noteText = noteText
        self.labels = bookmark.bookmarkToLabels?.compactMap { $0.label }.sorted { $0.name < $1.name } ?? []
        do {
            self.exactNavigationTarget = try BookmarkNavigationTargetResolver.resolve(bookmark)
            self.navigationError = nil
        } catch let error as BookmarkNavigationTargetError {
            self.exactNavigationTarget = nil
            self.navigationError = error
        } catch {
            self.exactNavigationTarget = nil
            self.navigationError = .missingGenericKey
        }
        self.navigationTarget = nil
    }
}

// MARK: - Bookmark Row

/**
 Renders one bookmark row inside `BookmarkListView`.

 The row shows the reference, label colors, optional icon, optional note preview, and a quick
 affordance for editing the bookmark's labels.
 */
private struct BookmarkRow: View {
    /// Bookmark being rendered.
    let bookmark: BookmarkListItem

    /// Whether note previews are visible under Android's persisted setting.
    let showNotes: Bool

    /// Callback used to resolve or visibly reject the exact bookmark target.
    var onSelect: () -> Void

    /// Callback used to open label editing for the bookmark.
    var onEditLabels: (() -> Void)?

    /// Builds the tappable bookmark row.
    var body: some View {
        selectionButton
    }

    /**
     Builds the main row button that navigates back into the reader for the bookmark passage.

     - Returns: Row button containing the bookmark summary content.
     - Side effects: Invokes `onSelect` when tapped.
     - Failure modes: This helper cannot fail.
     */
    private var selectionButton: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                headerRow
                notePreview
                labelTags
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(bookmarkRowIdentifier())
    }

    /// Header row containing label dots, icon, reference, and created-at date.
    private var headerRow: some View {
        HStack {
            // Label color dots
            if !bookmark.labels.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(bookmark.labels.prefix(3).enumerated()), id: \.offset) { _, label in
                        Circle()
                            .fill(Color(argbInt: label.color))
                            .frame(width: 10, height: 10)
                    }
                }
            }

            if let icon = bookmark.customIcon, !icon.isEmpty {
                Image(systemName: BibleCore.Label.sfSymbol(for: icon) ?? icon)
                    .font(.headline)
            }

            Text(bookmark.reference)
                .font(.headline)

            Spacer()

            Text(bookmark.createdAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    /// Optional note-preview text shown when the bookmark has saved note content.
    private var notePreview: some View {
        if showNotes, !bookmark.noteText.isEmpty {
            Text(bookmark.noteText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    /// Label tags or add-label affordance shown at the bottom of the bookmark row.
    private var labelTags: some View {
        if !bookmark.labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(bookmark.labels.prefix(3).enumerated()), id: \.offset) { _, label in
                    Text(label.name)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(argbInt: label.color).opacity(0.2))
                        .clipShape(Capsule())
                }
                Button {
                    onEditLabels?()
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(bookmarkInlineActionIdentifier("bookmarkListEditLabelsButton"))
            }
        } else {
            Button {
                onEditLabels?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .font(.caption2)
                    Text(String(localized: "add_labels"))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(bookmarkInlineActionIdentifier("bookmarkListEditLabelsButton"))
        }
    }

    /**
     Resolves the deterministic XCUITest accessibility identifier for the row's primary button.

     - Returns: Stable identifier derived from the bookmark reference string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func bookmarkRowIdentifier() -> String {
        "bookmarkListRowButton::\(bookmark.accessibilitySegment)"
    }

    /**
     Resolves the deterministic XCUITest accessibility identifier for one inline row action.

     - Parameter prefix: Fixed action prefix naming the control role.
     - Returns: Stable identifier derived from the action prefix and bookmark reference string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
    */
    private func bookmarkInlineActionIdentifier(_ prefix: String) -> String {
        "\(prefix)::\(bookmark.accessibilitySegment)"
    }
}

// MARK: - Filter Chip

/// Capsule-shaped label-filter button used in the bookmark list filter strip.
private struct FilterChip: View {
    /// User-visible chip title.
    let title: String

    /// Base color used for borders and selected-state fill.
    let chipColor: Color

    /// Whether this chip currently represents the active filter.
    let isSelected: Bool

    /// Stable accessibility identifier for UI automation.
    let accessibilityIdentifier: String

    /// Action invoked when the chip is tapped.
    let action: () -> Void

    /// Builds the chip button.
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? chipColor.opacity(0.3) : Color.clear)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(chipColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/**
 Sanitizes bookmark-list text for deterministic accessibility identifiers.

 - Parameter value: Raw user-visible label or reference string.
 - Returns: Identifier-safe text containing only ASCII letters, digits, and underscores.
 - Side effects: none.
 - Failure modes: This helper cannot fail.
 */
private func bookmarkListAccessibilitySegment(_ value: String) -> String {
    let mapped = value.unicodeScalars.map { scalar -> String in
        if CharacterSet.alphanumerics.contains(scalar) {
            return String(scalar)
        }
        return "_"
    }
    let collapsed = mapped.joined().replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

/** Immutable success or failure alert presented by bookmark navigation and CSV transfer. */
private struct BookmarkListPresentedMessage: Identifiable {
    /// Unique presentation identity so repeated equivalent outcomes remain visible.
    let id = UUID()

    /// Localized alert title.
    let title: String

    /// User-visible outcome detail.
    let message: String

    /** Creates a visible failure outcome without side effects. */
    static func error(_ message: String) -> BookmarkListPresentedMessage {
        BookmarkListPresentedMessage(
            title: String(localized: "error_occurred", defaultValue: "Error"),
            message: message
        )
    }

    /** Creates a visible successful transfer outcome without side effects. */
    static func success(_ message: String) -> BookmarkListPresentedMessage {
        BookmarkListPresentedMessage(
            title: String(localized: "success", defaultValue: "Success"),
            message: message
        )
    }
}
