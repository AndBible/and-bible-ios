// HistoryView.swift — Android-parity navigation history content

import BibleCore
import SwiftData
import SwiftUI

/**
 Renders Android's window-scoped History rows inside an application-owned dialog.

 This view has one presentation contract. It does not retain the former native iOS `List`,
 navigation toolbar, swipe deletion, or clear-history branch because none of those behaviors exist
 in Android's History activity and no production caller used that branch. The reader captures the
 source window and owns dismissal/navigation after a row tap.

 Inputs:
 - optional module-aware OSIS book-name resolver
 - row-selection callback
 - captured reader-window identity

 Output: a content-sized row stack for short histories or a bounded scrolling stack for long ones

 Side effects: selecting a row invokes `onNavigate` with its stored navigation key

 Failure modes: malformed keys and unresolved book names preserve their stored fallback text
 */
public struct HistoryView: View {
    /// Legacy scope fallback used only when the owner cannot capture a window identity.
    @Environment(WindowManager.self) private var windowManager

    /// All persisted checkpoints ordered newest-first.
    @Query(sort: \HistoryItem.createdAt, order: .reverse) private var allHistory: [HistoryItem]

    /// Callback that applies one stored key to the captured reader pane.
    private let onNavigate: ((String) -> Void)?

    /// Optional module-aware OSIS book-name resolver.
    private let bookNameResolver: ((String) -> String?)?

    /// Immutable source-window identity captured when the dialog opens.
    private let activeWindowID: UUID?

    /**
     Creates Android's History row content.

     - Parameters:
       - bookNameResolver: Maps OSIS book IDs to source-module display names when available.
       - onNavigate: Receives the selected persisted key.
       - activeWindowID: Captured source reader window; nil falls back to the active window.
     - Side effects: none until a row is selected.
     - Failure modes: none.
     */
    public init(
        bookNameResolver: ((String) -> String?)? = nil,
        onNavigate: ((String) -> Void)? = nil,
        activeWindowID: UUID? = nil
    ) {
        self.bookNameResolver = bookNameResolver
        self.onNavigate = onNavigate
        self.activeWindowID = activeWindowID
    }

    /// Newest-first checkpoints belonging to the captured source window.
    private var history: [HistoryItem] {
        HistoryListPresentation.visibleItems(allHistory, activeWindowID: resolvedWindowID)
    }

    /// Captured scope wins; active-window lookup remains only for source-compatible callers.
    private var resolvedWindowID: UUID? {
        activeWindowID ?? windowManager.activeWindow?.id
    }

    public var body: some View {
        let historySnapshot = history
        ZStack(alignment: .topLeading) {
            Group {
                if historySnapshot.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .accessibilityIdentifier("historyEmptyState")
                } else if historySnapshot.count <= 6 {
                    historyRows(historySnapshot)
                } else {
                    ScrollView {
                        historyRows(historySnapshot)
                    }
                    .frame(maxHeight: 520)
                    .scrollIndicators(.automatic)
                }
            }
            .frame(maxWidth: .infinity)

            AndroidActivityAccessibilityMarker(
                label: String(localized: "history", defaultValue: "History"),
                accessibilityIdentifier: "historyScreen",
                accessibilityValue: historyAccessibilityValue,
                surfaceColor: .clear
            )
        }
    }

    /** Builds Android's content-sized History rows without native list chrome. */
    private func historyRows(_ items: [HistoryItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.id) { item in
                Button {
                    onNavigate?(item.key)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(formatDescription(for: item))
                            .font(.title3)
                            .foregroundStyle(.primary)
                        Text(HistoryListPresentation.androidDateTime(item.createdAt))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(HistoryListPresentation.rowIdentifier(for: item))
            }
        }
        .padding(.bottom, 8)
    }

    /** Restores Android's reference-plus-module row title from persisted fields. */
    private func formatDescription(for item: HistoryItem) -> String {
        HistoryListPresentation.formattedDescription(
            key: item.key,
            document: item.document,
            bookNameResolver: bookNameResolver
        )
    }

    /// Stable bounded History state exported for UI automation.
    private var historyAccessibilityValue: String {
        HistoryListPresentation.accessibilityValue(
            for: history,
            includeRowTokens: UITestRuntimeConfiguration.enablesDetailedAccessibilityExports,
            rowTokenLimit: UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit
        )
    }
}
