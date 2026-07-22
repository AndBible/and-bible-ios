// HistoryView.swift — Navigation history

import SwiftUI
import SwiftData
import BibleCore

/**
 Displays navigation history for a captured reader window and lets the user jump back to prior locations.

 The view filters persisted history to the caller's captured window when supplied, formats stored
 OSIS-style keys and timestamps into Android-equivalent rows, and exposes destructive controls only
 to legacy callers that explicitly opt in.

 Data dependencies:
 - `modelContext` is used to delete persisted history rows
 - `activeWindowID` preserves the launching reader window even if focus changes while visible
 - `bookNameResolver` can translate OSIS book IDs using the active module's dynamic canon

 Side effects:
 - selecting a row closes its owning surface and forwards the stored history key through `onNavigate`
 - legacy callers can opt into swipe deletion and clear-all actions; Android-dialog callers cannot
 */
public struct HistoryView: View {
    /// SwiftData context used for deleting history rows.
    @Environment(\.modelContext) private var modelContext

    /// Legacy fallback scope used only when a caller did not capture a reader window explicitly.
    @Environment(WindowManager.self) private var windowManager

    /// Dismiss action for closing the history screen.
    @Environment(\.dismiss) private var dismiss

    /// All persisted history items ordered newest-first.
    @Query(sort: \HistoryItem.createdAt, order: .reverse) private var allHistory: [HistoryItem]

    /// Callback invoked when the user chooses a history item to navigate back to.
    var onNavigate: ((String) -> Void)?

    /// Resolves an OSIS book ID to a human-readable name using the active controller's dynamic book list.
    var bookNameResolver: ((String) -> String?)?

    /// Captured reader window whose navigation history is displayed, if known.
    var activeWindowID: UUID?

    /// Android-equivalent title supplied by the app-owned dialog owner.
    var title: String

    /// Whether legacy iOS-only delete and clear controls should remain available.
    var allowsDestructiveActions: Bool

    /// Optional owner callback used instead of SwiftUI sheet dismissal for app-owned dialogs.
    var onDismiss: (() -> Void)?

    /**
     Creates the history screen.

     - Parameters:
       - bookNameResolver: Optional resolver that maps OSIS IDs to dynamic, module-aware book names.
       - onNavigate: Optional callback invoked with the stored history key when a row is selected.
       - activeWindowID: Captured originating reader window. When nil, every loaded row is visible.
       - title: Navigation title, normally Android's workspace/window-scoped History title.
       - allowsDestructiveActions: Enables legacy delete and clear controls. Dialog callers pass false.
       - onDismiss: Optional owner callback used when embedded in an app-owned dialog.
     */
    public init(
        bookNameResolver: ((String) -> String?)? = nil,
        onNavigate: ((String) -> Void)? = nil,
        activeWindowID: UUID? = nil,
        title: String = String(localized: "history"),
        allowsDestructiveActions: Bool = true,
        onDismiss: (() -> Void)? = nil
    ) {
        self.bookNameResolver = bookNameResolver
        self.onNavigate = onNavigate
        self.activeWindowID = activeWindowID
        self.title = title
        self.allowsDestructiveActions = allowsDestructiveActions
        self.onDismiss = onDismiss
    }

    /// Filter history to the active window only.
    private var history: [HistoryItem] {
        HistoryListPresentation.visibleItems(allHistory, activeWindowID: resolvedWindowID)
    }

    /// Uses the dialog's immutable source window when supplied, preserving legacy active-window scope otherwise.
    private var resolvedWindowID: UUID? {
        activeWindowID ?? windowManager.activeWindow?.id
    }

    /**
     Builds the empty state or filtered history list with destructive toolbar actions.
     */
    public var body: some View {
        let historySnapshot = history
        Group {
            if historySnapshot.isEmpty {
                VStack {
                    ContentUnavailableView(
                        String(localized: "history_no_history"),
                        systemImage: "clock",
                        description: Text(String(localized: "history_no_history_description"))
                    )
                    .accessibilityIdentifier("historyEmptyState")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(historySnapshot, id: \.id) { item in
                        Button {
                            navigateTo(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(formatDescription(for: item))
                                        .font(.headline)
                                    Text(HistoryListPresentation.androidDateTime(item.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(historyRowIdentifier(for: item))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if allowsDestructiveActions {
                                Button(role: .destructive) {
                                    deleteItem(item)
                                } label: {
                                    SwiftUI.Label(String(localized: "delete"), systemImage: "trash")
                                }
                                .accessibilityIdentifier(historyDeleteButtonIdentifier(for: item))
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("historyScreen")
        .accessibilityValue(historyAccessibilityValue)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done"), action: dismissHistory)
                    .accessibilityIdentifier("historyDoneButton")
            }
            if allowsDestructiveActions, !historySnapshot.isEmpty {
                ToolbarItem(placement: .destructiveAction) {
                    Button(String(localized: "clear"), role: .destructive) {
                        clearHistory()
                    }
                    .accessibilityIdentifier("historyClearButton")
                }
            }
        }
    }

    /**
     Formats a stored OSIS-like history key such as `Gen.1.1` into a user-visible `Book Chapter` label.
     */
    private func formatKey(_ key: String) -> String {
        HistoryListPresentation.formattedKey(key, bookNameResolver: bookNameResolver)
    }

    /**
     Formats a History title exactly as Android's `KeyHistoryItem.description`: reference first,
     then the checkpoint's module abbreviation.

     - Parameter item: Persisted checkpoint whose key and document were captured together.
     - Returns: User-visible Android-equivalent History row title.
     - Side effects: none.
     - Failure modes: Preserves the raw key when it cannot be parsed and omits a blank document.
     */
    private func formatDescription(for item: HistoryItem) -> String {
        HistoryListPresentation.formattedDescription(
            key: item.key,
            document: item.document,
            bookNameResolver: bookNameResolver
        )
    }

    /**
     Dismisses the history view and forwards the selected stored key to the navigation callback.
     */
    private func navigateTo(_ item: HistoryItem) {
        onNavigate?(item.key)
        dismissHistory()
    }

    /// Closes through the app-owned dialog callback when supplied, otherwise dismisses legacy sheet ownership.
    private func dismissHistory() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    /**
     * Resolves the deterministic accessibility identifier for one persisted history row.
     *
     * - Parameter item: History row whose durable key should back the identifier.
     * - Returns: Accessibility identifier stable across row reordering for the same history key.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func historyRowIdentifier(for item: HistoryItem) -> String {
        HistoryListPresentation.rowIdentifier(for: item)
    }

    /**
     Resolves the deterministic accessibility identifier for one history row's delete action.
     *
     * - Parameter item: History row whose durable key should back the delete-action identifier.
     * - Returns: Accessibility identifier stable across row reordering for the same history key.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func historyDeleteButtonIdentifier(for item: HistoryItem) -> String {
        HistoryListPresentation.deleteButtonIdentifier(for: item)
    }

    /// Stable History screen state exported for UI automation.
    private var historyAccessibilityValue: String {
        HistoryListPresentation.accessibilityValue(
            for: history,
            includeRowTokens: UITestRuntimeConfiguration.enablesDetailedAccessibilityExports,
            rowTokenLimit: UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit
        )
    }

    /**
     Deletes one visible history row by model identity from the rendered history snapshot.
     *
     * - Parameter item: Persisted history row captured by the rendered swipe action.
     * - Side effects:
     *   - deletes the referenced `HistoryItem` from SwiftData
     *   - saves the mutated history state back to persistence
     * - Failure modes:
     *   - silently discards save failures because row deletion is a user-driven destructive action
     *     with no dedicated retry surface in this view
     */
    private func deleteItem(_ item: HistoryItem) {
        modelContext.delete(item)
        try? modelContext.save()
    }

    /**
     Deletes every visible history row whose key matches the requested deterministic test key.
     *
     * - Parameter key: Persisted history key to remove from the current history scope.
     * - Side effects:
     *   - deletes all matching `HistoryItem` rows from SwiftData
     *   - saves the mutated history state back to persistence
     * - Failure modes:
     *   - silently discards save failures because this helper only backs deterministic XCUITest
     *     built-in actions
     */
    private func deleteItems(matchingKey key: String) {
        try? HistoryListPresentation.deleteVisibleItems(
            matchingKey: key,
            from: allHistory,
            activeWindowID: resolvedWindowID,
            in: modelContext
        )
    }

    /**
     Deletes every currently visible history row for the active window scope.
     */
    private func clearHistory() {
        try? HistoryListPresentation.clearVisibleItems(
            from: allHistory,
            activeWindowID: resolvedWindowID,
            in: modelContext
        )
    }

}
