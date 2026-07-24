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

        /// Assign one exact label set to the selected Bible and generic bookmarks.
        case labelAssignment([UUID])

        /// Stable route identity for SwiftUI navigation.
        var id: String {
            switch self {
            case .labelManager:
                return "labelManager"
            case .labelAssignment(let bookmarkIDs):
                return "labelAssignment::" + bookmarkIDs
                    .map(\.uuidString)
                    .sorted()
                    .joined(separator: ",")
            }
        }
    }

    /// App-owned Android popup currently visible over the Bookmark activity.
    private enum BookmarkListPopup {
        case labelFilter
        case overflow
    }

    /// Stable anchor names shared by toolbar/filter controls and their popup surfaces.
    private enum PopupAnchor {
        static let labelFilter = "bookmarkListLabelFilterAnchor"
        static let overflow = "bookmarkListOverflowAnchor"
    }

    /// SwiftData context used for bookmark deletion and save operations.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss action for closing the bookmark sheet.
    @Environment(\.dismiss) private var dismiss

    /// Active scheme used by the shared application popup palette.
    @Environment(\.colorScheme) private var colorScheme

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

    /// Shared popup currently visible from the label selector or overflow action.
    @State private var activePopup: BookmarkListPopup?

    /// Bookmark identifiers selected by Android's contextual multi-select mode.
    @State private var selectedBookmarkIDs: Set<UUID> = []

    /// Selected bookmark identifiers waiting for explicit delete confirmation.
    @State private var pendingDeletionIDs: [UUID] = []

    /// Android-style transient sort description.
    @State private var toastMessage: String?

    /// Current visible navigation or CSV outcome message.
    @State private var presentedMessage: BookmarkListPresentedMessage?

    /// Whether Android CSV import's document picker is presented.
    @State private var showCSVImporter = false

    /// Shared Android column-selection, encoding, preference, and file-destination owner.
    @State private var csvExportWorkflow = AndroidBookmarkCSVExportWorkflow()

    /// Legacy callback retained only until the parent reader adopts exact typed navigation.
    var onNavigate: ((String, Int) -> Void)?

    /// Exact Bible/generic navigation callback for Android-parity reader wiring.
    var onNavigateTarget: ((BookmarkNavigationTarget) throws -> Void)?

    /// Workspace whose label auto-assignment and display overrides are edited from this route.
    private let workspace: Workspace?

    /// Reader/workspace-owned activity, content, and text palette.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Reader-owned route close action; standalone callers fall back to environment dismissal.
    private let onDismiss: (() -> Void)?

    /// Canonical annotation-factory projection for Bible row content.
    private let bibleTextResolver: ((BibleBookmark) -> BookmarkListTextProjection)?

    /// Canonical annotation-factory projection for generic row content.
    private let genericTextResolver: ((GenericBookmark) -> BookmarkListTextProjection)?

    /// Optional SWORD-backed resolver for Bible bookmark ordinals.
    var bibleOrdinalResolver: ((String, Int) -> BookmarkListVerseReference?)?

    /**
     Optional resolver mapping a stored KJVA ordinal into the active module's versification for
     display (Android renders list rows in the current Bible's versification). Exact navigation
     uses `onNavigateTarget` independently of this presentation-only resolver.
     */
    var activeReferenceResolver: ((Int) -> (bookName: String, reference: BookmarkListVerseReference)?)?

    /**
     Creates the bookmark list view.

     - Parameters:
       - onNavigate: Legacy source-compatible callback; exact navigation does not invoke it.
       - onNavigateTarget: Exact typed callback preferred over the legacy chapter-only callback.
       - workspace: Active workspace whose label-specific settings should be shown by Label Manager.
       - bibleOrdinalResolver: Optional resolver that maps `(bookName, ordinal)` to a concrete
         chapter/verse for legacy row display using the active Bible versification.
       - activeReferenceResolver: Optional resolver that maps a stored KJVA ordinal to the active
         module's versification (book name plus chapter/verse) for display only.
       - showsDismissButton: Retained for source compatibility. The app-owned activity always
         provides Android Up navigation and never presents native sheet chrome.
     */
    public init(
        onNavigate: ((String, Int) -> Void)? = nil,
        onNavigateTarget: ((BookmarkNavigationTarget) throws -> Void)? = nil,
        workspace: Workspace? = nil,
        bibleOrdinalResolver: ((String, Int) -> BookmarkListVerseReference?)? = nil,
        activeReferenceResolver: ((Int) -> (bookName: String, reference: BookmarkListVerseReference)?)? = nil,
        showsDismissButton: Bool = true
    ) {
        self.onNavigate = onNavigate
        self.onNavigateTarget = onNavigateTarget
        self.workspace = workspace
        self.surfacePalette = .standard
        self.onDismiss = nil
        self.bibleTextResolver = nil
        self.genericTextResolver = nil
        self.bibleOrdinalResolver = bibleOrdinalResolver
        self.activeReferenceResolver = activeReferenceResolver
        _ = showsDismissButton
    }

    /**
     Creates the reader-owned app activity with its live palette and canonical content resolvers.

     - Parameters:
       - surfacePalette: Active window/workspace palette shared with reader chrome.
       - onDismiss: Clears the reader-owned destination without native sheet dismissal.
       - bibleTextResolver: Reader annotation-factory projection for Bible bookmark text.
       - genericTextResolver: Stored-source annotation-factory projection for generic text.
       - onNavigateTarget: Exact typed navigation callback.
       - workspace: Active workspace for shared label management.
       - bibleOrdinalResolver: Legacy source-ordinal display resolver.
       - activeReferenceResolver: Active-module KJVA display resolver.
     - Side effects: none until the user invokes an action.
     - Failure modes: Missing content resolvers leave verse previews empty while retaining rows.
     */
    init(
        surfacePalette: ReaderThemeSurfacePalette,
        onDismiss: @escaping () -> Void,
        bibleTextResolver: @escaping (BibleBookmark) -> BookmarkListTextProjection,
        genericTextResolver: @escaping (GenericBookmark) -> BookmarkListTextProjection,
        onNavigateTarget: ((BookmarkNavigationTarget) throws -> Void)? = nil,
        workspace: Workspace? = nil,
        bibleOrdinalResolver: ((String, Int) -> BookmarkListVerseReference?)? = nil,
        activeReferenceResolver: ((Int) -> (bookName: String, reference: BookmarkListVerseReference)?)? = nil
    ) {
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
        self.bibleTextResolver = bibleTextResolver
        self.genericTextResolver = genericTextResolver
        self.onNavigate = nil
        self.onNavigateTarget = onNavigateTarget
        self.workspace = workspace
        self.bibleOrdinalResolver = bibleOrdinalResolver
        self.activeReferenceResolver = activeReferenceResolver
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
                    activeReferenceResolver: activeReferenceResolver,
                    textProjection: bibleTextResolver?($0) ?? .empty
                )
            }
        let genericItems = genericBookmarks.map {
            BookmarkListItem(
                genericBookmark: $0,
                textProjection: genericTextResolver?($0) ?? .empty
            )
        }
        return bibleItems + genericItems
    }

    /// Android assignable labels in stable visible-name order, excluding synthetic Unlabelled.
    private var assignableLabels: [BibleCore.Label] {
        labels
            .filter { $0.id != BibleCore.Label.unlabeledId && $0.name != BibleCore.Label.unlabeledName }
            .sorted { lhs, rhs in
                let comparison = AndroidLabelPresentation.displayName(for: lhs)
                    .localizedCaseInsensitiveCompare(AndroidLabelPresentation.displayName(for: rhs))
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /**
     Builds the bookmark list screen, empty state, and related navigation destinations.
     */
    public var body: some View {
        AndroidActivitySurface(palette: surfacePalette) {
            appBar
        } content: {
            VStack(spacing: 0) {
                labelFilterSelector
                if showNotes {
                    bookmarkSearchSection
                }
                Divider().overlay(surfacePalette.inactiveBorderColor)
                bookmarkList
            }
        }
        .overlay(alignment: .topLeading) {
            AndroidActivityAccessibilityMarker(
                label: String(localized: "bookmarks", defaultValue: "Bookmarks"),
                accessibilityIdentifier: "bookmarkListScreen",
                accessibilityValue: bookmarkListAccessibilityValue,
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .overlay(alignment: .topLeading) {
            bookmarkListStateExport
        }
        .navigationDestination(item: $activeBookmarkListRoute) { route in
            bookmarkListDestination(route)
        }
        .onAppear(perform: restoreBookmarkListPreferences)
        .onChange(of: sortOrder) { _, value in
            selectedBookmarkIDs = []
            SettingsStore(modelContext: modelContext).setString(.bookmarkSortOrder, value: value.rawValue)
        }
        .onChange(of: showNotes) { _, value in
            selectedBookmarkIDs = []
            if !value { searchText = "" }
            SettingsStore(modelContext: modelContext).setBool(.bookmarkShowNotes, value: value)
        }
        .onChange(of: selectedLabelId) { _, _ in selectedBookmarkIDs = [] }
        .onChange(of: searchText) { _, _ in selectedBookmarkIDs = [] }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.labelFilter,
            isPresented: popupBinding(.labelFilter),
            menuWidth: 300,
            estimatedMenuHeight: min(CGFloat(labelFilterOptions.count) * 48, 420),
            accessibilityIdentifier: "bookmarkListLabelFilterMenu"
        ) {
            labelFilterMenu
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: popupBinding(.overflow),
            menuWidth: 280,
            estimatedMenuHeight: 146,
            accessibilityIdentifier: "bookmarkListOverflowMenu"
        ) {
            bookmarkOverflowMenu
        }
        .overlay {
            if csvExportWorkflow.showsColumnSelector {
                BookmarkCSVColumnSelectionView(
                    selectedColumns: csvExportWorkflow.selectedColumns,
                    onExport: { columns in
                        csvExportWorkflow.prepareExport(
                            columns: columns,
                            modelContext: modelContext
                        )
                    },
                    onCancel: csvExportWorkflow.cancelColumnSelection
                )
            }
        }
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: BookmarkCSVTransferDocument.readableContentTypes,
            allowsMultipleSelection: false,
            onCompletion: importCSVSelection
        )
        .fileExporter(
            isPresented: Binding(
                get: { csvExportWorkflow.showsFileExporter },
                set: { csvExportWorkflow.showsFileExporter = $0 }
            ),
            document: csvExportWorkflow.exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: csvExportWorkflow.exportFileName,
            onCompletion: csvExportWorkflow.handleFileExportCompletion
        )
        .overlay {
            if let message = presentedMessage {
                AndroidDecisionDialog(
                    title: message.title,
                    message: message.message,
                    actions: [.init(id: "okay", title: String(localized: "ok", defaultValue: "OK"), style: .normal) { presentedMessage = nil }],
                    accessibilityIdentifier: "androidBookmarkListFeedbackDialog"
                )
            } else if let feedback = csvExportWorkflow.feedback {
                AndroidDecisionDialog(
                    title: feedback.title,
                    message: feedback.message,
                    actions: [
                        .init(
                            id: "okay",
                            title: String(localized: "ok", defaultValue: "OK"),
                            style: .normal
                        ) {
                            csvExportWorkflow.feedback = nil
                        },
                    ],
                    accessibilityIdentifier: "androidBookmarkListCSVFeedbackDialog"
                )
            }
        }
        .overlay { deleteConfirmationDialog }
        .androidToastFeedback(toastMessage, bottomPadding: 48)
    }

    /// Builds app-owned bookmark-list destinations without introducing nested iOS sheets.
    @ViewBuilder
    private func bookmarkListDestination(_ route: BookmarkListRoute) -> some View {
        switch route {
        case .labelManager:
            LabelManagerView(
                workspace: workspace,
                surfacePalette: surfacePalette,
                onDismiss: { activeBookmarkListRoute = nil }
            )
        case .labelAssignment(let bookmarkIDs):
            LabelAssignmentView(
                bookmarkIDs: bookmarkIDs,
                workspace: workspace,
                surfacePalette: surfacePalette,
                onDismiss: { activeBookmarkListRoute = nil }
            )
        }
    }

    /// Shared Android activity bar in normal or contextual selection mode.
    private var appBar: some View {
        AndroidActivityTopAppBar(
            title: selectedBookmarkIDs.isEmpty
                ? String(localized: "bookmarks", defaultValue: "Bookmarks")
                : "",
            accessibilityIdentifier: "bookmarkListAppBar",
            accessibilityValue: selectedBookmarkIDs.isEmpty
                ? ""
                : "selected=\(selectedBookmarkIDs.count)",
            backgroundColor: surfacePalette.toolbarBackgroundColor,
            foregroundColor: surfacePalette.toolbarForegroundColor,
            onBack: selectedBookmarkIDs.isEmpty ? closeBookmarkList : clearBookmarkSelection,
            navigationIcon: selectedBookmarkIDs.isEmpty
                ? .asset("ActivityBack")
                : .asset("ActivityClose"),
            navigationAccessibilityLabel: selectedBookmarkIDs.isEmpty
                ? String(localized: "back", defaultValue: "Back")
                : String(localized: "close", defaultValue: "Close")
        ) {
            if selectedBookmarkIDs.isEmpty {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("BookmarkManageLabels"),
                    accessibilityLabel: String(localized: "manage_labels", defaultValue: "Manage labels"),
                    accessibilityIdentifier: "bookmarkListManageLabelsButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: {
                        activePopup = nil
                        activeBookmarkListRoute = .labelManager
                    }
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset(BookmarkListProjection.sortIconName(for: sortOrder)),
                    accessibilityLabel: BookmarkListProjection.sortDescription(for: sortOrder),
                    accessibilityIdentifier: "bookmarkListSortButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: advanceSortOrder
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "bookmarkListOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: { togglePopup(.overflow) }
                )
                .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            } else {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("BookmarkLabel"),
                    accessibilityLabel: String(localized: "assign_labels", defaultValue: "Assign labels"),
                    accessibilityIdentifier: "bookmarkListAssignLabelsButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: beginLabelAssignment
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityDelete"),
                    accessibilityLabel: String(localized: "delete", defaultValue: "Delete"),
                    accessibilityIdentifier: "bookmarkListDeleteSelectionButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: requestSelectedBookmarkDeletion
                )
            }
        }
    }

    /// Android spinner-style label selector that owns the current filter popup anchor.
    private var labelFilterSelector: some View {
        Button { togglePopup(.labelFilter) } label: {
            HStack(spacing: 10) {
                Text(selectedLabelFilterTitle)
                    .font(.system(size: 17))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AndBibleIconView(name: "PromptExpandIndicator", size: 16)
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(surfacePalette.foregroundColor)
        .background(surfacePalette.backgroundColor)
        .androidPopupMenuAnchor(id: PopupAnchor.labelFilter)
        .accessibilityIdentifier("bookmarkListLabelFilterButton")
        .accessibilityValue(bookmarkListSelectedLabelAccessibilityToken)
    }

    /// Scrollable Android Bookmark rows or the activity's simple empty-list text.
    private var bookmarkList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if filteredBookmarks.isEmpty {
                    Text(String(localized: "empty_list", defaultValue: "No items to display"))
                        .font(.system(size: 17))
                        .foregroundStyle(surfacePalette.foregroundColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                        .accessibilityIdentifier("bookmarkListEmptyText")
                }
                ForEach(filteredBookmarks) { bookmark in
                BookmarkRow(
                    bookmark: bookmark,
                    showNotes: showNotes,
                    isSelected: selectedBookmarkIDs.contains(bookmark.id),
                    unlabeledColor: unlabeledLabelColor,
                    surfacePalette: surfacePalette,
                    onSelect: { handleBookmarkTap(bookmark) },
                    onLongPress: { beginBookmarkSelection(bookmark) }
                )
                    Divider().overlay(surfacePalette.inactiveBorderColor)
                }
            }
        }
    }

    /**
     Visible bookmark search control that mirrors Android's in-content bookmark search layout.

     Android's `Bookmarks` activity owns an `EditText` under the label selector rather than search
     chrome in the action bar. This app-owned row uses the same note-only hint and clear action.
     */
    private var bookmarkSearchSection: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                #if os(iOS)
                TextField(
                    "",
                    text: $searchText,
                    prompt: Text(String(localized: "filter_by_notes", defaultValue: "Search notes"))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("bookmarkListSearchField")
                #else
                TextField(
                    "",
                    text: $searchText,
                    prompt: Text(String(localized: "filter_by_notes", defaultValue: "Search notes"))
                )
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("bookmarkListSearchField")
                #endif
                Rectangle()
                    .fill(AndroidDialogSurfacePalette.accent(for: colorScheme))
                    .frame(height: 2)
            }

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    AndBibleIconView(name: "ActivityClose", size: 20)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .accessibilityIdentifier("bookmarkListClearSearchButton")
                .accessibilityLabel(String(localized: "clear", defaultValue: "Clear"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(surfacePalette.backgroundColor)
        .accessibilityElement(children: .contain)
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

    /// Android label spinner choices: All, Unlabelled, then every assignable persisted label.
    private var labelFilterOptions: [BookmarkLabelFilterOption] {
        [
            BookmarkLabelFilterOption(
                labelID: nil,
                title: String(localized: "all", defaultValue: "All")
            ),
            BookmarkLabelFilterOption(
                labelID: BibleCore.Label.unlabeledId,
                title: String(localized: "label_unlabelled", defaultValue: "Unlabelled")
            ),
        ] + assignableLabels.map {
            BookmarkLabelFilterOption(
                labelID: $0.id,
                title: AndroidLabelPresentation.displayName(for: $0)
            )
        }
    }

    /// Current Android spinner title.
    private var selectedLabelFilterTitle: String {
        labelFilterOptions.first { $0.labelID == selectedLabelId }?.title
            ?? String(localized: "all", defaultValue: "All")
    }

    /// Canonical Unlabelled tag color, with Android's blue-highlight default as fallback.
    private var unlabeledLabelColor: Color {
        let label = labels.first {
            $0.id == BibleCore.Label.unlabeledId || $0.name == BibleCore.Label.unlabeledName
        }
        return Color(argbInt: label?.color ?? BibleCore.Label.defaultColor)
    }

    /// Shared app-owned popup used by Android's label spinner.
    private var labelFilterMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "bookmarkListLabelFilterSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(labelFilterOptions) { option in
                        AndroidPopupMenuRow(
                            title: option.title,
                            accessibilityIdentifier: "bookmarkListFilterOption::\(option.accessibilitySegment)",
                            accessibilityValue: option.labelID == selectedLabelId ? "selected" : ""
                        ) {
                            selectedLabelId = option.labelID
                            activePopup = nil
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
        }
    }

    /// Shared app-owned overflow popup with Android's checkable notes and CSV commands.
    private var bookmarkOverflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "bookmarkListOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            VStack(spacing: 0) {
                AndroidPopupMenuRow(
                    title: String(localized: "show_notes", defaultValue: "Show notes"),
                    accessory: .checkbox(isOn: showNotes),
                    accessibilityIdentifier: "bookmarkListShowNotesToggle",
                    accessibilityValue: showNotes ? "on" : "off"
                ) {
                    showNotes.toggle()
                    activePopup = nil
                }
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "export_something", defaultValue: "Export %@"),
                        "CSV"
                    ),
                    accessibilityIdentifier: "bookmarkListExportCSVButton"
                ) {
                    activePopup = nil
                    if filteredBookmarks.contains(where: \.isBibleBookmark) {
                        presentCSVColumnSelector()
                    }
                }
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "import_items", defaultValue: "Import %@"),
                        "CSV"
                    ),
                    accessibilityIdentifier: "bookmarkListImportCSVButton"
                ) {
                    activePopup = nil
                    showCSVImporter = true
                }
            }
        }
    }

    /// Message-only Android confirmation for contextual bookmark deletion.
    @ViewBuilder
    private var deleteConfirmationDialog: some View {
        if !pendingDeletionIDs.isEmpty {
            AndroidDecisionDialog(
                title: "",
                message: String.localizedStringWithFormat(
                    String(
                        localized: "confirm_delete_bookmarks",
                        defaultValue: "Do you want to remove %ld bookmarks and their notes?"
                    ),
                    pendingDeletionIDs.count
                ),
                actions: [
                    .init(
                        id: "yes",
                        title: String(localized: "yes", defaultValue: "Yes"),
                        style: .destructive,
                        perform: confirmSelectedBookmarkDeletion
                    ),
                    .init(
                        id: "cancel",
                        title: String(localized: "cancel", defaultValue: "Cancel"),
                        style: .normal,
                        perform: { pendingDeletionIDs = [] }
                    ),
                ],
                accessibilityIdentifier: "bookmarkListDeleteConfirmationDialog"
            )
        }
    }

    /// Binding adapter used by both shared popup modifiers.
    private func popupBinding(_ popup: BookmarkListPopup) -> Binding<Bool> {
        Binding(
            get: { activePopup == popup },
            set: { isPresented in
                if isPresented {
                    activePopup = popup
                } else if activePopup == popup {
                    activePopup = nil
                }
            }
        )
    }

    /// Toggles one popup while ensuring the two Android menus remain mutually exclusive.
    private func togglePopup(_ popup: BookmarkListPopup) {
        activePopup = activePopup == popup ? nil : popup
    }

    /// Advances through Android's direct four-state sort cycle and shows its category toast.
    private func advanceSortOrder() {
        activePopup = nil
        let next = BookmarkListProjection.nextSortOrder(after: sortOrder)
        sortOrder = next
        let message = BookmarkListProjection.sortDescription(for: next)
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(AndroidToastFeedback.shortDuration))
            if toastMessage == message { toastMessage = nil }
        }
    }

    /// Starts contextual mode with the long-pressed bookmark selected.
    private func beginBookmarkSelection(_ bookmark: BookmarkListItem) {
        activePopup = nil
        selectedBookmarkIDs.insert(bookmark.id)
    }

    /// Navigates normally or toggles the tapped row while contextual mode is active.
    private func handleBookmarkTap(_ bookmark: BookmarkListItem) {
        guard !selectedBookmarkIDs.isEmpty else {
            navigate(to: bookmark)
            return
        }
        if selectedBookmarkIDs.contains(bookmark.id) {
            selectedBookmarkIDs.remove(bookmark.id)
        } else {
            selectedBookmarkIDs.insert(bookmark.id)
        }
    }

    /// Exits Android contextual action mode without closing the Bookmark activity.
    private func clearBookmarkSelection() {
        selectedBookmarkIDs = []
        pendingDeletionIDs = []
    }

    /**
     Opens canonical label assignment after ending Android contextual action mode.

     Android's `ListActionModeHelper` finishes action mode before dispatching Assign labels, so the
     selected bookmark identities must be captured before clearing the visible contextual state.

     - Side effects: Clears contextual selection and presents Label Assignment for the captured IDs.
     - Failure modes: An empty selection leaves the current activity unchanged.
     */
    private func beginLabelAssignment() {
        let bookmarkIDs = selectedBookmarkIDs.sorted { $0.uuidString < $1.uuidString }
        guard !bookmarkIDs.isEmpty else { return }
        selectedBookmarkIDs = []
        activeBookmarkListRoute = .labelAssignment(bookmarkIDs)
    }

    /// Stages the current contextual selection for Android's explicit confirmation.
    private func requestSelectedBookmarkDeletion() {
        pendingDeletionIDs = selectedBookmarkIDs.sorted { $0.uuidString < $1.uuidString }
    }

    /// Deletes the confirmed selection in one save and exits contextual mode.
    private func confirmSelectedBookmarkDeletion() {
        let selected = bookmarkListItems.filter { pendingDeletionIDs.contains($0.id) }
        do {
            _ = try BookmarkListMutation.deleteItems(selected, in: modelContext)
            clearBookmarkSelection()
        } catch {
            pendingDeletionIDs = []
            presentedMessage = .error(error.localizedDescription)
        }
    }

    /// Returns to the reader-owned route, or dismisses a standalone host.
    private func closeBookmarkList() {
        activePopup = nil
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
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
    }

    /** Opens Android's export-column selector with the persisted selection. */
    private func presentCSVColumnSelector() {
        let bookmarks = filteredBookmarks.compactMap { item -> BibleBookmark? in
            guard case .bible(let bookmark) = item.source else { return nil }
            return bookmark
        }
        csvExportWorkflow.beginExport(bookmarks: bookmarks, modelContext: modelContext)
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
                closeBookmarkList()
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
            if selectedLabelId == BibleCore.Label.unlabeledId {
                result = result.filter(\.labels.isEmpty)
            } else {
                result = result.filter { $0.labels.contains { $0.id == selectedLabelId } }
            }
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
     Advances through Android Bookmark's direct sort-button cycle.

     - Parameter sortOrder: Current persisted sort state.
     - Returns: `bibleOrderDesc`, `createdAtDesc`, `createdAt`, or `bibleOrder` in Android order;
       unsupported legacy states enter at `createdAtDesc`.
     - Side effects: none.
     - Failure modes: none.
     */
    static func nextSortOrder(after sortOrder: BookmarkSortOrder) -> BookmarkSortOrder {
        switch sortOrder {
        case .bibleOrder: return .bibleOrderDesc
        case .bibleOrderDesc: return .createdAtDesc
        case .createdAtDesc: return .createdAt
        case .createdAt: return .bibleOrder
        case .lastUpdated, .orderNumber: return .createdAtDesc
        }
    }

    /** Returns the exact ported Android sort drawable for one persisted sort state. */
    static func sortIconName(for sortOrder: BookmarkSortOrder) -> String {
        switch sortOrder {
        case .bibleOrder: return "BookmarkSortBibleAscending"
        case .bibleOrderDesc: return "BookmarkSortBibleDescending"
        case .createdAt: return "BookmarkSortDateAscending"
        case .createdAtDesc, .lastUpdated, .orderNumber: return "BookmarkSortDateDescending"
        }
    }

    /** Returns Android's category toast/accessibility text for one sort state. */
    static func sortDescription(for sortOrder: BookmarkSortOrder) -> String {
        switch sortOrder {
        case .bibleOrder, .bibleOrderDesc:
            return String(localized: "sort_by_bible_book", defaultValue: "Sort by Bible book")
        case .createdAt, .createdAtDesc, .lastUpdated, .orderNumber:
            return String(localized: "sort_by_date", defaultValue: "Sort by date")
        }
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
        guard let selectedLabelId else { return "all" }
        if selectedLabelId == BibleCore.Label.unlabeledId { return "unlabelled" }
        guard let label = labels.first(where: { $0.id == selectedLabelId }) else {
            return "all"
        }
        return bookmarkListAccessibilitySegment(AndroidLabelPresentation.displayName(for: label))
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

/** One stable Android label-spinner row, including synthetic All and Unlabelled choices. */
private struct BookmarkLabelFilterOption: Identifiable {
    /// Persisted label identity, `nil` only for Android's synthetic All row.
    let labelID: UUID?

    /// Localized visible title.
    let title: String

    /// Stable SwiftUI identity that cannot collide with a persisted label UUID.
    var id: String { labelID?.uuidString ?? "all" }

    /// Sanitized identifier segment used by UI automation.
    var accessibilitySegment: String {
        labelID == nil ? "all" : bookmarkListAccessibilitySegment(title)
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

    /// Canonical Android prefix/selection/suffix row content from the reader annotation factory.
    let textProjection: BookmarkListTextProjection

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
        activeReferenceResolver: ((Int) -> (bookName: String, reference: BookmarkListVerseReference)?)? = nil,
        textProjection: BookmarkListTextProjection = .empty
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
        self.textProjection = textProjection
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
    init(
        genericBookmark bookmark: GenericBookmark,
        textProjection: BookmarkListTextProjection = .empty
    ) {
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
        self.textProjection = textProjection
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

 This is the SwiftUI projection of Android `bookmark_list_item.xml` and `BookmarkItemAdapter`: exact
 generic label tags, Speak headphones, reference/date, emphasized bookmark content, and optional
 HTML notes. Selection is owned by the parent contextual action mode rather than native swipe or
 context-menu gestures.
 */
private struct BookmarkRow: View {
    /// Active AppCompat scheme used for the shared selection accent.
    @Environment(\.colorScheme) private var colorScheme

    /// Bookmark being rendered.
    let bookmark: BookmarkListItem

    /// Whether note previews are visible under Android's persisted setting.
    let showNotes: Bool

    /// Whether Android contextual action mode currently includes this row.
    let isSelected: Bool

    /// Android blue-highlight color used for the synthetic Unlabelled tag.
    let unlabeledColor: Color

    /// Reader/workspace palette inherited by the app-owned activity.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Callback used to resolve or visibly reject the exact bookmark target.
    let onSelect: () -> Void

    /// Callback that starts Android contextual selection after a long press.
    let onLongPress: () -> Void

    /**
     Builds one bookmark row with Android's mutually exclusive click and long-click behavior.

     Inputs: immutable bookmark projection, selection state, owner palette, and parent commands

     Output: one accessible row whose long press enters contextual mode and whose tap navigates or
     toggles an existing contextual selection

     Side effects: invokes exactly one parent command after a recognized gesture

     Failure modes: none; an incomplete gesture invokes neither command
    */
    var body: some View {
        AndroidTapLongPressButton(
            isLongPressActionActive: isSelected,
            onTap: onSelect,
            onLongPress: onLongPress
        ) {
            VStack(alignment: .leading, spacing: 4) {
                headerRow
                bookmarkContent
                notePreview
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(isSelected
                ? AndroidDialogSurfacePalette.accent(for: colorScheme).opacity(0.24)
                : Color.clear)
            .contentShape(Rectangle())
        }
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAction(named: Text(String(localized: "select", defaultValue: "Select"))) {
            onLongPress()
        }
        .accessibilityIdentifier(bookmarkRowIdentifier())
    }

    /// Assigned labels rendered as Android's generic tag glyphs, excluding Speak.
    private var visibleTagLabels: [BibleCore.Label] {
        bookmark.labels.filter { $0.name != BibleCore.Label.speakLabelName }
    }

    /// Whether the exact Android Speak headphones belong before the reference.
    private var hasSpeakLabel: Bool {
        bookmark.labels.contains { $0.name == BibleCore.Label.speakLabelName }
    }

    /// Header row containing label tags, Speak state, reference, and Android's fixed date pattern.
    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if bookmark.labels.isEmpty {
                AndBibleIconView(name: "BookmarkLabel", size: 24)
                    .foregroundStyle(unlabeledColor)
            } else {
                ForEach(visibleTagLabels) { label in
                    AndBibleIconView(name: "BookmarkLabel", size: 24)
                        .foregroundStyle(Color(argbInt: label.color))
                }
            }

            if hasSpeakLabel {
                AndBibleIconView(name: "BookmarkSpeak", size: 24)
                    .foregroundStyle(surfacePalette.foregroundColor)
            }

            Text(bookmark.reference)
                .font(.system(size: 17))
                .lineLimit(2)
                .layoutPriority(1)

            Spacer(minLength: 8)

            Text(formattedCreationDate)
                .font(.system(size: 13))
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    /// Verse/generic source content with only the persisted selection emphasized.
    private var bookmarkContent: some View {
        if !bookmark.textProjection.fullText.isEmpty {
            (Text(bookmark.textProjection.prefix)
                + Text(bookmark.textProjection.selectedText).bold()
                + Text(bookmark.textProjection.suffix))
                .font(.system(size: 14))
                .foregroundStyle(surfacePalette.foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    /// Optional note-preview text shown when the bookmark has saved note content.
    private var notePreview: some View {
        if showNotes, !bookmark.noteText.isEmpty {
            if let attributedNote {
                Text(attributedNote)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } else {
                Text(bookmark.noteText)
                    .font(.system(size: 14))
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    /// HTML note spans recolored to the owning reader/workspace palette.
    private var attributedNote: AttributedString? {
        guard var attributed = try? AttributedString(htmlBody: bookmark.noteText) else { return nil }
        attributed.foregroundColor = surfacePalette.foregroundColor
        return attributed
    }

    /// Android `EEE, yyyy-MM-dd HH:mm` timestamp rendered in the user's locale/time zone.
    private var formattedCreationDate: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, yyyy-MM-dd HH:mm"
        return formatter.string(from: bookmark.createdAt)
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
