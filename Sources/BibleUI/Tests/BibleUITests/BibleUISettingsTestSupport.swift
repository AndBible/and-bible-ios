import SwiftData
@testable import BibleCore

/**
 Creates an in-memory settings store for BibleUI package tests.

 Reader-controller package tests need native progress and memorization stores without carrying the
 app-host `AndBibleTests` superclass. This helper keeps those tests in the app-host-free BibleUI
 lane while preserving the same SwiftData-backed `SettingsStore` contract production code uses.

 - Returns: A `SettingsStore` backed by an in-memory SwiftData container containing only `Setting`.
 - Side effects: Allocates a transient model container for the calling test process.
 - Failure modes: Throws when SwiftData cannot create the in-memory model container.
 */
func makeInMemorySettingsStore() throws -> SettingsStore {
    SettingsStore(modelContext: ModelContext(try makeInMemorySettingsContainer()))
}

/**
 Creates an in-memory SwiftData container for settings-backed BibleUI tests.

 - Returns: A transient `ModelContainer` with the `Setting` schema.
 - Side effects: Allocates in-process SwiftData storage for the duration of the test.
 - Failure modes: Throws when SwiftData cannot initialize the model container.
 */
func makeInMemorySettingsContainer() throws -> ModelContainer {
    let schema = Schema([Setting.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}
