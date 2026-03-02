// HistoryView.swift — Navigation history

import SwiftUI
import SwiftData
import BibleCore

/// Displays navigation history for back/forward navigation.
public struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WindowManager.self) private var windowManager
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HistoryItem.createdAt, order: .reverse) private var allHistory: [HistoryItem]
    var onNavigate: ((String, Int) -> Void)?
    /// Resolves an OSIS book ID to a human-readable name using the active controller's dynamic book list.
    var bookNameResolver: ((String) -> String?)?

    public init(bookNameResolver: ((String) -> String?)? = nil, onNavigate: ((String, Int) -> Void)? = nil) {
        self.bookNameResolver = bookNameResolver
        self.onNavigate = onNavigate
    }

    /// Filter history to the active window only.
    private var history: [HistoryItem] {
        guard let windowId = windowManager.activeWindow?.id else { return allHistory }
        return allHistory.filter { $0.window?.id == windowId }
    }

    public var body: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView(
                    String(localized: "history_no_history"),
                    systemImage: "clock",
                    description: Text(String(localized: "history_no_history_description"))
                )
            } else {
                List {
                    ForEach(history) { item in
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
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteItems)
                }
            }
        }
        .navigationTitle(String(localized: "history"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
            if !history.isEmpty {
                ToolbarItem(placement: .destructiveAction) {
                    Button(String(localized: "clear"), role: .destructive) {
                        clearHistory()
                    }
                }
            }
        }
    }

    /// Format a key like "Gen.1.1" into "Genesis 1"
    private func formatKey(_ key: String) -> String {
        let parts = key.split(separator: ".")
        guard parts.count >= 2 else { return key }
        let osisId = String(parts[0])
        let chapter = String(parts[1])
        let bookName = bookNameResolver?(osisId) ?? BibleReaderController.bookName(forOsisId: osisId) ?? osisId
        return "\(bookName) \(chapter)"
    }

    private func navigateTo(_ item: HistoryItem) {
        let parts = item.key.split(separator: ".")
        guard parts.count >= 2 else { return }
        let osisId = String(parts[0])
        let chapter = Int(parts[1]) ?? 1
        let bookName = bookNameResolver?(osisId) ?? BibleReaderController.bookName(forOsisId: osisId) ?? osisId
        dismiss()
        onNavigate?(bookName, chapter)
    }

    private func deleteItems(at offsets: IndexSet) {
        let toDelete = offsets.map { history[$0] }
        for item in toDelete {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func clearHistory() {
        for item in history {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }
}
