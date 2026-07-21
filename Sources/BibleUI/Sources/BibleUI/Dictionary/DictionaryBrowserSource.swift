// DictionaryBrowserSource.swift -- Backend-independent exact dictionary chooser source

import BibleCore
import SwordKit

/**
 Immutable dictionary chooser operations bound to one exact SWORD or SQLite module snapshot.

 The browser consumes only a title, source-order exact keys, and lazy row presentations. Capturing a
 concrete module rather than mutable controller state keeps retries on the same backend and prevents
 a concurrent module switch from mixing one module's keys with another module's definitions.
 */
struct DictionaryBrowserSource: @unchecked Sendable {
    /// User-visible module title.
    let title: String

    /// Source-order exact key enumeration.
    private let keyLoader: @Sendable () throws -> [String]

    /// Lazy exact-entry presentation used by the bounded browser cache.
    private let presentationLoader: DictionaryEntryDisplayCache.CachePolicyLoader

    /**
     Creates a source bound to one native SWORD dictionary.

     - Parameter module: Exact module snapshot selected when the browser opens.
     - Side effects: None until keys or rows are requested.
     - Failure modes: Key enumeration rethrows SWORD failures; row failures become key-only labels.
     */
    init(swordModule module: SwordModule) {
        title = module.info.description
        keyLoader = { try module.loadAllKeys() }
        presentationLoader = { key in
            await Task.detached(priority: .utility) {
                do {
                    return DictionaryEntryDisplayLoadResult.cacheable(
                        try module.rawOSISFragment(forKey: key).dictionaryEntryPresentation()
                    )
                } catch {
                    return DictionaryEntryDisplayLoadResult.retryable(
                        Self.keyOnlyPresentation(key)
                    )
                }
            }.value
        }
    }

    /**
     Creates a source bound to one validated SQLite dictionary handle.

     - Parameter module: Exact immutable SQLite module selected when the browser opens.
     - Side effects: None until keys or rows are requested; each request owns its SQLite connection.
     - Failure modes: Key enumeration rethrows typed reader failures; missing/malformed definitions
       retain selectable key-only rows and never substitute a neighboring key.
     */
    init(sqliteModule module: BibleReaderSQLiteModuleHandle) {
        title = module.info.description
        keyLoader = { try module.dictionaryKeys() }
        presentationLoader = { key in
            await Task.detached(priority: .utility) {
                do {
                    guard let content = try module.dictionaryContent(for: key),
                          let snippet = SQLiteDocumentXMLCompatibility.dictionarySnippet(
                              fragment: content.text,
                              key: key
                          ) else {
                        return DictionaryEntryDisplayLoadResult.cacheable(
                            Self.keyOnlyPresentation(key)
                        )
                    }
                    return DictionaryEntryDisplayLoadResult.cacheable(
                        SwordDictionaryEntryPresentation(
                            key: key,
                            snippet: snippet,
                            displayText: snippet.isEmpty ? key : "\(key) - \(snippet)"
                        )
                    )
                } catch {
                    return DictionaryEntryDisplayLoadResult.retryable(
                        Self.keyOnlyPresentation(key)
                    )
                }
            }.value
        }
    }

    /** Returns exact keys from the captured backend snapshot. */
    func keys() throws -> [String] {
        try keyLoader()
    }

    /**
     Returns exact keys without blocking the caller's executor and propagates structured cancellation.

     - Returns: Source-order exact keys from the captured backend snapshot.
     - Side effects: Runs synchronous backend enumeration on a utility task.
     - Failure modes: Rethrows backend failures and `CancellationError`; cancellation explicitly
       reaches SQLite's progress handler instead of leaving an abandoned enumeration running.
     */
    func loadKeys() async throws -> [String] {
        let operation = Task.detached(priority: .utility) { [keyLoader] in
            try keyLoader()
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /** Creates one bounded lazy row cache over the captured backend snapshot. */
    func displayCache(capacity: Int = 4_096) -> DictionaryEntryDisplayCache {
        DictionaryEntryDisplayCache(
            capacity: capacity,
            cachePolicyLoader: presentationLoader
        )
    }

    /** Returns a deterministic selectable row when exact entry projection fails. */
    private static func keyOnlyPresentation(_ key: String) -> SwordDictionaryEntryPresentation {
        SwordDictionaryEntryPresentation(key: key, snippet: "", displayText: key)
    }
}
