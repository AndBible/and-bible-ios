// BookmarkListView.swift — Bookmark list screen

import SwiftUI
import SwiftData
import BibleCore

/// Displays a filterable, sortable list of bookmarks from SwiftData.
public struct BookmarkListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BibleBookmark.createdAt, order: .reverse) private var bookmarks: [BibleBookmark]
    @Query(sort: \BibleCore.Label.name) private var labels: [BibleCore.Label]
    @State private var sortOrder: BookmarkSortOrder = .createdAtDesc
    @State private var selectedLabelId: UUID?
    @State private var searchText = ""
    @State private var editingLabelsBookmarkId: UUID?
    @State private var showLabelManager = false
    var onNavigate: ((String, Int) -> Void)?
    var onOpenStudyPad: ((UUID) -> Void)?

    public init(onNavigate: ((String, Int) -> Void)? = nil, onOpenStudyPad: ((UUID) -> Void)? = nil) {
        self.onNavigate = onNavigate
        self.onOpenStudyPad = onOpenStudyPad
    }

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

    private var userLabels: [BibleCore.Label] {
        labels.filter { $0.isRealLabel }
    }

    public var body: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    String(localized: "no_bookmarks"),
                    systemImage: "bookmark",
                    description: Text(String(localized: "no_bookmarks_description"))
                )
            } else {
                bookmarkList
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
                .contextMenu {
                    Button {
                        editingLabelsBookmarkId = bookmark.id
                    } label: {
                        SwiftUI.Label(String(localized: "edit_labels"), systemImage: "tag")
                    }
                    Button(role: .destructive) {
                        modelContext.delete(bookmark)
                        try? modelContext.save()
                    } label: {
                        SwiftUI.Label(String(localized: "delete"), systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deleteBookmarks)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "sort"), selection: $sortOrder) {
                Text(String(localized: "sort_bible_order")).tag(BookmarkSortOrder.bibleOrder)
                Text(String(localized: "sort_date_created")).tag(BookmarkSortOrder.createdAtDesc)
                Text(String(localized: "sort_last_updated")).tag(BookmarkSortOrder.lastUpdated)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var labelFilterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: String(localized: "all"),
                        chipColor: .secondary,
                        isSelected: selectedLabelId == nil
                    ) {
                        selectedLabelId = nil
                    }

                    ForEach(userLabels) { label in
                        FilterChip(
                            title: label.name,
                            chipColor: Color(argbInt: label.color),
                            isSelected: selectedLabelId == label.id
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
            }
        }
    }

    private func deleteBookmarks(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredBookmarks[$0] }
        for bookmark in toDelete {
            modelContext.delete(bookmark)
        }
        try? modelContext.save()
    }

    /// Convert bookmark ordinals to a human-readable verse reference.
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

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

// MARK: - Bookmark Row

private struct BookmarkRow: View {
    let bookmark: BibleBookmark
    var onNavigate: ((String, Int) -> Void)?
    var onEditLabels: (() -> Void)?

    private var assignedLabels: [BibleCore.Label] {
        bookmark.bookmarkToLabels?.compactMap { $0.label }.sorted { $0.name < $1.name } ?? []
    }

    var body: some View {
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
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

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
                Text(icon)
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
    private var notePreview: some View {
        if let notes = bookmark.notes, !notes.notes.isEmpty {
            Text(notes.notes)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
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
                // Tap area to edit labels
                Button {
                    onEditLabels?()
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } else {
            // No labels — show a button to add some
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
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let chipColor: Color
    let isSelected: Bool
    let action: () -> Void

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
    }
}
