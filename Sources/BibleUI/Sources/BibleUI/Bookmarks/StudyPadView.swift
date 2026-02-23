// StudyPadView.swift — StudyPad (journal) view

import SwiftUI
import SwiftData
import BibleCore

/// Displays a StudyPad: a collection of notes and bookmark references
/// organized under a label.
public struct StudyPadView: View {
    let labelId: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var entries: [StudyPadTextEntry] = []
    @State private var bookmarkEntries: [BibleBookmarkToLabel] = []
    @State private var showNewNote = false
    @State private var editingEntry: StudyPadTextEntry?
    @State private var label: BibleCore.Label?

    public init(labelId: UUID) {
        self.labelId = labelId
    }

    public var body: some View {
        Group {
            if entries.isEmpty && bookmarkEntries.isEmpty {
                ContentUnavailableView(
                    "Empty StudyPad",
                    systemImage: "note.text",
                    description: Text("Add notes or bookmark verses to build your study journal.")
                )
            } else {
                entryList
            }
        }
        .navigationTitle(label?.name ?? "StudyPad")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Note", systemImage: "plus") {
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

    private func loadLabel() {
        let store = BookmarkStore(modelContext: modelContext)
        label = store.label(id: labelId)
    }

    private func loadEntries() {
        let store = BookmarkStore(modelContext: modelContext)
        entries = store.studyPadEntries(labelId: labelId)

        // Load bookmarks associated with this label
        let allBookmarks = store.bibleBookmarks()
        bookmarkEntries = allBookmarks.compactMap { bookmark in
            bookmark.bookmarkToLabels?.first { $0.label?.id == labelId }
        }.sorted { ($0.orderNumber) < ($1.orderNumber) }
    }

    private func deleteEntry(_ entry: StudyPadTextEntry) {
        modelContext.delete(entry)
        try? modelContext.save()
        loadEntries()
    }
}

// MARK: - Bookmark Row in StudyPad

private struct BookmarkStudyPadRow: View {
    let bookmark: BibleBookmark
    let isExpanded: Bool

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

private struct NoteEntryRow: View {
    let entry: StudyPadTextEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "note.text")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()

                Menu {
                    Button("Edit", systemImage: "pencil") { onEdit() }
                    Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
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

private struct NoteEditorView: View {
    let labelId: UUID
    let existingEntry: StudyPadTextEntry?
    let onSave: (StudyPadTextEntry) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var noteText = ""

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
        .navigationTitle(existingEntry == nil ? "New Note" : "Edit Note")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
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
