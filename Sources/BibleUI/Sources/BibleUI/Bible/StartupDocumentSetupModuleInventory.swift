// StartupDocumentSetupModuleInventory.swift -- Fresh cross-backend startup Bible inventory

import BibleCore
import Foundation
import SwordKit

/**
 Resolves the installed-module snapshot used by the blocking reader startup decision.

 Native SWORD access state must be read fresh so a verified session unlock takes effect immediately.
 Android-compatible SQLite Bibles are discovered independently because ordinary manually installed
 databases have no SWORD configuration row and therefore never appear in `installedModules()`. The
 shared installed-module resolver replays each raw SQLite candidate after native registration so
 startup observes the same full-name/initials ownership and rejection cascades as every reader
 content path.
 */
enum StartupDocumentSetupModuleInventory {
    /**
     Builds one fresh, validated startup inventory from the configured module root.

     - Parameter manager: Manager owning native inventory and the shared SQLite module root.
     - Returns: Fresh admitted native and SQLite metadata in Android's installed-book TreeSet order;
       startup policy selects the Bible rows from that inclusive registry.
     - Side effects: Reads current SWORD inventory, enumerates SQLite family directories, and opens
       candidate SQLite databases read-only for format validation.
     - Failure modes: Malformed SQLite files are omitted by library discovery; native rows remain
       inclusive so locked-only startup can still expose the shared unlock workflow.
     */
    static func modules(manager: SwordManager) -> [ModuleInfo] {
        let sqliteLibrary = SQLiteDocumentModuleLibrary(
            moduleRootURL: URL(fileURLWithPath: manager.modulePath, isDirectory: true)
        )
        return modules(manager: manager, sqliteLibrary: sqliteLibrary)
    }

    /**
     Replays Android's one combined installed-book registry for startup policy evaluation.

     - Parameters:
       - manager: Manager supplying inclusive native ownership and fresh encrypted-module access.
       - sqliteLibrary: Validated raw SQLite discovery sequence before custom-only registration.
     - Returns: Admitted native and SQLite metadata in JSword's installed-book TreeSet order.
     - Side effects: Enumerates the manager's native registry and authorizes readable native handles;
       no Bible content is read.
     - Failure modes: Locked native owners remain in the inventory without exposing content. A
       custom candidate rejected by native identity cannot suppress a later candidate because the
       shared resolver replays each raw candidate against the complete registry in Android order.
     - Note: This overload is internal so parity tests can supply a deterministic discovery sequence
       without changing production filesystem traversal.
     */
    static func modules(
        manager: SwordManager,
        sqliteLibrary: SQLiteDocumentModuleLibrary
    ) -> [ModuleInfo] {
        BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteLibrary: sqliteLibrary
        ).registeredBookMetadata()
    }
}
