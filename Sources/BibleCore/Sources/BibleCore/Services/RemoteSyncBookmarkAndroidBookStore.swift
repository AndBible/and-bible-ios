// RemoteSyncBookmarkAndroidBookStore.swift — Local preservation of Android bookmark book columns

import Foundation

/**
 Preserves raw Android `BibleBookmark.book` column values in iOS's local-only settings store.

 Android stores SWORD module initials (or NULL) in the bookmark `book` column, while iOS rewrites
 the same field into a display book name during restore so bookmark rendering works (issue #356).
 This store keeps the original Android value per bookmark so outbound sync snapshots and backup
 exports can round-trip Android's module-initials semantics instead of leaking display names into
 Android's column.

 Data dependencies:
 - `SettingsStore` provides local-only key-value persistence in the `LocalStore`

 Side effects:
 - writes and removes namespaced `Setting` rows in the local SwiftData settings table

 Failure modes:
 - underlying `SettingsStore` writes swallow persistence failures, so callers should treat this
   store as best-effort preservation rather than transactional storage

 Concurrency:
 - this type inherits the confinement requirements of the supplied `SettingsStore`
 */
public final class RemoteSyncBookmarkAndroidBookStore {
    /// Sentinel persisted for Android rows whose `book` column was NULL. Real SWORD module
    /// initials never contain double underscores, so the sentinel cannot collide with data.
    private static let nullSentinel = "__android_null__"

    private let settingsStore: SettingsStore

    private enum Keys {
        static let prefix = "remote_sync.bookmarks.android_book"
    }

    /**
     Creates a local-only store for preserved Android bookmark `book` column values.

     - Parameter settingsStore: Local settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Stores or replaces one preserved raw Android `book` value.

     - Parameters:
       - rawBook: Raw Android column value; `nil` records that Android stored NULL.
       - bookmarkID: Bible bookmark identifier that owns the value.
     - Side effects: writes one namespaced local `Setting` row.
     - Failure modes: persistence failures are swallowed by `SettingsStore`.
     */
    public func setRawBook(_ rawBook: String?, for bookmarkID: UUID) {
        settingsStore.setString(scopedKey(bookmarkID: bookmarkID), value: rawBook ?? Self.nullSentinel)
    }

    /**
     Reads one preserved raw Android `book` value.

     - Parameter bookmarkID: Bible bookmark identifier that owns the value.
     - Returns: `.some(value)` when a value was preserved (`value` itself is `nil` when Android
       stored NULL), or `nil` when this bookmark has no preserved entry.
     - Side effects: none.
     - Failure modes: missing stored keys return `nil`.
     */
    public func rawBook(for bookmarkID: UUID) -> String?? {
        guard let stored = settingsStore.getString(scopedKey(bookmarkID: bookmarkID)),
              !stored.isEmpty else {
            return nil
        }
        return .some(stored == Self.nullSentinel ? nil : stored)
    }

    /**
     Projects one bookmark's Android-facing `book` value for outbound snapshots.

     - Parameters:
       - bookmarkID: Bible bookmark identifier being projected.
       - localBook: Current iOS display value stored on the SwiftData model.
     - Returns: The preserved raw Android value when one exists, otherwise `localBook`.
     - Side effects: none.
     - Failure modes: none.
     */
    public func androidBookValue(for bookmarkID: UUID, localBook: String?) -> String? {
        if let preserved = rawBook(for: bookmarkID) {
            return preserved
        }
        return localBook
    }

    /**
     Removes every preserved Android `book` entry.

     - Side effects: deletes all namespaced rows for this store.
     - Failure modes: persistence failures are swallowed by `SettingsStore`.
     */
    public func clearAll() {
        for entry in settingsStore.entries(withPrefix: Keys.prefix) {
            settingsStore.remove(entry.key)
        }
    }

    private func scopedKey(bookmarkID: UUID) -> String {
        "\(Keys.prefix).\(bookmarkID.uuidString.lowercased())"
    }
}
