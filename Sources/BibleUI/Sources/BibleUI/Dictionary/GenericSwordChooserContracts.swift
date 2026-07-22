import Foundation
import SwordKit

/**
 Android-compatible dictionary key filtering.

 `ChooseDictionaryWord` displays snippets but filters only `key.name`, using locale-aware
 lowercasing. Keeping filtering independent from asynchronous snippet loading prevents visible rows
 from appearing or disappearing as large-lexicon cache entries arrive.
 */
enum DictionaryKeyFilter {
    /**
     Filters exact module keys by the user's search text.

     - Parameters:
       - keys: Exact global key list.
       - searchText: User-entered key query.
     - Returns: Keys whose locale-lowercased names contain the locale-lowercased query.
     - Side effects: None.
     - Failure modes: None; an empty query returns every key.
     */
    static func filteredKeys(_ keys: [String], searchText: String) -> [String] {
        guard !searchText.isEmpty else { return keys }
        let locale = Locale.current
        let query = searchText.lowercased(with: locale)
        return keys.filter { $0.lowercased(with: locale).contains(query) }
    }
}

/** Cache policy returned with one exact dictionary chooser presentation. */
enum DictionaryEntryDisplayLoadResult: Sendable {
    /// Stable source result that may be retained for this browser session.
    case cacheable(SwordDictionaryEntryPresentation)

    /// Fallback shown for this request only; the next request must retry the source.
    case retryable(SwordDictionaryEntryPresentation)

    /** Presentation shown to the current chooser row. */
    var presentation: SwordDictionaryEntryPresentation {
        switch self {
        case .cacheable(let presentation), .retryable(let presentation):
            return presentation
        }
    }
}

/**
 Bounded per-browser cache for Android dictionary chooser rows.

 Android materializes `KeyInfo` rows while filtering. iOS loads rows lazily as SwiftUI displays
 them, then retains the derived orthography/snippet so scrolling a large lexicon does not reread
 SWORD entries. Exact-key failures produce a key-only row and never accept SWORD's nearest key.
 */
actor DictionaryEntryDisplayCache {
    /// Exact-entry projection used by production and deterministic tests.
    typealias Loader = @Sendable (String) async -> SwordDictionaryEntryPresentation

    /// Exact-entry projection that distinguishes stable rows from retryable failures.
    typealias CachePolicyLoader = @Sendable (String) async -> DictionaryEntryDisplayLoadResult

    /// Maximum retained display rows for one browser session.
    private let capacity: Int
    /// Exact-entry loader bound to one module for the browser lifetime.
    private let loader: CachePolicyLoader
    /// Cached presentation keyed by exact module key.
    private var presentations: [String: SwordDictionaryEntryPresentation] = [:]
    /// FIFO insertion order used for deterministic eviction.
    private var insertionOrder: [String] = []
    /// Shared loads prevent concurrent SwiftUI rows from rereading the same SWORD entry.
    private var inFlight: [String: Task<DictionaryEntryDisplayLoadResult, Never>] = [:]

    /**
     Creates a bounded browser-session cache.

     - Parameters:
       - module: Dictionary module whose exact entries supply chooser rows.
       - capacity: Maximum rows retained; values below one are clamped to one.
     - Side effects: None.
     - Failure modes: None.
     */
    init(module: SwordModule, capacity: Int = 4_096) {
        self.capacity = max(1, capacity)
        self.loader = { key in
            await Task.detached(priority: .utility) {
                do {
                    return DictionaryEntryDisplayLoadResult.cacheable(
                        try module.rawOSISFragment(forKey: key).dictionaryEntryPresentation()
                    )
                } catch {
                    return DictionaryEntryDisplayLoadResult.retryable(
                        SwordDictionaryEntryPresentation(key: key, snippet: "", displayText: key)
                    )
                }
            }.value
        }
    }

    /**
     Creates a cache around a deterministic exact-entry loader.

     - Parameters:
       - capacity: Maximum rows retained; values below one are clamped to one.
       - loader: Async projection invoked once per retained exact key.
     - Side effects: None until `presentation(for:)` is called.
     - Failure modes: Loader failures must be represented by the supplied presentation contract.
     */
    init(capacity: Int = 4_096, loader: @escaping Loader) {
        self.capacity = max(1, capacity)
        self.loader = { key in .cacheable(await loader(key)) }
    }

    /**
     Creates a cache around a loader that classifies transient fallback rows.

     - Parameters:
       - capacity: Maximum stable rows retained; values below one are clamped to one.
       - cachePolicyLoader: Async projection returning a stable or retryable presentation.
     - Side effects: None until `presentation(for:)` is called.
     - Failure modes: Retryable rows are returned but never retained after the in-flight request.
     */
    init(
        capacity: Int = 4_096,
        cachePolicyLoader: @escaping CachePolicyLoader
    ) {
        self.capacity = max(1, capacity)
        self.loader = cachePolicyLoader
    }

    /**
     Loads and caches one exact dictionary chooser row.

     - Parameter key: Exact global-list key.
     - Returns: Android orthography/snippet presentation, or a key-only row on read/parse failure.
     - Side effects: Reads one SWORD entry on first access, coalesces concurrent requests for the same
       key, and may evict the oldest cached row.
     - Failure modes: Errors are represented by a deterministic key-only row so the chooser stays
       usable and never substitutes a nearby definition.
     - Important: The actor is reentrant while awaiting the loader; `inFlight` preserves exactly-once
       loading for concurrent requests to the same retained key.
     */
    func presentation(for key: String) async -> SwordDictionaryEntryPresentation {
        if let presentation = presentations[key] { return presentation }
        if let task = inFlight[key] { return await task.value.presentation }

        let loader = loader
        let task = Task { await loader(key) }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)

        guard case .cacheable(let presentation) = result else {
            return result.presentation
        }

        if presentations.count >= capacity, let evicted = insertionOrder.first {
            presentations.removeValue(forKey: evicted)
            insertionOrder.removeFirst()
        }
        presentations[key] = presentation
        insertionOrder.append(key)
        return presentation
    }

    /**
     Reports whether a row is cached for deterministic tests and diagnostics.

     - Parameter key: Exact module key.
     - Returns: `true` only after a stable source result was cached.
     - Side effects: None.
     - Failure modes: None.
     */
    func contains(_ key: String) -> Bool {
        presentations[key] != nil
    }
}

/**
 Result of preparing a SWORD generic-book/map chooser key list.

 The value preserves three states that Android handles differently: presentable content, a genuinely
 empty successful module, and a backend failure. It carries no side effects; browser views own
 presentation, dismissal, and retry behavior. Failure text remains available rather than being
 converted into an empty list.
 */
enum GenericSwordChooserResolution: Equatable {
    /// Present these exact keys in source order.
    case present([String])
    /// Android's empty-list path: notify the owner with no selection and dismiss the chooser.
    case dismissWithoutSelection
    /// Keep the chooser visible and present a retryable backend error instead of an empty state.
    case failed(message: String)
}

/**
 Normalizes SWORD general-book/map keys and applies Android's empty chooser behavior.

 Inputs are either exact source-order keys or a typed key-read result. Outputs are deterministic
 chooser values with no UI side effects. Backend errors remain `.failed`; only successful content can
 produce presentation or Android's null-selection dismissal.
 */
enum GenericSwordChooserResolver {
    /**
     Resolves a typed SWORD key-list result without conflating backend failure and empty content.

     - Parameter result: Successful exact keys or the backend error produced by `loadAllKeys()`.
     - Returns: Present/dismiss behavior for a successful list, or a retryable failure message.
     - Side effects: None.
     - Failure modes: Errors are represented by `.failed` and never converted to an empty array.
     */
    static func resolve(
        result: Result<[String], Error>
    ) -> GenericSwordChooserResolution {
        switch result {
        case .success(let keys):
            return resolve(keys: keys)
        case .failure(let error):
            return .failed(message: error.localizedDescription)
        }
    }

    /**
     Resolves loaded module keys into a deterministic chooser outcome.

     Android's cached key page removes only empty key names. Nonempty keys, including duplicate and
     whitespace-only names, remain in source order. When no keys remain, Android invokes
     `itemSelected(null)` and finishes the activity; iOS returns `.dismissWithoutSelection` for the
     equivalent callback and sheet dismissal.

     - Parameter keys: Raw keys returned by SWORD iteration.
     - Returns: Presentable exact keys or deterministic dismissal.
     - Side effects: None.
     - Failure modes: None.
     */
    static func resolve(keys: [String]) -> GenericSwordChooserResolution {
        let valid = keys.filter { !$0.isEmpty }
        return valid.isEmpty ? .dismissWithoutSelection : .present(valid)
    }
}
