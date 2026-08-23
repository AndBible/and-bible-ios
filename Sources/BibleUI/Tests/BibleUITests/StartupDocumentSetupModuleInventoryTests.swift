import Foundation
import XCTest

@testable import BibleCore
@testable import BibleUI
import SwordKit

/** Cross-backend integration coverage for the reader's fresh startup module inventory. */
final class StartupDocumentSetupModuleInventoryTests: BibleUISwordFixtureTestCase {
    /**
     Protects startup inventory from custom-only duplicate-admission cascades.

     - Setup: A native full name owns SQLite A's initials; A's full name then equals SQLite B's
       initials. The custom-only catalog admits A and suppresses B, while Android's combined
       registry rejects A first and therefore admits B.
     - Expected result: Production startup inventory retains the native owner, omits A, and includes
       B from the raw discovery sequence.
     - Failure meaning: Startup consulted the prefiltered SQLite catalog instead of the shared
       Android registry, so it can queue unlock/setup even though a valid readable Bible exists.
     - Side effects: Writes one isolated native descriptor and retains two in-memory SQLite readers;
       inherited teardown removes the temporary SWORD tree.
     */
    func testStartupInventoryReplaysRawSQLiteCandidatesAfterNativeCascadeRejection() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "NativeCascadeOwner",
            description: "AliasA",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let candidateA = makeSQLiteModule(
            initials: "AliasA",
            title: "AliasB"
        )
        let candidateB = makeSQLiteModule(
            initials: "AliasB",
            title: "Surviving SQLite"
        )
        let sqliteLibrary = SQLiteDocumentModuleLibrary(
            discoveredModules: [candidateA, candidateB]
        )

        let inventory = StartupDocumentSetupModuleInventory.modules(
            manager: manager,
            sqliteLibrary: sqliteLibrary
        )

        XCTAssertEqual(sqliteLibrary.modules.map(\.info.name), ["AliasA"])
        XCTAssertTrue(inventory.contains { $0.name == "NativeCascadeOwner" })
        XCTAssertFalse(inventory.contains { $0.name == "AliasA" })
        XCTAssertTrue(inventory.contains { $0.name == "AliasB" })
    }

    /**
     Pins Android 37 UTF-16 identity at the shared global installed-module lookup boundary.

     - Setup: Requests one Android ICU 78 BMP case partner and one supplementary Deseret case
       partner against distinct native metadata rows.
     - Expected result: The modern BMP pair resolves, while supplementary case partners do not
       compare equal because Java `String.equalsIgnoreCase` processes their surrogate chars.
     - Failure meaning: Reader inventory, Search, and navigation can disagree about the backend
       owning a Unicode module token or use a host/OpenJDK-derived fold.
     - Side effects: None.
     */
    func testInstalledLookupUsesSharedAndroid37UTF16Identity() {
        let modernBMP = ModuleInfo(
            name: "\u{A7C0}",
            description: "Modern BMP owner",
            category: .bible,
            language: "en"
        )
        let supplementary = ModuleInfo(
            name: "\u{10400}",
            description: "Supplementary owner",
            category: .bible,
            language: "en"
        )

        XCTAssertEqual(
            BibleReaderInstalledModuleLookup.module(
                named: "\u{A7C1}",
                in: [modernBMP, supplementary]
            )?.name,
            modernBMP.name
        )
        XCTAssertNil(BibleReaderInstalledModuleLookup.module(
            named: "\u{10428}",
            in: [modernBMP, supplementary]
        ))
    }

    /**
     Pins the case-insensitive lookup tier to JSword TreeSet order rather than registration order.

     - Setup: Adds two case-alias native registrations with the registration-first owner sorted
       last by configured abbreviation and requests a spelling that is exact for neither owner.
     - Expected result: The later registered but TreeSet-first `Alpha` book owns the alias.
     - Failure meaning: Controller, speech, or startup lookup scanned manager/custom add order and
       can select a different backend than Android's `Books.getBook`.
     - Side effects: Loads only the bundled Android character compatibility table.
     */
    func testInstalledBookSetCaseAliasUsesTreeSetInsteadOfRegistrationOrder() {
        let registrationFirst = BibleReaderInstalledBookSetRegistration(
            value: "registration-first",
            initials: "casealias",
            fullName: "Registration First",
            abbreviation: "Zulu",
            category: .bible
        )
        let treeSetFirst = BibleReaderInstalledBookSetRegistration(
            value: "tree-set-first",
            initials: "CaseAlias",
            fullName: "TreeSet First",
            abbreviation: "Alpha",
            category: .bible
        )
        let registrations = [registrationFirst, treeSetFirst]

        XCTAssertEqual(
            BibleReaderInstalledBookSet.treeSetOrderProjection(registrations).map(\.value),
            ["tree-set-first", "registration-first"]
        )
        XCTAssertEqual(
            BibleReaderInstalledBookSet.registration(
                named: "CASEALIAS",
                in: registrations
            )?.value,
            "tree-set-first"
        )
    }

    /**
     Preserves canonically equivalent native identities as separate Java BookSet registrations.

     - Setup: Registers composed and decomposed spellings with otherwise identical BookSet fields.
     - Expected result: Both survive the TreeSet comparator and each exact token resolves its own
       owner; neither spelling is normalized into the other.
     - Failure meaning: A Swift dictionary/set or host Unicode comparison collapsed Java-distinct
       native modules before picker, restore, or speech routing.
     - Side effects: Loads only the bundled Android character compatibility table.
     */
    func testInstalledBookSetPreservesComposedAndDecomposedNativeIdentities() {
        let composed = "Caf\u{00E9}Native"
        let decomposed = "Cafe\u{0301}Native"
        let registrations = [
            BibleReaderInstalledBookSetRegistration(
                value: "composed",
                initials: composed,
                fullName: "Composed native",
                abbreviation: "Native",
                category: .bible
            ),
            BibleReaderInstalledBookSetRegistration(
                value: "decomposed",
                initials: decomposed,
                fullName: "Decomposed native",
                abbreviation: "Native",
                category: .bible
            ),
        ]

        XCTAssertEqual(
            BibleReaderInstalledBookSet.registrationOrderProjection(registrations).count,
            2
        )
        XCTAssertEqual(
            BibleReaderInstalledBookSet.registration(named: composed, in: registrations)?.value,
            "composed"
        )
        XCTAssertEqual(
            BibleReaderInstalledBookSet.registration(named: decomposed, in: registrations)?.value,
            "decomposed"
        )
    }

    /**
     Verifies a manually installed SQLite Bible satisfies blocking reader startup.

     - Setup: Creates an empty SWORD root and installs one validated MyBible database directly under
       its Android `mybible` directory without a package sidecar or SWORD configuration.
     - Expected result: The shared startup inventory discovers the manual Bible and policy evaluation
       returns no blocking setup reason.
     - Failure meaning: Users with a readable manually imported Bible can be trapped behind Easy
       Start/Downloads because startup consulted only libsword's configuration inventory.
     - Side effects: Copies one checked-in SQLite fixture into a temporary module root and removes it.
     */
    func testManualSQLiteBiblePreventsNoBibleStartupPrompt() throws {
        let repositoryRoot = try BibleUITestSourceLocator.repositoryRoot(
            containing: "Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders/mybible-bible.SQLite3"
        )
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders/mybible-bible.SQLite3"
        )
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-manual-sqlite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let modsDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let myBibleDirectory = moduleRoot.appendingPathComponent("mybible", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: myBibleDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceURL,
            to: myBibleDirectory.appendingPathComponent("manual.SQLite3")
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))

        let inventory = StartupDocumentSetupModuleInventory.modules(manager: manager)

        XCTAssertTrue(
            inventory.contains {
                $0.category == .bible
                    && $0.name == "MyBible-manual"
                    && $0.description == "MyBible Bible Fixture"
            }
        )
        XCTAssertNil(StartupDocumentSetupPromptPolicy.promptReason(in: inventory))
    }

    /**
     Creates one raw custom-driver candidate before combined installed-book admission.

     - Parameters:
       - initials: Proposed Android book initials.
       - title: Proposed full-name identity used by later collision tiers.
     - Returns: Readable manual MyBible module retaining an in-memory source reader.
     - Side effects: Retains one deterministic reader; no database or filesystem is opened.
     - Failure modes: None; fixed fixture metadata and one verse are accepted verbatim.
     */
    private func makeSQLiteModule(initials: String, title: String) -> SQLiteDocumentModule {
        let metadata = SQLiteDocumentMetadata(
            sourceURL: URL(fileURLWithPath: "/tmp/startup-\(initials).SQLite3"),
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
            reader: StartupInventorySQLiteReader(metadata: metadata),
            origin: .manual
        )
    }
}

/** In-memory readable Bible used only to exercise startup's combined registration boundary. */
private final class StartupInventorySQLiteReader: SQLiteDocumentReading {
    /// Immutable custom-driver identity proposed to the installed-book registry.
    let metadata: SQLiteDocumentMetadata

    /// Fixed Bible category matching the supplied metadata.
    var category: DocumentCategory { .bible }

    /** Creates one deterministic reader without opening an external database. */
    init(metadata: SQLiteDocumentMetadata) {
        self.metadata = metadata
    }

    /** Returns the one addressable fixture verse. */
    func keys() throws -> [SQLiteDocumentKey] {
        [.verse(book: 10, chapter: 1, verse: 1)]
    }

    /** Returns readable content only for the fixture's exact verse coordinate. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        guard key == .verse(book: 10, chapter: 1, verse: 1) else { return nil }
        return SQLiteDocumentContent(key: key, text: "Readable startup Bible")
    }
}
