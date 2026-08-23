import Foundation
import XCTest
@testable import BibleCore

/** Verifies Android manual SQLite modules enter one readable installed-book catalog. */
final class SQLiteDocumentModuleLibraryTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    /** Removes every copied database and sidecar created by the current test. */
    override func tearDown() {
        for root in temporaryRoots.reversed() {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    /**
     Protects Android discovery depth, category projection, book maps, and exact content reads.

     The fixture copies one Bible/commentary/dictionary from MyBible and MySword plus two e-Sword
     files into Android's family roots. Successful discovery must expose seven unique identities,
     map MyBible book 10 to Genesis, retain static KJVA chapter bounds, and read verse and dictionary
     content through the common facade.
     */
    func testDiscoversEverySQLiteFamilyAsReadableInstalledModules() throws {
        let root = try makeRoot()
        try copyFixture("mybible-bible.SQLite3", to: root.appendingPathComponent("mybible/a/bible.SQLite3"))
        try copyFixture("mybible-commentary.SQLite3", to: root.appendingPathComponent("mybible/commentary.SQLite3"))
        try copyFixture("mybible-dictionary.SQLite3", to: root.appendingPathComponent("mybible/dictionary.SQLite3"))
        try copyFixture("sample.bbl.mybible", to: root.appendingPathComponent("mysword/nested/sample.bbl.mybible"))
        try copyFixture("sample.cmt.mybible", to: root.appendingPathComponent("mysword/sample.cmt.mybible"))
        try copyFixture("sample.dct.mybible", to: root.appendingPathComponent("mysword/sample.dct.mybible"))
        try copyFixture("sample.bblx", to: root.appendingPathComponent("esword/sample.bblx"))
        try copyFixture("sample.bbli", to: root.appendingPathComponent("esword/sample.bbli"))

        let library = SQLiteDocumentModuleLibrary(moduleRootURL: root)

        XCTAssertEqual(library.modules.count, 7)
        XCTAssertEqual(library.diagnostics.count, 1)
        XCTAssertEqual(library.modules(category: .bible).count, 3)
        XCTAssertEqual(library.modules(category: .commentary).count, 2)
        XCTAssertEqual(library.modules(category: .dictionary).count, 2)

        let bible = try XCTUnwrap(library.module(named: "MyBible-bible"))
        XCTAssertEqual(bible.sourceBookNumber(forOsisId: "Gen"), 10)
        XCTAssertEqual(bible.osisId(forSourceBookNumber: 10), "Gen")
        XCTAssertEqual(try bible.bookList().map(\.osisId), ["Gen"])
        XCTAssertEqual(try bible.bookList().map(\.chapterCount), [50])
        XCTAssertEqual(
            try bible.verseContent(osisId: "Gen", chapter: 1, verse: 1)?.text,
            "<title canonical=\"false\">Creation</title>In the <J>beginning</J>"
        )

        let dictionary = try XCTUnwrap(library.module(named: "MySword-sample_dct"))
        XCTAssertEqual(try dictionary.dictionaryKeys(), ["Elohim", "Logos"])
        XCTAssertNotNil(try dictionary.dictionaryContent(for: "Elohim"))
    }

    /**
     Protects strict identity admission from treating absent Android family roots as an error.

     - Setup: Creates only the parent module root, with no MyBible, MySword, or e-Sword directories.
     - Expected result: The strict snapshot succeeds empty and does not create any family directory.
     - Failure meaning: A read-only registry check either mutates the module store or cannot represent
       a clean installation that has never installed a SQLite document.
     - Side effects: Creates and later removes one otherwise-empty temporary parent directory.
     */
    func testStrictRegistrationSnapshotLeavesMissingFamilyRootsAbsent() throws {
        let root = try makeRoot()

        let snapshot = try SQLiteDocumentModuleLibrary.throwingRegistrationSnapshot(
            moduleRootURL: root
        )

        XCTAssertTrue(snapshot.registrationCandidates.isEmpty)
        XCTAssertTrue(snapshot.diagnostics.isEmpty)
        for family in ["mybible", "mysword", "esword"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(family, isDirectory: true).path
            ))
        }
    }

    /**
     Protects strict admission from rejecting Android's deterministic duplicate omission.

     - Setup: Installs the matching legacy and HTML e-Sword fixtures whose exposed initials collide.
     - Expected result: The strict snapshot retains both raw registration candidates, exposes one
       typed duplicate diagnostic, and registers only the first owner exactly as Android does.
     - Failure meaning: A valid installed library can block every later EPUB, MyDocument, and AI
       identity publication even though Android resolves the duplicate by add-order replay.
     - Side effects: Copies two checked-in SQLite fixtures into a temporary e-Sword family root.
     */
    func testStrictRegistrationSnapshotAllowsDeterministicDuplicateOmission() throws {
        let root = try makeRoot()
        try copyFixture("sample.bblx", to: root.appendingPathComponent("esword/sample.bblx"))
        try copyFixture("sample.bbli", to: root.appendingPathComponent("esword/sample.bbli"))

        let snapshot = try SQLiteDocumentModuleLibrary.throwingRegistrationSnapshot(
            moduleRootURL: root
        )

        XCTAssertEqual(snapshot.registrationCandidates.count, 2)
        XCTAssertEqual(snapshot.modules.count, 1)
        XCTAssertEqual(snapshot.diagnostics.count, 1)
        XCTAssertEqual(snapshot.diagnostics.first?.kind, .duplicateRegistration)
    }

    /**
     Protects fail-closed admission when permissive discovery cannot enumerate one family root.

     - Setup: Places immutable bytes at the `mybible` directory path while leaving sibling family
       roots absent; ordinary discovery would silently treat this state as an empty family.
     - Expected result: Strict discovery reports the existing non-directory root, preserves its
       bytes, and creates no sibling family roots or staging artifacts.
     - Failure meaning: A hidden SQLite owner can be omitted from global identity admission, or a
       supposedly read-only registry snapshot can mutate the module store while rejecting it.
     - Side effects: Writes one temporary sentinel file and reads its metadata and contents.
     */
    func testStrictRegistrationSnapshotRejectsNonDirectoryFamilyRootWithoutArtifacts() throws {
        let root = try makeRoot()
        let familyRoot = root.appendingPathComponent("mybible", isDirectory: true)
        let sentinel = Data("not a directory".utf8)
        try sentinel.write(to: familyRoot)

        XCTAssertThrowsError(
            try SQLiteDocumentModuleLibrary.throwingRegistrationSnapshot(moduleRootURL: root)
        ) { error in
            let snapshotError = error as? SQLiteDocumentModuleRegistrySnapshotError
            XCTAssertEqual(snapshotError?.diagnostics.count, 1)
            XCTAssertEqual(
                snapshotError?.diagnostics.first?.sourceURL.standardizedFileURL.path,
                familyRoot.standardizedFileURL.path
            )
            XCTAssertTrue(
                snapshotError?.diagnostics.first?.message.contains("not a readable") == true
            )
        }

        XCTAssertEqual(try Data(contentsOf: familyRoot), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["mybible"])
    }

    /**
     Protects strict admission from silently following a candidate link normal discovery may omit.

     - Setup: Links an accepted MySword filename to a readable database outside its family root.
     - Expected result: The strict snapshot rejects the symbolic link before opening its target and
       leaves the family tree and external database unchanged.
     - Failure meaning: Registration ownership can depend on a mutable or escaped link target, so an
       identity may change after admission without participating in the global mutation lease.
     - Side effects: Creates a temporary fixture copy and one symbolic link, then reads metadata.
     */
    func testStrictRegistrationSnapshotRejectsSymbolicLinkCandidate() throws {
        let root = try makeRoot()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let target = outside.appendingPathComponent("target.mybible")
        try copyFixture("sample.bbl.mybible", to: target)
        let familyRoot = root.appendingPathComponent("mysword", isDirectory: true)
        try FileManager.default.createDirectory(at: familyRoot, withIntermediateDirectories: true)
        let link = familyRoot.appendingPathComponent("linked.mybible")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let original = try Data(contentsOf: target)

        XCTAssertThrowsError(
            try SQLiteDocumentModuleLibrary.throwingRegistrationSnapshot(moduleRootURL: root)
        ) { error in
            let snapshotError = error as? SQLiteDocumentModuleRegistrySnapshotError
            XCTAssertEqual(snapshotError?.diagnostics.first?.sourceURL, link)
            XCTAssertTrue(snapshotError?.diagnostics.first?.message.contains("symbolic link") == true)
        }

        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    /**
     Pins Android `DocumentBibleBooks` visibility and static KJVA chooser chapter counts.

     - Setup: Creates Genesis with 1:1 plus an impossible extra chapter, Exodus with only 1:2,
       Leviticus with only 1:3, and an unmapped source book with 1:1.
     - Expected result: Only Genesis and Exodus are visible, in KJVA order, with static counts 50 and
       40. Later or unmapped rows neither admit books nor invalidate valid canonical entries.
     - Failure meaning: Source maxima or arbitrary rows are driving chooser navigation instead of
       Android's 1:1/1:2 containment probe and KJVA versification.
     - Side effects: Creates one temporary SQLite database and reads it through production discovery.
     */
    func testBookListUsesAndroidPresenceProbeAndStaticKJVACounts() throws {
        let root = try makeRoot()
        let myBibleRoot = root.appendingPathComponent("mybible", isDirectory: true)
        try FileManager.default.createDirectory(at: myBibleRoot, withIntermediateDirectories: true)
        let url = myBibleRoot.appendingPathComponent("navigation.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Navigation fixture')",
            "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
            "INSERT INTO verses VALUES (10, 1, 1, 'Genesis')",
            "INSERT INTO verses VALUES (10, 999, 1, 'Out of canon')",
            "INSERT INTO verses VALUES (20, 1, 2, 'Exodus')",
            "INSERT INTO verses VALUES (30, 1, 3, 'Too late')",
            "INSERT INTO verses VALUES (999, 1, 1, 'Unmapped')",
        ])

        let library = SQLiteDocumentModuleLibrary(moduleRootURL: root)
        let module = try XCTUnwrap(library.module(named: "MyBible-navigation"))
        let books = try module.bookList()

        XCTAssertEqual(books.map(\.osisId), ["Gen", "Exod"])
        XCTAssertEqual(books.map(\.chapterCount), [50, 40])
    }

    /**
     Protects sidecar-owned package identity and Android database-owned installed metadata.

     - Setup: Installs one production-shaped extension-bearing payload and one installer-accepted
       extensionless legacy payload. Their sidecars intentionally disagree with database metadata.
     - Expected result: Package filename binding retains sidecar initials/repository, while category,
       description, language, and version come from Android's database-generated configuration.
     - Failure meaning: A package can reappear as a manual module or repository metadata can override
       values Android derives from the installed database.
     - Side effects: Creates package directories, fixture database copies, and JSON sidecars.
     */
    func testMyBiblePackageUsesSidecarIdentityAndDatabaseMetadata() throws {
        let root = try makeRoot()
        let valid = root.appendingPathComponent("mybible/KJV-PACKAGE", isDirectory: true)
        try copyFixture("mybible-bible.SQLite3", to: valid.appendingPathComponent("finrk.SQLite3"))
        try writeSidecar(
            name: "PACKAGE-KJV",
            category: "Lexicons / Dictionaries",
            packageFileName: "finrk.SQLite3.zip",
            to: valid
        )

        let legacy = root.appendingPathComponent("mybible/LEGACY-PACKAGE", isDirectory: true)
        try copyFixture("mybible-bible.SQLite3", to: legacy.appendingPathComponent("legacy"))
        try writeSidecar(
            name: "PACKAGE-LEGACY",
            category: "Commentaries",
            packageFileName: "legacy.zip",
            to: legacy
        )

        let library = SQLiteDocumentModuleLibrary(moduleRootURL: root)

        XCTAssertEqual(
            Set(library.modules.map(\.info.name)),
            Set(["PACKAGE-KJV", "PACKAGE-LEGACY"])
        )
        XCTAssertTrue(library.modules.allSatisfy { $0.origin == .myBiblePackage })
        XCTAssertTrue(library.modules.allSatisfy { $0.info.description == "MyBible Bible Fixture" })
        XCTAssertTrue(library.modules.allSatisfy { $0.info.category == .bible })
        XCTAssertTrue(library.modules.allSatisfy { $0.info.language == "en" })
        XCTAssertTrue(library.modules.allSatisfy { $0.info.version == "0.0" })
        XCTAssertTrue(library.modules.allSatisfy {
            $0.info.aboutMetadata.repository == "Fixture Repository"
        })
        XCTAssertTrue(library.diagnostics.isEmpty)
    }

    /**
     Protects exact production payload-name binding without letting decoys hide readable data.

     - Setup: Places a malformed lexically earlier SQLite decoy beside one valid exact payload, and
       places a valid noncanonical payload in a second sidecar directory lacking its manifest name.
     - Expected result: The first sidecar binds only its exact payload; the second sidecar is
       diagnosed while its valid decoy remains discoverable as an ordinary manual module.
     - Failure meaning: Package identity can attach to attacker-selected data or a bad decoy can
       suppress the repository payload and every readable sibling beneath that directory.
     - Side effects: Creates temporary package trees, SQLite fixture copies, and JSON sidecars.
     */
    func testPackageSidecarBindsOnlyExactPayloadAndDecoysDoNotSuppressManualModules() throws {
        let root = try makeRoot()
        let exactPackage = root.appendingPathComponent("mybible/exact", isDirectory: true)
        try copyFixture(
            "mybible-bible.SQLite3",
            to: exactPackage.appendingPathComponent("finrk.SQLite3")
        )
        try Data("not sqlite".utf8).write(
            to: exactPackage.appendingPathComponent("000-decoy.SQLite3")
        )
        try writeSidecar(
            name: "EXACT-PACKAGE",
            category: "Biblical Texts",
            packageFileName: "finrk.SQLite3.zip",
            to: exactPackage
        )

        let missingExactPackage = root.appendingPathComponent(
            "mybible/missing-exact",
            isDirectory: true
        )
        try copyFixture(
            "mybible-bible.SQLite3",
            to: missingExactPackage.appendingPathComponent("readable-decoy.SQLite3")
        )
        try writeSidecar(
            name: "MISSING-EXACT",
            category: "Biblical Texts",
            packageFileName: "missing.SQLite3.zip",
            to: missingExactPackage
        )

        let library = SQLiteDocumentModuleLibrary(moduleRootURL: root)

        XCTAssertNotNil(library.module(named: "EXACT-PACKAGE"))
        XCTAssertEqual(library.module(named: "EXACT-PACKAGE")?.origin, .myBiblePackage)
        XCTAssertNotNil(library.module(named: "MyBible-readable_decoy"))
        XCTAssertEqual(library.module(named: "MyBible-readable_decoy")?.origin, .manual)
        XCTAssertNil(library.module(named: "MISSING-EXACT"))
        XCTAssertTrue(library.diagnostics.contains {
            $0.message.contains("MISSING-EXACT")
                && $0.message.contains("missing.SQLite3")
        })
    }

    /**
     Protects the pre-decode stat and bounded-read policy for package metadata.

     - Setup: Writes a sidecar one byte above the documented 64 KiB maximum beside a production-name
       payload.
     - Expected result: Discovery diagnoses the sidecar size before JSON decoding and exposes the
       payload only through ordinary manual discovery.
     - Failure meaning: An untrusted restore can force unbounded sidecar allocation or gain package
       identity through oversized JSON.
     - Side effects: Creates a temporary package, fixture database, and 64 KiB sidecar.
     */
    func testOversizedPackageSidecarIsRejectedBeforeDecode() throws {
        let root = try makeRoot()
        let package = root.appendingPathComponent("mybible/oversized", isDirectory: true)
        try copyFixture(
            "mybible-bible.SQLite3",
            to: package.appendingPathComponent("oversized.SQLite3")
        )
        try Data(
            repeating: 0x7B,
            count: SQLiteDocumentModuleLibrary.maximumPackageSidecarByteCount + 1
        ).write(to: package.appendingPathComponent("module.json"))

        let library = SQLiteDocumentModuleLibrary(moduleRootURL: root)

        XCTAssertEqual(library.modules.map(\.origin), [.manual])
        XCTAssertEqual(library.modules.first?.info.name, "MyBible-oversized")
        XCTAssertEqual(library.diagnostics.count, 1)
        XCTAssertTrue(library.diagnostics[0].message.contains("the maximum is 65536"))
    }

    /**
     Protects retryable catalog enumeration and the fixed-query-count chapter operation.

     A SQLite module can expose many duplicate rows, so chapter rendering must call the reader's
     batch operation once instead of issuing point lookups. Repeated book-list reads intentionally
     re-enumerate current keys so cancellation or transient I/O outcomes never become module state.
     */
    func testCatalogReadsRemainRetryableAndChapterUsesOneBatchQuery() throws {
        let reader = KeyCountingSQLiteBibleReader()
        let module = SQLiteDocumentModule(reader: reader, origin: .manual)

        XCTAssertEqual(try module.bookList().map(\.osisId), ["Gen"])
        XCTAssertEqual(try module.chapterContent(osisId: "Gen", chapter: 1).map(\.text), ["Text"])
        XCTAssertEqual(try module.bookList().map(\.chapterCount), [50])
        XCTAssertEqual(reader.keyReadCount, 2)
        XCTAssertEqual(reader.chapterReadCount, 1)
        XCTAssertEqual(reader.contentReadCount, 0)
    }

    /**
     Protects an uncancelled catalog retry from a prior transient enumeration failure.

     The first fake read fails and the second succeeds. Retaining the first error would permanently
     poison a readable module until the entire installed-module catalog was rebuilt.
     */
    func testCatalogRetryDoesNotCacheTransientKeyFailure() throws {
        let reader = KeyCountingSQLiteBibleReader(failingKeyReadCount: 1)
        let module = SQLiteDocumentModule(reader: reader, origin: .manual)

        XCTAssertThrowsError(try module.bookList()) { error in
            XCTAssertEqual(error as? KeyCountingSQLiteReaderError, .fixtureFailure)
        }
        XCTAssertEqual(try module.bookList().map(\.osisId), ["Gen"])
        XCTAssertEqual(reader.keyReadCount, 2)
    }

    /**
     Protects removal of facade-level blocking locks around operation-isolated readers.

     - Setup: Runs delayed fake Bible and dictionary readers through concurrent raw keys/content/
       chapter calls plus book-list, verse, chapter, dictionary-key, and dictionary-content calls.
     - Expected result: Every operation kind reaches each fake, concurrent operations overlap, and
       no facade adds an executor-blocking lock that built-in per-operation connections do not need.
     - Failure meaning: A layered lock can make queued cancellation wait behind unrelated SQLite
       work even though the production reader already owns its cancellation-aware isolation.
     - Side effects: Runs bounded work on a concurrent dispatch queue; no files are created.
     */
    func testModuleFacadeDoesNotSerializeOperationIsolatedReaderCalls() {
        let bibleReader = OverlapDetectingSQLiteDocumentReader(category: .bible)
        let dictionaryReader = OverlapDetectingSQLiteDocumentReader(category: .dictionary)
        let harnesses = [
            ConcurrentSQLiteDocumentModuleHarness(
                module: SQLiteDocumentModule(reader: bibleReader, origin: .manual),
                category: .bible
            ),
            ConcurrentSQLiteDocumentModuleHarness(
                module: SQLiteDocumentModule(reader: dictionaryReader, origin: .manual),
                category: .dictionary
            ),
        ]
        let failures = SQLiteDocumentModuleFailureRecorder()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "SQLiteDocumentModuleLibraryTests.concurrentDelegation",
            attributes: .concurrent
        )

        for harness in harnesses {
            for operationIndex in 0..<72 {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    do {
                        try harness.perform(operationIndex: operationIndex)
                    } catch {
                        failures.record(error)
                    }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failures.messages, [])
        for reader in [bibleReader, dictionaryReader] {
            XCTAssertGreaterThan(reader.maximumSimultaneousOperationCount, 1)
            XCTAssertGreaterThan(reader.count(for: .keys), 0)
            XCTAssertGreaterThan(reader.count(for: .content), 0)
            XCTAssertGreaterThan(reader.count(for: .chapter), 0)
        }
    }

    /**
     Protects JSword duplicate admission and exact-then-case-insensitive lookup precedence.

     - Setup: Supplies an explicit registration sequence derived independently from JSword
       `Books.getBook`: initials and full name, exact maps first, insertion-order folding last.
     - Expected result: Existing full names reject candidate initials, exact initials outrank exact
       names, the last duplicate full name owns exact lookup, and folded lookup selects the first.
     - Failure meaning: Enumeration-derived expectations can conceal precedence drift and route a
       persisted module name to a different installed book.
     - Side effects: None; deterministic reader doubles perform no filesystem access.
     */
    func testPackageDiscoveryPreservesOrderAndJavaCaseDuplicateSemantics() throws {
        let candidates = [
            SQLiteDocumentModule(
                reader: IdentitySQLiteDocumentReader(initials: "Alpha", fullName: "Shared Name"),
                origin: .manual
            ),
            SQLiteDocumentModule(
                reader: IdentitySQLiteDocumentReader(initials: "Delta", fullName: "Alpha"),
                origin: .manual
            ),
            SQLiteDocumentModule(
                reader: IdentitySQLiteDocumentReader(initials: "Echo", fullName: "Shared Name"),
                origin: .manual
            ),
            SQLiteDocumentModule(
                reader: IdentitySQLiteDocumentReader(initials: "Shared Name", fullName: "Rejected"),
                origin: .manual
            ),
            SQLiteDocumentModule(
                reader: IdentitySQLiteDocumentReader(initials: "alpha", fullName: "Rejected Fold"),
                origin: .manual
            ),
            SQLiteDocumentModule(
                reader: IdentitySQLiteDocumentReader(initials: "Straße", fullName: "Sharp S"),
                origin: .manual
            ),
            SQLiteDocumentModule(
                reader: IdentitySQLiteDocumentReader(initials: "STRASSE", fullName: "Double S"),
                origin: .manual
            ),
        ]
        let library = SQLiteDocumentModuleLibrary(discoveredModules: candidates)

        XCTAssertEqual(
            library.modules.map(\.info.name),
            ["Alpha", "Delta", "Echo", "Straße", "STRASSE"]
        )
        XCTAssertEqual(library.diagnostics.count, 2)
        XCTAssertEqual(library.module(named: "Alpha")?.info.name, "Alpha")
        XCTAssertEqual(library.module(named: "Shared Name")?.info.name, "Echo")
        XCTAssertEqual(library.module(named: "shared name")?.info.name, "Alpha")
        XCTAssertEqual(library.module(named: "aLpHa")?.info.name, "Alpha")
        XCTAssertEqual(library.module(named: "STRASSE")?.info.name, "STRASSE")
    }

    /**
     Protects Java's non-expanding UTF-16 `String.equalsIgnoreCase` identity edge cases.

     - Setup: Compares established BMP aliases, Android 37 ICU 78.3 pairs newer than OpenJDK 17,
       supplementary case pairs, sharp s, and equivalent accents.
     - Expected result: Android BMP pairs compare equal, while supplementary pairs remain distinct
       because Java's `String.equalsIgnoreCase` iterates UTF-16 `char`s rather than code points;
       multi-character expansion and composed/decomposed strings also remain distinct.
     - Failure meaning: Foundation's full-string case mapping can hide, merge, or misroute module
       identities differently from Android's installed-book registry.
     - Side effects: Loads the checked-in Android character oracle table once; performs no writes.
     */
    func testSQLiteDocumentIdentityMatchesJavaUTF16EqualsIgnoreCaseEdges() {
        XCTAssertEqual(SQLiteDocumentIdentity("İ"), SQLiteDocumentIdentity("i"))
        let javaUppercaseAliases: [(String, String)] = [
            ("\u{00B5}", "\u{03BC}"),
            ("\u{0131}", "i"),
            ("\u{017F}", "s"),
            ("\u{0345}", "\u{03B9}"),
            ("\u{03C2}", "\u{03C3}"),
            ("\u{03D0}", "\u{03B2}"),
            ("\u{03D1}", "\u{03B8}"),
            ("\u{03D5}", "\u{03C6}"),
            ("\u{03D6}", "\u{03C0}"),
            ("\u{03F0}", "\u{03BA}"),
            ("\u{03F1}", "\u{03C1}"),
            ("\u{03F5}", "\u{03B5}"),
            ("\u{1C80}", "\u{0432}"),
            ("\u{1C81}", "\u{0434}"),
            ("\u{1C82}", "\u{043E}"),
            ("\u{1C83}", "\u{0441}"),
            ("\u{1C84}", "\u{0442}"),
            ("\u{1C85}", "\u{0442}"),
            ("\u{1C86}", "\u{044A}"),
            ("\u{1C87}", "\u{0463}"),
            ("\u{1C88}", "\u{A64B}"),
            ("\u{1E9B}", "\u{1E61}"),
            ("\u{1FBE}", "\u{03B9}"),
        ]
        for (alias, representative) in javaUppercaseAliases {
            XCTAssertEqual(SQLiteDocumentIdentity(alias), SQLiteDocumentIdentity(representative))
        }

        let supplementaryPairs: [(String, String)] = [
            ("\u{10400}", "\u{10428}"), // Deseret
            ("\u{104B0}", "\u{104D8}"), // Osage
            ("\u{10C80}", "\u{10CC0}"), // Old Hungarian
            ("\u{118A0}", "\u{118C0}"), // Warang Citi
            ("\u{16E40}", "\u{16E60}"), // Medefaidrin
            ("\u{1E900}", "\u{1E922}"), // Adlam
        ]
        for (uppercase, lowercase) in supplementaryPairs {
            XCTAssertNotEqual(SQLiteDocumentIdentity(uppercase), SQLiteDocumentIdentity(lowercase))
        }

        let android37UnicodePairs: [(String, String)] = [
            ("\u{019B}", "\u{A7DC}"),
            ("\u{0264}", "\u{A7CB}"),
            ("\u{1C8A}", "\u{1C89}"),
            ("\u{2C5F}", "\u{2C2F}"),
            ("\u{A7C1}", "\u{A7C0}"),
            ("\u{A7CD}", "\u{A7CC}"),
            ("\u{A7CF}", "\u{A7CE}"),
            ("\u{A7D1}", "\u{A7D0}"),
            ("\u{A7D3}", "\u{A7D2}"),
            ("\u{A7D5}", "\u{A7D4}"),
            ("\u{A7D7}", "\u{A7D6}"),
            ("\u{A7D9}", "\u{A7D8}"),
            ("\u{A7DB}", "\u{A7DA}"),
        ]
        for (lowercase, uppercase) in android37UnicodePairs {
            XCTAssertEqual(SQLiteDocumentIdentity(lowercase), SQLiteDocumentIdentity(uppercase))
        }

        XCTAssertEqual(SQLiteDocumentIdentity("ß"), SQLiteDocumentIdentity("ẞ"))
        XCTAssertNotEqual(SQLiteDocumentIdentity("ß"), SQLiteDocumentIdentity("ss"))
        XCTAssertNotEqual(
            SQLiteDocumentIdentity("\u{00C9}"),
            SQLiteDocumentIdentity("E\u{0301}")
        )
    }

    /**
     Protects package identity and payload containment when restored trees contain symlinks.

     - Setup: Creates one package with an internal sidecar and external payload link, plus one with
       an internal payload and external sidecar link.
     - Expected result: The escaped payload is rejected as missing, while the readable internal
       database remains Android-visible as a manual module without adopting the escaped sidecar.
     - Failure meaning: Package discovery could traverse outside its directory or let external JSON
       override an internal module's installed identity.
     - Side effects: Creates temporary fixture copies, JSON files, and symbolic links.
     */
    func testPackageDiscoveryRejectsEscapedPayloadAndSidecarSymlinks() throws {
        let root = try makeRoot()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsidePayload = outside.appendingPathComponent("outside.SQLite3")
        try copyFixture("mybible-bible.SQLite3", to: outsidePayload)
        try writeSidecar(
            name: "ESCAPED-IDENTITY",
            category: "Biblical Texts",
            packageFileName: "outside.SQLite3.zip",
            to: outside
        )

        let escapedPayloadPackage = root.appendingPathComponent(
            "mybible/escaped-payload",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: escapedPayloadPackage,
            withIntermediateDirectories: true
        )
        try writeSidecar(
            name: "ESCAPED-PAYLOAD",
            category: "Biblical Texts",
            packageFileName: "escaped.SQLite3.zip",
            to: escapedPayloadPackage
        )
        try FileManager.default.createSymbolicLink(
            at: escapedPayloadPackage.appendingPathComponent("escaped.SQLite3"),
            withDestinationURL: outsidePayload
        )

        let escapedSidecarPackage = root.appendingPathComponent(
            "mybible/escaped-sidecar",
            isDirectory: true
        )
        try copyFixture(
            "mybible-bible.SQLite3",
            to: escapedSidecarPackage.appendingPathComponent("inside.SQLite3")
        )
        try FileManager.default.createSymbolicLink(
            at: escapedSidecarPackage.appendingPathComponent("module.json"),
            withDestinationURL: outside.appendingPathComponent("module.json")
        )

        let library = SQLiteDocumentModuleLibrary(moduleRootURL: root)

        XCTAssertEqual(library.modules.map(\.info.name), ["MyBible-inside"])
        XCTAssertEqual(library.modules.first?.origin, .manual)
        XCTAssertEqual(library.diagnostics.count, 1)
        XCTAssertTrue(library.diagnostics[0].message.contains("no readable escaped.SQLite3 payload"))
    }

    /** Creates one empty Android module root and records it for teardown. */
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-module-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    /** Returns one checked-in real SQLite fixture. */
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SQLiteDocumentReaders/\(name)")
    }

    /** Copies a fixture after creating its Android discovery directory. */
    private func copyFixture(_ name: String, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureURL(name), to: destination)
    }

    /** Writes a production-shape MyBible package sidecar with intentionally distinct metadata. */
    private func writeSidecar(
        name: String,
        category: String,
        packageFileName: String,
        to directory: URL
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "description": "Sidecar-only description",
            "category": category,
            "language": "zz",
            "version": "99",
            "sourceName": "Fixture Repository",
            "packageFileName": packageFileName,
            "downloadURL": "https://example.invalid/\(packageFileName)",
            "installedAt": "2026-01-01T00:00:00Z",
        ], options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("module.json"))
    }
}

/** Deterministic installed-book candidate used by the independent JSword lookup oracle. */
private final class IdentitySQLiteDocumentReader: SQLiteDocumentReading {
    /// Metadata whose initials and description model JSword's two exact lookup maps.
    let metadata: SQLiteDocumentMetadata

    /// All identity-oracle candidates use a Bible category without source content.
    var category: DocumentCategory { .bible }

    /** Creates one no-I/O candidate with explicit initials and full book name. */
    init(initials: String, fullName: String) {
        metadata = SQLiteDocumentMetadata(
            sourceURL: URL(fileURLWithPath: "/tmp/\(initials).SQLite3"),
            format: .myBible,
            initials: initials,
            abbreviation: initials,
            title: fullName,
            description: fullName,
            language: "en",
            version: "0.0",
            category: .bible,
            direction: .ltr,
            hasStrongs: false,
            isStrongsDictionary: false,
            hasWordsOfChrist: false
        )
    }

    /** Returns no keys because this double tests registry identity only. */
    func keys() throws -> [SQLiteDocumentKey] { [] }

    /** Returns no content because this double tests registry identity only. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? { nil }
}

/** Deterministic Bible reader that records bounded-key enumeration calls for cache verification. */
private final class KeyCountingSQLiteBibleReader: SQLiteDocumentReading {
    let metadata = SQLiteDocumentMetadata(
        sourceURL: URL(fileURLWithPath: "/tmp/key-counting-bible.SQLite3"),
        format: .myBible,
        initials: "MyBible-key-counting-bible",
        abbreviation: "Cache",
        title: "Key cache fixture",
        description: "Key cache fixture",
        language: "en",
        version: "1",
        category: .bible,
        direction: .ltr,
        hasStrongs: false,
        isStrongsDictionary: false,
        hasWordsOfChrist: false
    )

    var category: DocumentCategory { .bible }
    private(set) var keyReadCount = 0
    private(set) var contentReadCount = 0
    private(set) var chapterReadCount = 0
    private var remainingKeyFailures: Int

    /** Creates a fixture reader that fails a bounded number of initial key reads. */
    init(failingKeyReadCount: Int = 0) {
        remainingKeyFailures = failingKeyReadCount
    }

    /** Returns one Genesis key while recording the database-enumeration boundary. */
    func keys() throws -> [SQLiteDocumentKey] {
        keyReadCount += 1
        if remainingKeyFailures > 0 {
            remainingKeyFailures -= 1
            throw KeyCountingSQLiteReaderError.fixtureFailure
        }
        return [.verse(book: 10, chapter: 1, verse: 1)]
    }

    /** Returns deterministic text for the single fixture verse. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        contentReadCount += 1
        guard key == .verse(book: 10, chapter: 1, verse: 1) else { return nil }
        return SQLiteDocumentContent(key: key, text: "Text")
    }

    /** Returns one complete chapter while recording the batch-query boundary. */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        chapterReadCount += 1
        guard book == 10, chapter == 1 else { return [] }
        return [(1, "Text")]
    }
}

/** Stable fixture failure used to verify retryable key-enumeration errors. */
private enum KeyCountingSQLiteReaderError: Error, Equatable {
    case fixtureFailure
}

/** Operation boundaries recorded by the delayed concurrent-delegation fake. */
private enum SQLiteDocumentRecordedOperation: CaseIterable {
    /// Source key enumeration.
    case keys

    /// Point verse or dictionary content lookup.
    case content

    /// Batch chapter lookup.
    case chapter
}

/**
 Delayed reader that records simultaneous entry across every protocol operation.

 The fake intentionally omits SQLite behavior and returns one deterministic Bible or dictionary
 value. Its lock protects only counters, leaving the delay outside the lock so a missing production
 facade lock is observable as an active-operation count of one.
 */
private final class OverlapDetectingSQLiteDocumentReader: SQLiteDocumentReading {
    /// Immutable metadata projected into the facade for the selected fake category.
    let metadata: SQLiteDocumentMetadata

    /// Category that selects the fake key and content shape.
    let category: DocumentCategory

    /// Protects active-operation and per-kind counters.
    private let lock = NSLock()

    /// Operations currently inside the delayed fake boundary.
    private var activeOperationCount = 0

    /// Highest simultaneous active-operation count observed by this fake.
    private var storedMaximumSimultaneousOperationCount = 0

    /// Number of entries recorded for each protocol operation.
    private var operationCounts: [SQLiteDocumentRecordedOperation: Int] = [:]

    /**
     Creates a deterministic Bible or dictionary reader.

     - Parameter category: `.bible` or `.dictionary`; other values are unsupported by this fixture.
     - Side effects: None.
     - Failure modes: None; tests pass only the two documented categories.
     */
    init(category: DocumentCategory) {
        self.category = category
        let name = category == .dictionary ? "concurrent-dictionary" : "concurrent-bible"
        self.metadata = SQLiteDocumentMetadata(
            sourceURL: URL(fileURLWithPath: "/tmp/\(name).SQLite3"),
            format: .myBible,
            initials: "MyBible-\(name)",
            abbreviation: name,
            title: name,
            description: name,
            language: "en",
            version: "0.0",
            category: category,
            direction: .ltr,
            hasStrongs: false,
            isStrongsDictionary: false,
            hasWordsOfChrist: false
        )
    }

    /** Returns the category-appropriate key after one delayed recorded operation. */
    func keys() throws -> [SQLiteDocumentKey] {
        perform(.keys) {
            switch category {
            case .dictionary: return [.dictionary("Term")]
            default: return [.verse(book: 10, chapter: 1, verse: 1)]
            }
        }
    }

    /** Returns deterministic content after one delayed recorded operation. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        perform(.content) {
            switch (category, key) {
            case (.dictionary, .dictionary("Term")):
                return SQLiteDocumentContent(key: key, text: "Definition")
            case (.bible, .verse(book: 10, chapter: 1, verse: 1)):
                return SQLiteDocumentContent(key: key, text: "Verse")
            default:
                return nil
            }
        }
    }

    /** Returns one Bible row, or an empty dictionary result, after a delayed recorded operation. */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        perform(.chapter) {
            guard category == .bible, book == 10, chapter == 1 else { return [] }
            return [(1, "Verse")]
        }
    }

    /** Returns the highest overlapping operation count under the counter lock. */
    var maximumSimultaneousOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMaximumSimultaneousOperationCount
    }

    /** Returns how many times one protocol boundary was entered. */
    func count(for operation: SQLiteDocumentRecordedOperation) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return operationCounts[operation, default: 0]
    }

    /**
     Records entry, delays outside the counter lock, and records exit on every return path.

     - Parameters:
       - operation: Protocol boundary being exercised.
       - result: Deterministic result builder that performs no synchronization or I/O.
     - Returns: The result builder's value.
     - Side effects: Mutates protected counters and sleeps for two milliseconds.
     - Throws: Re-throws the result builder's error after recording exit.
     */
    private func perform<Result>(
        _ operation: SQLiteDocumentRecordedOperation,
        result: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        activeOperationCount += 1
        storedMaximumSimultaneousOperationCount = max(
            storedMaximumSimultaneousOperationCount,
            activeOperationCount
        )
        operationCounts[operation, default: 0] += 1
        lock.unlock()
        defer {
            lock.lock()
            activeOperationCount -= 1
            lock.unlock()
        }

        Thread.sleep(forTimeInterval: 0.002)
        return try result()
    }
}

/**
 Transfers a non-Sendable facade into bounded workers solely to verify concurrent delegation.

 The wrapper is test-only and does not claim the facade is generally safe to pass between actors;
 every access is synchronous and all workers finish before the owning test releases the module.
 */
private final class ConcurrentSQLiteDocumentModuleHarness: @unchecked Sendable {
    /// Facade whose direct reader and convenience commands are exercised by workers.
    private let module: SQLiteDocumentModule

    /// Selects the complete Bible or dictionary command set.
    private let category: DocumentCategory

    /** Retains one facade and its operation category for bounded concurrent dispatch. */
    init(module: SQLiteDocumentModule, category: DocumentCategory) {
        self.module = module
        self.category = category
    }

    /**
     Executes one operation selected cyclically from every raw and facade boundary.

     - Parameter operationIndex: Nonnegative worker index used only to choose an operation.
     - Side effects: Invokes one synchronous module or direct-reader operation.
     - Throws: Re-throws fake reader failures.
     */
    func perform(operationIndex: Int) throws {
        if category == .dictionary {
            switch operationIndex % 5 {
            case 0: _ = try module.reader.keys()
            case 1: _ = try module.reader.content(for: .dictionary("Term"))
            case 2: _ = try module.reader.chapterContent(book: 10, chapter: 1)
            case 3: _ = try module.dictionaryKeys()
            default: _ = try module.dictionaryContent(for: "Term")
            }
        } else {
            switch operationIndex % 6 {
            case 0: _ = try module.reader.keys()
            case 1:
                _ = try module.reader.content(
                    for: .verse(book: 10, chapter: 1, verse: 1)
                )
            case 2: _ = try module.reader.chapterContent(book: 10, chapter: 1)
            case 3: _ = try module.bookList()
            case 4: _ = try module.verseContent(osisId: "Gen", chapter: 1, verse: 1)
            default: _ = try module.chapterContent(osisId: "Gen", chapter: 1)
            }
        }
    }
}

/** Collects concurrent module-test errors for assertion on the XCTest thread. */
private final class SQLiteDocumentModuleFailureRecorder: @unchecked Sendable {
    /// Protects mutation and snapshots of worker diagnostics.
    private let lock = NSLock()

    /// Human-readable errors copied from failed workers.
    private var storedMessages: [String] = []

    /** Records one worker failure without invoking XCTest from a background queue. */
    func record(_ error: Error) {
        lock.lock()
        storedMessages.append(String(describing: error))
        lock.unlock()
    }

    /** Returns an immutable diagnostic snapshot. */
    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedMessages
    }
}
