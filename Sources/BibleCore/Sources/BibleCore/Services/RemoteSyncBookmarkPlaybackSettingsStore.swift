// RemoteSyncBookmarkPlaybackSettingsStore.swift — Local preservation of Android bookmark playback payloads

import Foundation

/**
 Preserves Android bookmark `playbackSettings` JSON payloads in iOS's local-only settings store.

 Android bookmark rows persist a richer `PlaybackSettings` JSON payload than the current iOS
 bookmark model can represent directly. iOS currently consumes only the `bookId` subset natively,
 so this store keeps the original Android JSON locally for future patch application and fidelity
 restoration instead of discarding it during initial-backup import.

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
public final class RemoteSyncBookmarkPlaybackSettingsStore {
    /**
     Identifies which Android bookmark table owned one preserved playback-settings payload.

     The key space distinguishes Bible and generic bookmarks so future patch logic can recover the
     original table membership without inferring it from the UUID alone.
     */
    public enum BookmarkKind: String, Sendable, Equatable, Codable {
        /// Playback payload preserved for one `BibleBookmark` row.
        case bible

        /// Playback payload preserved for one `GenericBookmark` row.
        case generic
    }

    /**
     One preserved Android bookmark playback-settings payload.

     - Important: `playbackSettingsJSON` is stored verbatim so future sync work can rehydrate the
       full Android semantics without lossy translation.
     */
    public struct Entry: Sendable, Equatable {
        /// Android bookmark table that owned the payload.
        public let bookmarkKind: BookmarkKind

        /// Bookmark identifier associated with the preserved payload.
        public let bookmarkID: UUID

        /// Raw Android JSON payload from the bookmark table's `playbackSettings` column.
        public let playbackSettingsJSON: String

        /**
         Creates one preserved Android bookmark playback-settings payload.

         - Parameters:
           - bookmarkKind: Android bookmark table that owned the payload.
           - bookmarkID: Bookmark identifier associated with the preserved payload.
           - playbackSettingsJSON: Raw Android JSON payload from the `playbackSettings` column.
         - Side effects: none.
         - Failure modes: This initializer cannot fail.
         */
        public init(bookmarkKind: BookmarkKind, bookmarkID: UUID, playbackSettingsJSON: String) {
            self.bookmarkKind = bookmarkKind
            self.bookmarkID = bookmarkID
            self.playbackSettingsJSON = playbackSettingsJSON
        }
    }

    private let settingsStore: SettingsStore

    private enum Keys {
        static let prefix = "remote_sync.bookmarks.android_playback_settings"
    }

    /**
     Creates a local-only store for preserved Android bookmark playback-settings payloads.

     - Parameter settingsStore: Local settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Stores or replaces one raw Android bookmark playback-settings payload.

     - Parameters:
       - playbackSettingsJSON: Raw JSON payload to preserve.
       - bookmarkID: Bookmark identifier that owns the payload.
       - kind: Android bookmark table that owns the payload.
     - Side effects:
       - writes one namespaced local `Setting` row
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func setPlaybackSettingsJSON(_ playbackSettingsJSON: String, for bookmarkID: UUID, kind: BookmarkKind) {
        settingsStore.setString(scopedKey(bookmarkID: bookmarkID, kind: kind), value: playbackSettingsJSON)
    }

    /**
     Reads one preserved Android bookmark playback-settings payload.

     - Parameters:
       - bookmarkID: Bookmark identifier that owns the payload.
       - kind: Android bookmark table that owns the payload.
     - Returns: The preserved raw JSON payload, or `nil` when no value has been stored.
     - Side effects: none.
     - Failure modes:
       - malformed or missing stored keys return `nil`
     */
    public func playbackSettingsJSON(for bookmarkID: UUID, kind: BookmarkKind) -> String? {
        let value = settingsStore.getString(scopedKey(bookmarkID: bookmarkID, kind: kind))
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    /**
     Returns every preserved Android bookmark playback-settings payload.

     - Returns: Preserved payloads sorted by bookmark kind and UUID string.
     - Side effects: none.
     - Failure modes:
       - malformed keys are skipped rather than throwing
     */
    public func allEntries() -> [Entry] {
        settingsStore.entries(withPrefix: Keys.prefix)
            .compactMap { decodeEntry($0) }
            .sorted {
                if $0.bookmarkKind == $1.bookmarkKind {
                    return $0.bookmarkID.uuidString < $1.bookmarkID.uuidString
                }
                return $0.bookmarkKind.rawValue < $1.bookmarkKind.rawValue
            }
    }

    /**
     Removes one preserved Android bookmark playback-settings payload.

     - Parameters:
       - bookmarkID: Bookmark identifier that owns the payload.
       - kind: Android bookmark table that owns the payload.
     - Side effects:
       - deletes one namespaced local `Setting` row when present
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func removePlaybackSettings(for bookmarkID: UUID, kind: BookmarkKind) {
        settingsStore.remove(scopedKey(bookmarkID: bookmarkID, kind: kind))
    }

    /**
     Removes all preserved Android bookmark playback-settings payloads.

     - Side effects:
       - deletes every namespaced local `Setting` row managed by this store
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func clearAll() {
        for entry in settingsStore.entries(withPrefix: Keys.prefix) {
            settingsStore.remove(entry.key)
        }
    }

    private func scopedKey(bookmarkID: UUID, kind: BookmarkKind) -> String {
        "\(Keys.prefix).\(kind.rawValue).\(bookmarkID.uuidString.lowercased())"
    }

    private func decodeEntry(_ entry: Setting) -> Entry? {
        let prefix = "\(Keys.prefix)."
        guard entry.key.hasPrefix(prefix), !entry.value.isEmpty else {
            return nil
        }

        let suffix = String(entry.key.dropFirst(prefix.count))
        let parts = suffix.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let bookmarkKind = BookmarkKind(rawValue: String(parts[0])),
              let bookmarkID = UUID(uuidString: String(parts[1])) else {
            return nil
        }

        return Entry(
            bookmarkKind: bookmarkKind,
            bookmarkID: bookmarkID,
            playbackSettingsJSON: entry.value
        )
    }
}
