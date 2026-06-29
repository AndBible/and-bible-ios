// LabelAssignmentView.swift — Toggle labels on a bookmark

import SwiftUI
import SwiftData
import BibleCore
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "LabelAssignment")

/**
 Applies label-assignment mutations for Bible and generic bookmarks without depending on SwiftUI.

 The SwiftUI view owns presentation state, while this helper owns the persistence contract that
 Android exposes through `ManageLabels.Mode.ASSIGN`: load current assignments, toggle a label,
 toggle favourite state, and create a new label before assigning it to the active bookmark.

 Side effects:
 - fetches and mutates SwiftData bookmark, label, and junction records
 - saves the supplied `ModelContext` after successful mutations

 Failure modes:
 - throws `LabelAssignmentMutationError.missingBookmark` when the target bookmark no longer exists
 - propagates SwiftData save/fetch errors so callers and package tests can distinguish persistence
   failures from presentation failures
 */
enum LabelAssignmentMutation {
    /// Bookmark storage table represented by the active label-assignment screen.
    enum BookmarkKind: Equatable {
        /// A normal Bible verse bookmark backed by `BibleBookmarkToLabel`.
        case bible

        /// A generic document bookmark backed by `GenericBookmarkToLabel`.
        case generic
    }

    /**
     Current persisted assignment state for one bookmark.

     `assignedLabelIds` is derived from relationship rows rather than view state so callers can
     refresh immediately after any mutation and expose the same row accessibility value that the
     app UI renders.
     */
    struct State: Equatable {
        /// Bookmark storage table containing the target bookmark.
        let kind: BookmarkKind

        /// Label identifiers currently assigned to the target bookmark.
        let assignedLabelIds: Set<UUID>
    }

    /**
     Loads the current assignment state for a bookmark.

     - Parameters:
       - bookmarkId: Identifier for either a Bible or generic bookmark.
       - modelContext: SwiftData context containing bookmark and label records.
     - Returns: The bookmark type and assigned label identifiers.
     - Side effects: Fetches SwiftData records.
     - Throws: `LabelAssignmentMutationError.missingBookmark` when no matching bookmark exists, or
       a SwiftData fetch error.
     */
    static func state(for bookmarkId: UUID, in modelContext: ModelContext) throws -> State {
        if let bookmark = try fetchBibleBookmark(bookmarkId, in: modelContext) {
            return State(
                kind: .bible,
                assignedLabelIds: Set(bookmark.bookmarkToLabels?.compactMap { $0.label?.id } ?? [])
            )
        }
        if let bookmark = try fetchGenericBookmark(bookmarkId, in: modelContext) {
            return State(
                kind: .generic,
                assignedLabelIds: Set(bookmark.bookmarkToLabels?.compactMap { $0.label?.id } ?? [])
            )
        }
        throw LabelAssignmentMutationError.missingBookmark(bookmarkId)
    }

    /**
     Toggles one label assignment for the specified bookmark type.

     - Parameters:
       - label: Label whose relationship row should be added or removed.
       - bookmarkId: Bookmark receiving the assignment change.
       - kind: Persisted bookmark table already resolved by the visible label-assignment view.
       - modelContext: SwiftData context used for the mutation.
     - Returns: Refreshed assignment state after saving.
     - Side effects: Inserts or deletes a bookmark-to-label junction, updates the bookmark
       timestamp, and saves the context.
     - Throws: `LabelAssignmentMutationError.missingBookmark` for stale routes, or a SwiftData
       save/fetch error.
     */
    @discardableResult
    static func toggleLabel(
        _ label: BibleCore.Label,
        bookmarkId: UUID,
        kind: BookmarkKind,
        in modelContext: ModelContext
    ) throws -> State {
        switch kind {
        case .bible:
            guard let bookmark = try fetchBibleBookmark(bookmarkId, in: modelContext) else {
                throw LabelAssignmentMutationError.missingBookmark(bookmarkId)
            }
            toggleBibleLabel(label, for: bookmark, in: modelContext)
        case .generic:
            guard let bookmark = try fetchGenericBookmark(bookmarkId, in: modelContext) else {
                throw LabelAssignmentMutationError.missingBookmark(bookmarkId)
            }
            toggleGenericLabel(label, for: bookmark, in: modelContext)
        }
        try modelContext.save()
        return try state(for: bookmarkId, in: modelContext)
    }

    /**
     Toggles whether a label should be shown as a favourite.

     - Parameters:
       - label: Label whose favourite flag should change.
       - modelContext: SwiftData context used for persistence.
     - Returns: The updated favourite value.
     - Side effects: Mutates `Label.favourite` and saves the context.
     - Throws: A SwiftData save error.
     */
    @discardableResult
    static func toggleFavourite(
        _ label: BibleCore.Label,
        in modelContext: ModelContext
    ) throws -> Bool {
        label.favourite.toggle()
        try modelContext.save()
        return label.favourite
    }

    /**
     Creates or reuses a user label by name and assigns it to the active bookmark.

     - Parameters:
       - name: User-visible label name. Empty names leave assignments unchanged.
       - bookmarkId: Bookmark receiving the assignment.
       - kind: Persisted bookmark table already resolved by the visible label-assignment view.
       - modelContext: SwiftData context used for fetches, insertion, and save.
     - Returns: Refreshed assignment state after the create/assign operation.
     - Side effects:
       - inserts a new `Label` when no real label with the exact name exists
       - inserts one bookmark-to-label junction when the bookmark is not already assigned
       - updates the bookmark timestamp and saves the context
     - Throws: `LabelAssignmentMutationError.missingBookmark` for stale routes, or a SwiftData
       fetch/save error.
     */
    @discardableResult
    static func createAndAssignLabel(
        named name: String,
        bookmarkId: UUID,
        kind: BookmarkKind,
        in modelContext: ModelContext
    ) throws -> State {
        guard !name.isEmpty else {
            return try state(for: bookmarkId, in: modelContext)
        }

        let label: BibleCore.Label
        if let existingLabel = try existingUserLabel(named: name, in: modelContext) {
            label = existingLabel
        } else {
            let createdLabel = BibleCore.Label(name: name)
            modelContext.insert(createdLabel)
            label = createdLabel
        }

        switch kind {
        case .bible:
            guard let bookmark = try fetchBibleBookmark(bookmarkId, in: modelContext) else {
                throw LabelAssignmentMutationError.missingBookmark(bookmarkId)
            }
            assignBibleLabelIfNeeded(label, to: bookmark, in: modelContext)
        case .generic:
            guard let bookmark = try fetchGenericBookmark(bookmarkId, in: modelContext) else {
                throw LabelAssignmentMutationError.missingBookmark(bookmarkId)
            }
            assignGenericLabelIfNeeded(label, to: bookmark, in: modelContext)
        }
        try modelContext.save()
        return try state(for: bookmarkId, in: modelContext)
    }

    /**
     Fetches one Bible bookmark by identifier.

     - Parameters:
       - bookmarkId: Bookmark identifier to resolve.
       - modelContext: SwiftData context containing bookmark records.
     - Returns: Matching Bible bookmark, or `nil`.
     - Side effects: Fetches SwiftData records.
     - Throws: A SwiftData fetch error.
     */
    private static func fetchBibleBookmark(
        _ bookmarkId: UUID,
        in modelContext: ModelContext
    ) throws -> BibleBookmark? {
        let target = bookmarkId
        var descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /**
     Fetches one generic bookmark by identifier.

     - Parameters:
       - bookmarkId: Bookmark identifier to resolve.
       - modelContext: SwiftData context containing generic bookmark records.
     - Returns: Matching generic bookmark, or `nil`.
     - Side effects: Fetches SwiftData records.
     - Throws: A SwiftData fetch error.
     */
    private static func fetchGenericBookmark(
        _ bookmarkId: UUID,
        in modelContext: ModelContext
    ) throws -> GenericBookmark? {
        let target = bookmarkId
        var descriptor = FetchDescriptor<GenericBookmark>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /**
     Resolves an existing user-created label by exact display name.

     - Parameters:
       - name: Exact label name to find.
       - modelContext: SwiftData context containing labels.
     - Returns: The first real user label with the supplied name, or `nil`.
     - Side effects: Fetches SwiftData records.
     - Throws: A SwiftData fetch error.
     */
    private static func existingUserLabel(
        named name: String,
        in modelContext: ModelContext
    ) throws -> BibleCore.Label? {
        let target = name
        let descriptor = FetchDescriptor<BibleCore.Label>(
            predicate: #Predicate { $0.name == target }
        )
        return try modelContext.fetch(descriptor).first { $0.isRealLabel }
    }

    /**
     Toggles a Bible bookmark-label relationship without saving.

     - Parameters:
       - label: Label to add or remove.
       - bookmark: Bible bookmark being mutated.
       - modelContext: SwiftData context used to insert or delete relationship rows.
     - Side effects: Mutates `bookmark.bookmarkToLabels`, deletes stale links, inserts new links,
       and updates `lastUpdatedOn`.
     - Failure modes: This helper does not throw; callers save and surface persistence failures.
     */
    private static func toggleBibleLabel(
        _ label: BibleCore.Label,
        for bookmark: BibleBookmark,
        in modelContext: ModelContext
    ) {
        let links = bookmark.bookmarkToLabels ?? []
        let matchingLinks = links.filter { $0.label?.id == label.id }
        if !matchingLinks.isEmpty {
            matchingLinks.forEach(modelContext.delete)
            bookmark.bookmarkToLabels?.removeAll { $0.label?.id == label.id }
        } else {
            assignBibleLabelIfNeeded(label, to: bookmark, in: modelContext)
        }
        bookmark.lastUpdatedOn = Date()
    }

    /**
     Toggles a generic bookmark-label relationship without saving.

     - Parameters:
       - label: Label to add or remove.
       - bookmark: Generic bookmark being mutated.
       - modelContext: SwiftData context used to insert or delete relationship rows.
     - Side effects: Mutates `bookmark.bookmarkToLabels`, deletes stale links, inserts new links,
       and updates `lastUpdatedOn`.
     - Failure modes: This helper does not throw; callers save and surface persistence failures.
     */
    private static func toggleGenericLabel(
        _ label: BibleCore.Label,
        for bookmark: GenericBookmark,
        in modelContext: ModelContext
    ) {
        let links = bookmark.bookmarkToLabels ?? []
        let matchingLinks = links.filter { $0.label?.id == label.id }
        if !matchingLinks.isEmpty {
            matchingLinks.forEach(modelContext.delete)
            bookmark.bookmarkToLabels?.removeAll { $0.label?.id == label.id }
        } else {
            assignGenericLabelIfNeeded(label, to: bookmark, in: modelContext)
        }
        bookmark.lastUpdatedOn = Date()
    }

    /**
     Assigns a label to a Bible bookmark when the relationship does not already exist.

     - Parameters:
       - label: Label to assign.
       - bookmark: Bible bookmark receiving the label.
       - modelContext: SwiftData context used to insert the relationship.
     - Side effects: Inserts one `BibleBookmarkToLabel` and updates `lastUpdatedOn`.
     - Failure modes: This helper does not throw; callers save and surface persistence failures.
     */
    private static func assignBibleLabelIfNeeded(
        _ label: BibleCore.Label,
        to bookmark: BibleBookmark,
        in modelContext: ModelContext
    ) {
        guard bookmark.bookmarkToLabels?.contains(where: { $0.label?.id == label.id }) != true else {
            return
        }
        let link = BibleBookmarkToLabel()
        link.bookmark = bookmark
        link.label = label
        modelContext.insert(link)
        var links = bookmark.bookmarkToLabels ?? []
        links.append(link)
        bookmark.bookmarkToLabels = links
        bookmark.lastUpdatedOn = Date()
    }

    /**
     Assigns a label to a generic bookmark when the relationship does not already exist.

     - Parameters:
       - label: Label to assign.
       - bookmark: Generic bookmark receiving the label.
       - modelContext: SwiftData context used to insert the relationship.
     - Side effects: Inserts one `GenericBookmarkToLabel` and updates `lastUpdatedOn`.
     - Failure modes: This helper does not throw; callers save and surface persistence failures.
     */
    private static func assignGenericLabelIfNeeded(
        _ label: BibleCore.Label,
        to bookmark: GenericBookmark,
        in modelContext: ModelContext
    ) {
        guard bookmark.bookmarkToLabels?.contains(where: { $0.label?.id == label.id }) != true else {
            return
        }
        let link = GenericBookmarkToLabel()
        link.bookmark = bookmark
        link.label = label
        modelContext.insert(link)
        var links = bookmark.bookmarkToLabels ?? []
        links.append(link)
        bookmark.bookmarkToLabels = links
        bookmark.lastUpdatedOn = Date()
    }
}

/**
 Errors surfaced when label-assignment persistence cannot resolve the active bookmark route.

 The visible UI treats these as non-fatal stale-route failures, while package tests assert them
 directly so persistence regressions are not hidden behind XCUITest waits.
 */
enum LabelAssignmentMutationError: Error, Equatable {
    /// The requested bookmark identifier no longer exists in either bookmark table.
    case missingBookmark(UUID)
}

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

    /**
     Caller-owned dismissal action for parent-managed navigation routes.

     When this callback is provided, the parent owns the navigation state and the view must not
     also call SwiftUI's environment dismiss. Doing both can pop past the parent list after route
     state has already been cleared.
     */
    var onDismiss: (() -> Void)?

    /// SwiftData context used for bookmark fetches, relationship creation, and persistence.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss action for standalone presentations that do not provide `onDismiss`.
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
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
                    if let onDismiss {
                        onDismiss()
                    } else {
                        dismiss()
                    }
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

    /**
     Loads the target bookmark type and currently assigned labels into SwiftUI state.

     - Side effects:
       - fetches SwiftData bookmark relationship rows through `LabelAssignmentMutation`
       - mutates `isGenericBookmark` and `assignedLabelIds` for row rendering
       - logs stale-route or persistence failures without dismissing the view
     - Failure modes: Missing bookmarks and SwiftData fetch errors are logged and leave the
       previous in-memory row state unchanged.
     */
    private func loadAssignedLabels() {
        logger.info("loadAssignedLabels: looking for bookmarkId=\(bookmarkId)")
        do {
            let state = try LabelAssignmentMutation.state(for: bookmarkId, in: modelContext)
            isGenericBookmark = state.kind == .generic
            assignedLabelIds = state.assignedLabelIds
            logger.info("loadAssignedLabels: found \(isGenericBookmark ? "GenericBookmark" : "BibleBookmark"), \(assignedLabelIds.count) labels assigned")
        } catch {
            logger.error("loadAssignedLabels: failed for id=\(bookmarkId), error=\(String(describing: error))")
        }
    }

    /**
     Routes label toggling to the correct bookmark type handler.

     - Parameter label: Label whose assignment should be toggled.
     - Side effects:
       - inserts or deletes the persisted bookmark-to-label relationship through
         `LabelAssignmentMutation`
       - refreshes local bookmark type and assignment state after save
       - logs stale-route or persistence failures without dismissing the view
     - Failure modes: Missing bookmarks and SwiftData save/fetch errors are logged and leave the
       current visible assignment state unchanged.
     */
    private func toggleLabel(_ label: BibleCore.Label) {
        do {
            let kind: LabelAssignmentMutation.BookmarkKind = isGenericBookmark ? .generic : .bible
            let state = try LabelAssignmentMutation.toggleLabel(
                label,
                bookmarkId: bookmarkId,
                kind: kind,
                in: modelContext
            )
            isGenericBookmark = state.kind == .generic
            assignedLabelIds = state.assignedLabelIds
        } catch {
            logger.error("toggleLabel failed for bookmarkId=\(bookmarkId), label=\(label.name), error=\(String(describing: error))")
        }
    }

    /**
     Toggles whether a label is marked as a favourite.

     - Parameter label: Label whose favourite state should change.
     - Side effects:
       - mutates `Label.favourite`
       - saves the supplied SwiftData context through `LabelAssignmentMutation`
       - logs persistence failures without dismissing the view
     - Failure modes: SwiftData save errors are logged after the attempted in-memory toggle.
     */
    private func toggleFavourite(_ label: BibleCore.Label) {
        logger.info("toggleFavourite: label=\(label.name), was=\(label.favourite), now=\(!label.favourite)")
        do {
            _ = try LabelAssignmentMutation.toggleFavourite(label, in: modelContext)
        } catch {
            logger.error("toggleFavourite failed for label=\(label.name), error=\(String(describing: error))")
        }
    }

    /**
     Handles the create-label alert confirmation.

     - Side effects:
       - delegates non-empty names to `createAndAssignLabel(named:)`
       - clears the alert text field after attempting the create/assign mutation
     - Failure modes: Empty names are ignored; persistence failures are handled by
       `createAndAssignLabel(named:)`.
     */
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
        do {
            let kind: LabelAssignmentMutation.BookmarkKind = isGenericBookmark ? .generic : .bible
            let state = try LabelAssignmentMutation.createAndAssignLabel(
                named: name,
                bookmarkId: bookmarkId,
                kind: kind,
                in: modelContext
            )
            isGenericBookmark = state.kind == .generic
            assignedLabelIds = state.assignedLabelIds
        } catch {
            logger.error("createAndAssignLabel failed for bookmarkId=\(bookmarkId), name=\(name), error=\(String(describing: error))")
        }
    }
}
