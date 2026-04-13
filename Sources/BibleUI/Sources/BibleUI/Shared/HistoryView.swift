// HistoryView.swift — Navigation history

import SwiftUI
import SwiftData
import BibleCore

/**
 Displays navigation history for the active reader window and lets the user jump back to prior locations.

 The view filters persisted history to the active window when possible, formats stored OSIS-style keys
 into user-visible references, and offers row deletion plus full-history clearing.

 Data dependencies:
 - `modelContext` is used to delete persisted history rows
 - `windowManager` determines which window's history should be shown
 - `bookNameResolver` can translate OSIS book IDs using the active module's dynamic canon

 Side effects:
 - selecting a row dismisses the sheet and forwards the stored history key through `onNavigate`
 - swipe deletion and clear-all actions remove persisted history items from SwiftData
 */
public struct HistoryView: View {
    /// SwiftData context used for deleting history rows.
    @Environment(\.modelContext) private var modelContext

    /// Shared window manager used to scope history to the active window.
    @Environment(WindowManager.self) private var windowManager

    /// Dismiss action for closing the history screen.
    @Environment(\.dismiss) private var dismiss

    /// All persisted history items ordered newest-first.
    @Query(sort: \HistoryItem.createdAt, order: .reverse) private var allHistory: [HistoryItem]

    /// Callback invoked when the user chooses a history item to navigate back to.
    var onNavigate: ((String) -> Void)?

    /// Resolves an OSIS book ID to a human-readable name using the active controller's dynamic book list.
    var bookNameResolver: ((String) -> String?)?

    /**
     Creates the history screen.

     - Parameters:
       - bookNameResolver: Optional resolver that maps OSIS IDs to dynamic, module-aware book names.
       - onNavigate: Optional callback invoked with the stored history key when a row is selected.
     */
    public init(
        bookNameResolver: ((String) -> String?)? = nil,
        onNavigate: ((String) -> Void)? = nil
    ) {
        self.bookNameResolver = bookNameResolver
        self.onNavigate = onNavigate
    }

    /// Filter history to the active window only.
    private var history: [HistoryItem] {
        guard let windowId = windowManager.activeWindow?.id else { return allHistory }
        return allHistory.filter { $0.window?.id == windowId }
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
                                    Text(formatKey(item.key))
                                        .font(.headline)
                                    Text(item.document)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.createdAt, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(historyRowIdentifier(for: item))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
        .accessibilityIdentifier("historyScreen")
        .accessibilityValue(historyAccessibilityValue)
        .navigationTitle(String(localized: "history"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done")) { dismiss() }
                    .accessibilityIdentifier("historyDoneButton")
            }
            if !historySnapshot.isEmpty {
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
        let parts = key.split(separator: ".")
        guard parts.count >= 2 else { return key }
        let osisId = String(parts[0])
        let chapter = String(parts[1])
        let bookName = bookNameResolver?(osisId) ?? BibleReaderController.bookName(forOsisId: osisId) ?? osisId
        return "\(bookName) \(chapter)"
    }

    /**
     Dismisses the history view and forwards the selected stored key to the navigation callback.
     */
    private func navigateTo(_ item: HistoryItem) {
        onNavigate?(item.key)
        dismiss()
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
        "historyRow::\(sanitizedHistoryKey(for: item))"
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
        "historyDeleteButton::\(sanitizedHistoryKey(for: item))"
    }

    /// Stable History screen state exported for UI automation.
    private var historyAccessibilityValue: String {
        let baseState = "count=\(history.count)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }

        let rowTokens = history.prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit).map {
            "|\(sanitizedHistoryKey(for: $0))|"
        }.joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
    }

    /**
     Sanitizes one stored history key for reuse in accessibility identifiers.
     *
     * - Parameter item: History row whose stored key should be transformed into an identifier-safe token.
     * - Returns: Key token containing only ASCII letters, digits, and underscores.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func sanitizedHistoryKey(for item: HistoryItem) -> String {
        item.key.replacingOccurrences(
            of: #"[^A-Za-z0-9]+"#,
            with: "_",
            options: .regularExpression
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
        for item in history where item.key == key {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    /**
     Deletes every currently visible history row for the active window scope.
     */
    private func clearHistory() {
        let visibleHistory = history
        for item in visibleHistory {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

}
