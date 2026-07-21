// SearchModePreferences.swift - Android search-mode persistence contracts

import SwordKit

/** Android EPUB Search's three decorated modes plus its nullable raw FTS5 mode. */
public enum EpubSearchMode: Sendable, Codable, Equatable, CaseIterable {
    case allWords
    case anyWords
    case phrase
    case fullTextQuery

    /** Word-mode decoration used by the shared query compiler, or `nil` for raw FTS5 syntax. */
    public var wordMode: SearchWordMode? {
        switch self {
        case .allWords: return .allWords
        case .anyWords: return .anyWord
        case .phrase: return .phrase
        case .fullTextQuery: return nil
        }
    }

    /** Exact nullable `SearchType.name()` value persisted by Android. */
    fileprivate var androidPersistedValue: String? {
        switch self {
        case .allWords: return "ALL_WORDS"
        case .anyWords: return "ANY_WORDS"
        case .phrase: return "PHRASE"
        case .fullTextQuery: return nil
        }
    }
}

/**
 Persists search-mode choices using Android's exact EPUB preference key and value spellings.

 Android's Bible Search keeps its mode in activity state, while EPUB Search durably stores the
 nullable `SearchType` name under `epubSearch-SearchType`. This helper owns that storage mapping so
 UI consumers do not duplicate Android enum strings or write directly through `SettingsStore`.
 */
public struct SearchModePreferences {
    private let settingsStore: SettingsStore

    /** Creates a mode preference adapter over the app's shared settings store. */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Restores Android's complete EPUB mode, including its missing-value raw FTS5 selection.

     Unknown persisted values are treated as raw FTS5 mode, matching Android's fallback branch,
     and are never silently reinterpreted as a decorated word mode.
     */
    public func epubMode() -> EpubSearchMode {
        switch settingsStore.getString(.epubSearchType) {
        case "ALL_WORDS": return .allWords
        case "ANY_WORDS": return .anyWords
        case "PHRASE": return .phrase
        default: return .fullTextQuery
        }
    }

    /**
     Restores Android's persisted EPUB word mode.

     - Returns: The persisted phrase/all/any mode, or `nil` for Android's unselected/advanced state.
     - Side effects: Reads the registry-routed SwiftData setting.
     - Failure modes: Missing and unknown values return `nil` rather than selecting a different mode.
     */
    public func epubWordMode() -> SearchWordMode? {
        epubMode().wordMode
    }

    /**
     Saves the complete EPUB mode using Android's nullable `SearchType.name()` representation.

     Raw FTS5 mode removes the preference row because Android writes `null`; decorated modes store
     the exact JSword enum name.
     */
    public func saveEpubMode(_ mode: EpubSearchMode) {
        if let value = mode.androidPersistedValue {
            settingsStore.setString(.epubSearchType, value: value)
        } else {
            settingsStore.remove(AppPreferenceKey.epubSearchType.rawValue)
        }
    }

    /**
     Saves one EPUB word mode using JSword `SearchType.name()` spelling.

     - Parameter mode: Phrase/all/any mode selected by the EPUB Search form.
     - Side effects: Writes the Android-compatible string through `SettingsStore`.
     - Failure modes: `SettingsStore` retains its existing best-effort persistence behavior.
     */
    public func saveEpubWordMode(_ mode: SearchWordMode) {
        switch mode {
        case .allWords: saveEpubMode(.allWords)
        case .anyWord: saveEpubMode(.anyWords)
        case .phrase: saveEpubMode(.phrase)
        }
    }
}
