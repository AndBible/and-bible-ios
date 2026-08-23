// BibleReaderInstalledDocumentRegistrySnapshot.swift -- strict Android book admission snapshot

import BibleCore
import Foundation
import SwiftData
import SwordKit

/** A complete installed-book registry could not be captured safely enough for publication. */
struct BibleReaderInstalledDocumentRegistrySnapshotError: LocalizedError, Sendable {
    /// Stable source failure detail retained without exposing a partially captured registry.
    let detail: String

    /// User-facing generic registry failure used by My Documents publication surfaces.
    var errorDescription: String? {
        "The installed document registry could not be read: \(detail)"
    }
}

/**
 Fresh read-only projection of Android's native, SQLite, EPUB, then My Documents book registry.

 Identity-changing writers capture this value only while holding the canonical module-store lease.
 Unlike reader inventory, every local source is strict: malformed SQLite discovery, corrupt EPUB
 publication, and SwiftData fetch failures abort admission rather than omitting a potential owner.
 */
struct BibleReaderInstalledDocumentRegistrySnapshot {
    /** Typed local owner needed to distinguish an exact EPUB update from another registration. */
    private enum LocalOwner {
        /// Published EPUB whose stable source identifier may authorize its own replacement.
        case epub(String)

        /// Persisted My Documents row, which never authorizes an incoming EPUB replacement.
        case myDocument(UUID)
    }

    /// Native-plus-SQLite resolver already replayed in Android registration order.
    private let installedResolver: BibleReaderInstalledModuleResolver

    /// Strict EPUB-then-My Documents registrations in Android add order.
    private let localRegistrations: [BibleReaderLocalDocumentRegistration<LocalOwner>]

    /**
     Captures every current owner from fresh read-only storage.

     - Parameters:
       - modelContainer: SwiftData container holding persisted My Documents registrations.
       - modulePath: Canonical SWORD root containing native and Android SQLite families.
     - Returns: Immutable resolver state ordered native, SQLite, EPUB, then My Documents.
     - Side effects: Opens a fresh SWORD manager, discovers SQLite databases read-only, reads strict
       EPUB pointer/index metadata, and fetches My Documents metadata in registration order.
     - Throws: `BibleReaderInstalledDocumentRegistrySnapshotError` when any registry source cannot
       be captured completely. Missing SQLite/EPUB family roots remain valid empty sources.
     */
    static func capture(
        modelContainer: ModelContainer,
        modulePath: String
    ) throws -> BibleReaderInstalledDocumentRegistrySnapshot {
        do {
            guard let swordManager = SwordManager(modulePath: modulePath) else {
                throw BibleReaderInstalledDocumentRegistrySnapshotError(
                    detail: "the native module registry is unavailable"
                )
            }
            let moduleRootURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            let sqliteSnapshot = try SQLiteDocumentModuleLibrary
                .throwingRegistrationSnapshot(moduleRootURL: moduleRootURL)
            let resolver = BibleReaderInstalledModuleResolver(
                swordManager: swordManager,
                sqliteLibrary: sqliteSnapshot
            )
            let epubRegistrations = try EpubReader.registrationSnapshot().map { info in
                BibleReaderLocalDocumentRegistration(
                    document: LocalOwner.epub(info.identifier),
                    initials: info.initials,
                    fullName: info.title,
                    abbreviation: info.title,
                    category: .generalBook
                )
            }
            let documents = try MyDocumentStore(
                modelContext: ModelContext(modelContainer)
            ).documentsInRegistrationOrder()
            let myDocumentRegistrations = documents.map { document in
                BibleReaderLocalDocumentRegistration(
                    document: LocalOwner.myDocument(document.id),
                    initials: document.initials,
                    fullName: document.name,
                    abbreviation: document.initials,
                    category: .generalBook
                )
            }
            return BibleReaderInstalledDocumentRegistrySnapshot(
                installedResolver: resolver,
                localRegistrations: epubRegistrations + myDocumentRegistrations
            )
        } catch let error as BibleReaderInstalledDocumentRegistrySnapshotError {
            throw error
        } catch {
            throw BibleReaderInstalledDocumentRegistrySnapshotError(
                detail: error.localizedDescription
            )
        }
    }

    /**
     Reports whether Android resolves a proposed My Documents initials token to any current owner.

     - Parameter initials: Candidate generated or explicitly imported by My Documents.
     - Returns: `true` for exact initials, exact full-name, or Java case-insensitive ownership.
     - Side effects: Replays immutable resolver metadata only.
     - Failure modes: None after successful strict capture.
     */
    func ownsDocument(named initials: String) -> Bool {
        switch installedResolver.resolveDocumentOwner(
            named: initials,
            localRegistrations: { localRegistrations }
        ) {
        case .missing: return false
        case .installed, .local: return true
        }
    }

    /**
     Reports whether a proposed EPUB is absent or is replacing its own exact stable registration.

     - Parameter candidate: Exact source identifier plus generated Android initials.
     - Returns: `true` only for a missing owner or the same published EPUB identifier.
     - Side effects: Replays immutable resolver metadata only.
     - Failure modes: None after successful strict capture; every non-EPUB and different-EPUB owner
       rejects the candidate.
     */
    func admitsEpub(_ candidate: EpubReader.InstallCandidate) -> Bool {
        switch installedResolver.resolveDocumentOwner(
            named: candidate.initials,
            localRegistrations: { localRegistrations }
        ) {
        case .missing:
            return true
        case .local(.epub(let identifier)):
            return identifier == candidate.identifier
        case .installed, .local(.myDocument):
            return false
        }
    }
}
