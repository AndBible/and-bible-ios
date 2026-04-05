// BookmarkListView.swift — Bookmark list screen

import SwiftUI
import SwiftData
import BibleCore

/**
 Displays a searchable, filterable, and sortable list of Bible bookmarks from SwiftData.

 `BookmarkListView` is the main bookmark-browser surface. It excludes note-bearing bookmarks that
 belong in the My Notes flow, supports label-chip filtering, search-by-reference text, and
 navigation back into the reader or into a label's study pad.

 Data dependencies:
 - `modelContext` is used for bookmark deletion
 - `bookmarks` queries all `BibleBookmark` records for in-memory filtering and sorting
 - `labels` queries all labels so the view can build filter chips and label-manager entry points

 Side effects:
 - deleting rows or context-menu deletions mutate SwiftData and save immediately
 - opening the label manager or label-assignment sheet changes modal presentation state
 - selecting a bookmark dismisses through the caller-provided navigation callback rather than
   performing navigation directly inside the list
 */
public struct BookmarkListView: View {
    /// SwiftData context used for bookmark deletion and save operations.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss action for closing the bookmark sheet.
    @Environment(\.dismiss) private var dismiss

    /// Raw bookmark query used as the source set for filtering and sorting.
    @Query(sort: \BibleBookmark.createdAt, order: .reverse) private var bookmarks: [BibleBookmark]

    /// Raw label query used to build filter chips and label-management affordances.
    @Query(sort: \BibleCore.Label.name) private var labels: [BibleCore.Label]

    /// Current bookmark sort order.
    @State private var sortOrder: BookmarkSortOrder = .createdAtDesc

    /// Selected label filter, or `nil` when showing all labels.
    @State private var selectedLabelId: UUID?

    /// Search text applied to formatted references and note previews.
    @State private var searchText = ""

    /// Bookmark currently being edited in the label-assignment sheet.
    @State private var editingLabelsBookmarkId: UUID?

    /// Presents the label manager sheet.
    @State private var showLabelManager = false

    /// Optional callback used to navigate back into the reader for a bookmark.
    var onNavigate: ((String, Int) -> Void)?

    /// Optional callback used to open a study pad for a selected label.
    var onOpenStudyPad: ((UUID) -> Void)?

    /**
     Creates the bookmark list view.

     - Parameters:
       - onNavigate: Callback invoked when the user opens a bookmark from the list.
       - onOpenStudyPad: Callback invoked when the user wants to open a selected label's study pad.
     */
    public init(
        onNavigate: ((String, Int) -> Void)? = nil,
        onOpenStudyPad: ((UUID) -> Void)? = nil
    ) {
        self.onNavigate = onNavigate
        self.onOpenStudyPad = onOpenStudyPad
    }

    /**
     Bookmarks after note suppression, label filtering, text filtering, and sort application.
     */
    private var filteredBookmarks: [BibleBookmark] {
        // Hide bookmarks that have notes (those belong in My Notes)
        var result = bookmarks.filter { $0.notes == nil || $0.notes!.notes.isEmpty }

        // Filter by label
        if let labelId = selectedLabelId {
            result = result.filter { bookmark in
                bookmark.bookmarkToLabels?.contains { $0.label?.id == labelId } ?? false
            }
        }

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { bookmark in
                let ref = Self.verseReference(for: bookmark)
                let noteText = bookmark.notes?.notes ?? ""
                return ref.localizedCaseInsensitiveContains(searchText) ||
                    noteText.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort
        switch sortOrder {
        case .bibleOrder:
            result.sort { $0.kjvOrdinalStart < $1.kjvOrdinalStart }
        case .bibleOrderDesc:
            result.sort { $0.kjvOrdinalStart > $1.kjvOrdinalStart }
        case .createdAt:
            result.sort { $0.createdAt < $1.createdAt }
        case .createdAtDesc:
            result.sort { $0.createdAt > $1.createdAt }
        case .lastUpdated:
            result.sort { $0.lastUpdatedOn > $1.lastUpdatedOn }
        case .orderNumber:
            result.sort { $0.kjvOrdinalStart < $1.kjvOrdinalStart }
        }

        return result
    }

    /// User-created labels that should appear in the filter strip.
    private var userLabels: [BibleCore.Label] {
        labels.filter { $0.isRealLabel }
    }

    /**
     Builds the bookmark list screen, empty state, and related sheets.
     */
    public var body: some View {
        Group {
            if bookmarks.isEmpty {
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
        .searchable(text: $searchText, prompt: String(localized: "search_bookmarks"))
        .navigationTitle(String(localized: "bookmarks"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done")) { dismiss() }
                    .accessibilityIdentifier("bookmarkListDoneButton")
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button {
                        showLabelManager = true
                    } label: {
                        Image(systemName: "tag")
                    }
                    sortMenu
                }
            }
        }
        .sheet(isPresented: $showLabelManager) {
            NavigationStack {
                LabelManagerView(onOpenStudyPad: onOpenStudyPad != nil ? { labelId in
                    showLabelManager = false
                    onOpenStudyPad?(labelId)
                } : nil)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "done")) { showLabelManager = false }
                        }
                    }
            }
        }
        .sheet(item: $editingLabelsBookmarkId) { bookmarkId in
            NavigationStack {
                LabelAssignmentView(
                    bookmarkId: bookmarkId,
                    onDismiss: { editingLabelsBookmarkId = nil }
                )
            }
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
                    onEditLabels: { editingLabelsBookmarkId = bookmark.id }
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteBookmark(bookmark)
                    } label: {
                        SwiftUI.Label(String(localized: "delete"), systemImage: "trash")
                    }
                    .accessibilityIdentifier(
                        "bookmarkListDeleteButton::\(bookmarkListAccessibilitySegment(Self.verseReference(for: bookmark)))"
                    )
                }
                .contextMenu {
                    Button {
                        editingLabelsBookmarkId = bookmark.id
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

    /// Stable bookmark-list state exported for UI automation.
    private var bookmarkListAccessibilityValue: String {
        let rowTokens = filteredBookmarks.map {
            "|\(bookmarkListAccessibilitySegment(Self.verseReference(for: $0)))|"
        }.joined(separator: ",")
        return "count=\(filteredBookmarks.count);selectedLabel=\(bookmarkListSelectedLabelAccessibilityToken);query=\(bookmarkListAccessibilitySegment(searchText));rows=\(rowTokens)"
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
            modelContext.delete(bookmark)
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
    private func deleteBookmark(_ bookmark: BibleBookmark) {
        modelContext.delete(bookmark)
        try? modelContext.save()
    }

    /**
     Converts bookmark ordinals into a human-readable verse reference string.

     - Parameter bookmark: Bookmark whose ordinals should be rendered for the list UI.
     - Returns: Reference text like `Genesis 1:1` or `Genesis 1:1-3`.
     */
    static func verseReference(for bookmark: BibleBookmark) -> String {
        let bookName = bookmark.book ?? "Unknown"
        let startChapter = bookmark.ordinalStart / 40 + 1
        let startVerse = max(bookmark.ordinalStart % 40, 1)
        // Normalize: treat endOrdinal <= 0 or <= startOrdinal as single verse
        let effectiveEnd = bookmark.ordinalEnd > bookmark.ordinalStart ? bookmark.ordinalEnd : bookmark.ordinalStart
        let endVerse = max(effectiveEnd % 40, 1)

        if effectiveEnd == bookmark.ordinalStart || endVerse == startVerse {
            return "\(bookName) \(startChapter):\(startVerse)"
        } else {
            return "\(bookName) \(startChapter):\(startVerse)-\(endVerse)"
        }
    }
}

// MARK: - UUID Identifiable for sheet(item:)

/// Retroactive `Identifiable` conformance so raw `UUID` values can drive `sheet(item:)`.
extension UUID: @retroactive Identifiable {
    /// Retroactive `Identifiable` conformance value for SwiftUI sheet presentation.
    public var id: UUID { self }
}

// MARK: - Bookmark Row

/**
 Renders one bookmark row inside `BookmarkListView`.

 The row shows the reference, label colors, optional icon, optional note preview, and a quick
 affordance for editing the bookmark's labels.
 */
private struct BookmarkRow: View {
    /// Bookmark being rendered.
    let bookmark: BibleBookmark

    /// Callback used to navigate to the bookmark's passage.
    var onNavigate: ((String, Int) -> Void)?

    /// Callback used to open label editing for the bookmark.
    var onEditLabels: (() -> Void)?

    /// Labels currently assigned to the bookmark, sorted by name.
    private var assignedLabels: [BibleCore.Label] {
        bookmark.bookmarkToLabels?.compactMap { $0.label }.sorted { $0.name < $1.name } ?? []
    }

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
            let chapter = bookmark.ordinalStart / 40 + 1
            let bookName = bookmark.book ?? "Genesis"
            onNavigate?(bookName, chapter)
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
            if !assignedLabels.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(assignedLabels.prefix(3).enumerated()), id: \.offset) { _, label in
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

            Text(BookmarkListView.verseReference(for: bookmark))
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
        if let notes = bookmark.notes, !notes.notes.isEmpty {
            Text(notes.notes)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    /// Label tags or add-label affordance shown at the bottom of the bookmark row.
    private var labelTags: some View {
        if !assignedLabels.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(assignedLabels.prefix(3).enumerated()), id: \.offset) { _, label in
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
        "bookmarkListRowButton::\(bookmarkListAccessibilitySegment(BookmarkListView.verseReference(for: bookmark)))"
    }

    /**
     Resolves the deterministic XCUITest accessibility identifier for one inline row action.

     - Parameter prefix: Fixed action prefix naming the control role.
     - Returns: Stable identifier derived from the action prefix and bookmark reference string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func bookmarkInlineActionIdentifier(_ prefix: String) -> String {
        "\(prefix)::\(bookmarkListAccessibilitySegment(BookmarkListView.verseReference(for: bookmark)))"
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
