// BibleReaderSQLiteDictionaryChooser.swift -- Exact-key SQLite dictionary selection

import SwordKit

/**
 Immutable result of validating a SQLite dictionary switch against its exact chooser keys.

 The plan retains a prior key only when the source key list contains that exact spelling. The
 controller applies the plan atomically after preflight succeeds, avoiding partially persisted
 module/key state when key enumeration fails.
 */
struct BibleReaderSQLiteDictionarySwitchPlan {
    /// Immutable dictionary module that passed category and key-enumeration preflight.
    let module: BibleReaderSQLiteModuleHandle

    /// Byte-exact retained key, or nil when the chooser must request a new key.
    let retainedKey: String?

    /// Shared generic-switch outcome consumed by existing picker presentation.
    let outcome: BibleReaderGenericModuleSwitchOutcome
}

/**
 Owns exact chooser-key behavior for Android-compatible SQLite dictionaries.

 MyBible and MySword dictionary keys are source identities, not case-normalized labels. This helper
 exposes source-order keys and constructs switch plans before the controller mutates pane state.
 */
struct BibleReaderSQLiteDictionaryChooser {
    /**
     Resolves one persisted chooser key by byte-exact source spelling.

     Swift string equality intentionally treats canonically equivalent Unicode spellings as equal,
     while SQLite dictionary identities can distinguish their UTF-8 sequences. Comparing views
     prevents a composed persisted key from retaining a decomposed source key, or vice versa.

     - Parameters:
       - requestedKey: Persisted or currently selected key, if any.
       - keys: Exact source-order chooser keys.
     - Returns: The matching source key, or nil when no UTF-8-identical key exists.
     - Side effects: None.
     - Failure modes: Nil and canonically equivalent but byte-distinct keys fail closed.
     */
    static func exactSourceKey(
        matching requestedKey: String?,
        in keys: [String]
    ) -> String? {
        guard let requestedKey else { return nil }
        return keys.first { sourceKey in
            sourceKey.utf8.elementsEqual(requestedKey.utf8)
        }
    }

    /**
     Enumerates exact chooser keys from whichever dictionary backend is active.

     - Parameters:
       - sqliteModule: Active immutable SQLite dictionary, if selected.
       - swordModule: Active SWORD dictionary used only when SQLite is absent.
     - Returns: Source-order SQLite keys or SWORD's immutable key snapshot.
     - Side effects: SQLite opens an operation-owned read connection; SWORD may populate its
       bounded immutable key snapshot.
     - Throws: Propagates SQLite or SWORD key-enumeration failures.
     - Important: SQLite failures are not cached, so a later uncancelled call retries the source.
     */
    func keys(
        sqliteModule: BibleReaderSQLiteModuleHandle?,
        swordModule: SwordModule?
    ) throws -> [String] {
        if let sqliteModule {
            return try sqliteModule.dictionaryKeys()
        }
        return try swordModule?.loadAllKeys() ?? []
    }

    /**
     Preflights one SQLite dictionary switch while preserving exact-key semantics.

     - Parameters:
       - module: Requested immutable SQLite dictionary.
       - currentKey: Previously selected key, if any.
     - Returns: An atomic switch plan with an exact retained key and shared picker outcome.
     - Side effects: Enumerates the source-order key list on an operation-owned SQLite connection.
     - Throws: Propagates key-enumeration errors before any controller/PageManager mutation occurs.
     - Note: Matching compares UTF-8 source bytes and therefore rejects canonically equivalent but
       byte-distinct spellings as well as case variants.
     */
    func switchPlan(
        module: BibleReaderSQLiteModuleHandle,
        currentKey: String?
    ) throws -> BibleReaderSQLiteDictionarySwitchPlan {
        let keys = try module.dictionaryKeys()
        let retainedKey = Self.exactSourceKey(matching: currentKey, in: keys)
        return BibleReaderSQLiteDictionarySwitchPlan(
            module: module,
            retainedKey: retainedKey,
            outcome: retainedKey == nil
                ? .switchedRequiringKeySelection
                : .switchedPreservingKey
        )
    }
}
