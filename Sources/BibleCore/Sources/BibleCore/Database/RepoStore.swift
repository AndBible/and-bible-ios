// RepoStore.swift — Repository metadata persistence

import Foundation
import SwiftData

/// Metadata about a module repository source.
@Model
public final class Repository {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var url: String
    public var lastRefreshed: Date?
    public var isEnabled: Bool

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

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Fetch all repositories.
    public func repositories() -> [Repository] {
        let descriptor = FetchDescriptor<Repository>(
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetch enabled repositories.
    public func enabledRepositories() -> [Repository] {
        let descriptor = FetchDescriptor<Repository>(
            predicate: #Predicate { $0.isEnabled }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Insert or update a repository.
    public func upsert(_ repo: Repository) {
        modelContext.insert(repo)
        save()
    }

    /// Delete a repository.
    public func delete(_ repo: Repository) {
        modelContext.delete(repo)
        save()
    }

    private func save() {
        try? modelContext.save()
    }
}
