// HistoryListPresentation.swift - History list presentation and mutation contracts

import Foundation
import SwiftData
import BibleCore

/**
 Centralizes the History screen's value-level presentation and destructive action rules.

 The SwiftUI `HistoryView` remains responsible for rendering and user gestures, while this helper
 owns deterministic row scoping, accessibility identifiers, exported UI-test state, and the
 SwiftData deletion operations behind Clear and row-delete actions. Keeping those contracts here
 lets app-host-free package tests verify the behavior that used to require expensive XCUITest
 reopen flows.

 Inputs:
 - persisted `HistoryItem` rows ordered by the caller's fetch descriptor
 - an optional active-window identifier matching Android's active pane scoping
 - the `ModelContext` that owns rows when destructive actions are requested

 Outputs:
 - filtered history rows, deterministic identifiers/state strings, or the number of rows deleted

 Side effects:
 - `clearVisibleItems` and `deleteVisibleItems` delete rows from SwiftData and save the context

 Failure modes:
 - save failures are rethrown to test callers; production UI wrappers intentionally discard them
   because the screen has no retry surface for destructive gestures
 */
enum HistoryListPresentation {
    /**
     Filters persisted rows to the active reader window when one is available.

     - Parameters:
       - allHistory: History rows in display order.
       - activeWindowID: Active reader window identifier, or nil when no scoped window exists.
     - Returns: Rows visible in the current History screen, preserving the input order.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func visibleItems(_ allHistory: [HistoryItem], activeWindowID: UUID?) -> [HistoryItem] {
        guard let activeWindowID else { return allHistory }
        return allHistory.filter { $0.window?.id == activeWindowID }
    }

    /**
     Formats a persisted OSIS-style history key for display in the row title.

     - Parameters:
       - key: Stored history key, normally shaped like `Gen.1.1`.
       - bookNameResolver: Optional module-aware OSIS name resolver supplied by the reader.
     - Returns: `Book Chapter` for recognized OSIS keys, otherwise the original key.
     - Side effects: none.
     - Failure modes: Falls back to the OSIS ID or original key when no localized book name exists.
     */
    static func formattedKey(_ key: String, bookNameResolver: ((String) -> String?)?) -> String {
        let parts = key.split(separator: ".")
        guard parts.count >= 2 else { return key }
        let osisID = String(parts[0])
        let chapter = String(parts[1])
        let bookName = bookNameResolver?(osisID) ?? BibleReaderController.bookName(forOsisId: osisID) ?? osisID
        return "\(bookName) \(chapter)"
    }

    /**
     Formats one persisted History row using Android's `KeyHistoryItem.description` contract.

     Android appends the active document abbreviation after the localized reference.  iOS stores
     that abbreviation separately, so this projection restores it without changing the persisted
     history schema or the generic reference formatter used by legacy callers.

     - Parameters:
       - key: Stored OSIS-style reference from the history checkpoint.
       - document: Active module initials captured with the checkpoint.
       - bookNameResolver: Optional module-aware OSIS name resolver supplied by the reader.
     - Returns: Localized reference followed by the nonempty document abbreviation.
     - Side effects: none.
     - Failure modes: Falls back to the raw key and omits an unavailable document abbreviation.
     */
    static func formattedDescription(
        key: String,
        document: String,
        bookNameResolver: ((String) -> String?)?
    ) -> String {
        let reference = formattedKey(key, bookNameResolver: bookNameResolver)
        let abbreviation = document.trimmingCharacters(in: .whitespacesAndNewlines)
        return abbreviation.isEmpty ? reference : "\(reference) \(abbreviation)"
    }

    /**
     Formats a History timestamp using Android's dialog-row information density.

     - Parameter date: Timestamp captured with the persisted navigation checkpoint.
     - Returns: Localized time, weekday, day, and abbreviated month, for example `2:35 PM, Tue 21 Jul`.
     - Side effects: Reads the user's current locale and time zone through `DateFormatter`.
     - Failure modes: The formatter always returns a nonempty localized string for valid `Date` values.
     */
    static func androidDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "h:mm a, E d MMM"
        return formatter.string(from: date)
    }

    /**
     Resolves the deterministic accessibility identifier for one history row.

     - Parameter item: History row whose stored key should back the identifier.
     - Returns: Accessibility identifier stable across row reordering for the same history key.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func rowIdentifier(for item: HistoryItem) -> String {
        "historyRow::\(sanitizedKey(item.key))"
    }

    /**
     Resolves the deterministic accessibility identifier for one history row's delete action.

     - Parameter item: History row whose stored key should back the delete-action identifier.
     - Returns: Accessibility identifier stable across row reordering for the same history key.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func deleteButtonIdentifier(for item: HistoryItem) -> String {
        "historyDeleteButton::\(sanitizedKey(item.key))"
    }

    /**
     Exports stable History screen state for UI automation without exposing live view internals.

     - Parameters:
       - visibleHistory: Rows visible in the current active-window scope.
       - includeRowTokens: Whether row tokens should be included for detailed UI-test runs.
       - rowTokenLimit: Maximum number of row tokens exported to keep accessibility values bounded.
     - Returns: `count=N` plus optional delimited row tokens.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func accessibilityValue(
        for visibleHistory: [HistoryItem],
        includeRowTokens: Bool,
        rowTokenLimit: Int
    ) -> String {
        let baseState = "count=\(visibleHistory.count)"
        guard includeRowTokens else { return baseState }

        let rowTokens = visibleHistory.prefix(rowTokenLimit).map {
            rowStateToken(for: $0)
        }.joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
    }

    /**
     Sanitizes one stored history key for reuse in accessibility identifiers.

     - Parameter key: Stored key to transform into an identifier-safe token.
     - Returns: Token containing only ASCII letters, digits, and underscores.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func sanitizedKey(_ key: String) -> String {
        key.replacingOccurrences(
            of: #"[^A-Za-z0-9]+"#,
            with: "_",
            options: .regularExpression
        )
    }

    /**
     Wraps one row's sanitized key in delimiters for exact accessibility-state matching.

     - Parameter item: History row whose key should be exported.
     - Returns: Delimited row token such as `|Exod_2_1|`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func rowStateToken(for item: HistoryItem) -> String {
        "|\(sanitizedKey(item.key))|"
    }

    /**
     Deletes every row visible in the active History scope and saves the model context.

     - Parameters:
       - allHistory: All persisted rows currently loaded by the view.
       - activeWindowID: Active reader window identifier, or nil to clear every loaded row.
       - modelContext: SwiftData context that owns the history rows.
     - Returns: Number of rows deleted.
     - Side effects: Deletes matching `HistoryItem` rows from SwiftData and saves the context.
     - Throws: Any SwiftData save error produced after deleting the visible rows.
     */
    @discardableResult
    static func clearVisibleItems(
        from allHistory: [HistoryItem],
        activeWindowID: UUID?,
        in modelContext: ModelContext
    ) throws -> Int {
        let items = visibleItems(allHistory, activeWindowID: activeWindowID)
        for item in items {
            modelContext.delete(item)
        }
        try modelContext.save()
        return items.count
    }

    /**
     Deletes visible rows whose stored key matches the requested deterministic key.

     - Parameters:
       - key: Persisted history key to remove from the current History scope.
       - allHistory: All persisted rows currently loaded by the view.
       - activeWindowID: Active reader window identifier, or nil to search every loaded row.
       - modelContext: SwiftData context that owns the history rows.
     - Returns: Number of rows deleted.
     - Side effects: Deletes matching `HistoryItem` rows from SwiftData and saves the context.
     - Throws: Any SwiftData save error produced after deleting matching rows.
     */
    @discardableResult
    static func deleteVisibleItems(
        matchingKey key: String,
        from allHistory: [HistoryItem],
        activeWindowID: UUID?,
        in modelContext: ModelContext
    ) throws -> Int {
        let items = visibleItems(allHistory, activeWindowID: activeWindowID).filter { $0.key == key }
        for item in items {
            modelContext.delete(item)
        }
        try modelContext.save()
        return items.count
    }
}
