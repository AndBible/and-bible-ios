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
                        .accessibilityIdentifier(labelInlineActionIdentifier("labelAssignmentFavouriteButton", for: label))
                        .accessibilityValue(label.favourite ? "favourite" : "notFavourite")

                        Button {
                            toggleLabel(label)
                        } label: {
                            Image(systemName: assignedLabelIds.contains(label.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(assignedLabelIds.contains(label.id) ? Color.accentColor : Color.secondary)
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(labelInlineActionIdentifier("labelAssignmentToggleButton", for: label))
                        .accessibilityValue(assignedLabelIds.contains(label.id) ? "assigned" : "unassigned")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(labelRowIdentifier(label))
                    .accessibilityValue(labelRowAccessibilityValue(for: label))
                }
            }

            Section {
                Button {
                    showNewLabel = true
                } label: {
                    SwiftUI.Label("Create New Label", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("labelAssignmentCreateNewLabelButton")
            }
        }
        .navigationTitle("Assign Labels")
        .accessibilityIdentifier("labelAssignmentScreen")
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
                .accessibilityIdentifier("labelAssignmentDoneButton")
            }
        }
        .alert("New Label", isPresented: $showNewLabel) {
            TextField("Label name", text: $newLabelName)
                .accessibilityIdentifier("labelManagerNewLabelNameField")
            Button("Create") { createAndAssignLabel() }
                .accessibilityIdentifier("labelManagerCreateButton")
            Button("Cancel", role: .cancel) { newLabelName = "" }
        }
        .onAppear { loadAssignedLabels() }
    }

    /**
     Resolves the deterministic XCUITest accessibility identifier for one label row.
     *
     * - Parameter label: Label represented by the row.
     * - Returns: Stable identifier derived from the label name.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func labelRowIdentifier(_ label: BibleCore.Label) -> String {
        "labelAssignmentRow::\(sanitizedAccessibilitySegment(label.name))"
    }

    /**
     Resolves the deterministic XCUITest accessibility identifier for one inline row action.
     *
     * - Parameters:
     *   - prefix: Fixed action prefix naming the control role.
     *   - label: Label represented by the enclosing row.
     * - Returns: Stable identifier derived from the action prefix and label name.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func labelInlineActionIdentifier(_ prefix: String, for label: BibleCore.Label) -> String {
        "\(prefix)::\(sanitizedAccessibilitySegment(label.name))"
    }

    /**
     Builds the row-level accessibility summary for one label-assignment row.
     *
     * - Parameter label: Label represented by the row.
     * - Returns: Comma-delimited assignment and favourite state summary.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func labelRowAccessibilityValue(for label: BibleCore.Label) -> String {
        let assignmentState = assignedLabelIds.contains(label.id) ? "assigned" : "unassigned"
        let favouriteState = label.favourite ? "favourite" : "notFavourite"
        return "\(assignmentState),\(favouriteState)"
    }

    /**
     Sanitizes one free-form label name for deterministic accessibility identifiers.
     *
     * - Parameter value: Raw user-visible label name.
     * - Returns: Identifier-safe string containing only ASCII letters, digits, and underscores.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func sanitizedAccessibilitySegment(_ value: String) -> String {
        let mapped = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(scalar)
            }
            return "_"
        }
        let collapsed = mapped.joined().replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
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
        createAndAssignLabel(named: newLabelName)
        newLabelName = ""
    }

    /**
     Creates or reuses one label by name and immediately assigns it to the active bookmark.
     *
     * - Parameter name: User-visible label name that should exist and be assigned after the helper runs.
     * - Side effects:
     *   - inserts and saves one label when no existing label matches `name`
     *   - creates one bookmark-to-label relationship for the active bookmark when needed
     *   - updates local assigned-label state immediately after persistence
     *
     * - Failure modes:
     *   - returns without mutation when `name` is empty or the target bookmark cannot be fetched
     */
    private func createAndAssignLabel(named name: String) {
        guard !name.isEmpty else { return }
        logger.info("createAndAssignLabel: name=\(name)")

        let label: BibleCore.Label
        if let existingLabel = userLabels.first(where: { $0.name == name }) {
            label = existingLabel
        } else {
            let createdLabel = BibleCore.Label(name: name)
            modelContext.insert(createdLabel)
            try? modelContext.save()
            label = createdLabel
        }

        if assignedLabelIds.contains(label.id) {
            return
        }

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
    }
}
