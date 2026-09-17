// MyDocumentRegistrationPublication.swift -- Payload-free installed registry wakeups

import Foundation
import SwiftData
import SwordKit

/**
 Captures Java-effective My Documents registration fields around one atomic commit.

 Page content, descriptions, update timestamps, and other reader data are deliberately absent.
 Creation time remains because the live registry uses it as an order tie-breaker. The observer wakes
 only when registration ownership can change: insertion, deletion, registration order fields,
 initials, or Java-trimmed full name.
 */
enum MyDocumentRegistrationPublication {
    /** Identity fields that can affect JSword registration or lookup precedence. */
    struct Snapshot: Equatable {
        fileprivate let ownerCounts: [Owner: Int]
    }

    /** Java-exact effective owner identity. */
    fileprivate struct Owner: Hashable {
        let id: UUID
        let orderNumber: Int
        let createdAt: Date
        let sortName: SwordJavaExactStringIdentity
        let initials: SwordJavaExactStringIdentity
        let fullName: SwordJavaExactStringIdentity
    }

    /**
     Reads one deterministic registration snapshot from the supplied transaction context.

     - Throws: Propagates SwiftData fetch failures before the owning transaction can publish.
     - Side effects: Fetches My Documents metadata without reading page content.
     */
    static func capture(in modelContext: ModelContext) throws -> Snapshot {
        // Full-category restore already fetches every existing document to replace the graph. This
        // one metadata-only pre-commit scan is the only additional full-library work on that rare
        // boundary. Patch replay reuses its materialized before/after snapshots and does no scan.
        let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
        return Snapshot(
            ownerCounts: ownerCounts(documents.map {
                Owner(
                    id: $0.id,
                    orderNumber: $0.orderNumber,
                    createdAt: $0.createdAt,
                    sortName: SwordJavaExactStringIdentity($0.name),
                    initials: SwordJavaExactStringIdentity($0.initials),
                    fullName: SwordJavaExactStringIdentity(
                        SwordJavaStringIdentity.trim($0.name)
                    )
                )
            })
        )
    }

    /** Builds the same projection from an already materialized remote-sync snapshot. */
    static func capture(from snapshot: RemoteSyncAndroidMyDocumentSnapshot) -> Snapshot {
        capture(documents: snapshot.documents)
    }

    /** Builds the registration projection directly from remote document rows without sorting. */
    static func capture<Documents: Sequence>(documents: Documents) -> Snapshot
    where Documents.Element == RemoteSyncAndroidMyDocument {
        Snapshot(
            ownerCounts: ownerCounts(documents.map {
                Owner(
                    id: $0.id,
                    orderNumber: $0.orderNumber,
                    createdAt: $0.createdAt,
                    sortName: SwordJavaExactStringIdentity($0.name),
                    initials: SwordJavaExactStringIdentity($0.initials),
                    fullName: SwordJavaExactStringIdentity(
                        SwordJavaStringIdentity.trim($0.name)
                    )
                )
            })
        )
    }

    /** Builds the same projection from an in-memory management baseline without fetching. */
    static func capture(from drafts: [MyDocumentDraft]) -> Snapshot {
        Snapshot(
            ownerCounts: ownerCounts(drafts.map {
                Owner(
                    id: $0.id,
                    orderNumber: $0.orderNumber,
                    createdAt: $0.createdAt,
                    sortName: SwordJavaExactStringIdentity($0.name),
                    initials: SwordJavaExactStringIdentity($0.initials),
                    fullName: SwordJavaExactStringIdentity(
                        SwordJavaStringIdentity.trim($0.name)
                    )
                )
            })
        )
    }

    /** Builds a multiset without assuming persisted UUID uniqueness or registration ordering. */
    private static func ownerCounts(_ owners: [Owner]) -> [Owner: Int] {
        owners.reduce(into: [:]) { counts, owner in
            counts[owner, default: 0] += 1
        }
    }

    /** Posts ADR-0011's payload-free notification after a changed snapshot commits. */
    static func notifyIfChanged(from before: Snapshot, to after: Snapshot) {
        guard before != after else { return }
        SwordModuleStore.notifyModulesDidChange()
    }
}
