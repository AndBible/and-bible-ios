// PageManagerBibleBookEncodingMigrationService.swift -- One-way PageManager Bible identity reset

import SwiftData

/** Summary of one idempotent PageManager Bible identity normalization pass. */
public struct PageManagerBibleBookEncodingMigrationReport: Sendable, Equatable {
    /// Rows whose ambiguous or incomplete position reset to Android's Genesis 1:1 default.
    public let normalizedPageManagerCount: Int

    /// Whether this pass saved any durable change.
    public var didChangePersistence: Bool { normalizedPageManagerCount > 0 }

    /** Creates a report for one completed migration pass. */
    public init(normalizedPageManagerCount: Int) {
        self.normalizedPageManagerCount = normalizedPageManagerCount
    }
}

/**
 Resets every unmarked, unknown-encoding, or incomplete PageManager Bible tuple before readers or
 sync observe it.

 This migration deliberately does not inspect installed modules or reinterpret old integers. The
 selected Bible document and the complete workspace graph remain intact while an ambiguous or
 incomplete Bible location becomes Android's canonical Genesis 1:1 default.
 */
public final class PageManagerBibleBookEncodingMigrationService {
    private let modelContext: ModelContext

    /** Creates a migration bound to one initialized SwiftData context. */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /**
     Runs one idempotent normalization pass and saves at most once.

     - Returns: The number of PageManager rows reset during this pass.
     - Side Effects: Fetches every PageManager, resets ambiguous or incomplete Bible tuples, and
       saves the supplied context once when at least one row changed.
     - Failure Modes: Rethrows SwiftData fetch and save failures.
     */
    public func migrate() throws -> PageManagerBibleBookEncodingMigrationReport {
        let pageManagers = try modelContext.fetch(FetchDescriptor<PageManager>())
        let changedCount = pageManagers.reduce(into: 0) { count, pageManager in
            if pageManager.normalizeBibleBookEncodingToJSwordOrdinal() {
                count += 1
            }
        }
        if changedCount > 0 {
            try modelContext.save()
        }
        return PageManagerBibleBookEncodingMigrationReport(
            normalizedPageManagerCount: changedCount
        )
    }
}
