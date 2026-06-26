// BookmarkListView.swift — Bookmark list screen

import SwiftUI
import SwiftData
import BibleCore

/**
 Verse reference resolved from an Android/JSword-style bookmark ordinal.

 Bookmark rows are built from persisted SwiftData records, but those records store ordinals in the
 source versification rather than chapter/verse text. The reader injects a resolver backed by
 SWORD's `VerseKey` so the list can display and navigate bookmarks without reintroducing local
 ordinal arithmetic.
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

 `BookmarkListView` is the main bookmark-browser surface. It excludes note-bearing bookmarks that
 belong in the My Notes flow, supports label-chip filtering, search-by-reference text, and
 navigation back into the reader or into a label's study pad.

 Data dependencies:
 - `modelContext` is used for bookmark deletion
 - `bibleBookmarks` queries all `BibleBookmark` records for in-memory filtering and sorting
 - `genericBookmarks` queries all `GenericBookmark` records for in-memory filtering and sorting
 - `labels` queries all labels so the view can build filter chips and label-manager entry points

 Side effects:
 - deleting rows or context-menu deletions mutate SwiftData and save immediately
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
    @State private var sortOrder: BookmarkSortOrder = .createdAtDesc

    /// Selected label filter, or `nil` when showing all labels.
    @State private var selectedLabelId: UUID?

    /// Search text applied to formatted references and note previews.
    @State private var searchText = ""

    /// Current bookmark-list route for label management or label assignment.
    @State private var activeBookmarkListRoute: BookmarkListRoute?

    /// Optional callback used to navigate back into the reader for a bookmark.
    var onNavigate: ((String, Int) -> Void)?

    /// Optional callback used to open a study pad for a selected label.
    var onOpenStudyPad: ((UUID) -> Void)?

    /// Optional SWORD-backed resolver for Bible bookmark ordinals.
    var bibleOrdinalResolver: ((String, Int) -> BookmarkListVerseReference?)?

    /// Whether the list should expose sheet-style explicit dismiss chrome.
    private let showsDismissButton: Bool

    /**
     Creates the bookmark list view.

     - Parameters:
       - onNavigate: Callback invoked when the user opens a bookmark from the list.
       - onOpenStudyPad: Callback invoked when the user wants to open a selected label's study pad.
       - bibleOrdinalResolver: Optional resolver that maps `(bookName, ordinal)` to a concrete
         chapter/verse using the active Bible versification.
       - showsDismissButton: Whether to show the sheet-style Done button; app-owned destination
         routes rely on navigation-stack back chrome instead.
     */
    public init(
        onNavigate: ((String, Int) -> Void)? = nil,
        onOpenStudyPad: ((UUID) -> Void)? = nil,
        bibleOrdinalResolver: ((String, Int) -> BookmarkListVerseReference?)? = nil,
        showsDismissButton: Bool = true
    ) {
        self.onNavigate = onNavigate
        self.onOpenStudyPad = onOpenStudyPad
        self.bibleOrdinalResolver = bibleOrdinalResolver
        self.showsDismissButton = showsDismissButton
    }

    /**
     Bookmarks after note suppression, label filtering, text filtering, and sort application.
     */
    private var filteredBookmarks: [BookmarkListItem] {
        var result = bookmarkListItems

        // Filter by label
        if let labelId = selectedLabelId {
            result = result.filter { $0.labels.contains { $0.id == labelId } }
        }

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { $0.searchableText.localizedCaseInsensitiveContains(searchText) }
        }

        // Sort
        switch sortOrder {
        case .bibleOrder:
            result.sort { Self.compareBookmarkListItems($0, $1, by: \.documentSortKey, ascending: true) }
        case .bibleOrderDesc:
            result.sort { Self.compareBookmarkListItems($0, $1, by: \.documentSortKey, ascending: false) }
        case .createdAt:
            result.sort { Self.compareBookmarkListItems($0, $1, by: \.createdAt, ascending: true) }
        case .createdAtDesc:
            result.sort { Self.compareBookmarkListItems($0, $1, by: \.createdAt, ascending: false) }
        case .lastUpdated:
            result.sort { Self.compareBookmarkListItems($0, $1, by: \.lastUpdatedOn, ascending: false) }
        case .orderNumber:
            result.sort { Self.compareBookmarkListItems($0, $1, by: \.documentSortKey, ascending: true) }
        }

        return result
    }

    /// Bookmark rows that belong in the native bookmark browser before label/search filtering.
    private var bookmarkListItems: [BookmarkListItem] {
        let bibleItems = bibleBookmarks
            .filter { ($0.notes?.notes ?? "").isEmpty }
            .map { BookmarkListItem(bibleBookmark: $0, ordinalResolver: bibleOrdinalResolver) }
        let genericItems = genericBookmarks
            .filter { ($0.notes?.notes ?? "").isEmpty }
            .map(BookmarkListItem.init(genericBookmark:))
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
        .searchable(text: $searchText, prompt: String(localized: "search_bookmarks"))
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
                }
            }
        }
        .navigationDestination(item: $activeBookmarkListRoute) { route in
            bookmarkListDestination(route)
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

            // Bookmark list
            ForEach(filteredBookmarks) { bookmark in
                BookmarkRow(
                    bookmark: bookmark,
                    onNavigate: onNavigate,
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

    /// Stable bookmark-list state exported for UI automation, including route presentation flags.
    private var bookmarkListAccessibilityValue: String {
        let baseState = [
            "count=\(filteredBookmarks.count)",
            "selectedLabel=\(bookmarkListSelectedLabelAccessibilityToken)",
            "query=\(bookmarkListAccessibilitySegment(searchText))",
            "labelAssignment=\(bookmarkListIsAssigningLabels ? "true" : "false")",
        ].joined(separator: ";")
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }

        let rowTokens = filteredBookmarks.prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit).map {
            "|\($0.accessibilitySegment)|"
        }.joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
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
        guard let labelId = selectedLabelId,
              let label = labels.first(where: { $0.id == labelId })
        else {
            return "all"
        }
        return bookmarkListAccessibilitySegment(label.name)
    }

    /// Sort-order menu shown in the navigation bar.
    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "sort"), selection: $sortOrder) {
                Text(String(localized: "sort_bible_order"))
                    .tag(BookmarkSortOrder.bibleOrder)
                    .accessibilityIdentifier("bookmarkListSortOption::bibleOrder")
                Text(String(localized: "sort_date_created"))
                    .tag(BookmarkSortOrder.createdAtDesc)
                    .accessibilityIdentifier("bookmarkListSortOption::createdAtDesc")
                Text(String(localized: "sort_last_updated"))
                    .tag(BookmarkSortOrder.lastUpdated)
                    .accessibilityIdentifier("bookmarkListSortOption::lastUpdated")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("bookmarkListSortMenu")
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
        for bookmark in toDelete {
            deleteBookmarkWithoutSaving(bookmark)
        }
        try? modelContext.save()
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
        deleteBookmarkWithoutSaving(bookmark)
        try? modelContext.save()
    }

    /// Deletes one bookmark row from SwiftData without saving the context.
    private func deleteBookmarkWithoutSaving(_ bookmark: BookmarkListItem) {
        switch bookmark.source {
        case .bible(let bibleBookmark):
            modelContext.delete(bibleBookmark)
        case .generic(let genericBookmark):
            modelContext.delete(genericBookmark)
        }
    }

    /**
     Converts bookmark ordinals into a human-readable verse reference string.

     - Parameter bookmark: Bookmark whose ordinals should be rendered for the list UI.
     - Returns: Reference text like `Genesis 1:1`, `Genesis 1:1-3`, or `Genesis 1:31-2:1`.
     */
    static func verseReference(
        for bookmark: BibleBookmark,
        ordinalResolver: ((String, Int) -> BookmarkListVerseReference?)? = nil
    ) -> String {
        let bookName = bookmark.book ?? "Unknown"
        let startReference = ordinalResolver?(bookName, bookmark.ordinalStart)
            ?? compatibilityVerseReference(ordinal: bookmark.ordinalStart)
        // Normalize: treat endOrdinal <= 0 or <= startOrdinal as single verse
        let effectiveEnd = bookmark.ordinalEnd > bookmark.ordinalStart ? bookmark.ordinalEnd : bookmark.ordinalStart
        let endReference = ordinalResolver?(bookName, effectiveEnd)
            ?? compatibilityVerseReference(ordinal: effectiveEnd)

        if effectiveEnd == bookmark.ordinalStart || endReference == startReference {
            return "\(bookName) \(startReference.chapter):\(startReference.verse)"
        } else if endReference.chapter == startReference.chapter {
            return "\(bookName) \(startReference.chapter):\(startReference.verse)-\(endReference.verse)"
        } else {
            return "\(bookName) \(startReference.chapter):\(startReference.verse)-\(endReference.chapter):\(endReference.verse)"
        }
    }

    /**
     Compatibility fallback for no-module bookmark list previews.

     Real reader-owned bookmark lists should inject `bibleOrdinalResolver` so ordinals are decoded
     through SWORD's versification. The fallback keeps design previews and isolated unit tests
     functional when no reader/controller exists.
     */
    fileprivate static func compatibilityVerseReference(ordinal: Int) -> BookmarkListVerseReference {
        let chapter = max(1, ((ordinal - 1) / 40) + 1)
        let verse = max(1, ordinal - ((chapter - 1) * 40))
        return BookmarkListVerseReference(chapter: chapter, verse: verse)
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

    /// Compares two rows by a primary key and uses reference/id tiebreakers for deterministic UI order.
    private static func compareBookmarkListItems<Value: Comparable>(
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

// MARK: - UUID Identifiable for sheet(item:)

/// Retroactive `Identifiable` conformance so raw `UUID` values can drive `sheet(item:)`.
extension UUID: @retroactive Identifiable {
    /// Retroactive `Identifiable` conformance value for SwiftUI sheet presentation.
    public var id: UUID { self }
}

// MARK: - Bookmark List Item

/// Normalized row data for Bible and generic bookmarks shown in `BookmarkListView`.
private struct BookmarkListItem: Identifiable {
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

    /// Stable document-order key used by sort options.
    let documentSortKey: Int

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

    /// Optional reader navigation target for Bible bookmarks.
    let navigationTarget: (bookName: String, chapter: Int)?

    /// Identifier-safe row reference segment used by UI automation.
    var accessibilitySegment: String {
        bookmarkListAccessibilitySegment(reference)
    }

    /// Creates a normalized row for one Bible bookmark.
    init(
        bibleBookmark bookmark: BibleBookmark,
        ordinalResolver: ((String, Int) -> BookmarkListVerseReference?)? = nil
    ) {
        let reference = BookmarkListView.verseReference(for: bookmark, ordinalResolver: ordinalResolver)
        let noteText = bookmark.notes?.notes ?? ""
        self.id = bookmark.id
        self.source = .bible(bookmark)
        self.reference = reference
        self.searchableText = "\(reference) \(noteText)"
        self.documentSortKey = bookmark.kjvOrdinalStart
        self.createdAt = bookmark.createdAt
        self.lastUpdatedOn = bookmark.lastUpdatedOn
        self.customIcon = bookmark.customIcon
        self.noteText = noteText
        self.labels = bookmark.bookmarkToLabels?.compactMap { $0.label }.sorted { $0.name < $1.name } ?? []
        let bookName = bookmark.book ?? "Genesis"
        let resolvedStart = ordinalResolver?(bookName, bookmark.ordinalStart)
            ?? BookmarkListView.compatibilityVerseReference(ordinal: bookmark.ordinalStart)
        self.navigationTarget = (
            bookName: bookName,
            chapter: resolvedStart.chapter
        )
    }

    /// Creates a normalized row for one generic bookmark.
    init(genericBookmark bookmark: GenericBookmark) {
        let reference = BookmarkListView.genericReference(for: bookmark)
        let noteText = bookmark.notes?.notes ?? ""
        self.id = bookmark.id
        self.source = .generic(bookmark)
        self.reference = reference
        self.searchableText = "\(reference) \(noteText)"
        self.documentSortKey = bookmark.ordinalStart
        self.createdAt = bookmark.createdAt
        self.lastUpdatedOn = bookmark.lastUpdatedOn
        self.customIcon = bookmark.customIcon
        self.noteText = noteText
        self.labels = bookmark.bookmarkToLabels?.compactMap { $0.label }.sorted { $0.name < $1.name } ?? []
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

    /// Callback used to navigate to the bookmark's passage.
    var onNavigate: ((String, Int) -> Void)?

    /// Callback used to open label editing for the bookmark.
    var onEditLabels: (() -> Void)?

    /// Builds the tappable bookmark row.
    var body: some View {
        selectionButton
    }

    /**
     Builds the main row button that navigates back into the reader for the bookmark passage.

     - Returns: Row button containing the bookmark summary content.
     - Side effects:
       - invokes `onNavigate` with the bookmark's book/chapter when tapped
     - Failure modes: This helper cannot fail.
     */
    private var selectionButton: some View {
        Button {
            if let target = bookmark.navigationTarget {
                onNavigate?(target.bookName, target.chapter)
            }
        } label: {
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
        if !bookmark.noteText.isEmpty {
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
