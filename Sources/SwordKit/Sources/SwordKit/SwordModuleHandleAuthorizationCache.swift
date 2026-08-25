// SwordModuleHandleAuthorizationCache.swift — Exact native handle and session-unlock ownership

import Foundation

/**
 Owns manager-lifetime native module wrappers and verified current-session unlock identities.

 Cache keys use exact Java UTF-16 identity. A native handle is admitted only when the resulting
 `SwordModule` reports code-unit-identical initials, preventing a libsword alias from being cached
 under the wrong Android book. Refresh clears both wrappers and session overrides.

 - Side effects: Creates `SwordModule` wrappers and mutates in-memory cache/unlock state.
 - Failure modes: Cross-resolved handles return nil and never enter the cache.
 */
final class SwordModuleHandleAuthorizationCache {
    /// Validated wrappers keyed by exact Android initials.
    private var modules: [SwordJavaExactStringIdentity: SwordModule] = [:]

    /// Current-session verified unlock overrides keyed by exact canonical initials.
    private var unlockedNames: Set<SwordJavaExactStringIdentity> = []

    /**
     Creates or returns one exact native wrapper.

     - Parameters:
       - name: Exact config initials used to request the native handle.
       - handle: Native handle owned by the calling manager.
       - modulePath: Calling manager's installed SWORD root.
       - config: Already-parsed exact config owner from the registry scan.
     - Returns: Stable wrapper only when its reported initials exactly match `name`.
     - Side effects: Inserts one validated wrapper on first access.
     - Failure modes: A cross-resolved handle returns nil without cache mutation.
     */
    func module(
        name: String,
        handle: UnsafeMutableRawPointer,
        modulePath: String,
        config: SwordModuleConfig
    ) -> SwordModule? {
        let identity = SwordJavaExactStringIdentity(name)
        if let cached = modules[identity] { return cached }
        let module = SwordModule(
            handle: handle,
            modulePath: modulePath,
            parsedConfig: config
        )
        guard SwordJavaExactStringIdentity(module.info.name) == identity else { return nil }
        modules[identity] = module
        return module
    }

    /**
     Records one exact canonical name whose cipher content was verified this session.

     - Parameter name: Ownership-proven native initials.
     - Side effects: Inserts one raw UTF-16 identity into current-session unlock state.
     - Failure modes: None; reinserting the same exact identity is idempotent.
     */
    func markSessionUnlocked(_ name: String) {
        unlockedNames.insert(SwordJavaExactStringIdentity(name))
    }

    /**
     Returns whether one exact canonical name has a verified current-session unlock.

     - Parameter name: Native initials tested with raw Java UTF-16 identity.
     - Returns: True only when the exact identity was verified by this manager session.
     - Side effects: None.
     - Failure modes: None; missing identities return false.
     */
    func isSessionUnlocked(_ name: String) -> Bool {
        unlockedNames.contains(SwordJavaExactStringIdentity(name))
    }

    /**
     Clears every handle and session override after refresh or manager teardown.

     - Side effects: Releases all cached wrappers and exact unlock identities.
     - Failure modes: None; clearing an empty cache is idempotent.
     */
    func clear() {
        modules.removeAll()
        unlockedNames.removeAll()
    }
}
