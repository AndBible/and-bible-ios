// RepoStore.swift — Repository metadata persistence

import Foundation
import SwiftData

/// Metadata about a module repository source.
@Model
public final class Repository {
    /// Unique repository identifier.
    @Attribute(.unique) public var id: UUID
    /// User-visible repository name.
    public var name: String
    /// Base URL used to fetch catalog metadata.
    public var url: String
    /// Timestamp of the last successful refresh, if any.
    public var lastRefreshed: Date?
    /// Whether the source should be considered when browsing/installing modules.
    public var isEnabled: Bool

    /// Creates a repository metadata row.
    /// - Parameters:
    ///   - id: Unique repository identifier.
    ///   - name: User-visible repository name.
    ///   - url: Repository base URL.
    ///   - isEnabled: Whether the source is active.
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

/// Manages repository metadata persistence.
@Observable
public final class RepoStore {
    private let modelContext: ModelContext

    /// Creates a repository store bound to the caller's SwiftData context.
    /// - Parameter modelContext: Context used for repository persistence.
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Fetches all repositories ordered by name.
    /// - Returns: Persisted repository metadata rows.
    public func repositories() -> [Repository] {
        let descriptor = FetchDescriptor<Repository>(
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetches only enabled repositories.
    /// - Returns: Repository rows whose `isEnabled` flag is `true`.
    public func enabledRepositories() -> [Repository] {
        let descriptor = FetchDescriptor<Repository>(
            predicate: #Predicate { $0.isEnabled }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Inserts or updates a repository row and immediately saves the context.
    /// - Parameter repo: Repository row to persist.
    public func upsert(_ repo: Repository) {
        modelContext.insert(repo)
        save()
    }

    /// Deletes a repository row and immediately saves the context.
    /// - Parameter repo: Repository row to delete.
    public func delete(_ repo: Repository) {
        modelContext.delete(repo)
        save()
    }

    private func save() {
        try? modelContext.save()
    }
}
