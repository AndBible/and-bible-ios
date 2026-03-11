// StudyPadView.swift — StudyPad (journal) view

import SwiftUI
import SwiftData
import BibleCore

/**
 Displays one StudyPad label as a mixed journal of note entries and linked bookmark references.

 The view resolves its backing `Label`, loads both persisted note entries and bookmark-to-label
 associations, and presents editing sheets for creating or updating text notes.

 Data dependencies:
 - `labelId` identifies the label whose StudyPad content should be loaded
 - `modelContext` is used for `BookmarkStore` queries and note deletion/persistence

 Side effects:
 - `onAppear` loads the label metadata and its current note/bookmark entries from SwiftData
 - presenting the note editor can insert or update `StudyPadTextEntry` rows and then refresh local
   state through `loadEntries()`
 - deleting a note mutates SwiftData and saves the context before reloading the StudyPad list
 */
public struct StudyPadView: View {
    /// Identifier of the label whose StudyPad content should be displayed.
    let labelId: UUID

    /// SwiftData context used for queries, deletion, and persistence.
    @Environment(\.modelContext) private var modelContext

    /// Persisted text note entries assigned to the selected label.
    @State private var entries: [StudyPadTextEntry] = []

    /// Bible bookmark-to-label rows assigned to the selected label.
    @State private var bookmarkEntries: [BibleBookmarkToLabel] = []

    /// Whether the create-note sheet is currently presented.
    @State private var showNewNote = false

    /// Note entry currently being edited, or `nil` when no edit sheet is active.
    @State private var editingEntry: StudyPadTextEntry?

    /// Resolved label metadata used for the navigation title.
    @State private var label: BibleCore.Label?

    /**
     Creates a StudyPad view for one label.

     - Parameter labelId: Identifier of the label whose notes and bookmark references should be displayed.
     */
    public init(labelId: UUID) {
        self.labelId = labelId
    }

    /**
     Builds the empty state or mixed StudyPad entry list with note editor sheet presentation.
     */
    public var body: some View {
        Group {
            if entries.isEmpty && bookmarkEntries.isEmpty {
                ContentUnavailableView(
                    String(localized: "studypad_empty"),
                    systemImage: "note.text",
                    description: Text(String(localized: "studypad_empty_description"))
                )
            } else {
                entryList
            }
        }
        .navigationTitle(label?.name ?? String(localized: "studypad"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "add_note"), systemImage: "plus") {
                    showNewNote = true
                }
            }
        }
        .sheet(isPresented: $showNewNote) {
            NavigationStack {
                NoteEditorView(labelId: labelId, existingEntry: nil) { _ in
                    loadEntries()
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                NoteEditorView(labelId: labelId, existingEntry: entry) { _ in
                    loadEntries()
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            loadLabel()
            loadEntries()
        }
    }

    /// Scrollable list that interleaves bookmark references and text note entries.
    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Bookmark entries (verses assigned to this label)
                if !bookmarkEntries.isEmpty {
                    ForEach(bookmarkEntries, id: \.bookmark?.id) { btl in
                        if let bookmark = btl.bookmark {
                            BookmarkStudyPadRow(
                                bookmark: bookmark,
                                isExpanded: btl.expandContent
                            )
                            Divider().padding(.horizontal)
                        }
                    }
                }

                // Text note entries
                ForEach(entries) { entry in
                    NoteEntryRow(entry: entry) {
                        editingEntry = entry
                    } onDelete: {
                        deleteEntry(entry)
                    }
                    Divider().padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
        }
    }

    /**
     Resolves the StudyPad label metadata for the current `labelId`.

     Side effects:
     - updates local `label` state used by the navigation title
     */
    private func loadLabel() {
        let store = BookmarkStore(modelContext: modelContext)
        label = store.label(id: labelId)
    }

    /**
     Reloads text entries and bookmark references assigned to the current label.

     Side effects:
     - replaces the local `entries` and `bookmarkEntries` arrays from SwiftData-backed queries
     - sorts bookmark associations by their persisted `orderNumber`
     */
    private func loadEntries() {
        let store = BookmarkStore(modelContext: modelContext)
        entries = store.studyPadEntries(labelId: labelId)

        // Load bookmarks associated with this label
        let allBookmarks = store.bibleBookmarks()
        bookmarkEntries = allBookmarks.compactMap { bookmark in
            bookmark.bookmarkToLabels?.first { $0.label?.id == labelId }
        }.sorted { ($0.orderNumber) < ($1.orderNumber) }
    }

    /**
     Deletes one text note entry and refreshes the StudyPad content.

     - Parameter entry: Entry to delete from SwiftData.

     Side effects:
     - removes the entry from the model context
     - attempts to save the context and then reloads StudyPad state
     */
    private func deleteEntry(_ entry: StudyPadTextEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
        loadEntries()
    }
}

// MARK: - Bookmark Row in StudyPad

/**
 Renders one bookmark reference row inside the StudyPad list.

 The row can optionally expand to show bookmark notes when the bookmark-to-label association marks
 the content as expanded.
 */
private struct BookmarkStudyPadRow: View {
    /// Bookmark whose reference and optional notes should be shown.
    let bookmark: BibleBookmark

    /// Whether bookmark notes should be rendered beneath the verse reference.
    let isExpanded: Bool

    /// Builds the bookmark summary row shown in the StudyPad list.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(BookmarkListView.verseReference(for: bookmark))
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if isExpanded, let notes = bookmark.notes, !notes.notes.isEmpty {
                Text(notes.notes)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - Note Entry Row

/**
 Renders one editable text note row inside the StudyPad list.

 Tapping the row opens the edit flow, while the overflow menu exposes explicit edit and delete
 actions.
 */
private struct NoteEntryRow: View {
    /// Persisted StudyPad text entry displayed in the row.
    let entry: StudyPadTextEntry

    /// Callback invoked when the user starts editing the entry.
    let onEdit: () -> Void

    /// Callback invoked when the user deletes the entry.
    let onDelete: () -> Void

    /// Builds the tappable note row and overflow actions.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "note.text")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(String(localized: "note"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()

                Menu {
                    Button(String(localized: "edit"), systemImage: "pencil") { onEdit() }
                    Button(String(localized: "delete"), systemImage: "trash", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.textEntry?.text ?? "")
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}

// MARK: - Note Editor

/**
 Modal editor for creating or updating one StudyPad text note.

 Data dependencies:
 - `labelId` identifies which label should own a newly created note
 - `existingEntry` determines whether the editor updates an existing row or inserts a new one
 - `modelContext` persists note mutations

 Side effects:
 - `onAppear` seeds the editor text from the existing entry when editing
 - saving mutates SwiftData, may create a nested `StudyPadTextEntryText` row, and dismisses the
   sheet through the caller's toolbar action
 */
private struct NoteEditorView: View {
    /// Label that should own a newly created note.
    let labelId: UUID

    /// Existing entry being edited, or `nil` when creating a new note.
    let existingEntry: StudyPadTextEntry?

    /// Callback invoked after a save so the parent view can reload state.
    let onSave: (StudyPadTextEntry) -> Void

    /// SwiftData context used to insert and update note entities.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss action for closing the editor sheet.
    @Environment(\.dismiss) private var dismiss

    /// Editable note text shown in the `TextEditor`.
    @State private var noteText = ""

    /// Builds the editor body, toolbar actions, and initial text hydration.
    var body: some View {
        VStack {
            TextEditor(text: $noteText)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .padding()
        }
        .navigationTitle(existingEntry == nil ? String(localized: "new_note") : String(localized: "edit_note"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "save")) {
                    saveNote()
                    dismiss()
                }
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if let existing = existingEntry {
                noteText = existing.textEntry?.text ?? ""
            }
        }
    }

    /**
     Persists the current note text by updating an existing entry or creating a new one.

     Side effects:
     - trims the editor text and returns early when no user-visible content remains
     - updates or inserts `StudyPadTextEntry` and `StudyPadTextEntryText` rows in SwiftData
     - attempts to save the context and invokes `onSave` so the parent can refresh its content
     */
    private func saveNote() {
        let trimmedText = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if let existing = existingEntry {
            // Update existing entry
            if let textEntry = existing.textEntry {
                textEntry.text = trimmedText
            } else {
                let textEntry = StudyPadTextEntryText(
                    studyPadTextEntryId: existing.id,
                    text: trimmedText
                )
                existing.textEntry = textEntry
                modelContext.insert(textEntry)
            }
            onSave(existing)
        } else {
            // Create new entry
            let store = BookmarkStore(modelContext: modelContext)
            let existingEntries = store.studyPadEntries(labelId: labelId)
            let nextOrder = (existingEntries.map(\.orderNumber).max() ?? -1) + 1

            let entry = StudyPadTextEntry(orderNumber: nextOrder)

            // Associate with label
            if let label = store.label(id: labelId) {
                entry.label = label
            }

            modelContext.insert(entry)

            let textEntry = StudyPadTextEntryText(
                studyPadTextEntryId: entry.id,
                text: trimmedText
            )
            entry.textEntry = textEntry
            modelContext.insert(textEntry)

            try? modelContext.save()
            onSave(entry)
        }

        try? modelContext.save()
    }
}
