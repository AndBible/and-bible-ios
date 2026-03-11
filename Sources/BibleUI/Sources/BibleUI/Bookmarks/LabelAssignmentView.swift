// LabelAssignmentView.swift — Toggle labels on a bookmark

import SwiftUI
import SwiftData
import BibleCore
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "LabelAssignment")

/**
 Assigns and removes labels for a single bookmark.

 `LabelAssignmentView` supports both `BibleBookmark` and `GenericBookmark` records. It loads the
 target bookmark by `bookmarkId`, displays all user labels, lets the user toggle assignment and
 favourite state, and can create a new label inline before assigning it immediately.

 Data dependencies:
 - `modelContext` is used to fetch bookmarks, create relationship rows, toggle favourites, and
   persist label creation
 - `allLabels` is the source list for assignment rows and excludes system labels via `userLabels`

 Side effects:
 - `onAppear` fetches the target bookmark type and assigned labels
 - tapping assignment controls creates or removes bookmark-to-label relationship rows
 - tapping the heart toggles `Label.favourite`
 - creating a new label inserts it, saves it, and immediately assigns it to the active bookmark
 */
struct LabelAssignmentView: View {
    /// Bookmark identifier for either a Bible or generic bookmark.
    let bookmarkId: UUID

    /// Optional callback invoked before the view dismisses itself.
    var onDismiss: (() -> Void)?

    /// SwiftData context used for bookmark fetches, relationship creation, and persistence.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss action for closing the sheet.
    @Environment(\.dismiss) private var dismiss

    /// All labels queried from SwiftData, including system labels.
    @Query(sort: \BibleCore.Label.name) private var allLabels: [BibleCore.Label]

    /// Presents the inline create-label alert.
    @State private var showNewLabel = false

    /// Draft name for the create-label alert text field.
    @State private var newLabelName = ""

    /// Label IDs currently assigned to the target bookmark.
    @State private var assignedLabelIds: Set<UUID> = []

    /// Whether the target bookmark is a `GenericBookmark` instead of a `BibleBookmark`.
    @State private var isGenericBookmark = false

    /// User-created labels that may be assigned in this UI.
    private var userLabels: [BibleCore.Label] {
        allLabels.filter { $0.isRealLabel }
    }

    /// Builds the label-assignment list, toolbar, and create-label alert.
    var body: some View {
        let _ = logger.info("LabelAssignmentView body: bookmarkId=\(bookmarkId), allLabels=\(allLabels.count), userLabels=\(userLabels.count), assignedLabelIds=\(assignedLabelIds.count), isGeneric=\(isGenericBookmark)")
        List {
            Section {
                ForEach(userLabels) { label in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(argbInt: label.color))
                            .frame(width: 14, height: 14)

                        Text(label.name)
                            .font(.body)
                            .foregroundStyle(.primary)

                        Spacer()

                        Button {
                            toggleFavourite(label)
                        } label: {
                            Image(systemName: label.favourite ? "heart.fill" : "heart")
                                .foregroundStyle(label.favourite ? Color.red : Color.secondary)
                                .font(.body)
                        }
                        .buttonStyle(.plain)

                        Button {
                            toggleLabel(label)
                        } label: {
                            Image(systemName: assignedLabelIds.contains(label.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(assignedLabelIds.contains(label.id) ? Color.accentColor : Color.secondary)
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                Button {
                    showNewLabel = true
                } label: {
                    SwiftUI.Label("Create New Label", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Assign Labels")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    logger.info("Done button tapped, onDismiss=\(onDismiss != nil)")
                    onDismiss?()
                    dismiss()
                }
            }
        }
        .alert("New Label", isPresented: $showNewLabel) {
            TextField("Label name", text: $newLabelName)
            Button("Create") { createAndAssignLabel() }
            Button("Cancel", role: .cancel) { newLabelName = "" }
        }
        .onAppear { loadAssignedLabels() }
    }

    // MARK: - Bible Bookmark helpers

    /**
     Fetches the target Bible bookmark, if the identifier belongs to one.

     - Returns: Matching `BibleBookmark`, or `nil` when the identifier belongs to another type or
       no record exists.
     */
    private func fetchBibleBookmark() -> BibleBookmark? {
        let target = bookmarkId
        var descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     Fetches the target generic bookmark, if the identifier belongs to one.

     - Returns: Matching `GenericBookmark`, or `nil` when the identifier belongs to another type
       or no record exists.
     */
    private func fetchGenericBookmark() -> GenericBookmark? {
        let target = bookmarkId
        var descriptor = FetchDescriptor<GenericBookmark>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Loads the target bookmark type and its currently assigned label IDs into local state.
    private func loadAssignedLabels() {
        logger.info("loadAssignedLabels: looking for bookmarkId=\(bookmarkId)")
        // Try BibleBookmark first, then GenericBookmark
        if let bookmark = fetchBibleBookmark() {
            isGenericBookmark = false
            let ids = bookmark.bookmarkToLabels?.compactMap { $0.label?.id } ?? []
            assignedLabelIds = Set(ids)
            logger.info("loadAssignedLabels: found BibleBookmark, \(ids.count) labels assigned")
        } else if let bookmark = fetchGenericBookmark() {
            isGenericBookmark = true
            let ids = bookmark.bookmarkToLabels?.compactMap { $0.label?.id } ?? []
            assignedLabelIds = Set(ids)
            logger.info("loadAssignedLabels: found GenericBookmark, \(ids.count) labels assigned")
        } else {
            logger.error("loadAssignedLabels: NO bookmark found for id=\(bookmarkId)")
        }
    }

    /**
     Routes label toggling to the correct bookmark type handler.

     - Parameter label: Label whose assignment should be toggled.
     */
    private func toggleLabel(_ label: BibleCore.Label) {
        if isGenericBookmark {
            toggleGenericLabel(label)
        } else {
            toggleBibleLabel(label)
        }
    }

    /**
     Toggles assignment for a Bible bookmark.

     - Parameter label: Label whose assignment should be toggled.
     */
    private func toggleBibleLabel(_ label: BibleCore.Label) {
        logger.info("toggleBibleLabel: label=\(label.name) id=\(label.id)")
        guard let bookmark = fetchBibleBookmark() else {
            logger.error("toggleBibleLabel: bookmark NOT found for id=\(bookmarkId)")
            return
        }

        if assignedLabelIds.contains(label.id) {
            bookmark.bookmarkToLabels?.removeAll { $0.label?.id == label.id }
            assignedLabelIds.remove(label.id)
            logger.info("toggleBibleLabel: REMOVED label \(label.name)")
        } else {
            let btl = BibleBookmarkToLabel()
            btl.bookmark = bookmark
            btl.label = label
            modelContext.insert(btl)
            assignedLabelIds.insert(label.id)
            logger.info("toggleBibleLabel: ADDED label \(label.name)")
        }
        bookmark.lastUpdatedOn = Date()
        try? modelContext.save()
    }

    /**
     Toggles assignment for a generic bookmark.

     - Parameter label: Label whose assignment should be toggled.
     */
    private func toggleGenericLabel(_ label: BibleCore.Label) {
        guard let bookmark = fetchGenericBookmark() else { return }

        if assignedLabelIds.contains(label.id) {
            bookmark.bookmarkToLabels?.removeAll { $0.label?.id == label.id }
            assignedLabelIds.remove(label.id)
        } else {
            let gbtl = GenericBookmarkToLabel()
            gbtl.bookmark = bookmark
            gbtl.label = label
            modelContext.insert(gbtl)
            assignedLabelIds.insert(label.id)
        }
        bookmark.lastUpdatedOn = Date()
        try? modelContext.save()
    }

    /**
     Toggles whether a label is marked as a favourite.

     - Parameter label: Label whose favourite state should change.
     */
    private func toggleFavourite(_ label: BibleCore.Label) {
        logger.info("toggleFavourite: label=\(label.name), was=\(label.favourite), now=\(!label.favourite)")
        label.favourite.toggle()
        try? modelContext.save()
    }

    /// Creates a new label and immediately assigns it to the active bookmark.
    private func createAndAssignLabel() {
        guard !newLabelName.isEmpty else { return }
        logger.info("createAndAssignLabel: name=\(newLabelName)")
        let label = BibleCore.Label(name: newLabelName)
        modelContext.insert(label)
        // Save the label first so SwiftData can establish relationships
        try? modelContext.save()

        if isGenericBookmark {
            if let bookmark = fetchGenericBookmark() {
                let gbtl = GenericBookmarkToLabel()
                gbtl.bookmark = bookmark
                gbtl.label = label
                modelContext.insert(gbtl)
                bookmark.lastUpdatedOn = Date()
                assignedLabelIds.insert(label.id)
            }
        } else {
            if let bookmark = fetchBibleBookmark() {
                let btl = BibleBookmarkToLabel()
                btl.bookmark = bookmark
                btl.label = label
                modelContext.insert(btl)
                bookmark.lastUpdatedOn = Date()
                assignedLabelIds.insert(label.id)
            }
        }
        try? modelContext.save()
        newLabelName = ""
    }
}
