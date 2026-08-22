// StartupDocumentSetupModuleInventory.swift -- Fresh cross-backend startup Bible inventory

import BibleCore
import Foundation
import SwordKit

/**
 Resolves the installed-module snapshot used by the blocking reader startup decision.

 Native SWORD access state must be read fresh so a verified session unlock takes effect immediately.
 Android-compatible SQLite Bibles are discovered independently because ordinary manually installed
 databases have no SWORD configuration row and therefore never appear in `installedModules()`.
 The merge retains SWORD's global initials ownership so a SQLite book cannot surface behind a
 locked or otherwise installed native module that the reader runtime would still shadow.
 */
enum StartupDocumentSetupModuleInventory {
    /**
     Builds one fresh, validated startup inventory from the configured module root.

     - Parameter manager: Manager owning native inventory and the shared SQLite module root.
     - Returns: Fresh native metadata followed by readable, unshadowed SQLite Bible metadata in
       Android discovery order.
     - Side effects: Reads current SWORD inventory, enumerates SQLite family directories, and opens
       candidate SQLite databases read-only for format validation.
     - Failure modes: Malformed SQLite files are omitted by library discovery; native rows remain
       inclusive so locked-only startup can still expose the shared unlock workflow.
     */
    static func modules(manager: SwordManager) -> [ModuleInfo] {
        let nativeModules = manager.installedModules()
        let sqliteLibrary = SQLiteDocumentModuleLibrary(
            moduleRootURL: URL(fileURLWithPath: manager.modulePath, isDirectory: true)
        )
        return merge(
            nativeModules: nativeModules,
            sqliteBibleModules: sqliteLibrary.modules(category: .bible).map(\.info)
        )
    }

    /**
     Merges validated SQLite Bibles without violating the reader's global ownership resolver.

     - Parameters:
       - nativeModules: Inclusive installed manager rows in registration order, including locked
         modules and manager-projected Android SQLite packages.
       - sqliteBibleModules: Independently discovered, validated SQLite Bible metadata.
     - Returns: Native rows followed by SQLite rows for which neither a native initials nor native
       full-name lookup owns the SQLite initials token.
     - Side effects: None.
     - Failure modes: A locked native owner still shadows a readable SQLite collision because
       activation resolves the native owner first and requires its credential. Duplicate SQLite
       identities are expected to have been removed by library discovery.
     */
    static func merge(
        nativeModules: [ModuleInfo],
        sqliteBibleModules: [ModuleInfo]
    ) -> [ModuleInfo] {
        nativeModules + sqliteBibleModules.filter { module in
            BibleReaderInstalledModuleLookup.module(
                named: module.name,
                in: nativeModules
            ) == nil
        }
    }
}
