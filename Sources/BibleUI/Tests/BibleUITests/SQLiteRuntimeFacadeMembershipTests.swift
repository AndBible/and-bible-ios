import Foundation
import XCTest

@testable import BibleCore
@testable import BibleUI
import SwordKit

/** Behavioral coverage for exact current SQLite facade membership across runtime reloads. */
final class SQLiteRuntimeFacadeMembershipTests: BibleUISwordFixtureTestCase {
    /**
     Pins membership to the exact admitted handle and Java-exact initials of one completed reload.

     - Setup: Publishes one SQLite Bible, then reloads with a fresh same-name facade, two
       canonically equivalent but Java-distinct names, and a SQLite candidate shadowed by native
       KJV ownership.
     - Expected result: The retired same-name facade is rejected, its replacement and both exact
       UTF-16 spellings are independently current, cross-spelling checks fail, and KJV never enters
       the current SQLite inventory.
     - Failure meaning: A visible-content callback can accept a retired or shadowed facade, or the
       membership index applies Swift canonical equality instead of Android's exact string identity.
     - Side effects: Copies the inherited SWORD fixture and retains deterministic in-memory SQLite
       readers; teardown removes the temporary native module tree.
     */
    func testReloadPublishesOnlyExactCurrentAdmittedFacadeMembership() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let primaryBibles = manager.installedModules(category: .bible)
        let repeatedInitials = "FacadeMembership"
        let composedInitials = "\u{00C9}Facade"
        let decomposedInitials = "E\u{0301}Facade"
        var coordinator = BibleReaderSQLiteRuntimeCoordinator()

        _ = coordinator.reload(
            manager: manager,
            sqliteLibrary: SQLiteDocumentModuleLibrary(discoveredModules: [
                makeModule(initials: repeatedInitials, title: "First facade")
            ]),
            primaryBibles: primaryBibles,
            primaryCommentaries: [],
            primaryDictionaries: []
        )
        let retiredFacade = try XCTUnwrap(
            coordinator.unshadowedSQLiteModules().first { module in
                exact(module.info.name, equals: repeatedInitials)
            }
        )
        XCTAssertTrue(coordinator.isCurrentSQLiteModule(
            moduleIdentity: ObjectIdentifier(retiredFacade),
            initials: repeatedInitials
        ))

        _ = coordinator.reload(
            manager: manager,
            sqliteLibrary: SQLiteDocumentModuleLibrary(discoveredModules: [
                makeModule(initials: repeatedInitials, title: "Replacement facade"),
                makeModule(initials: composedInitials, title: "Composed facade"),
                makeModule(initials: decomposedInitials, title: "Decomposed facade"),
                makeModule(initials: "KJV", title: "Native-shadowed facade")
            ]),
            primaryBibles: primaryBibles,
            primaryCommentaries: [],
            primaryDictionaries: []
        )

        let currentModules = coordinator.unshadowedSQLiteModules()
        let replacementFacade = try XCTUnwrap(currentModules.first { module in
            exact(module.info.name, equals: repeatedInitials)
        })
        let composedFacade = try XCTUnwrap(currentModules.first { module in
            exact(module.info.name, equals: composedInitials)
        })
        let decomposedFacade = try XCTUnwrap(currentModules.first { module in
            exact(module.info.name, equals: decomposedInitials)
        })

        XCTAssertFalse(retiredFacade === replacementFacade)
        XCTAssertFalse(coordinator.isCurrentSQLiteModule(
            moduleIdentity: ObjectIdentifier(retiredFacade),
            initials: repeatedInitials
        ))
        XCTAssertTrue(coordinator.isCurrentSQLiteModule(
            moduleIdentity: ObjectIdentifier(replacementFacade),
            initials: repeatedInitials
        ))
        XCTAssertTrue(coordinator.isCurrentSQLiteModule(
            moduleIdentity: ObjectIdentifier(composedFacade),
            initials: composedInitials
        ))
        XCTAssertTrue(coordinator.isCurrentSQLiteModule(
            moduleIdentity: ObjectIdentifier(decomposedFacade),
            initials: decomposedInitials
        ))
        XCTAssertFalse(coordinator.isCurrentSQLiteModule(
            moduleIdentity: ObjectIdentifier(composedFacade),
            initials: decomposedInitials
        ))
        XCTAssertFalse(coordinator.isCurrentSQLiteModule(
            moduleIdentity: ObjectIdentifier(decomposedFacade),
            initials: composedInitials
        ))
        XCTAssertFalse(currentModules.contains { exact($0.info.name, equals: "KJV") })
        XCTAssertNil(coordinator.preferredModule(named: "KJV", category: .bible))
    }

    /** Returns whether two strings have exactly equal Java UTF-16 identities. */
    private func exact(_ lhs: String, equals rhs: String) -> Bool {
        SwordJavaExactStringIdentity(lhs) == SwordJavaExactStringIdentity(rhs)
    }

    /** Builds one readable in-memory custom-driver candidate without filesystem discovery. */
    private func makeModule(initials: String, title: String) -> SQLiteDocumentModule {
        let metadata = SQLiteDocumentMetadata(
            sourceURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).SQLite3"),
            format: .myBible,
            initials: initials,
            abbreviation: initials,
            title: title,
            description: title,
            language: "en",
            version: "1",
            category: .bible,
            direction: .ltr,
            hasStrongs: false,
            isStrongsDictionary: false,
            hasWordsOfChrist: false
        )
        return SQLiteDocumentModule(
            reader: FacadeMembershipSQLiteReader(metadata: metadata),
            origin: .manual
        )
    }
}

/** Minimal readable Bible retaining exact installed metadata for facade-ownership tests. */
private final class FacadeMembershipSQLiteReader: SQLiteDocumentReading {
    /// Immutable metadata proposed to Android's global installed-book registry.
    let metadata: SQLiteDocumentMetadata

    /// Fixed Bible category matching the supplied metadata.
    var category: DocumentCategory { .bible }

    /** Retains exact metadata without opening a database. */
    init(metadata: SQLiteDocumentMetadata) {
        self.metadata = metadata
    }

    /** Returns one deterministic source coordinate so the candidate remains readable. */
    func keys() throws -> [SQLiteDocumentKey] {
        [.verse(book: 10, chapter: 1, verse: 1)]
    }

    /** Returns content only for the fixture's exact source coordinate. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        guard key == .verse(book: 10, chapter: 1, verse: 1) else { return nil }
        return SQLiteDocumentContent(key: key, text: "Facade membership")
    }
}
