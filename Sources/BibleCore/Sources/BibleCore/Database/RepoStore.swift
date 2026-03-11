// RepoStore.swift — Repository metadata persistence

import Foundation
import SwiftData

/**
 * Persisted metadata about a remote module repository source.
 *
 * Repository rows are local configuration only. They capture which repositories the user can
 * browse/install from, their base URLs, and the last successful refresh timestamp used by the UI.
 */
@Model
public final class Repository {
    /// Stable unique identifier for the repository row.
    @Attribute(.unique) public var id: UUID
    /// User-visible repository name shown in repository and download UI.
    public var name: String
    /// Base URL used to fetch repository metadata and module catalogs.
    public var url: String
    /// Timestamp of the last successful catalog refresh, if any.
    public var lastRefreshed: Date?
    /// Whether the source should be considered when browsing and installing modules.
    public var isEnabled: Bool

    /**
     * Creates a repository metadata row.
     * - Parameters:
     *   - id: Unique repository identifier.
     *   - name: User-visible repository name.
     *   - url: Repository base URL.
     *   - isEnabled: Whether the source is active.
     * - Important: The initializer does not save by itself. Persistence occurs only after the
     *   owning `ModelContext` is saved by `RepoStore`.
     */
    public init(
        id: UUID = UUID(),
        name: String = "",
        url: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }
}

/**
 * Manages repository metadata persistence in the local SwiftData store.
 *
 * The store is intentionally small and local-only:
 * - it persists repository enable/disable state and refresh timestamps
 * - it does not perform network refreshes itself
 * - it always saves eagerly after mutation so download UI sees consistent state
 *
 * - Important: Like other SwiftData stores, this type inherits the thread/actor confinement of
 *   the supplied `ModelContext`.
 */
@Observable
public final class RepoStore {
    /// SwiftData context used for all repository reads and writes.
    private let modelContext: ModelContext

    /**
     * Creates a repository store bound to the caller's SwiftData context.
     * - Parameter modelContext: Context used for repository persistence.
     * - Important: The caller owns context lifecycle and confinement.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /**
     * Fetches all repositories ordered by name.
     * - Returns: Persisted repository metadata rows.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     */
    public func repositories() -> [Repository] {
        let descriptor = FetchDescriptor<Repository>(
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /**
     * Fetches only enabled repositories.
     * - Returns: Repository rows whose `isEnabled` flag is `true`.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     */
    public func enabledRepositories() -> [Repository] {
        let descriptor = FetchDescriptor<Repository>(
            predicate: #Predicate { $0.isEnabled }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /**
     * Inserts or updates a repository row and immediately saves the context.
     * - Parameter repo: Repository row to persist.
     * - Side Effects: Inserts the model into SwiftData and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     * - Note: `modelContext.insert(_:)` acts as an upsert for already-tracked instances in this usage pattern.
     */
    public func upsert(_ repo: Repository) {
        modelContext.insert(repo)
        save()
    }

    /**
     * Deletes a repository row and immediately saves the context.
     * - Parameter repo: Repository row to delete.
     * - Side Effects: Removes the row from SwiftData and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ repo: Repository) {
        modelContext.delete(repo)
        save()
    }

    /**
     * Saves any pending repository mutations.
     * - Side Effects: Flushes `modelContext` to disk.
     * - Failure: Save errors are swallowed.
     */
    private func save() {
        try? modelContext.save()
    }
}
