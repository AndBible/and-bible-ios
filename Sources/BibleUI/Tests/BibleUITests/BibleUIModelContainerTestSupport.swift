import SwiftData
@testable import BibleCore

/**
 Builds the in-memory SwiftData graph used by BibleUI reader tests that exercise workspace state.

 The helper mirrors the app-host test fixture but lives in the package test target so reader
 navigation, synchronized scroll, and configuration tests can run without launching the app bundle.

 - Returns: A transient `ModelContainer` containing settings, workspace, window, page manager, and
   history models.
 - Side effects: Allocates in-process SwiftData storage for the current test only.
 - Failure modes: Throws if SwiftData cannot create the in-memory container.
 */
func makeWorkspaceModelContainer() throws -> ModelContainer {
    let schema = Schema([
        Setting.self,
        Workspace.self,
        Window.self,
        PageManager.self,
        HistoryItem.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

/**
 Builds the in-memory SwiftData graph used by BibleUI reader tests that exercise My Documents.

 The helper keeps MyDocument bridge tests app-host-free while preserving the same model set the
 production store expects for page content and AI regeneration metadata.

 - Returns: A transient `ModelContainer` containing MyDocument, page, content, and AI cache models.
 - Side effects: Allocates in-process SwiftData storage for the current test only.
 - Failure modes: Throws if SwiftData cannot create the in-memory container.
 */
func makeMyDocumentModelContainer() throws -> ModelContainer {
    let schema = Schema([
        MyDocument.self,
        MyDocumentPage.self,
        MyDocumentPageContent.self,
        AiPageCacheEntry.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}
