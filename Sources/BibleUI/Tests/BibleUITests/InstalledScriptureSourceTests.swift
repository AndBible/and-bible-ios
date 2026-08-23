import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** Tests exact Android installed-book behavior across the backend-neutral scripture boundary. */
final class InstalledScriptureSourceTests: BibleUISwordFixtureTestCase {
    /**
     Preserves Android's global-book identity contract for an explicit dictionary selection.

     - Setup: Resolves the readable KJV native Bible through the production installed-module
       registry, then projects that globally selected book into the dictionary-key facade.
     - Expected result: The native Bible remains available by exact initials and case-insensitive
       initials even though its category is not dictionary or glossary.
     - Failure meaning: iOS reapplied a category filter after global identity resolution, so an
       explicit Android selection can disappear before Strong's lookup.
     - Side effects: Writes only an inherited temporary SWORD fixture and removes it in teardown.
     */
    func testExplicitDictionarySelectionProjectsGloballyResolvedNativeBookWithoutCategoryFilter() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: []
        )

        XCTAssertEqual(
            resolver.module(named: "KJV")?.explicitDictionaryKeySource?.info.name,
            "KJV"
        )
        XCTAssertEqual(
            resolver.module(named: "kjv")?.explicitDictionaryKeySource?.info.name,
            "KJV"
        )
        XCTAssertEqual(
            resolver.dictionaryKeySources().map(\.info.name),
            ["KJV"],
            "Automatic feature discovery must receive readable native books of every category"
        )
    }

    /**
     Protects `OsisFragment.v11n` classification by pinned JSword concrete driver class.

     - Setup: Publishes representative zText4 and RawFiles SwordBook descriptors plus one RawLD
       SwordDictionary descriptor in a real manager snapshot.
     - Expected result: Both SwordBook drivers serialize KJV versification, RawLD stays null, and
       the nonexistent pinned RawText4 driver is not classified as SwordBook.
     - Failure meaning: iOS infers v11n from category or an incomplete/extra hand list rather than
       the exact `BookType` constructor map Android uses.
     - Side effects: Writes isolated descriptors/data placeholders removed by base teardown.
     */
    func testDictionarySourceVersificationUsesPinnedSwordBookDriverMap() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "ZText4Meta",
            description: "zText4 metadata fixture",
            moduleDriver: "zText4",
            in: modulePath
        )
        try seedBibleAliasModule(
            named: "RawFilesMeta",
            description: "RawFiles metadata fixture",
            moduleDriver: "RawFiles",
            in: modulePath
        )
        try seedEmptyRawDictionaryModule(named: "RawLDMeta", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let zText4 = try XCTUnwrap(manager.module(named: "ZText4Meta"))
        let rawFiles = try XCTUnwrap(manager.module(named: "RawFilesMeta"))
        let rawLD = try XCTUnwrap(manager.module(named: "RawLDMeta"))
        let unpinnedRawText4 = ModuleInfo(
            name: "RawText4",
            description: "Not a pinned BookType",
            category: .bible,
            language: "en",
            moduleDriver: "RawText4",
            aboutMetadata: ModuleAboutMetadata(versification: "KJV")
        )

        XCTAssertEqual(
            BibleReaderInstalledDictionarySource.sword(zText4).versificationName,
            "KJV"
        )
        XCTAssertEqual(
            BibleReaderInstalledDictionarySource.sword(rawFiles).versificationName,
            "KJV"
        )
        XCTAssertNil(BibleReaderInstalledDictionarySource.sword(rawLD).versificationName)
        XCTAssertFalse(unpinnedRawText4.isJSwordSwordBook)
    }

    /**
     Protects Android custom-driver admission and later exact-full-name ownership.

     - Setup: A native full name consumes one proposed SQLite initials token; another SQLite book
       has distinct initials but duplicates a different native book's full name.
     - Expected result: The first SQLite row is never registered, while the admitted later SQLite
       row becomes JSword's last exact-full-name owner.
     - Failure meaning: iOS either admits an Android-suppressed driver row or gives every native
       identity tier permanent precedence after custom books join the global registry.
     - Side effects: Writes isolated native fixtures and retains two in-memory SQLite readers.
     */
    func testGlobalIdentityReplaysSQLiteAdmissionAndLastExactNameOwnership() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "NativeAliasOwner",
            description: "SuppressedSQLiteInitials",
            in: modulePath
        )
        try seedBibleAliasModule(
            named: "NativeSharedName",
            description: "Shared Full Name",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let suppressedMetadata = SQLiteDocumentMetadata(
            sourceURL: URL(fileURLWithPath: "/tmp/sqlite-suppressed-tier.SQLite3"),
            format: .myBible,
            initials: "SuppressedSQLiteInitials",
            abbreviation: "Suppressed",
            title: "Suppressed SQLite",
            description: "Suppressed SQLite",
            language: "en",
            version: "1",
            category: .bible,
            direction: .ltr,
            hasStrongs: false,
            isStrongsDictionary: false,
            hasWordsOfChrist: false
        )
        let duplicateNameMetadata = SQLiteDocumentMetadata(
            sourceURL: URL(fileURLWithPath: "/tmp/sqlite-duplicate-name-tier.SQLite3"),
            format: .myBible,
            initials: "SQLiteDistinctInitials",
            abbreviation: "SQLite shared",
            title: "Shared Full Name",
            description: "Shared Full Name",
            language: "en",
            version: "1",
            category: .bible,
            direction: .ltr,
            hasStrongs: false,
            isStrongsDictionary: false,
            hasWordsOfChrist: false
        )
        let suppressedSQLite = makeSQLiteModuleHandle(
            rows: [(.verse(book: 10, chapter: 1, verse: 1), "Suppressed content")],
            metadata: suppressedMetadata
        )
        let duplicateNameSQLite = makeSQLiteModuleHandle(
            rows: [(.verse(book: 10, chapter: 1, verse: 1), "Later full-name content")],
            metadata: duplicateNameMetadata
        )
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: [suppressedSQLite, duplicateNameSQLite]
        )

        XCTAssertEqual(
            resolver.module(named: "SuppressedSQLiteInitials")?.info.name,
            "NativeAliasOwner"
        )
        guard case .sqlite(let resolved)? = resolver.module(named: "Shared Full Name") else {
            return XCTFail("The last admitted exact full-name owner must be SQLite")
        }
        XCTAssertEqual(resolved.info.name, "SQLiteDistinctInitials")
        XCTAssertFalse(resolver.hasNativeRegistration(named: "Shared Full Name"))
        XCTAssertEqual(
            resolver.module(named: "NativeSharedName")?.info.name,
            "NativeSharedName"
        )
    }

    /**
     Protects Android custom-driver admission from a custom-only duplicate cascade.

     - Setup: A native full name owns SQLite A's initials; SQLite A's full name in turn equals
       SQLite B's initials. The standalone SQLite catalog therefore retains A and suppresses B.
     - Expected result: The combined resolver rejects A against native ownership, then independently
       admits B from the raw discovery sequence and resolves B by its exact initials.
     - Failure meaning: iOS consumed the SQLite-only prefiltered catalog, so a driver candidate that
       Android never registers incorrectly prevented a later valid custom book from registering.
     - Side effects: Writes one isolated native descriptor and retains two in-memory SQLite readers.
     */
    func testProductionResolverReplaysRawSQLiteCandidatesAfterNativeCascadeRejection() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "NativeCascadeOwner",
            description: "AliasA",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let candidateA = makeSQLiteModule(
            rows: [(.verse(book: 10, chapter: 1, verse: 1), "Candidate A")],
            metadata: SQLiteDocumentMetadata(
                sourceURL: URL(fileURLWithPath: "/tmp/sqlite-cascade-a.SQLite3"),
                format: .myBible,
                initials: "AliasA",
                abbreviation: "Candidate A",
                title: "AliasB",
                description: "AliasB",
                language: "en",
                version: "1",
                category: .bible,
                direction: .ltr,
                hasStrongs: false,
                isStrongsDictionary: false,
                hasWordsOfChrist: false
            )
        )
        let candidateB = makeSQLiteModule(
            rows: [(.verse(book: 10, chapter: 1, verse: 1), "Candidate B")],
            metadata: SQLiteDocumentMetadata(
                sourceURL: URL(fileURLWithPath: "/tmp/sqlite-cascade-b.SQLite3"),
                format: .myBible,
                initials: "AliasB",
                abbreviation: "Candidate B",
                title: "Surviving SQLite",
                description: "Surviving SQLite",
                language: "en",
                version: "1",
                category: .bible,
                direction: .ltr,
                hasStrongs: false,
                isStrongsDictionary: false,
                hasWordsOfChrist: false
            )
        )
        let library = SQLiteDocumentModuleLibrary(
            discoveredModules: [candidateA, candidateB]
        )
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteLibrary: library
        )

        XCTAssertEqual(library.modules.map(\.info.name), ["AliasA"])
        XCTAssertEqual(
            library.registrationCandidates.map(\.info.name),
            ["AliasA", "AliasB"]
        )
        XCTAssertEqual(resolver.module(named: "AliasA")?.info.name, "NativeCascadeOwner")
        guard case .sqlite(let surviving)? = resolver.module(named: "AliasB") else {
            return XCTFail("The later raw SQLite candidate must survive combined admission")
        }
        XCTAssertEqual(surviving.info.name, "AliasB")
    }

    /**
     Anchors automatic discovery to JSword TreeSet order and Java-trimmed config metadata.

     - Setup: Supplies a Bible plus two SQLite dictionaries in reverse display order. One
       abbreviation has Java-trimmable ASCII controls; the other is bounded by preserved NBSP.
     - Expected result: Both inclusive metadata and readable key sources order by category then Java
       abbreviation comparison, ASCII edge whitespace is removed, and NBSP remains byte-for-byte.
     - Failure meaning: Automatic Strong's tabs use registration order, sort by initials before
       abbreviation, apply Swift Unicode trimming, or skip JSword's generated-config trim boundary.
     - Side effects: Writes only the inherited KJV fixture and retains two in-memory SQLite readers.
     */
    func testAutomaticDictionaryInventoryUsesJSwordTreeSetOrderAndJavaTrimmedMetadata() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let kjv = try XCTUnwrap(manager.module(named: "KJV"))
        let zuluAbbreviation = makeSQLiteModuleHandle(
            rows: [(.dictionary("G243"), "Zulu entry")],
            metadata: SQLiteDocumentMetadata(
                sourceURL: URL(fileURLWithPath: "/tmp/sqlite-zulu-abbreviation.SQLite3"),
                format: .myBible,
                initials: "AlphaInitials",
                abbreviation: "\u{00A0}Zulu\u{00A0}",
                title: "Zulu abbreviation",
                description: "\u{00A0}Zulu full name\u{00A0}",
                language: "\u{00A0}en\u{00A0}",
                version: "1",
                category: .dictionary,
                direction: .ltr,
                hasStrongs: false,
                isStrongsDictionary: true,
                hasWordsOfChrist: false
            )
        )
        let whitespaceAbbreviation = makeSQLiteModuleHandle(
            rows: [(.dictionary("G243"), "Whitespace entry")],
            metadata: SQLiteDocumentMetadata(
                sourceURL: URL(fileURLWithPath: "/tmp/sqlite-space-abbreviation.SQLite3"),
                format: .myBible,
                initials: "ZedInitials",
                abbreviation: " \talpha \r",
                title: "Whitespace abbreviation",
                description: " \t \r",
                language: " \t",
                version: "1",
                category: .dictionary,
                direction: .ltr,
                hasStrongs: false,
                isStrongsDictionary: true,
                hasWordsOfChrist: false
            )
        )
        let resolver = BibleReaderInstalledModuleResolver(
            swordModules: [kjv],
            sqliteModules: [zuluAbbreviation, whitespaceAbbreviation]
        )

        XCTAssertEqual(
            resolver.registeredBookMetadata().map(\.name),
            ["KJV", "ZedInitials", "AlphaInitials"]
        )
        let sources = resolver.dictionaryKeySources()
        XCTAssertEqual(sources.map(\.info.name), ["KJV", "ZedInitials", "AlphaInitials"])
        XCTAssertEqual(sources[1].abbreviation, "alpha")
        XCTAssertEqual(sources[2].abbreviation, "\u{00A0}Zulu\u{00A0}")
        XCTAssertEqual(sources[1].info.description, "")
        XCTAssertEqual(sources[1].info.language, "und")
        XCTAssertEqual(sources[2].info.description, "\u{00A0}Zulu full name\u{00A0}")
        XCTAssertEqual(sources[2].info.language, "\u{00A0}en\u{00A0}")
    }

    /**
     Keeps inclusive native ownership separate from authorization across shared content readers.

     - Setup: Registers readable KJV, a locked native Bible whose initials collide with a readable
       SQLite Bible, and builds the production installed-module resolver from that fresh manager.
     - Expected result: KJV remains readable, the locked native owns the collision without exposing
       either backend, Compare contains only KJV, and copy/share cannot read the locked identity.
     - Failure meaning: A non-activation content path can inspect a locked Bible or fall through to
       a SQLite namesake that Android's native registration shadows.
     - Side effects: Writes only an inherited temporary SWORD fixture and removes it in teardown.
     */
    @MainActor
    func testLockedNativeOwnershipFailsClosedAcrossContentSearchAIAndAnnotationBoundaries() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let lockedName = "MyBible-installed-source"
        try seedBibleAliasModule(
            named: lockedName,
            description: "Locked native collision owner",
            in: modulePath
        )
        let lockedConfigURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(lockedName.lowercased()).conf")
        var lockedConfiguration = try String(contentsOf: lockedConfigURL, encoding: .utf8)
        lockedConfiguration.append("\nCipherKey=\n")
        try lockedConfiguration.write(to: lockedConfigURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sqliteModule = makeSQLiteModuleHandle(rows: [
            (.verse(book: 10, chapter: 1, verse: 1), "SQLite collision content"),
        ])
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: [sqliteModule]
        )
        let lockedNativeHandle = try XCTUnwrap(manager.module(named: lockedName))
        let kjvSource = try XCTUnwrap(resolver.scripture(named: "KJV"))
        let ordinal = try XCTUnwrap(kjvSource.verseOrdinal(
            osisBookId: "Gen",
            chapter: 1,
            verse: 1
        ))

        XCTAssertEqual(manager.moduleAccessState(named: lockedName), .locked)
        XCTAssertNil(manager.readableModule(named: lockedName))
        XCTAssertNil(resolver.module(named: lockedName))
        XCTAssertNil(resolver.scripture(named: lockedName))
        XCTAssertNil(resolver.searchIndexSource(named: lockedName))
        XCTAssertNil(resolver.module(named: sqliteModule.info.description))
        XCTAssertEqual(
            resolver.modules(categories: [.bible]).map(\.info.name),
            ["KJV"]
        )
        let staleIndexedNames = Set([lockedName, "KJV"])
        XCTAssertEqual(
            resolver.modules(categories: [.bible])
                .map(\.info.name)
                .filter(staleIndexedNames.contains),
            ["KJV"],
            "A stale index cannot make a relocked Bible eligible for text or Strong's search."
        )
        XCTAssertNil(SearchView.resolveStandaloneSearchIndexSource(
            named: lockedName,
            primaryModule: lockedNativeHandle,
            manager: manager
        ))
        XCTAssertNil(SearchView.resolveStandaloneSearchIndexSource(
            named: lockedName,
            primaryModule: lockedNativeHandle,
            manager: nil
        ))
        XCTAssertEqual(
            SearchView.resolveStandaloneSearchIndexSource(
                named: "KJV",
                primaryModule: nil,
                manager: manager
            )?.searchIndexModuleInfo.name,
            "KJV"
        )

        let installedMetadata = manager.installedModules() + [sqliteModule.info]
        let compareRequest = try XCTUnwrap(
            BibleReaderCompareDocumentBuilder(
                moduleResolver: resolver,
                installedBibleModules: installedMetadata
            ).makeRequest(
                bookInitials: "KJV",
                startOrdinal: ordinal,
                endOrdinal: ordinal
            )
        )
        XCTAssertEqual(compareRequest.sources.map(\.info.name), ["KJV"])

        let copyShareBuilder = BibleReaderVerseActionTextBuilder(moduleResolver: resolver)
        XCTAssertNil(copyShareBuilder.build(
            bookInitials: lockedName,
            startOrdinal: ordinal,
            endOrdinal: ordinal
        ))
        XCTAssertNotNil(copyShareBuilder.build(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        ))

        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        XCTAssertNil(controller.aiBibleSourceContext(
            bookInitials: lockedName,
            startOrdinal: ordinal,
            endOrdinal: ordinal
        ))
        XCTAssertNotNil(controller.aiBibleSourceContext(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        ))
        let lockedBookmark = BibleBookmark(
            kjvOrdinalStart: ordinal,
            kjvOrdinalEnd: ordinal,
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            v11n: "KJV",
            bookInitials: lockedName
        )
        lockedBookmark.book = "Genesis"
        XCTAssertEqual(controller.bookmarkListTextProjection(for: lockedBookmark), .empty)
        let readableBookmark = BibleBookmark(
            kjvOrdinalStart: ordinal,
            kjvOrdinalEnd: ordinal,
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            v11n: "KJV",
            bookInitials: "KJV"
        )
        readableBookmark.book = "Genesis"
        XCTAssertFalse(
            controller.bookmarkListTextProjection(for: readableBookmark).fullText.isEmpty
        )
    }

    /**
     Rebuilds authorization from fresh persisted access state after a successful unlock.

     - Setup: Captures one resolver while an encrypted Bible has an empty key, persists the
       post-verification non-empty key shape, then constructs a new manager and resolver.
     - Expected result: The locked snapshot exposes no content; the fresh post-unlock snapshot
       classifies and exposes the same native owner as readable.
     - Failure meaning: Resolver authorization is cached independently from manager access state,
       leaving successful startup/picker unlocks unusable until another unrelated refresh.
     - Side effects: Rewrites one descriptor in the inherited temporary SWORD fixture and removes it
       in teardown; no shared module store is touched.
     */
    func testFreshResolverExposesNativeContentAfterPersistedUnlockState() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let moduleName = "POSTLOCK"
        try seedBibleAliasModule(
            named: moduleName,
            description: "Post-unlock resolver Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let lockedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let lockedResolver = BibleReaderInstalledModuleResolver(
            swordManager: lockedManager,
            sqliteModules: []
        )
        XCTAssertEqual(lockedManager.moduleAccessState(named: moduleName), .locked)
        XCTAssertNil(lockedResolver.scripture(named: moduleName))

        configuration = configuration.replacingOccurrences(
            of: "CipherKey=\n",
            with: "CipherKey=verified-test-key\n"
        )
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        let unlockedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let unlockedResolver = BibleReaderInstalledModuleResolver(
            swordManager: unlockedManager,
            sqliteModules: []
        )

        XCTAssertEqual(unlockedManager.moduleAccessState(named: moduleName), .readable)
        XCTAssertEqual(unlockedManager.readableModule(named: moduleName)?.info.name, moduleName)
        XCTAssertEqual(unlockedResolver.scripture(named: moduleName)?.info.name, moduleName)
        XCTAssertEqual(
            unlockedResolver.searchIndexSource(named: moduleName)?.searchIndexModuleInfo.name,
            moduleName
        )
        XCTAssertEqual(
            SearchView.resolveStandaloneSearchIndexSource(
                named: moduleName,
                primaryModule: nil,
                manager: unlockedManager
            )?.searchIndexModuleInfo.name,
            moduleName
        )
        XCTAssertTrue(
            unlockedResolver.modules(categories: [.bible]).contains {
                $0.info.name == moduleName
            }
        )
    }

    /**
     Restores MyBible commentary through its concrete verse-key book contract and actual metadata.

     - Setup: Registers one in-memory MyBible Commentary containing Genesis 1:1 with Hebrew,
       right-to-left, and Strong's metadata, then restores its persisted Android child key.
     - Expected result: The verse fragment opens with Commentary category, KJVA versification,
       exact installed identity, source language/direction, and actual Strong's capability.
     - Failure meaning: Restore limits SQLite verse-key sources to Bibles, routes Commentary through
       dictionary lookup, or serializes the shared Bible builder's route-derived metadata.
     - Side effects: Retains an in-memory reader and serializes one transient Multi payload.
     */
    func testRestoredMultiPreservesSQLiteCommentaryConcreteBookMetadata() throws {
        let metadata = SQLiteDocumentMetadata(
            sourceURL: URL(fileURLWithPath: "/tmp/restored-commentary.SQLite3"),
            format: .myBible,
            initials: "RestoreSQLiteCommentary",
            abbreviation: "RSC",
            title: "Restored SQLite Commentary",
            description: "Restored SQLite Commentary",
            language: "he",
            version: "1",
            category: .commentary,
            direction: .rtl,
            hasStrongs: true,
            isStrongsDictionary: false,
            hasWordsOfChrist: false
        )
        let module = makeSQLiteModuleHandle(
            rows: [
                (.verse(book: 10, chapter: 1, verse: 1), "SQLite commentary text"),
            ],
            metadata: metadata
        )
        let resolver = BibleReaderInstalledModuleResolver(
            swordModules: [],
            sqliteModules: [module]
        )
        let builder = BibleReaderRestoredMultiDocumentBuilder(
            moduleResolver: resolver,
            activeModuleName: nil
        )

        let request = try XCTUnwrap(
            builder.build(pageKey: "RestoreSQLiteCommentary:Gen.1.1")
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.documentJSON.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.commentary.rawValue)
        XCTAssertEqual(fragment["bookInitials"] as? String, "RestoreSQLiteCommentary")
        XCTAssertEqual(fragment["bookAbbreviation"] as? String, "RSC")
        XCTAssertEqual(fragment["key"] as? String, "RestoreSQLiteCommentary--Gen.1.1")
        XCTAssertEqual(fragment["osisRef"] as? String, "Gen.1.1")
        XCTAssertEqual(fragment["v11n"] as? String, JSwordKJVAVersification.name)
        XCTAssertTrue(features.isEmpty)
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, true)
        XCTAssertEqual(fragment["language"] as? String, "he")
        XCTAssertEqual(fragment["direction"] as? String, "rtl")
        XCTAssertTrue((fragment["xml"] as? String)?.contains("SQLite commentary text") == true)
        XCTAssertTrue(payload["contentType"] is NSNull)
    }

    /**
     Verifies a SQLite passage crosses KJVA's chapter-introduction slot without losing real verses.

     - Setup: A sparse MyBible source contains only Genesis 1:31 and Genesis 2:1.
     - Expected result: Both rows are returned in canonical order and adjacency ignores only the
       chapter-introduction ordinal between them.
     - Failure meaning: Copy, Compare, links, or speech would truncate a cross-chapter selection or
       treat a KJVA introduction slot as missing scripture.
     */
    func testSQLitePassageCrossesChapterIntroductionWithoutInventingRows() throws {
        let source = makeSource(rows: [
            (.verse(book: 10, chapter: 1, verse: 31), "End of chapter"),
            (.verse(book: 10, chapter: 2, verse: 1), "Start of chapter"),
        ])
        let startOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 31
        ))
        let endOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 2,
            verse: 1
        ))

        let passage = try source.passage(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        XCTAssertEqual(passage.verses.map(\.reference.ordinal), [startOrdinal, endOrdinal])
        XCTAssertEqual(passage.plainText, "End of chapter Start of chapter")
        XCTAssertEqual(passage.sourceOSISRange, "Gen.1.31-Gen.2.1")
        XCTAssertTrue(try XCTUnwrap(passage.verses.last).reference == source.verseReference(ordinal: endOrdinal))
        XCTAssertTrue(source.isCanonicallyAdjacent(
            try XCTUnwrap(passage.verses.last).reference,
            after: try XCTUnwrap(passage.verses.first).reference
        ))
    }

    /**
     Verifies passage reads are bounded by source chapters rather than verse count.

     - Setup: Three sparse verses span two Genesis chapters.
     - Expected result: The source receives exactly one batch read for each chapter and no
       single-verse lookup.
     - Failure meaning: Long copy, Compare, or speech passages could reopen SQLite for every verse.
     */
    func testSQLitePassageBatchesReadsByChapter() throws {
        let reader = InstalledScriptureSQLiteReader(rows: [
            (.verse(book: 10, chapter: 1, verse: 30), "Thirty"),
            (.verse(book: 10, chapter: 1, verse: 31), "Thirty-one"),
            (.verse(book: 10, chapter: 2, verse: 1), "One"),
        ])
        let source = makeSource(reader: reader)
        let startOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 30
        ))
        let endOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 2,
            verse: 1
        ))

        let passage = try source.passage(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        XCTAssertEqual(passage.verses.map(\.plainText), ["Thirty", "Thirty-one", "One"])
        XCTAssertEqual(reader.chapterRequests, ["10:1", "10:2"])
        XCTAssertEqual(reader.singleContentReadCount, 0)
    }

    /**
     Verifies SQLite source markup and visible text come from the selected custom module.

     - Setup: One MyBible verse contains OSIS lexical markup and XML-sensitive visible text.
     - Expected result: Structural source XML is retained while canonical text strips markup.
     - Failure meaning: Backend-neutral callers would relabel raw database text or expose tags in
       native copy/share output.
     */
    func testSQLiteVerseKeepsSourceMarkupAndProjectsCanonicalText() throws {
        let source = makeSource(rows: [
            (
                .verse(book: 10, chapter: 1, verse: 1),
                #"<w lemma="strong:H07225">Beginning</w> &amp; creation"#
            ),
        ])
        let ordinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 1
        ))
        let reference = try XCTUnwrap(source.verseReference(ordinal: ordinal))

        let verse = try XCTUnwrap(source.verse(reference))

        XCTAssertEqual(
            verse.sourceXML,
            #"<w lemma="strong:H07225">Beginning</w> &amp; creation"#
        )
        XCTAssertEqual(verse.plainText, "Beginning & creation")
        XCTAssertEqual(verse.reference, reference)
    }

    /**
     Verifies range validation rejects introduction endpoints and excessive work before source I/O.

     - Setup: A valid Genesis 1:1 source plus its immediately preceding chapter-introduction slot.
     - Expected result: The introduction fails as a non-verse endpoint and a zero work bound fails
       as an invalid range.
     - Failure meaning: Bridge callers could reinterpret introduction ordinals or trigger an
       unbounded SQLite walk.
     */
    func testSQLitePassageRejectsIntroductionEndpointAndInvalidWorkBound() throws {
        let source = makeSource(rows: [
            (.verse(book: 10, chapter: 1, verse: 1), "Beginning"),
        ])
        let verseOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 1
        ))
        let introductionOrdinal = verseOrdinal - 1

        XCTAssertThrowsError(try source.passage(
            startOrdinal: introductionOrdinal,
            endOrdinal: verseOrdinal
        )) { error in
            XCTAssertEqual(
                error as? BibleReaderInstalledScriptureSourceError,
                .nonAddressableEndpoint(introductionOrdinal)
            )
        }
        XCTAssertThrowsError(try source.passage(
            startOrdinal: verseOrdinal,
            endOrdinal: verseOrdinal,
            maximumVerseCount: 0
        )) { error in
            XCTAssertEqual(
                error as? BibleReaderInstalledScriptureSourceError,
                .invalidRange
            )
        }
    }

    /** Creates one immutable MyBible source from exact ordered fixture rows. */
    private func makeSource(
        rows: [(SQLiteDocumentKey, String)]
    ) -> BibleReaderInstalledScriptureSource {
        makeSource(reader: InstalledScriptureSQLiteReader(rows: rows))
    }

    /** Wraps one retained fixture reader so tests can inspect its source-access count. */
    private func makeSource(
        reader: InstalledScriptureSQLiteReader
    ) -> BibleReaderInstalledScriptureSource {
        .sqlite(BibleReaderSQLiteModuleHandle(
            module: SQLiteDocumentModule(reader: reader, origin: .manual)
        ))
    }

    /** Creates one readable SQLite runtime handle from exact ordered fixture rows. */
    private func makeSQLiteModuleHandle(
        rows: [(SQLiteDocumentKey, String)],
        metadata: SQLiteDocumentMetadata = InstalledScriptureSQLiteReader.defaultMetadata
    ) -> BibleReaderSQLiteModuleHandle {
        BibleReaderSQLiteModuleHandle(module: makeSQLiteModule(rows: rows, metadata: metadata))
    }

    /**
     Creates one unregistered SQLite discovery candidate for combined-registry admission tests.

     - Parameters:
       - rows: Exact source records exposed by the retained in-memory reader.
       - metadata: Android installed-book identity proposed by the custom driver.
     - Returns: A validated manual module that has not passed either catalog registration layer.
     - Side effects: Retains an in-memory reader; no filesystem or database is opened.
     - Failure modes: None; the fixture reader and module initializer preserve inputs verbatim.
     */
    private func makeSQLiteModule(
        rows: [(SQLiteDocumentKey, String)],
        metadata: SQLiteDocumentMetadata
    ) -> SQLiteDocumentModule {
        SQLiteDocumentModule(
            reader: InstalledScriptureSQLiteReader(rows: rows, metadata: metadata),
            origin: .manual
        )
    }
}

/** Deterministic in-memory MyBible reader used by installed-source behavior tests. */
private final class InstalledScriptureSQLiteReader: SQLiteDocumentReading {
    /// Immutable MyBible Bible metadata projected into the installed-book registry.
    static let defaultMetadata = SQLiteDocumentMetadata(
        sourceURL: URL(fileURLWithPath: "/tmp/installed-scripture-source.SQLite3"),
        format: .myBible,
        initials: "MyBible-installed-source",
        abbreviation: "Fixture",
        title: "Installed source fixture",
        description: "Installed source fixture",
        language: "en",
        version: "1",
        category: .bible,
        direction: .ltr,
        hasStrongs: true,
        isStrongsDictionary: false,
        hasWordsOfChrist: false
    )

    /// Immutable MyBible Bible metadata projected into the installed-book registry.
    let metadata: SQLiteDocumentMetadata

    /// Exact fixture category projected from immutable installed metadata.
    var category: DocumentCategory { metadata.category }

    /// Ordered source rows, including sparse coordinates when requested by a test.
    private let rows: [(key: SQLiteDocumentKey, text: String)]

    /// Source chapter requests retained for bounded-I/O assertions.
    private(set) var chapterRequests: [String] = []

    /// Exact content lookups retained to catch accidental per-verse passage access.
    private(set) var singleContentReadCount = 0

    /**
     Captures exact fixture rows and installed metadata without normalization.

     - Parameters:
       - rows: Ordered source rows returned by key and chapter queries.
       - metadata: Installed-book identity/category metadata for resolver tests.
     - Side effects: None.
     - Failure modes: None; rows and metadata are retained verbatim.
     */
    init(
        rows: [(SQLiteDocumentKey, String)],
        metadata: SQLiteDocumentMetadata = defaultMetadata
    ) {
        self.rows = rows.map { (key: $0.0, text: $0.1) }
        self.metadata = metadata
    }

    /** Returns fixture keys in source order. */
    func keys() throws -> [SQLiteDocumentKey] {
        rows.map(\.key)
    }

    /** Returns the first exact source row for one typed key. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        singleContentReadCount += 1
        return rows.first(where: { $0.key == key }).map {
            SQLiteDocumentContent(key: key, text: $0.text)
        }
    }

    /** Returns one exact source chapter and records the single batch operation. */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        chapterRequests.append("\(book):\(chapter)")
        return rows.compactMap { row in
            guard case .verse(let rowBook, let rowChapter, let verse) = row.key,
                  rowBook == book,
                  rowChapter == chapter else {
                return nil
            }
            return (verse, row.text)
        }
    }
}
