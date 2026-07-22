// ModuleSearchIndexUninstaller.swift -- Search index cleanup around module removal

/**
 Coordinates Android's search-index-first module uninstall sequence.

 Android attempts `IndexManager.deleteIndex` before deleting the installed document so reinstalling
 the same initials cannot inherit generated rows from the previous module. Index deletion is
 best-effort in `SearchIndexService`, while the module-removal closure remains authoritative for
 user-visible success or failure.
 */
enum ModuleSearchIndexUninstaller {
    /**
     Deletes one module's generated Search index before invoking its repository uninstall.

     - Parameters:
       - moduleName: SWORD initials shared by the generated index and installed module.
       - deleteSearchIndex: Async best-effort index deletion, normally
         `SearchIndexService.deleteIndex(for:)`.
       - removeModule: Async repository operation that removes the installed module files.
     - Side effects: Executes both caller-provided mutations sequentially, with index deletion
       completing before module removal starts.
     - Throws: Propagates only `removeModule` failures. Search-index deletion owns its own diagnostic
       reporting and does not prevent the repository uninstall, matching Android.
     - Important: The function never runs the two mutations concurrently; same-initials replacement
       may begin only after the caller observes successful completion.
     */
    static func uninstall(
        moduleName: String,
        deleteSearchIndex: (String) async -> Void,
        removeModule: (String) async throws -> Void
    ) async throws {
        await deleteSearchIndex(moduleName)
        try await removeModule(moduleName)
    }
}
