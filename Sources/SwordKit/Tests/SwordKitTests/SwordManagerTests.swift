// SwordManagerTests.swift — Tests for SwordKit

import XCTest
import SQLite3
@testable import SwordKit

final class SwordManagerTests: XCTestCase {
    /**
     Verifies the shared authority stays pinned to the Android current-stable version code.

     - Setup: Reads the public compatibility authority used by add-on admission and backup
       manifests without constructing a manager or reading bundle metadata.
     - Expected result: The value equals Android commit 00b4ea24 version code 1115.
     - Side effects: None.
     - Failure meaning: iOS has silently changed the compatibility boundary without the required
       Android parity review.
     */
    func testAndroidCompatibilityAuthorityPinsCurrentStableVersionCode() {
        XCTAssertEqual(AndBibleAndroidCompatibility.currentVersionCode, 1115)
    }

    /**
     Verifies the public exact-string key follows Java UTF-16 identity rather than Swift equality.

     - Setup: Constructs keys for canonically equivalent composed/decomposed spellings and one exact
       copy, then places all three in a native Swift set.
     - Expected result: Exact copies compare equal, NFC/NFD values remain distinct, exposed code
       units retain their original form, and the set owns two identities.
     - Side effects: Allocates bounded in-memory strings and a set only.
     - Failure meaning: Dictionary/set clients can collapse Java-distinct persisted identities.
     */
    func testJavaExactStringIdentityPreservesRawUTF16Equality() {
        let composed = "CAF\u{00C9}"
        let decomposed = "CAFE\u{0301}"
        let composedIdentity = SwordJavaExactStringIdentity(composed)
        let decomposedIdentity = SwordJavaExactStringIdentity(decomposed)

        XCTAssertEqual(composedIdentity, SwordJavaExactStringIdentity(composed))
        XCTAssertNotEqual(composedIdentity, decomposedIdentity)
        XCTAssertEqual(composedIdentity.utf16CodeUnits, Array(composed.utf16))
        XCTAssertEqual(decomposedIdentity.utf16CodeUnits, Array(decomposed.utf16))
        XCTAssertEqual(Set([composedIdentity, decomposedIdentity]).count, 2)
    }

    /**
     Verifies manager-level unlock rejects invalid requests without manufacturing module state.

     The setup uses an empty SWORD root so the contract is deterministic with both the real and stub
     bridge. A failure means picker unlock could report success for a missing module or empty key.
     */
    func testUnlockModuleRejectsMissingModuleAndEmptyCipherKey() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))

        XCTAssertFalse(manager.unlockModule(named: "MISSING", withCipherKey: "secret"))
        XCTAssertFalse(manager.unlockModule(named: "MISSING", withCipherKey: ""))
    }

    /**
     Verifies decrypted Bible, commentary, dictionary, and general-book entries must form
     renderable OSIS before a key is accepted.

     - Setup: Supplies representative in-memory OSIS fragments for every encrypted SWORD document
       category; no native backend state is mocked.
     - Expected result: Each category-specific fragment parses into renderable document content.
     - Side effects: Parses in-memory fixtures only.
     - Failure meaning: A category can persist unauthenticated ciphertext despite the native
       backend returning success.
     */
    func testCipherEntryValidationAcceptsRenderableAndroidDocumentFormats() {
        let fixtures: [(ModuleCategory, String)] = [
            (.bible, #"<verse osisID="Gen.1.1">In the beginning</verse>"#),
            (.commentary, #"<verse osisID="Gen.1.1"><p>Commentary text</p></verse>"#),
            (.dictionary, #"<entryFree><orth>agape</orth><p>Love</p></entryFree>"#),
            (.generalBook, #"<div><title>Introduction</title><p>Book text</p></div>"#),
        ]

        for (category, content) in fixtures {
            XCTAssertTrue(
                SwordManager.cipherEntryIsStructurallyReadable(
                    osisFragment: content,
                    category: category,
                    moduleInitials: "LOCKED"
                ),
                "Expected structurally valid \(category.rawValue) content to pass."
            )
        }
    }

    /**
     Verifies empty, control-corrupted, and malformed decrypted bytes fail independently of SWORD's
     backend error flag.

     - Setup: Supplies replacement/control scalars plus empty and truncated OSIS fragments.
     - Expected result: Raw plausibility and category-aware structural checks reject every fixture.
     - Side effects: Parses in-memory fixtures only.
     - Failure meaning: A wrong raw-module key can still be persisted when ciphertext happens not to
       trigger `SWModule_popError`.
     */
    func testCipherEntryValidationRejectsUnauthenticatedGarbage() {
        XCTAssertFalse(SwordManager.isPlausibleDecryptedModuleText("bad\u{0097}text"))
        XCTAssertFalse(SwordManager.isPlausibleDecryptedModuleText("bad\u{E000}text"))
        XCTAssertFalse(SwordManager.cipherEntryIsStructurallyReadable(
            osisFragment: "",
            category: .bible,
            moduleInitials: "LOCKED"
        ))
        XCTAssertFalse(SwordManager.cipherEntryIsStructurallyReadable(
            osisFragment: "<p>cipher\u{0001}text</p>",
            category: .dictionary,
            moduleInitials: "LOCKED"
        ))
        XCTAssertFalse(SwordManager.cipherEntryIsStructurallyReadable(
            osisFragment: "<entryFree><p>truncated",
            category: .generalBook,
            moduleInitials: "LOCKED"
        ))
    }

    /**
     Verifies a real encrypted RawLD module rejects a wrong key without persistence and remains
     retryable with the correct key.

     - Setup: Loads a native Sapphire II encrypted RawLD record through libsword with an empty
       `CipherKey`, then submits an ordinary wrong passphrase before the fixture's real key.
     - Expected result: The fresh manager access API stays locked after the wrong key, becomes
       readable on the next inventory snapshot after the correct retry, decrypts content, and
       persists the verified key even though the native module remains resolvable while locked.
     - Side effects: Writes a native RawLD index/record, encrypts the entry with SWORD's Sapphire II
       format, loads it through libsword, and rewrites only the temporary config after success.
     - Failure meaning: Wrong keys can mark encrypted modules unlocked, poison durable config, or
       prevent a later correct-key retry.
     */
    func testEncryptedRawLDWrongKeyIsUnpersistedAndCorrectKeyRemainsRetryable() throws {
        let fixture = try makeEncryptedRawLDFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalConfig = try Data(contentsOf: fixture.configURL)
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let initiallyLocked = try XCTUnwrap(
            manager.installedModules().first { $0.name == "LOCKED" }
        )
        XCTAssertTrue(initiallyLocked.isEncrypted)
        XCTAssertFalse(initiallyLocked.isUnlocked)
        XCTAssertEqual(manager.moduleAccessState(named: "locked"), .locked)
        XCTAssertNotNil(manager.module(named: "LOCKED"))
        XCTAssertNil(manager.readableModule(named: "locked"))

        XCTAssertFalse(
            manager.unlockModule(named: "LOCKED", withCipherKey: "wrong-test-key")
        )
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), originalConfig)
        XCTAssertFalse(
            manager.installedModules().first { $0.name == "LOCKED" }?.isUnlocked ?? true
        )
        XCTAssertEqual(manager.moduleAccessState(named: "LOCKED"), .locked)
        XCTAssertNil(manager.readableModule(named: "LOCKED"))

        XCTAssertTrue(manager.unlockModule(named: "LOCKED", withCipherKey: fixture.cipherKey))
        let persistedConfig = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(persistedConfig.contains("CipherKey=\(fixture.cipherKey)"))
        XCTAssertTrue(
            manager.installedModules().first { $0.name == "LOCKED" }?.isUnlocked ?? false
        )
        XCTAssertEqual(
            manager.moduleAccessState(named: "LOCKED"),
            .readable,
            "Manager access must observe the live unlock through a fresh inventory snapshot."
        )
        let module = try XCTUnwrap(manager.readableModule(named: "locked"))
        module.begin()
        XCTAssertTrue(module.rawEntry().contains("Encrypted dictionary entry"))
    }

    /**
     Verifies a verified encrypted Bible remains decryptable through a newly constructed manager.

     - Setup: Creates a licensed-safe two-verse RawText Bible, Sapphire-encrypts each native record,
       and opens it once with an empty `CipherKey` so libsword materializes its locked aggregate
       config cache. The test rejects one wrong key before accepting the real key.
     - Expected result: The wrong key changes neither config nor cache; the correct key decrypts a
       live chapter range, removes the stale cache, and a fresh manager rebuilds that cache with the
       persisted key and reconstructs both exact source verses.
     - Side effects: Creates and removes one isolated SWORD root, rewrites its temporary module
       config, and lets libsword rebuild `mods.d/modules-conf.cache`.
     - Failure meaning: Picker unlock can appear successful in memory while startup or saved-position
       restore after relaunch authorizes ciphertext as a readable Bible.
     - Note: Every fixture byte is synthetic; no distributable Bible text or key is embedded.
     */
    func testEncryptedRawTextBibleUnlockSurvivesFreshManagerChapterRead() throws {
        let fixture = try makeEncryptedRawTextBibleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cacheURL = fixture.root.appendingPathComponent("mods.d/modules-conf.cache")

        do {
            let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
            let originalConfig = try Data(contentsOf: fixture.configURL)
            let originalCache = try Data(contentsOf: cacheURL)

            XCTAssertEqual(manager.moduleAccessState(named: "LOCKEDBIBLE"), .locked)
            XCTAssertNil(manager.readableModule(named: "LOCKEDBIBLE"))
            XCTAssertFalse(
                manager.unlockModule(named: "LOCKEDBIBLE", withCipherKey: "wrongtestkey")
            )
            XCTAssertEqual(try Data(contentsOf: fixture.configURL), originalConfig)
            XCTAssertEqual(try Data(contentsOf: cacheURL), originalCache)

            XCTAssertTrue(
                manager.unlockModule(named: "LOCKEDBIBLE", withCipherKey: fixture.cipherKey)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
            XCTAssertEqual(manager.moduleAccessState(named: "LOCKEDBIBLE"), .readable)
            let liveModule = try XCTUnwrap(manager.readableModule(named: "LOCKEDBIBLE"))
            try assertSyntheticEncryptedChapterReadable(in: liveModule)
        }

        let freshManager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        XCTAssertEqual(freshManager.moduleAccessState(named: "LOCKEDBIBLE"), .readable)
        let freshModule = try XCTUnwrap(freshManager.readableModule(named: "LOCKEDBIBLE"))
        try assertSyntheticEncryptedChapterReadable(in: freshModule)
        let rebuiltCache = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertTrue(rebuiltCache.contains("CipherKey=\(fixture.cipherKey)"))
    }

    /**
     Verifies access checks resolve the same installed initials that Java would resolve.

     - Setup: Installs a real locked RawLD module whose initials are `ß`, then requests the
       length-expanding Foundation case-fold alias `SS`.
     - Expected result: The exact initials remain locked, while `SS` is unavailable because Java
       `String.equalsIgnoreCase` never expands one UTF-16 code unit into two.
     - Side effects: Creates and removes one temporary encrypted SWORD fixture.
     - Failure meaning: A lookup can authorize or unlock a different installed row than Android.
     */
    func testModuleAccessStateDoesNotUseExpandingFoundationCaseFold() throws {
        let fixture = try makeEncryptedRawLDFixture(moduleName: "ß")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))

        XCTAssertEqual(manager.moduleAccessState(named: "ß"), .locked)
        XCTAssertEqual(manager.moduleAccessState(named: "SS"), .unavailable)
        XCTAssertNil(manager.readableModule(named: "ß"))
        XCTAssertNil(manager.readableModule(named: "SS"))
    }

    /**
     Verifies Java-distinct NFC/NFD initials retain separate native handles and backend content.

     - Setup: Installs two real RawLD configs whose initials are canonically equivalent to Swift but
       have different UTF-16 sequences, with a unique native data file and entry for each spelling.
     - Expected result: Inventory, exact lookup, access classification, and readable lookup retain
       both handles, and each handle reads only its own backend entry.
     - Side effects: Creates and removes one isolated two-module SWORD root and advances each test
       module cursor to its first entry.
     - Failure meaning: Swift normalization or a string-keyed cache has collapsed Java identities and
       can return document content from the wrong native backend.
     */
    func testNativeRegistryKeepsCanonicallyEquivalentJavaInitialsAndBackendsDistinct() throws {
        let composed = "CAF\u{00C9}"
        let decomposed = "CAFE\u{0301}"
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: composed,
                fullName: "Composed identity dictionary",
                abbreviation: "Composed",
                dataStem: "composed",
                entryText: "NFC_UNIQUE_BACKEND"
            ),
            SwordManagerPlainRawLDDefinition(
                initials: decomposed,
                fullName: "Decomposed identity dictionary",
                abbreviation: "Decomposed",
                dataStem: "decomposed",
                entryText: "NFD_UNIQUE_BACKEND"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))

        XCTAssertNotEqual(
            SwordJavaExactStringIdentity(composed),
            SwordJavaExactStringIdentity(decomposed)
        )
        let installedModules = manager.installedModules()
        XCTAssertEqual(installedModules.count, 2)
        XCTAssertEqual(
            Set(installedModules.map { SwordJavaExactStringIdentity($0.name) }),
            Set([
                SwordJavaExactStringIdentity(composed),
                SwordJavaExactStringIdentity(decomposed),
            ])
        )
        XCTAssertEqual(manager.moduleAccessState(named: composed), .readable)
        XCTAssertEqual(manager.moduleAccessState(named: decomposed), .readable)

        let composedModule = try XCTUnwrap(manager.module(named: composed))
        let decomposedModule = try XCTUnwrap(manager.module(named: decomposed))
        XCTAssertNotEqual(ObjectIdentifier(composedModule), ObjectIdentifier(decomposedModule))
        XCTAssertEqual(
            SwordJavaExactStringIdentity(composedModule.info.name),
            SwordJavaExactStringIdentity(composed)
        )
        XCTAssertEqual(
            SwordJavaExactStringIdentity(decomposedModule.info.name),
            SwordJavaExactStringIdentity(decomposed)
        )
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(manager.readableModule(named: composed))),
            ObjectIdentifier(composedModule)
        )
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(manager.readableModule(named: decomposed))),
            ObjectIdentifier(decomposedModule)
        )

        composedModule.begin()
        let composedEntry = composedModule.rawEntry()
        decomposedModule.begin()
        let decomposedEntry = decomposedModule.rawEntry()
        XCTAssertTrue(composedEntry.contains("NFC_UNIQUE_BACKEND"))
        XCTAssertFalse(composedEntry.contains("NFD_UNIQUE_BACKEND"))
        XCTAssertTrue(decomposedEntry.contains("NFD_UNIQUE_BACKEND"))
        XCTAssertFalse(decomposedEntry.contains("NFC_UNIQUE_BACKEND"))
    }

    /**
     Verifies exact case-distinct initials beat aliases and aliases use JSword TreeSet order.

     - Setup: Installs real `foo` and `FOO` RawLD backends. Their abbreviations intentionally make
       uppercase `FOO` sort first even when config enumeration could present lowercase first.
     - Expected result: Exact initials and exact full names return their own handles, while mixed-case
       `FoO` selects uppercase `FOO` through category/abbreviation/initials/name TreeSet ordering.
     - Side effects: Creates and removes one isolated native SWORD root and reads both first entries.
     - Failure meaning: Native lookup is list-first, cache-normalized, or bypassing JSword exact-map
       precedence, allowing case aliases to cross-read another installed document.
     */
    func testNativeLookupUsesExactMapsBeforePinnedCaseAliasTreeSetWinner() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "foo",
                fullName: "Lowercase full name",
                abbreviation: "Zulu",
                dataStem: "lowercase",
                entryText: "LOWERCASE_BACKEND_ONLY"
            ),
            SwordManagerPlainRawLDDefinition(
                initials: "FOO",
                fullName: "Uppercase full name",
                abbreviation: "Alpha",
                dataStem: "uppercase",
                entryText: "UPPERCASE_BACKEND_ONLY"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))

        XCTAssertEqual(
            manager.installedModules().map(\.name),
            ["FOO", "foo"],
            "Installed TreeSet order must use Alpha/Zulu abbreviations before exact initials."
        )

        let lowercase = try XCTUnwrap(manager.module(named: "foo"))
        let uppercase = try XCTUnwrap(manager.module(named: "FOO"))
        XCTAssertNotEqual(ObjectIdentifier(lowercase), ObjectIdentifier(uppercase))
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(manager.module(named: "Lowercase full name"))),
            ObjectIdentifier(lowercase)
        )
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(manager.module(named: "Uppercase full name"))),
            ObjectIdentifier(uppercase)
        )
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(manager.module(named: "FoO"))),
            ObjectIdentifier(uppercase)
        )
        XCTAssertEqual(manager.moduleAccessState(named: "foo"), .readable)
        XCTAssertEqual(manager.moduleAccessState(named: "FOO"), .readable)
        XCTAssertEqual(manager.moduleAccessState(named: "FoO"), .readable)
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(manager.readableModule(named: "foo"))),
            ObjectIdentifier(lowercase)
        )
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(manager.readableModule(named: "FOO"))),
            ObjectIdentifier(uppercase)
        )
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(manager.readableModule(named: "FoO"))),
            ObjectIdentifier(uppercase)
        )

        lowercase.begin()
        let lowercaseEntry = lowercase.rawEntry()
        uppercase.begin()
        let uppercaseEntry = uppercase.rawEntry()
        XCTAssertTrue(lowercaseEntry.contains("LOWERCASE_BACKEND_ONLY"))
        XCTAssertFalse(lowercaseEntry.contains("UPPERCASE_BACKEND_ONLY"))
        XCTAssertTrue(uppercaseEntry.contains("UPPERCASE_BACKEND_ONLY"))
        XCTAssertFalse(uppercaseEntry.contains("LOWERCASE_BACKEND_ONLY"))
    }

    /**
     Verifies exact initials-map precedence beats an exact full-name collision.

     - Setup: Installs one real RawLD module whose initials equal another module's full name.
     - Expected result: Looking up the shared token returns the initials owner and its unique backend.
     - Side effects: Creates/removes an isolated native fixture and reads one RawLD entry.
     - Failure meaning: The full-name map can redirect an exact initials request to another document.
     */
    func testNativeLookupPrefersExactInitialsOverExactFullNameCollision() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "TOKEN",
                fullName: "Initials owner",
                abbreviation: "Zulu",
                dataStem: "initials-owner",
                entryText: "INITIALS_OWNER_BACKEND"
            ),
            SwordManagerPlainRawLDDefinition(
                initials: "OTHER",
                fullName: "TOKEN",
                abbreviation: "Alpha",
                dataStem: "full-name-owner",
                entryText: "FULL_NAME_OWNER_BACKEND"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))

        let selected = try XCTUnwrap(manager.module(named: "TOKEN"))
        XCTAssertEqual(selected.info.name, "TOKEN")
        selected.begin()
        let entry = selected.rawEntry()
        XCTAssertTrue(entry.contains("INITIALS_OWNER_BACKEND"))
        XCTAssertFalse(entry.contains("FULL_NAME_OWNER_BACKEND"))
    }

    /**
     Verifies an exact full-name collision with no initials owner fails closed without hiding books.

     - Setup: Installs two real RawLD books with unique initials/backends and one identical full name.
     - Expected result: Both exact initials remain independently readable, while the shared exact
       full-name token resolves to no module or access state.
     - Side effects: Creates/removes an isolated native fixture and reads both backend entries.
     - Failure meaning: HashSet/toArray registration order can choose an unprovable Android-runtime
       winner and cross-read another installed document through the exact full-name map.
     */
    func testNativeExactFullNameCollisionFailsClosedButInitialsRemainReadable() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "FULLNAMEONE",
                fullName: "Shared exact full name",
                abbreviation: "Alpha",
                dataStem: "full-name-one",
                entryText: "FULL_NAME_ONE_BACKEND"
            ),
            SwordManagerPlainRawLDDefinition(
                initials: "FULLNAMETWO",
                fullName: "Shared exact full name",
                abbreviation: "Zulu",
                dataStem: "full-name-two",
                entryText: "FULL_NAME_TWO_BACKEND"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))

        XCTAssertEqual(manager.installedModules().map(\.name), ["FULLNAMEONE", "FULLNAMETWO"])
        let first = try XCTUnwrap(manager.readableModule(named: "FULLNAMEONE"))
        let second = try XCTUnwrap(manager.readableModule(named: "FULLNAMETWO"))
        first.begin()
        second.begin()
        XCTAssertTrue(first.rawEntry().contains("FULL_NAME_ONE_BACKEND"))
        XCTAssertTrue(second.rawEntry().contains("FULL_NAME_TWO_BACKEND"))
        XCTAssertNil(manager.module(named: "Shared exact full name"))
        XCTAssertNil(manager.readableModule(named: "Shared exact full name"))
        XCTAssertEqual(
            manager.moduleAccessState(named: "Shared exact full name"),
            .unavailable
        )
    }

    /**
     Verifies native pre-registration applies JSword metadata HashSet equality before BookSet order.

     - Setup: Installs two real configs with exact-equal category, initials, and full name but distinct
       abbreviations/backends.
     - Expected result: Inventory exposes one deterministic metadata row, while raw duplicate
       initials keep every content/access path unavailable and both configs unchanged.
     - Side effects: Creates/removes an isolated fixture and reads the two config byte snapshots.
     - Failure meaning: iOS exposes two books Android's `SwordBookDriver` coalesces, or invents unsafe
       content ownership for Android's runtime-undefined HashSet winner.
     */
    func testNativeHashSetEqualBooksCoalesceMetadataAndFailContentOwnershipClosed() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "HASHEQUAL",
                fullName: "Hash-equal name",
                abbreviation: "Zulu",
                dataStem: "hash-equal-zulu",
                entryText: "HASH_EQUAL_ZULU"
            ),
            SwordManagerPlainRawLDDefinition(
                initials: "HASHEQUAL",
                fullName: "Hash-equal name",
                abbreviation: "Alpha",
                dataStem: "hash-equal-alpha",
                entryText: "HASH_EQUAL_ALPHA"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configURLs = [0, 1].map {
            fixture.root.appendingPathComponent("mods.d/identity-\($0).conf")
        }
        let originalConfigs = try configURLs.map { try Data(contentsOf: $0) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))

        XCTAssertEqual(
            manager.installedModules().filter { $0.name == "HASHEQUAL" }.count,
            1
        )
        XCTAssertNil(manager.module(named: "HASHEQUAL"))
        XCTAssertNil(manager.module(named: "Hash-equal name"))
        XCTAssertNil(manager.readableModule(named: "HASHEQUAL"))
        XCTAssertEqual(manager.moduleAccessState(named: "HASHEQUAL"), .unavailable)
        XCTAssertFalse(
            manager.unlockModule(named: "HASHEQUAL", withCipherKey: "must-not-persist")
        )
        XCTAssertEqual(try configURLs.map { try Data(contentsOf: $0) }, originalConfigs)
    }

    /**
     Verifies native HashSet equality retains metadata-equal books of different concrete classes.

     Pinned `AbstractBook.equals` requires identical runtime classes before comparing metadata. A
     RawLD `SwordDictionary` and RawGenBook `SwordGenBook` may therefore share category, initials,
     and full name while distinct abbreviations keep both in the later TreeSet.

     - Setup: Installs one real RawLD config and one registered RawGenBook config with identical
       HashSet metadata but Alpha/Zulu abbreviations and distinguishable versions.
     - Expected result: Both inventory rows survive in abbreviation order, while their duplicate
       exact initials still fail content ownership closed.
     - Side effects: Creates/removes one isolated SWORD fixture and opens one native manager.
     - Failure meaning: iOS coalesces books JSword retains because concrete class was omitted from
       `AbstractBook` equality, or reintroduces unsafe duplicate-initial backend ownership.
     */
    func testNativeHashSetRetainsCrossClassMetadataEqualBooks() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "CLASSDISTINCT",
                fullName: "Shared cross-class name",
                abbreviation: "Alpha",
                dataStem: "class-dictionary",
                entryText: "CLASS_DICTIONARY_BACKEND"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let genBookDirectory = fixture.root.appendingPathComponent(
            "modules/genbook/rawgenbook/class-genbook",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: genBookDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: genBookDirectory.appendingPathComponent("class-genbook.bdt"))
        try Data().write(to: genBookDirectory.appendingPathComponent("class-genbook.bdx"))
        try """
        [CLASSDISTINCT]
        Description=Shared cross-class name
        Abbreviation=Zulu
        Category=Lexicons / Dictionaries
        ModDrv=RawGenBook
        DataPath=./modules/genbook/rawgenbook/class-genbook/
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        Version=2.0
        """.write(
            to: fixture.root.appendingPathComponent("mods.d/identity-1.conf"),
            atomically: true,
            encoding: .utf8
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))

        let rows = manager.installedModules().filter { $0.name == "CLASSDISTINCT" }
        XCTAssertEqual(rows.map(\.description), [
            "Shared cross-class name",
            "Shared cross-class name",
        ])
        XCTAssertEqual(rows.map(\.version), ["1.0", "2.0"])
        XCTAssertNil(manager.module(named: "CLASSDISTINCT"))
        XCTAssertNil(manager.module(named: "Shared cross-class name"))
        XCTAssertEqual(manager.moduleAccessState(named: "CLASSDISTINCT"), .unavailable)
    }

    /**
     Verifies native lookup reuses one registry capture until explicit refresh invalidates it.

     - Setup: Resolves one real RawLD module, then moves its temporary `mods.d` directory aside.
     - Expected result: A second exact/full-name lookup returns the cached wrapper; after `refresh()`,
       the same lookup is unavailable because the new config snapshot is empty.
     - Side effects: Creates, renames, and removes one isolated native fixture directory.
     - Failure meaning: Each lookup rebuilds the full registry/config projection, restoring O(N²)
       inventory behavior under repeated module resolution.
     */
    func testNativeRegistrySnapshotIsReusedUntilExplicitRefresh() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "CACHED",
                fullName: "Cached full name",
                dataStem: "cached",
                entryText: "CACHED_BACKEND"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let first = try XCTUnwrap(manager.module(named: "CACHED"))
        let originalConfigDirectory = fixture.root.appendingPathComponent("mods.d")
        let movedConfigDirectory = fixture.root.appendingPathComponent("mods.captured")
        try FileManager.default.moveItem(at: originalConfigDirectory, to: movedConfigDirectory)

        let cached = try XCTUnwrap(manager.module(named: "Cached full name"))
        XCTAssertEqual(ObjectIdentifier(cached), ObjectIdentifier(first))
        manager.refresh()
        XCTAssertNil(manager.module(named: "CACHED"))
    }

    /**
     Verifies installed TreeSet projection retains same-initials books with distinct comparator fields.

     - Setup: Installs two real configs with identical initials/abbreviations but distinct full names,
       plus modules that omit Description and Abbreviation.
     - Expected result: Both duplicate-initials metadata rows survive in full-name order, but all
       content and unlock paths reject the runtime-undefined collision without changing either
       config; missing Description falls back to initials and missing abbreviations order by their
       initials fallback.
     - Side effects: Creates and removes one isolated native RawLD fixture.
     - Failure meaning: Inventory still deduplicates by initials, diverges from JSword defaults, or
       exposes one duplicate module through an unproven native-backend/config-owner pairing.
     */
    func testInstalledTreeSetRetainsDistinctSameInitialsAndUsesMetadataFallbacks() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "DUP",
                fullName: "Bravo duplicate",
                abbreviation: "Same",
                dataStem: "duplicate-bravo",
                entryText: "DUPLICATE_BRAVO"
            ),
            SwordManagerPlainRawLDDefinition(
                initials: "DUP",
                fullName: "Alpha duplicate",
                abbreviation: "Same",
                dataStem: "duplicate-alpha",
                entryText: "DUPLICATE_ALPHA"
            ),
            SwordManagerPlainRawLDDefinition(
                initials: "ZuluFallback",
                dataStem: "zulu-fallback",
                entryText: "ZULU_FALLBACK"
            ),
            SwordManagerPlainRawLDDefinition(
                initials: "AlphaFallback",
                dataStem: "alpha-fallback",
                entryText: "ALPHA_FALLBACK"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let installed = manager.installedModules()
        let duplicateConfigURLs = [0, 1].map {
            fixture.root.appendingPathComponent("mods.d/identity-\($0).conf")
        }
        let duplicateConfigsBeforeUnlock = try duplicateConfigURLs.map { try Data(contentsOf: $0) }

        let duplicates = installed.filter {
            SwordJavaStringIdentity.equals($0.name, "DUP")
        }
        XCTAssertEqual(duplicates.map(\.description), ["Alpha duplicate", "Bravo duplicate"])
        XCTAssertNil(manager.module(named: "DUP"))
        XCTAssertNil(manager.module(named: "Alpha duplicate"))
        XCTAssertNil(manager.readableModule(named: "DUP"))
        XCTAssertEqual(manager.moduleAccessState(named: "DUP"), .unavailable)
        XCTAssertFalse(manager.unlockModule(named: "DUP", withCipherKey: "must-not-persist"))
        XCTAssertEqual(
            try duplicateConfigURLs.map { try Data(contentsOf: $0) },
            duplicateConfigsBeforeUnlock
        )
        XCTAssertEqual(
            installed.filter { $0.name.hasSuffix("Fallback") }.map(\.name),
            ["AlphaFallback", "ZuluFallback"]
        )
        XCTAssertEqual(
            installed.first { SwordJavaStringIdentity.equals($0.name, "AlphaFallback") }?
                .description,
            "AlphaFallback"
        )
    }

    /**
     Verifies registration filters cannot erase evidence of a raw duplicate-initial collision.

     - Setup: Installs one supported native RawLD module and one unknown-driver config with the same
       exact initials. Libsword exposes the supported native handle while JSword support filtering
       excludes the second metadata row.
     - Expected result: Supported metadata remains installed, but initials/full-name content access
       and unlock all fail closed and neither raw config changes.
     - Side effects: Creates and removes one isolated native RawLD fixture and an extra config.
     - Failure meaning: Ambiguity is counted after registration filters, allowing a cached native
       wrapper to claim an exact config/backend owner that libsword cannot prove.
     */
    func testFilteredRawDuplicateInitialsStillFailNativeOwnershipClosed() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "FILTEREDDUP",
                fullName: "Supported owner",
                abbreviation: "Supported",
                dataStem: "supported-filtered-duplicate",
                entryText: "SUPPORTED_FILTERED_DUPLICATE"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let filteredConfigURL = fixture.root
            .appendingPathComponent("mods.d/filtered-duplicate.conf")
        try """
        [FILTEREDDUP]
        Description=Filtered duplicate
        Category=Lexicons / Dictionaries
        ModDrv=UnknownDuplicateDriver
        DataPath=./modules/lexdict/rawld/filtered-duplicate/filtered-duplicate
        Lang=en
        Versification=KJV
        """.write(to: filteredConfigURL, atomically: true, encoding: .utf8)
        let configURLs = [
            fixture.root.appendingPathComponent("mods.d/identity-0.conf"),
            filteredConfigURL,
        ]
        let configsBeforeUnlock = try configURLs.map { try Data(contentsOf: $0) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))

        XCTAssertEqual(
            manager.installedModules().filter {
                SwordJavaStringIdentity.equals($0.name, "FILTEREDDUP")
            }.map(\.description),
            ["Supported owner"]
        )
        XCTAssertNil(manager.module(named: "FILTEREDDUP"))
        XCTAssertNil(manager.module(named: "Supported owner"))
        XCTAssertNil(manager.readableModule(named: "FILTEREDDUP"))
        XCTAssertEqual(manager.moduleAccessState(named: "FILTEREDDUP"), .unavailable)
        XCTAssertFalse(
            manager.unlockModule(named: "FILTEREDDUP", withCipherKey: "must-not-persist")
        )
        XCTAssertEqual(
            try configURLs.map { try Data(contentsOf: $0) },
            configsBeforeUnlock
        )
    }

    /**
     Verifies a failed replacement key leaves an already-unlocked module and its durable key intact.

     - Setup: Builds a native encrypted RawLD fixture, persists its correct key before manager
       creation, and proves the live module can decrypt the entry.
     - Expected result: A wrong candidate fails structural validation in an isolated manager while
       the original config bytes and live-manager plaintext remain unchanged.
     - Side effects: Creates and removes a temporary SWORD root; no shared module state is touched.
     - Failure meaning: Retrying unlock can replace a working key before validation or leave the
       current reader poisoned by a failed candidate.
     */
    func testEncryptedRawLDFailedReplacementRestoresExistingKeyAndReadableSession() throws {
        let fixture = try makeEncryptedRawLDFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var persistedConfiguration = try String(contentsOf: fixture.configURL, encoding: .utf8)
        persistedConfiguration = persistedConfiguration.replacingOccurrences(
            of: "CipherKey=",
            with: "CipherKey=\(fixture.cipherKey)"
        )
        try persistedConfiguration.write(
            to: fixture.configURL,
            atomically: true,
            encoding: .utf8
        )
        let originalConfig = try Data(contentsOf: fixture.configURL)
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let module = try XCTUnwrap(manager.module(named: "LOCKED"))
        module.begin()
        XCTAssertTrue(module.rawEntry().contains("Encrypted dictionary entry"))

        XCTAssertFalse(manager.unlockModule(named: "LOCKED", withCipherKey: "wrong-test-key"))

        XCTAssertEqual(try Data(contentsOf: fixture.configURL), originalConfig)
        module.begin()
        XCTAssertTrue(module.rawEntry().contains("Encrypted dictionary entry"))
        XCTAssertTrue(
            manager.installedModules().first { $0.name == "LOCKED" }?.isUnlocked ?? false
        )
    }

    /**
     Verifies direct verified-key persistence invalidates libsword's aggregate config cache.

     - Setup: Writes one locked config plus a stale `modules-conf.cache` snapshot without creating a
       native manager.
     - Expected result: The exact key survives config reload and the aggregate cache is absent so a
       later manager must rebuild it from the updated module config.
     - Side effects: Creates and removes one temporary config directory.
     - Failure meaning: A picker unlock can persist only metadata while a relaunched native manager
       continues reading the old blank `CipherKey` from cache.
     */
    func testPersistVerifiedCipherKeySurvivesConfigReload() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let configURL = configDirectory.appendingPathComponent("locked.conf")
        try """
        [LOCKED]
        ModDrv=RawText
        DataPath=./modules/texts/rawtext/locked/
        CipherKey=
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let cacheURL = configDirectory.appendingPathComponent("modules-conf.cache")
        try Data("[LOCKED]\nCipherKey=\n".utf8).write(to: cacheURL)

        XCTAssertTrue(
            SwordManager.persistVerifiedCipherKey(
                "secret-key",
                moduleName: "locked",
                modulePath: moduleRoot.path
            )
        )

        let reloaded = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(reloaded.contains("CipherKey=secret-key"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    /**
     Verifies config persistence owns one exact case-distinct section and rejects ambiguous aliases.

     - Setup: Writes separate `FOO` and `foo` configs with independent initial cipher values.
     - Expected result: Mixed-case `FoO` changes neither file; exact `FOO` updates only its owner.
     - Side effects: Creates, stages, and removes an isolated pair of temporary configs.
     - Failure meaning: Unlock persistence can overwrite a different case-distinct installed book.
     */
    func testPersistVerifiedCipherKeyUsesExactOwnerBeforeUniqueCaseAlias() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let uppercaseURL = configDirectory.appendingPathComponent("upper.conf")
        let lowercaseURL = configDirectory.appendingPathComponent("lower.conf")
        try """
        [FOO]
        ModDrv=RawText
        DataPath=./modules/texts/rawtext/upper/
        CipherKey=upper-original
        """.write(to: uppercaseURL, atomically: true, encoding: .utf8)
        try """
        [foo]
        ModDrv=RawText
        DataPath=./modules/texts/rawtext/lower/
        CipherKey=lower-original
        """.write(to: lowercaseURL, atomically: true, encoding: .utf8)
        let originalUppercase = try Data(contentsOf: uppercaseURL)
        let originalLowercase = try Data(contentsOf: lowercaseURL)

        XCTAssertFalse(
            SwordManager.persistVerifiedCipherKey(
                "ambiguous-key",
                moduleName: "FoO",
                modulePath: moduleRoot.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: uppercaseURL), originalUppercase)
        XCTAssertEqual(try Data(contentsOf: lowercaseURL), originalLowercase)

        XCTAssertTrue(
            SwordManager.persistVerifiedCipherKey(
                "upper-replacement",
                moduleName: "FOO",
                modulePath: moduleRoot.path
            )
        )
        XCTAssertTrue(
            try String(contentsOf: uppercaseURL, encoding: .utf8)
                .contains("CipherKey=upper-replacement")
        )
        XCTAssertEqual(try Data(contentsOf: lowercaseURL), originalLowercase)
    }

    /**
     Verifies duplicate exact initials require the selected registration's concrete config owner.

     - Setup: Writes two configs with the same exact section but independent cipher values.
     - Expected result: Name-only persistence fails closed; supplying the second registration owner
       updates only that file and preserves the first byte-for-byte.
     - Side effects: Stages, publishes, verifies, and removes temporary config files.
     - Failure meaning: Unlock can persist a verified key into a different same-initials book config.
     */
    func testPersistVerifiedCipherKeyUsesResolvedDuplicateExactConfigOwner() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let firstURL = configDirectory.appendingPathComponent("first.conf")
        let secondURL = configDirectory.appendingPathComponent("second.conf")
        try """
        [DUPLICATE]
        Description=First owner
        ModDrv=RawLD
        CipherKey=first-original
        """.write(to: firstURL, atomically: true, encoding: .utf8)
        try """
        [DUPLICATE]
        Description=Second owner
        ModDrv=RawLD
        CipherKey=second-original
        """.write(to: secondURL, atomically: true, encoding: .utf8)
        let originalFirst = try Data(contentsOf: firstURL)
        let originalSecond = try Data(contentsOf: secondURL)

        XCTAssertFalse(
            SwordManager.persistVerifiedCipherKey(
                "ambiguous-key",
                moduleName: "DUPLICATE",
                modulePath: moduleRoot.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: firstURL), originalFirst)
        XCTAssertEqual(try Data(contentsOf: secondURL), originalSecond)

        XCTAssertTrue(
            SwordManager.persistVerifiedCipherKey(
                "selected-owner-key",
                moduleName: "DUPLICATE",
                modulePath: moduleRoot.path,
                owningConfigURL: secondURL
            )
        )
        XCTAssertEqual(try Data(contentsOf: firstURL), originalFirst)
        XCTAssertTrue(
            try String(contentsOf: secondURL, encoding: .utf8)
                .contains("CipherKey=selected-owner-key")
        )
    }

    /**
     Verifies failed cipher-key read-back restores both sides of the persistence transaction.

     - Setup: Writes a locked config and stale aggregate cache, then injects a publisher that first
       observes cache removal and atomically replaces the real config with invalid bytes.
     - Expected result: Staging succeeds, persistence fails real-config read-back, and config plus
       cache bytes exactly match their pre-mutation snapshots.
     - Side effects: Creates and removes one temporary config directory.
     - Failure meaning: Cache invalidation can escape rollback after a config write fails
       verification, leaving restart behavior different even though unlock reported failure.
     */
    func testPersistVerifiedCipherKeyRestoresConfigAndCacheAfterReadBackFailure() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let configURL = configDirectory.appendingPathComponent("locked.conf")
        try """
        [LOCKED]
        ModDrv=RawText
        DataPath=./modules/texts/rawtext/locked/
        CipherKey=original-key
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let cacheURL = configDirectory.appendingPathComponent("modules-conf.cache")
        try Data("[LOCKED]\nCipherKey=original-key\n".utf8).write(to: cacheURL)
        let originalConfig = try Data(contentsOf: configURL)
        let originalCache = try Data(contentsOf: cacheURL)
        var didPublishAfterCacheRemoval = false

        XCTAssertFalse(
            SwordManager.persistVerifiedCipherKey(
                "replacement-key",
                moduleName: "locked",
                modulePath: moduleRoot.path,
                publishVerifiedConfig: { verifiedData, destinationURL in
                    didPublishAfterCacheRemoval = !FileManager.default.fileExists(
                        atPath: cacheURL.path
                    )
                    XCTAssertTrue(
                        String(decoding: verifiedData, as: UTF8.self)
                            .contains("CipherKey=replacement-key")
                    )
                    try Data("invalid published config".utf8).write(
                        to: destinationURL,
                        options: .atomic
                    )
                }
            )
        )
        XCTAssertTrue(didPublishAfterCacheRemoval)
        XCTAssertEqual(try Data(contentsOf: configURL), originalConfig)
        XCTAssertEqual(try Data(contentsOf: cacheURL), originalCache)
    }

    func testDefaultModulePath() {
        let path = SwordManager.defaultModulePath()
        XCTAssertTrue(path.contains("sword"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testModuleInfoCreation() {
        let info = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            version: "2.3",
            features: [.strongsNumbers, .redLetterWords]
        )
        XCTAssertEqual(info.name, "KJV")
        XCTAssertEqual(info.id, "KJV")
        XCTAssertEqual(info.category, .bible)
        XCTAssertTrue(info.features.contains(.strongsNumbers))
        XCTAssertFalse(info.features.contains(.morphology))
        XCTAssertFalse(info.isEncrypted)
        XCTAssertTrue(info.isUnlocked)
    }

    /**
     Verifies installed module rows retain Android `CommonUtils.showAbout` metadata from SWORD config.

     JSword reloads `SwordBookMetaData` before opening About and exposes fields such as `About`,
     copyright, version history, versification, OSIS ID, bad-document state, and version date. iOS must
     project those config values into `ModuleInfo` so reader-picker and Downloads About dialogs show
     real metadata instead of iOS-only substitutes.
     */
    func testSwordModuleConfigProjectsAndroidAboutMetadataIntoModuleInfo() throws {
        let config = try XCTUnwrap(SwordModuleConfig.parse("""
        [TEST]
        Description=Test Bible
        Category=Biblical Texts
        ModDrv=zText
        Lang=en
        Version=2.0
        SwordVersionDate=2024-01-02
        About=First line\\par Second line
        ShortPromo=Short promo
        ShortCopyright=Short copyright
        Copyright=Long copyright
        DistributionLicense=GPL
        UnlockInfo=Request a key
        History_1.0=First release
        History_2.0=Second release
        Versification=KJVA
        BadDocument=true
        """))

        let info = config.moduleInfo

        XCTAssertEqual(info.aboutMetadata.about, "First line\\par Second line")
        XCTAssertEqual(info.aboutMetadata.shortPromo, "Short promo")
        XCTAssertEqual(info.aboutMetadata.shortCopyright, "Short copyright")
        XCTAssertEqual(info.aboutMetadata.copyright, "Long copyright")
        XCTAssertEqual(info.aboutMetadata.distributionLicense, "GPL")
        XCTAssertEqual(info.aboutMetadata.unlockInfo, "Request a key")
        XCTAssertEqual(info.aboutMetadata.history, ["1.0 First release", "2.0 Second release"])
        XCTAssertEqual(info.aboutMetadata.versification, "KJVA")
        XCTAssertEqual(info.aboutMetadata.osisId, "TEST")
        XCTAssertTrue(info.aboutMetadata.isBadDocument)
        XCTAssertEqual(info.aboutMetadata.swordVersionDate, "2024-01-02")
    }

    /**
     Verifies a versionless config defaults to JSword's `1.0` on parse.

     Android reads `Version` through `SwordBookMetaData`, which defaults a missing value to `1.0`
     on both the catalog and installed sides. Failure means modules without a `Version` line (for
     example BDBT) permanently report an update because an empty installed version can never equal
     the catalog value.
     */
    func testConfigWithoutVersionDefaultsToJSwordOneDotZero() throws {
        let config = try XCTUnwrap(SwordModuleConfig.parse("""
        [BDBT]
        DataPath=./modules/texts/MyBible/BDBT/
        ModDrv=MyBibleDictionary
        """))
        XCTAssertEqual(config.version, "1.0")

        let versioned = try XCTUnwrap(SwordModuleConfig.parse("""
        [KJV]
        DataPath=./modules/texts/ztext/kjv/
        ModDrv=zText
        Version=2.3
        """))
        XCTAssertEqual(versioned.version, "2.3")
    }

    /**
     Verifies config parsing follows pinned JSword BOM, trim, continuation, and name defaults.

     - Setup: Parses BOM-prefixed metadata with a continued description, NBSP-surrounded value,
       missing Description, and deliberately empty Description variants.
     - Expected result: BOM is removed, Java `trim()` preserves NBSP, continuation inserts one
       newline, absent Description falls back to initials, and present empty Description stays empty.
     - Side effects: Parses bounded in-memory strings only.
     - Failure meaning: Valid JSword configs can disappear or change BookSet identity/order on iOS.
     */
    func testSwordModuleConfigParseUsesPinnedJavaIniSemantics() throws {
        let parsed = try XCTUnwrap(SwordModuleConfig.parse("""
        \u{FEFF}[BOMBOOK]
        Description=First line \\
          Second line
        Abbreviation=\u{00A0}NBSP\u{00A0}
        ; Java treats semicolon as a comment.
        ModDrv=RawLD
        """))

        XCTAssertEqual(parsed.name, "BOMBOOK")
        XCTAssertEqual(parsed.description, "First line\nSecond line")
        XCTAssertEqual(parsed.values["Abbreviation"]?.first, "\u{00A0}NBSP\u{00A0}")
        XCTAssertNil(parsed.sourceURL)

        let missingDescription = try XCTUnwrap(SwordModuleConfig.parse("""
        [MISSING]
        ModDrv=RawLD
        """))
        XCTAssertEqual(missingDescription.description, "MISSING")

        let emptyDescription = try XCTUnwrap(SwordModuleConfig.parse("""
        [EMPTY]
        Description=
        ModDrv=RawLD
        """))
        XCTAssertEqual(emptyDescription.description, "")
    }

    /**
     Verifies config files follow JSword's exact-key encoding reload policy.

     - Setup: Writes the same valid UTF-8 bytes with canonical UTF-8, missing, and wrong-case
       `Encoding` keys, plus native Windows-1252, malformed-declared-UTF-8, and undefined-CP1252
       physical byte fixtures.
     - Expected result: Only exact `Encoding=UTF-8` preserves the UTF-8 description; missing and
       wrong-case keys reinterpret original bytes as Windows-1252, while both Java decoders replace
       malformed/undefined input with U+FFFD and continue parsing the config.
     - Side effects: Creates, reads, and removes one isolated temporary `mods.d` directory.
     - Failure meaning: iOS retains a UTF-8 parse JSword discards or normalizes case-sensitive keys.
     */
    func testSwordModuleConfigReadUsesExactEncodingKeyAndWindows1252Reload() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        let canonicalURL = configDirectory.appendingPathComponent("canonical.conf")
        let missingURL = configDirectory.appendingPathComponent("missing.conf")
        let wrongCaseURL = configDirectory.appendingPathComponent("wrong-case.conf")
        let windowsURL = configDirectory.appendingPathComponent("windows.conf")
        let malformedUTF8URL = configDirectory.appendingPathComponent("malformed-utf8.conf")
        let undefinedWindowsURL = configDirectory.appendingPathComponent("undefined-windows.conf")
        try Data("[UTF8]\nDescription=Café\nModDrv=RawLD\nEncoding=UTF-8\n".utf8)
            .write(to: canonicalURL)
        try Data("[MISSINGENC]\nDescription=Café\nModDrv=RawLD\n".utf8)
            .write(to: missingURL)
        try Data("[WRONGCASE]\nDescription=Café\nModDrv=RawLD\nencoding=UTF-8\n".utf8)
            .write(to: wrongCaseURL)
        var windowsBytes = Data("[WINDOWS]\nDescription=Caf".utf8)
        windowsBytes.append(0xE9)
        windowsBytes.append(contentsOf: Data("\nModDrv=RawLD\nEncoding=Latin-1\n".utf8))
        try windowsBytes.write(to: windowsURL)
        var malformedUTF8Bytes = Data("[MALFORMEDUTF8]\nDescription=Bad".utf8)
        malformedUTF8Bytes.append(contentsOf: [0xC3, 0x28])
        malformedUTF8Bytes.append(
            contentsOf: Data("\nModDrv=RawLD\nEncoding=UTF-8\n".utf8)
        )
        try malformedUTF8Bytes.write(to: malformedUTF8URL)
        var undefinedWindowsBytes = Data("[UNDEFINEDWINDOWS]\nDescription=Bad".utf8)
        undefinedWindowsBytes.append(0x81)
        undefinedWindowsBytes.append(
            contentsOf: Data("\nModDrv=RawLD\nEncoding=Latin-1\n".utf8)
        )
        try undefinedWindowsBytes.write(to: undefinedWindowsURL)

        XCTAssertEqual(SwordModuleConfig.read(url: canonicalURL)?.description, "Café")
        XCTAssertEqual(SwordModuleConfig.read(url: missingURL)?.description, "CafÃ©")
        XCTAssertEqual(SwordModuleConfig.read(url: wrongCaseURL)?.description, "CafÃ©")
        XCTAssertEqual(SwordModuleConfig.read(url: windowsURL)?.description, "Café")
        XCTAssertEqual(SwordModuleConfig.read(url: malformedUTF8URL)?.description, "Bad\u{FFFD}(")
        XCTAssertEqual(SwordModuleConfig.read(url: undefinedWindowsURL)?.description, "Bad\u{FFFD}")
        XCTAssertNil(SwordModuleConfig.read(url: wrongCaseURL)?.values["Encoding"])
        XCTAssertEqual(
            SwordModuleConfig.read(url: wrongCaseURL)?.values["encoding"]?.first,
            "UTF-8"
        )
    }

    /**
     Verifies JSword config properties remain exact-case keys instead of a lowercase dictionary.

     - Setup: Parses wrong-case metadata beside the one canonical `ModDrv` required for admission.
     - Expected result: Wrong-case Description/Category/Lang stay accessible only under their exact
       spellings and do not change canonical metadata defaults.
     - Side effects: Parses one bounded in-memory config string.
     - Failure meaning: iOS accepts metadata JSword callers cannot retrieve from `IniSection`.
     */
    func testSwordModuleConfigPropertiesRemainCaseSensitive() throws {
        let config = try XCTUnwrap(SwordModuleConfig.parse("""
        [CASEKEYS]
        description=Wrong-case description
        category=Commentaries
        lang=fr
        ModDrv=RawLD
        """))

        XCTAssertEqual(config.description, "CASEKEYS")
        XCTAssertEqual(config.category, .dictionary)
        XCTAssertEqual(config.language, "en")
        XCTAssertEqual(config.values["description"]?.first, "Wrong-case description")
        XCTAssertNil(config.values["Description"])
        XCTAssertNil(SwordModuleConfig.parse("[REJECTED]\nmoddrv=RawLD\n"))
    }

    /**
     Verifies config discovery preserves JSword's unsorted platform directory enumeration.

     - Setup: Writes valid case- and normalization-distinct configs plus malformed/non-config files,
       then independently captures `FileManager`'s filtered parseable URL sequence.
     - Expected result: `readAll` returns exact UTF-16 section identities in that captured sequence;
       public manager ordering is tested separately through the pinned JSword TreeSet comparator.
     - Side effects: Creates, enumerates, reads, and removes one temporary `mods.d` directory.
     - Failure meaning: A host-locale or initials sort has changed JSword driver registration order.
     */
    func testSwordModuleConfigReadAllPreservesPlatformDirectoryEnumeration() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        let eligibleFileNames = ["z-last.conf", "a-first.conf", ".hidden.conf"]
        for fileName in eligibleFileNames {
            try """
            [PLACEHOLDER]
            Description=\(fileName)
            ModDrv=RawLD
            """.write(
                to: configDirectory.appendingPathComponent(fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        try """
        [UPPERCASE_SUFFIX]
        Description=Uppercase suffix is not accepted by Java's filter
        ModDrv=RawLD
        """.write(
            to: configDirectory.appendingPathComponent("middle.CONF"),
            atomically: true,
            encoding: .utf8
        )
        try "malformed".write(
            to: configDirectory.appendingPathComponent("malformed.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [IGNORED_GLOBALS]
        Description=JSword globals prefix is not a book
        ModDrv=RawLD
        """.write(
            to: configDirectory.appendingPathComponent("globals.synthetic.conf"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored".write(
            to: configDirectory.appendingPathComponent("ignored.txt"),
            atomically: true,
            encoding: .utf8
        )

        let enumeratedURLs = try FileManager.default.contentsOfDirectory(
            at: configDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        let parseableURLs = enumeratedURLs.filter {
            $0.lastPathComponent.hasSuffix(".conf")
                && !$0.lastPathComponent.hasPrefix("globals.")
                && $0.lastPathComponent != "malformed.conf"
        }
        let reverseOrderedNames = parseableURLs.indices.map {
            String(format: "ORDER%04d", parseableURLs.count - $0)
        }
        for (url, initials) in zip(parseableURLs, reverseOrderedNames) {
            try """
            [\(initials)]
            Description=\(url.lastPathComponent)
            ModDrv=RawLD
            """.write(to: url, atomically: true, encoding: .utf8)
        }
        let configs = SwordModuleConfig.readAll(modulePath: moduleRoot.path)
        let expectedIdentities = reverseOrderedNames.map(SwordJavaExactStringIdentity.init)
        let actualIdentities = configs.map { SwordJavaExactStringIdentity($0.name) }

        XCTAssertEqual(actualIdentities, expectedIdentities)
        XCTAssertEqual(configs.compactMap(\.sourceURL), parseableURLs)
        XCTAssertTrue(configs.contains { $0.sourceURL?.lastPathComponent == ".hidden.conf" })
        XCTAssertFalse(configs.contains { $0.name == "UPPERCASE_SUFFIX" })
        XCTAssertFalse(configs.contains { $0.name == "IGNORED_GLOBALS" })
        XCTAssertNotEqual(reverseOrderedNames, reverseOrderedNames.sorted())
    }

    /**
     Verifies config-by-name lookup uses exact section identity instead of a lowercased filename.

     - Setup: Writes case-distinct `FOO` and `foo` sections under unrelated filenames.
     - Expected result: Each exact name returns its own description; mixed-case `FoO` is ambiguous.
     - Side effects: Creates, enumerates, reads, and removes one temporary config directory.
     - Failure meaning: Module construction can attach another case-distinct book's metadata.
     */
    func testSwordModuleConfigReadUsesExactSectionBeforeCaseAlias() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        try """
        [FOO]
        Description=Upper exact metadata
        ModDrv=RawLD
        """.write(
            to: configDirectory.appendingPathComponent("first-arbitrary.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [foo]
        Description=Lower exact metadata
        ModDrv=RawLD
        """.write(
            to: configDirectory.appendingPathComponent("second-arbitrary.conf"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            SwordModuleConfig.read(name: "FOO", modulePath: moduleRoot.path)?.description,
            "Upper exact metadata"
        )
        XCTAssertEqual(
            SwordModuleConfig.read(name: "foo", modulePath: moduleRoot.path)?.description,
            "Lower exact metadata"
        )
        XCTAssertNil(SwordModuleConfig.read(name: "FoO", modulePath: moduleRoot.path))
    }

    func testRemoteModuleInfoDefaultsToInstallable() {
        let info = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire"
        )

        XCTAssertTrue(info.isInstallable)
        XCTAssertEqual(info.availability, .installable)
        XCTAssertNil(info.unavailableReason)
        XCTAssertEqual(info.version, "")
        XCTAssertNil(info.installSizeBytes)
    }

    func testPseudoBookMetadataCreatesUnavailableModules() throws {
        let data = """
        [
          {"id": "ESV", "suggested": "Please contact the copyright holder."},
          {"id": "NIV", "suggested": ""}
        ]
        """.data(using: .utf8)!

        let modules = try ModuleRepository.pseudoModules(from: data)

        XCTAssertEqual(modules.map(\.name), ["ESV", "NIV"])
        XCTAssertEqual(modules.map(\.sourceName), ["Not Available", "Not Available"])
        XCTAssertTrue(modules.allSatisfy { !$0.isInstallable })
        XCTAssertTrue(modules.allSatisfy { $0.category == .bible })
        XCTAssertTrue(modules.allSatisfy { $0.language == "en" })
        XCTAssertTrue(modules[0].description.contains("not available due to Copyright Holder"))
        XCTAssertTrue(modules[0].description.contains("Please contact the copyright holder."))
        XCTAssertEqual(modules[0].unavailableReason, modules[0].description)
    }

    func testMalformedPseudoBookRefreshDoesNotOverwriteCachedMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validData = """
        [
          {"id": "ESV", "suggested": "Please contact the copyright holder."}
        ]
        """.data(using: .utf8)!
        let malformedData = Data("<html>temporary failure</html>".utf8)
        var responseBodies = [validData, malformedData]

        PseudoBooksMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseBodies.removeFirst())
        }
        defer { PseudoBooksMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: Self.makePseudoBooksMockSession()
        )

        let refreshedModules = try await repository.refreshPseudoModules()
        XCTAssertEqual(refreshedModules.map(\.name), ["ESV"])
        XCTAssertEqual(repository.loadCachedPseudoModules().map(\.name), ["ESV"])

        do {
            _ = try await repository.refreshPseudoModules()
            XCTFail("Expected malformed pseudo book metadata to fail decoding.")
        } catch {
            XCTAssertEqual(repository.loadCachedPseudoModules().map(\.name), ["ESV"])
        }
    }

    /**
     Verifies recommended-document refresh failures preserve the last valid Android metadata cache.

     Downloads and startup default-module selection rely on this cache when GitHub-hosted metadata is
     malformed or temporarily unavailable. A failure means a transient server problem can erase the
     Android-compatible recommendation state even though the prior cache is still valid.
     */
    func testRecommendedDocumentRefreshPreservesCachedMetadataAfterFailures() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validData = """
        {
          "bibles": {"en": ["KJV::CrossWire"]},
          "commentaries": {},
          "dictionaries": {},
          "books": {},
          "maps": {}
        }
        """.data(using: .utf8)!
        let malformedData = Data("<html>temporary failure</html>".utf8)
        var responses = [
            (statusCode: 200, data: validData),
            (statusCode: 200, data: malformedData),
            (statusCode: 500, data: Data("temporary failure".utf8))
        ]

        PseudoBooksMockURLProtocol.requestHandler = { request in
            let responsePayload = responses.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: responsePayload.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responsePayload.data)
        }
        defer { PseudoBooksMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: Self.makePseudoBooksMockSession()
        )

        let refreshedMetadata = try await repository.refreshRecommendedDocuments()
        XCTAssertEqual(refreshedMetadata.bibles["en"], ["KJV::CrossWire"])
        XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])

        do {
            _ = try await repository.refreshRecommendedDocuments()
            XCTFail("Expected malformed recommended-document metadata to fail decoding.")
        } catch {
            XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])
        }

        do {
            _ = try await repository.refreshRecommendedDocuments()
            XCTFail("Expected non-200 recommended-document metadata to fail downloading.")
        } catch {
            XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])
        }
    }

    func testDefaultInstallManagerConfigIncludesAndBibleSources() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)

        let configPath = tempDir.appendingPathComponent("InstallMgr.conf")
        let config = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(config.contains("HTTPSource=AndBible|andbible.github.io|/data/andbible"))
        XCTAssertTrue(config.contains("HTTPSource=AndBible Beta|andbible.github.io|/data/andbible/beta"))
    }

    func testLegacyInstallManagerConfigMigratesAndBibleSourcesOnce() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("InstallMgr.conf")
        try """
        [General]
        PassiveFTP=true

        [Sources]
        HTTPSource=CrossWire|crosswire.org|/ftpmirror/pub/sword/raw
        HTTPSource=AndBible Extra|andbible.github.io|/andbible-extra
        """.write(to: configPath, atomically: true, encoding: .utf8)

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)

        let migrated = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(migrated.contains("HTTPSource=AndBible|andbible.github.io|/data/andbible"))
        XCTAssertTrue(migrated.contains("HTTPSource=AndBible Beta|andbible.github.io|/data/andbible/beta"))

        let withoutAndBible = migrated
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("HTTPSource=AndBible|") }
            .joined(separator: "\n")
        try withoutAndBible.write(to: configPath, atomically: true, encoding: .utf8)

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)

        let afterUserDeletion = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertFalse(afterUserDeletion.contains("HTTPSource=AndBible|andbible.github.io|/data/andbible"))
        XCTAssertTrue(afterUserDeletion.contains("HTTPSource=AndBible Beta|andbible.github.io|/data/andbible/beta"))
    }

    func testModuleCategoryInit() {
        XCTAssertEqual(ModuleCategory(typeString: "Biblical Texts"), .bible)
        XCTAssertEqual(ModuleCategory(typeString: "Commentaries"), .commentary)
        XCTAssertEqual(ModuleCategory(typeString: "And Bible"), .addon)
        XCTAssertEqual(
            ModuleCategory(typeString: "Cults / Unorthodox / Questionable Material"),
            .questionable
        )
        XCTAssertEqual(ModuleCategory(typeString: "Questionable"), .unknown)
        XCTAssertEqual(ModuleCategory(typeString: "Unknown Type"), .unknown)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "MyBibleBible"), .bible)
        XCTAssertEqual(ModuleCategory(typeString: "Unknown", modDrv: "MyBibleDictionary"), .dictionary)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "MyBibleCommentary"), .commentary)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "MySwordDictionary"), .dictionary)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "ESwordBible"), .bible)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "RawLD4"), .dictionary)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "RawGenBook"), .generalBook)
    }

    /**
     Verifies restored Android custom-driver configs participate in shared installed inventory.

     Android registers `MyBibleDictionary` as a JSword dictionary `BookType`, so restored BDBT-style
     configs must appear as dictionaries even when their `Category=` line is absent or `Unknown`.

     - Setup: Writes a minimal `mods.d` config plus readable `module.SQLite3` payload.
     - Expected result: `installedModules()` and category filtering both expose the dictionary row.
     - Failure meaning: Reader/settings/download filters are likely hiding restored Android modules.
     */
    func testInstalledModulesIncludesRestoredAndroidMyBibleDictionary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        let moduleDir = swordDir
            .appendingPathComponent("modules/texts/MyBible/BDBT", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        [BDBT]
        Description=Brown-Driver-Briggs' Hebrew Definitions / Thayer's Greek Definitions
        Category=Unknown
        DataPath=./modules/texts/MyBible/BDBT/
        ModDrv=MyBibleDictionary
        Lang=en
        Feature=GreekDef
        Feature=HebrewDef
        """.write(
            to: modsDir.appendingPathComponent("bdbt.conf"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: moduleDir.appendingPathComponent("module.SQLite3"))

        let manager = try XCTUnwrap(SwordManager(modulePath: swordDir.path))
        let modules = manager.installedModules()
        let bdbt = try XCTUnwrap(modules.first { $0.name == "BDBT" })

        XCTAssertEqual(bdbt.category, .dictionary)
        XCTAssertEqual(bdbt.language, "en")
        XCTAssertEqual(bdbt.moduleDriver, "MyBibleDictionary")
        XCTAssertTrue(bdbt.features.contains(.greekDef))
        XCTAssertTrue(bdbt.features.contains(.hebrewDef))
        XCTAssertTrue(manager.installedModules(category: .dictionary).contains { $0.name == "BDBT" })
    }

    /**
     Verifies both installed-book APIs reject the same malformed metadata JSword excludes.

     - Setup: Writes a real RawLD payload referenced by three configs: one known driver with an
       unknown versification, one unknown driver, and one missing `ModDrv`.
     - Expected result: Neither enumeration nor direct name lookup exposes any invalid module.
     - Failure meaning: A malformed non-Bible module can enter iOS pickers or Downloads despite being
       absent from Android's `Books.installed()` registry.
     - Side effects: Creates and removes one isolated temporary SWORD root.
     */
    func testInstalledBookAPIsRejectUnknownDriverAndVersificationMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modsDir = tempDir.appendingPathComponent("mods.d", isDirectory: true)
        let dataDir = tempDir.appendingPathComponent(
            "modules/lexdict/rawld/invalid",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let record = Data("entry\r\nvalue".utf8)
        let recordSize = UInt16(record.count)
        try (record + Data([0x0A])).write(to: dataDir.appendingPathComponent("invalid.dat"))
        try Data([
            0x00, 0x00, 0x00, 0x00,
            UInt8(recordSize & 0x00FF), UInt8(recordSize >> 8),
        ]).write(to: dataDir.appendingPathComponent("invalid.idx"))

        let sharedConfig = """
        Description=Invalid Dictionary
        Category=Lexicons / Dictionaries
        DataPath=./modules/lexdict/rawld/invalid/invalid
        Lang=en
        """
        try """
        [UNKNOWNV11N]
        \(sharedConfig)
        ModDrv=RawLD
        Versification=NotAVersification
        """.write(
            to: modsDir.appendingPathComponent("unknownv11n.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [UNKNOWNDRIVER]
        \(sharedConfig)
        ModDrv=MadeUpDictionary
        """.write(
            to: modsDir.appendingPathComponent("unknowndriver.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [MISSINGDRIVER]
        \(sharedConfig)
        """.write(
            to: modsDir.appendingPathComponent("missingdriver.conf"),
            atomically: true,
            encoding: .utf8
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: tempDir.path))
        let invalidNames = Set(["UNKNOWNV11N", "UNKNOWNDRIVER", "MISSINGDRIVER"])

        XCTAssertTrue(invalidNames.isDisjoint(with: manager.installedModules().map(\.name)))
        for name in invalidNames {
            XCTAssertNil(manager.module(named: name), "Expected \(name) to fail closed")
        }
    }

    /**
     Verifies Android custom-driver configs cannot escape the SWORD install root.

     Restored Android configs should describe payloads unpacked into the local module tree. A
     readable SQLite file elsewhere on disk must not become visible through installed inventory just
     because a config path points to it.

     - Setup: Writes a `MyBibleDictionary` row with an absolute external `DataPath`.
     - Expected result: `installedModules()` ignores the row.
     - Failure meaning: Inventory parity is being achieved by trusting unsafe metadata rather than by
       restoring Android modules into the same local module contract.
     */
    func testInstalledModulesRejectsCustomPayloadOutsideSwordRoot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        let externalModuleDir = tempDir
            .appendingPathComponent("outside", isDirectory: true)
            .appendingPathComponent("BDBT", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalModuleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        [BDBT]
        Description=Brown-Driver-Briggs' Hebrew Definitions / Thayer's Greek Definitions
        Category=Unknown
        DataPath=\(externalModuleDir.path)
        ModDrv=MyBibleDictionary
        Lang=en
        """.write(
            to: modsDir.appendingPathComponent("bdbt.conf"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: externalModuleDir.appendingPathComponent("module.SQLite3"))

        let manager = try XCTUnwrap(SwordManager(modulePath: swordDir.path))

        XCTAssertFalse(manager.installedModules().contains { $0.name == "BDBT" })
    }

    /**
     Verifies installed And Bible add-on modules expose Android-compatible reading-plan providers.

     Android's `AndBibleAddons.providedReadingPlans` reads repeated
     `AndBibleProvidesReadingPlan` config values, resolves those files relative to the installed
     book location, and carries `AndBibleReadingPlanDateBased`, `Versification`, and `ShortPromo`
     metadata into `ReadingPlanTextFileDao`. This test writes a minimal add-on config plus one
     readable `.properties` file under the SWORD root. The expected result proves iOS can discover
     the same provider contract while ignoring unsafe or missing provider entries.
     */
    func testReadingPlanProvidersExposeReadableAddonPlansAndMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        let addonDir = swordDir
            .appendingPathComponent("modules/genbook/rawgenbook/planaddon", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: addonDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        # Add-on plan
        Versification=NRSVA
        1=Matt.1
        """.write(
            to: addonDir.appendingPathComponent("addon_plan.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [PLANADDON]
        Description=Add-on Reading Plans
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./modules/genbook/rawgenbook/planaddon/
        Lang=en
        ShortPromo=Plans supplied by an add-on module.
        Versification=NRSVA
        AndBibleMinimumVersion=1112
        AndBibleMinimumVersion=9999
        AndBibleReadingPlanDateBased=True
        AndBibleProvidesReadingPlan=addon_plan.properties
        AndBibleProvidesReadingPlan=missing.properties
        AndBibleProvidesReadingPlan=../escape.properties
        """.write(
            to: modsDir.appendingPathComponent("planaddon.conf"),
            atomically: true,
            encoding: .utf8
        )

        let providers = SwordManager.readingPlanProviders(
            modulePath: swordDir.path,
            applicationVersionNumber: 1112
        )

        XCTAssertEqual(providers.map(\.planCode), ["addon_plan"])
        let provider = try XCTUnwrap(providers.first)
        XCTAssertEqual(provider.name, "Add-on Reading Plans")
        XCTAssertEqual(provider.description, "Plans supplied by an add-on module.")
        XCTAssertEqual(provider.fileURL, addonDir.appendingPathComponent("addon_plan.properties").standardizedFileURL)
        XCTAssertEqual(provider.versification, "NRSVA")
        XCTAssertTrue(provider.isDateBased)
    }

    /**
     Verifies add-on plan discovery applies Android category, support, and minimum-version admission.

     - Setup: Writes readable providers for a missing-minimum add-on, future add-on, non-add-on,
       malformed-minimum add-on, and unsupported-driver add-on.
     - Expected result: At the shared current-stable compatibility code only the supported
       `And Bible` config whose missing minimum defaults to zero is admitted.
     - Side effects: Creates and removes one isolated SWORD config/provider tree.
     - Failure meaning: iOS exposes plans Android filters out or rejects Android-compatible add-ons.
     */
    func testReadingPlanProvidersApplyAndroidAddonAdmissionGate() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        let definitions: [(String, String, String, String?)] = [
            ("ADMITTED", "And Bible", "RawGenBook", nil),
            (
                "FUTURE",
                "And Bible",
                "RawGenBook",
                String(AndBibleAndroidCompatibility.currentVersionCode + 1)
            ),
            ("WRONGCATEGORY", "Generic Books", "RawGenBook", nil),
            ("MALFORMED", "And Bible", "RawGenBook", "not-a-number"),
            ("UNSUPPORTED", "And Bible", "UnknownDriver", nil),
        ]
        for (index, definition) in definitions.enumerated() {
            let (initials, category, driver, minimumVersion) = definition
            let code = initials.lowercased()
            let providerDirectory = moduleRoot.appendingPathComponent(
                "modules/genbook/rawgenbook/\(code)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: providerDirectory,
                withIntermediateDirectories: true
            )
            try "1=Matt.1\n".write(
                to: providerDirectory.appendingPathComponent("\(code).properties"),
                atomically: true,
                encoding: .utf8
            )
            var lines = [
                "[\(initials)]",
                "Description=\(initials) provider",
                "Category=\(category)",
                "ModDrv=\(driver)",
                "DataPath=./modules/genbook/rawgenbook/\(code)/",
                "AndBibleProvidesReadingPlan=\(code).properties",
            ]
            if let minimumVersion {
                lines.append("AndBibleMinimumVersion=\(minimumVersion)")
            }
            try (lines.joined(separator: "\n") + "\n").write(
                to: configDirectory.appendingPathComponent("admission-\(index).conf"),
                atomically: true,
                encoding: .utf8
            )
        }

        let providers = SwordManager.readingPlanProviders(modulePath: moduleRoot.path)

        XCTAssertEqual(providers.map(\.planCode), ["admitted"])
        XCTAssertEqual(providers.first?.name, "ADMITTED provider")
    }

    /**
     Verifies duplicate reading-plan ownership follows installed BookSet order, not file order.

     - Setup: Writes Zulu-abbreviation config first and Alpha-abbreviation config second under
       oppositely named files; both provide `shared`, while Alpha also provides `alpha_only`.
     - Expected result: Alpha is traversed first, preserving `alpha_only` then `shared` key order;
       later TreeSet book Zulu overwrites only the shared provider value.
     - Side effects: Creates and removes one isolated SWORD config/provider tree.
     - Failure meaning: Directory enumeration changes which add-on owns a duplicate Android plan.
     */
    func testReadingPlanProviderDuplicateOwnerUsesInstalledTreeSetOrder() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        let zuluDirectory = moduleRoot.appendingPathComponent("addons/zulu", isDirectory: true)
        let alphaDirectory = moduleRoot.appendingPathComponent("addons/alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: zuluDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alphaDirectory, withIntermediateDirectories: true)
        try "1=Luke.1\n".write(
            to: zuluDirectory.appendingPathComponent("shared.properties"),
            atomically: true,
            encoding: .utf8
        )
        try "1=Acts.1\n".write(
            to: alphaDirectory.appendingPathComponent("shared.properties"),
            atomically: true,
            encoding: .utf8
        )
        try "1=John.1\n".write(
            to: alphaDirectory.appendingPathComponent("alpha_only.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [ZULUOWNER]
        Description=Zulu owner
        Abbreviation=Zulu
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./addons/zulu/
        AndBibleProvidesReadingPlan=shared.properties
        """.write(
            to: configDirectory.appendingPathComponent("a-zulu.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [ALPHAOWNER]
        Description=Alpha owner
        Abbreviation=Alpha
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./addons/alpha/
        AndBibleProvidesReadingPlan=alpha_only.properties
        AndBibleProvidesReadingPlan=shared.properties
        """.write(
            to: configDirectory.appendingPathComponent("z-alpha.conf"),
            atomically: true,
            encoding: .utf8
        )

        let providers = SwordManager.readingPlanProviders(
            modulePath: moduleRoot.path,
            applicationVersionNumber: 1115
        )

        XCTAssertEqual(providers.map(\.planCode), ["alpha_only", "shared"])
        XCTAssertEqual(providers.last?.name, "Zulu owner")
        XCTAssertEqual(
            providers.last?.fileURL,
            zuluDirectory.appendingPathComponent("shared.properties").standardizedFileURL
        )
    }

    /**
     Verifies add-on projection applies JSword's concrete-class discriminator before TreeSet order.

     `SwordBookDriver` may produce a `SwordDictionary` and `SwordGenBook` with identical category,
     initials, and full name. `AbstractBook.equals` retains both because their classes differ, and
     distinct abbreviations then retain both reading-plan providers in `Books` TreeSet order.

     - Setup: Writes metadata-equal RawLD and RawGenBook add-ons under deterministic opposite config
       paths, with Alpha/Zulu abbreviations and one readable provider per class.
     - Expected result: Both providers survive, ordered by abbreviation rather than config path.
     - Side effects: Creates and removes one isolated SWORD config/provider tree.
     - Failure meaning: Add-on discovery coalesces cross-class books Android retains in its native
       driver HashSet, hiding a valid reading-plan provider.
     */
    func testReadingPlanProvidersRetainCrossClassMetadataEqualAddons() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let dictionaryDirectory = moduleRoot.appendingPathComponent(
            "addons/dictionary",
            isDirectory: true
        )
        let genBookDirectory = moduleRoot.appendingPathComponent(
            "addons/genbook",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dictionaryDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: genBookDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        try "1=Matt.1\n".write(
            to: dictionaryDirectory.appendingPathComponent("dictionary_class.properties"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: dictionaryDirectory.appendingPathComponent("module.dat"))
        try "1=Luke.1\n".write(
            to: genBookDirectory.appendingPathComponent("genbook_class.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [CROSSCLASSPLAN]
        Description=Shared cross-class provider
        Abbreviation=Alpha
        Category=And Bible
        ModDrv=RawLD
        DataPath=./addons/dictionary/module
        Encoding=UTF-8
        Versification=KJV
        AndBibleProvidesReadingPlan=dictionary_class.properties
        """.write(
            to: configDirectory.appendingPathComponent("a-dictionary.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [CROSSCLASSPLAN]
        Description=Shared cross-class provider
        Abbreviation=Zulu
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./addons/genbook/
        Encoding=UTF-8
        Versification=KJV
        AndBibleProvidesReadingPlan=genbook_class.properties
        """.write(
            to: configDirectory.appendingPathComponent("z-genbook.conf"),
            atomically: true,
            encoding: .utf8
        )

        let providers = SwordManager.readingPlanProviders(
            modulePath: moduleRoot.path,
            applicationVersionNumber: 1115
        )

        XCTAssertEqual(providers.map(\.planCode), ["dictionary_class", "genbook_class"])
        XCTAssertEqual(providers.map(\.name), [
            "Shared cross-class provider",
            "Shared cross-class provider",
        ])
    }

    /**
     Verifies the shared add-on feature inventory applies Android admission and TreeSet identity.

     - Setup: Writes supported, duplicate, future, malformed-minimum, and wrong-category configs;
       supported case/NFC-NFD variants; and comparator-equal cross-class compatible/future books in
       deliberately opposite file/order fields.
     - Expected result: Only admitted HashSet-distinct add-ons survive; Java-distinct variants remain
       separate in abbreviation/initials TreeSet order, the first singular prompt property is
       retained, and filtering the future TreeSet owner does not resurrect its compatible sibling.
     - Side effects: Creates, reads, and removes one isolated temporary SWORD config tree.
     - Failure meaning: Prompt, picker, and other add-on consumers can observe different books from
       Android's `AndBibleAddonFilter`/`Books.installed()` projection.
     */
    func testAdmittedAddonModulesShareAndroidAdmissionIdentityAndOrder() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        let composed = "CAF\u{00C9}"
        let decomposed = "CAFE\u{0301}"
        let definitions: [(file: String, initials: String, abbreviation: String, category: String, minimum: String?, prompts: [String])] = [
            ("z-alpha.conf", "ALPHA", "Alpha", "And Bible", nil, ["first.csv", "ignored.csv"]),
            ("zz-alpha-duplicate.conf", "ALPHA", "Zulu duplicate", "And Bible", nil, ["duplicate.csv"]),
            ("a-composed.conf", composed, "Beta", "And Bible", "1115", ["composed.csv"]),
            ("b-decomposed.conf", decomposed, "Beta", "And Bible", "1115", ["decomposed.csv"]),
            ("c-case-upper.conf", "CASE", "Gamma", "And Bible", "1115", ["upper.csv"]),
            ("d-case-lower.conf", "case", "Gamma", "And Bible", "1115", ["lower.csv"]),
            ("future.conf", "FUTURE", "Future", "And Bible", "1116", ["future.csv"]),
            ("malformed.conf", "MALFORMED", "Malformed", "And Bible", "later", ["bad.csv"]),
            ("wrong.conf", "WRONG", "Wrong", "Generic Books", nil, ["wrong.csv"]),
        ]
        for definition in definitions {
            let payloadDirectory = moduleRoot.appendingPathComponent(
                "addons/\(definition.file)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: payloadDirectory,
                withIntermediateDirectories: true
            )
            var lines = [
                "[\(definition.initials)]",
                "Description=\(definition.initials) add-on",
                "Abbreviation=\(definition.abbreviation)",
                "Category=\(definition.category)",
                "ModDrv=RawGenBook",
                "DataPath=./addons/\(definition.file)",
                "Encoding=UTF-8",
            ]
            if let minimum = definition.minimum {
                lines.append("AndBibleMinimumVersion=\(minimum)")
            }
            lines.append(contentsOf: definition.prompts.map { "AndBibleProvidesPrompts=\($0)" })
            try (lines.joined(separator: "\n") + "\n").write(
                to: configDirectory.appendingPathComponent(definition.file),
                atomically: true,
                encoding: .utf8
            )
        }
        try """
        [MISSINGDRIVER]
        Description=Missing driver
        Category=And Bible
        AndBibleProvidesPrompts=missing.csv
        """.write(
            to: configDirectory.appendingPathComponent("missing-driver.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [GHOST]
        Description=Missing payload add-on
        Abbreviation=Ghost
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./addons/missing-payload
        AndBibleProvidesPrompts=ghost.csv
        """.write(
            to: configDirectory.appendingPathComponent("ghost.conf"),
            atomically: true,
            encoding: .utf8
        )
        let rawTextPrefix = moduleRoot.appendingPathComponent("addons/rawtext-prefix")
        try Data().write(to: URL(fileURLWithPath: rawTextPrefix.path + ".dat"))
        try """
        [PREFIXTEXT]
        Description=RawText prefix add-on
        Abbreviation=Epsilon
        Category=And Bible
        ModDrv=RawText
        DataPath=./addons/rawtext-prefix
        AndBibleMinimumVersion=1115
        AndBibleProvidesPrompts=rawtext.csv
        """.write(
            to: configDirectory.appendingPathComponent("rawtext-prefix.conf"),
            atomically: true,
            encoding: .utf8
        )
        let compatibleReplacementDirectory = moduleRoot.appendingPathComponent(
            "addons/replaced-compatible",
            isDirectory: true
        )
        let futureReplacementDirectory = moduleRoot.appendingPathComponent(
            "addons/replaced-future",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: compatibleReplacementDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: futureReplacementDirectory,
            withIntermediateDirectories: true
        )
        try """
        [REPLACED]
        Description=Comparator replacement
        Abbreviation=Delta
        Category=And Bible
        ModDrv=RawLD
        DataPath=./addons/replaced-compatible/
        Version=1.0
        AndBibleMinimumVersion=1115
        AndBibleProvidesPrompts=compatible.csv
        """.write(
            to: configDirectory.appendingPathComponent("a-compatible-replacement.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [REPLACED]
        Description=Comparator replacement
        Abbreviation=Delta
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./addons/replaced-future/
        Version=2.0
        AndBibleMinimumVersion=1116
        AndBibleProvidesPrompts=future-replacement.csv
        """.write(
            to: configDirectory.appendingPathComponent("z-future-replacement.conf"),
            atomically: true,
            encoding: .utf8
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        let replacedOwners = manager.installedModules().filter {
            SwordJavaStringIdentity.equals($0.name, "REPLACED")
        }
        XCTAssertEqual(replacedOwners.map(\.version), ["2.0"])
        let modules = manager.admittedAddonModules()

        XCTAssertEqual(
            modules.map(\.moduleInfo.name),
            ["ALPHA", decomposed, composed, "PREFIXTEXT", "CASE", "case"]
        )
        XCTAssertEqual(modules.map(\.promptFileName), [
            "first.csv", "decomposed.csv", "composed.csv", "rawtext.csv", "upper.csv",
            "lower.csv",
        ])
        XCTAssertEqual(
            modules.first?.locationURL,
            moduleRoot.appendingPathComponent("addons/z-alpha.conf", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertEqual(Set(modules.map { SwordJavaExactStringIdentity($0.moduleInfo.name) }).count, 6)
    }

    /**
     Verifies JSword payload adjustment rejects a broken native row before driver HashSet ownership.

     - Setup: Writes equality-identical RawGenBook configs in path order, first without `DataPath`,
       then with a missing payload, and finally with an existing directory.
     - Expected result: The valid later config becomes the sole installed/admitted owner and carries
       its adjusted directory location.
     - Side effects: Creates, reads, and removes one isolated SWORD tree.
     - Failure meaning: A ghost config can consume the native HashSet slot and hide a valid Android
       installed add-on.
     */
    func testAddonPayloadAdmissionPrecedesNativeHashSetOwnership() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let validDirectory = moduleRoot.appendingPathComponent("addons/valid", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: validDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        /**
         Writes one equality-identical add-on config with a caller-selected payload path.

         - Parameters:
           - file: Config filename controlling deterministic native enumeration.
           - dataPath: Optional raw `DataPath`; nil deliberately omits the required property.
         - Side effects: Atomically writes one config below the fixture root.
         - Throws: Propagates filesystem encoding/write failures.
         */
        func writeConfig(file: String, dataPath: String?) throws {
            var lines = [
                "[PAYLOADWIN]",
                "Description=Payload equality owner",
                "Abbreviation=Payload",
                "Category=And Bible",
                "ModDrv=RawGenBook",
            ]
            if let dataPath {
                lines.append("DataPath=\(dataPath)")
            }
            lines.append("AndBibleMinimumVersion=1115")
            try lines.joined(separator: "\n").write(
                to: configDirectory.appendingPathComponent(file),
                atomically: true,
                encoding: .utf8
            )
        }
        try writeConfig(file: "a-missing.conf", dataPath: nil)
        try writeConfig(file: "b-broken.conf", dataPath: "./addons/missing/")
        try writeConfig(file: "z-valid.conf", dataPath: "./addons/valid/")

        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        XCTAssertEqual(
            manager.installedModules().filter { $0.name == "PAYLOADWIN" }.map(\.name),
            ["PAYLOADWIN"]
        )
        let addon = try XCTUnwrap(
            manager.admittedAddonModules().first { $0.moduleInfo.name == "PAYLOADWIN" }
        )
        XCTAssertEqual(addon.locationURL, validDirectory.standardizedFileURL)
    }

    /**
     Verifies adjusted-location parity distinguishes no-location metadata from an explicit root.

     - Setup: Writes one add-on with slashless `DataPath=foo` and one with `DataPath=./`.
     - Expected result: Both books remain installed, but only the explicit root owns a feature-file
       location; the slashless book cannot borrow files from the module root.
     - Side effects: Creates, reads, and removes one isolated SWORD tree.
     - Failure meaning: Prompt/plan discovery can read files from a location JSword never assigned.
     */
    func testAddonAdjustedLocationDistinguishesSlashlessPathFromExplicitRoot() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        try """
        [NOLOCATION]
        Description=No location
        Abbreviation=No location
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=foo
        """.write(
            to: configDirectory.appendingPathComponent("no-location.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [ROOTLOCATION]
        Description=Root location
        Abbreviation=Root location
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./
        """.write(
            to: configDirectory.appendingPathComponent("root-location.conf"),
            atomically: true,
            encoding: .utf8
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        let addons = manager.admittedAddonModules()
        XCTAssertNil(addons.first { $0.moduleInfo.name == "NOLOCATION" }?.locationURL)
        XCTAssertEqual(
            addons.first { $0.moduleInfo.name == "ROOTLOCATION" }?.locationURL,
            moduleRoot.standardizedFileURL
        )
    }

    /**
     Verifies configless prompt CSV files become Android synthetic installed books.

     - Setup: Writes one readable mixed-case-extension CSV under `prompts` and no `.conf` file.
     - Expected result: Installed module/registration inventory and the admitted add-on projection
       expose the same synthetic Android identity, metadata, prompt filename, and parent location.
     - Side effects: Creates, reads, and removes one isolated SWORD tree.
     - Failure meaning: Manually installed Android prompt packs remain invisible on iOS.
     */
    func testStandalonePromptCSVIsSynthesizedWithoutConfig() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let promptDirectory = moduleRoot.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        try "id;name;description;promptTemplate\n".write(
            to: promptDirectory.appendingPathComponent("Study Pack.CSV"),
            atomically: true,
            encoding: .utf8
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        XCTAssertEqual(manager.installedModules().map(\.name), ["Prompts_Study Pack"])
        let installed = manager.installedBookRegistrations()
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.first?.moduleInfo.name, "Prompts_Study Pack")
        XCTAssertEqual(installed.first?.abbreviation, "Prompts_Study Pack")
        let addons = manager.admittedAddonModules()
        XCTAssertEqual(addons.count, 1)
        let addon = try XCTUnwrap(addons.first)
        XCTAssertEqual(addon.moduleInfo.name, "Prompts_Study Pack")
        XCTAssertEqual(addon.moduleInfo.description, "Study Pack prompts")
        XCTAssertEqual(addon.abbreviation, "Prompts_Study Pack")
        XCTAssertEqual(addon.promptFileName, "Study Pack.CSV")
        XCTAssertEqual(addon.locationURL, promptDirectory.standardizedFileURL)
    }

    /**
     Verifies Android synthetic prompt uninstall deletes the exact CSV owner without a config.

     - Setup: Synthesizes one configless `CsvPromptBook`, captures its opaque installed owner, and
       invokes the production repository deletion API.
     - Expected result: The CSV is removed transactionally, no config is required, a fresh manager
       exposes no installed/add-on row, and no transaction backup remains.
     - Side effects: Creates and removes one isolated SWORD root and performs one real deletion.
     - Failure meaning: The picker can advertise Android's Uninstall action for a generated prompt
       book but route it into the ordinary config lookup and fail with `moduleNotFound`.
     */
    func testStandalonePromptCSVUninstallDeletesExactGeneratedBookOwner() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let promptDirectory = moduleRoot.appendingPathComponent("prompts", isDirectory: true)
        let csvURL = promptDirectory.appendingPathComponent("Delete Me.csv")
        try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        try "id;name;description;promptTemplate\n".write(
            to: csvURL,
            atomically: true,
            encoding: .utf8
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        let addon = try XCTUnwrap(manager.admittedAddonModules().first)
        let repository = ModuleRepository(
            basePath: moduleRoot.appendingPathComponent("install-manager").path,
            swordPath: moduleRoot.path
        )

        try repository.uninstallAddon(addon.removalTarget)

        XCTAssertFalse(FileManager.default.fileExists(atPath: csvURL.path))
        let refreshed = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        XCTAssertTrue(refreshed.installedModules().isEmpty)
        XCTAssertTrue(refreshed.admittedAddonModules().isEmpty)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: moduleRoot.path)
                .contains { $0.hasPrefix(".module-transaction-") }
        )
    }

    /**
     Verifies duplicate-initial add-on uninstall retains the selected concrete config owner.

     - Setup: Installs two JSword-retained RawGenBook add-ons with exact-equal initials but distinct
       names, abbreviations, config files, and payload directories, then selects the Beta row.
     - Expected result: Repository deletion removes only Beta's config/payload; Gamma survives and a
       fresh admitted projection contains only the Gamma row.
     - Side effects: Creates and removes one isolated SWORD tree and performs one real transaction.
     - Failure meaning: Destructive picker actions collapse comparator-distinct rows back to initials
       and delete, reject, or otherwise target the wrong Android Book.
     */
    func testAddonUninstallTargetsSelectedComparatorDistinctConfigOwner() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let betaDirectory = moduleRoot.appendingPathComponent("addons/beta", isDirectory: true)
        let gammaDirectory = moduleRoot.appendingPathComponent("addons/gamma", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gammaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        let betaConfigURL = configDirectory.appendingPathComponent("beta.conf")
        let gammaConfigURL = configDirectory.appendingPathComponent("gamma.conf")
        try """
        [DUPDELETE]
        Description=Duplicate beta owner
        Abbreviation=Beta
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./addons/beta/
        AndBibleMinimumVersion=1115
        """.write(to: betaConfigURL, atomically: true, encoding: .utf8)
        try """
        [DUPDELETE]
        Description=Duplicate gamma owner
        Abbreviation=Gamma
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./addons/gamma/
        AndBibleMinimumVersion=1115
        """.write(to: gammaConfigURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        let addons = manager.admittedAddonModules()
        XCTAssertEqual(addons.map(\.abbreviation), ["Beta", "Gamma"])
        let beta = try XCTUnwrap(addons.first { $0.abbreviation == "Beta" })
        let repository = ModuleRepository(
            basePath: moduleRoot.appendingPathComponent("install-manager").path,
            swordPath: moduleRoot.path
        )

        try repository.uninstallAddon(beta.removalTarget)

        XCTAssertFalse(FileManager.default.fileExists(atPath: betaConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: betaDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gammaConfigURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gammaDirectory.path))
        XCTAssertThrowsError(try repository.uninstallAddon(beta.removalTarget)) { error in
            guard case ModuleRepositoryError.moduleNotFound(let name) = error else {
                return XCTFail("Expected stale exact-owner rejection, received \(error)")
            }
            XCTAssertEqual(name, "DUPDELETE")
        }
        let refreshed = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        XCTAssertEqual(refreshed.admittedAddonModules().map(\.abbreviation), ["Gamma"])
    }

    /**
     Verifies opaque deletion tokens preserve Java-distinct canonical spellings.

     - Setup: Constructs generated-prompt targets whose filenames and initials use composed and
       decomposed spellings that Swift normally treats as canonically equivalent.
     - Expected result: Equality distinguishes the tokens and a `Set` retains both owners.
     - Side effects: None.
     - Failure meaning: Picker confirmation or fresh-owner revalidation can collapse one installed
       Android Book into its canonically equivalent sibling.
     */
    func testAddonRemovalTargetHashingUsesExactJavaStringIdentity() {
        let composed = SwordInstalledAddonRemovalTarget(
            standalonePromptFileName: "\u{00E9}.csv",
            moduleName: "Prompts_\u{00E9}"
        )
        let decomposed = SwordInstalledAddonRemovalTarget(
            standalonePromptFileName: "e\u{0301}.csv",
            moduleName: "Prompts_e\u{0301}"
        )

        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
    }

    /**
     Verifies a stale token cannot delete a config replaced in the current installed TreeSet.

     - Setup: Captures a RawLD add-on token, then installs a later RawGenBook with comparator-equal
       metadata and a distinct payload/config before invoking repository deletion.
     - Expected result: Under-lease registry replay rejects the stale token and leaves both configs
       and payloads byte-for-byte present; the fresh installed projection exposes the replacement.
     - Side effects: Creates and removes one isolated SWORD tree and attempts one real transaction.
     - Failure meaning: A row captured before module-store replacement can delete a Book that is no
       longer the owner visible through Android's `Books.installed()` TreeSet.
     */
    func testAddonUninstallRejectsOwnerReplacedAfterRowCapture() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let dictionaryDirectory = moduleRoot.appendingPathComponent(
            "addons/original",
            isDirectory: true
        )
        let replacementDirectory = moduleRoot.appendingPathComponent(
            "addons/replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dictionaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        let originalConfigURL = configDirectory.appendingPathComponent("a-original.conf")
        let originalPrefixURL = dictionaryDirectory.appendingPathComponent("module")
        try Data().write(to: URL(fileURLWithPath: originalPrefixURL.path + ".dat"))
        try """
        [CURRENTOWNER]
        Description=Current owner
        Abbreviation=Current
        Category=And Bible
        ModDrv=RawLD
        DataPath=./addons/original/module
        AndBibleMinimumVersion=1115
        """.write(to: originalConfigURL, atomically: true, encoding: .utf8)

        let initialManager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        let staleTarget = try XCTUnwrap(
            initialManager.admittedAddonModules().first?.removalTarget
        )

        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: true
        )
        let replacementConfigURL = configDirectory.appendingPathComponent("z-replacement.conf")
        try """
        [CURRENTOWNER]
        Description=Current owner
        Abbreviation=Current
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./addons/replacement/
        AndBibleMinimumVersion=1115
        """.write(to: replacementConfigURL, atomically: true, encoding: .utf8)

        let currentManager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        let currentAddons = currentManager.admittedAddonModules()
        XCTAssertEqual(currentAddons.count, 1)
        XCTAssertEqual(currentAddons.first?.locationURL, replacementDirectory.standardizedFileURL)
        XCTAssertNotEqual(currentAddons.first?.removalTarget, staleTarget)

        let repository = ModuleRepository(
            basePath: moduleRoot.appendingPathComponent("install-manager").path,
            swordPath: moduleRoot.path
        )
        XCTAssertThrowsError(try repository.uninstallAddon(staleTarget)) { error in
            guard case ModuleRepositoryError.moduleNotFound(let name) = error else {
                return XCTFail("Expected stale owner rejection, received \(error)")
            }
            XCTAssertEqual(name, "CURRENTOWNER")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalConfigURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPrefixURL.path + ".dat"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementConfigURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementDirectory.path))
    }

    /**
     Verifies add-on deletion cannot remove a shared Android installed-family root.

     - Setup: Installs one config-backed add-on whose adjusted location is the canonical `prompts`
       root alongside a separately synthesized standalone CSV prompt Book.
     - Expected result: Deletion rejects the shared root and preserves the config, directory, and
       standalone CSV owner without creating rollback residue.
     - Side effects: Creates and removes one isolated SWORD tree and attempts one real transaction.
     - Failure meaning: Deleting a config-backed add-on can silently erase independently registered
       raw-family books that do not own a SWORD config location.
     */
    func testAddonUninstallRejectsSharedInstalledFamilyRoot() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let promptsDirectory = moduleRoot.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: promptsDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        let csvURL = promptsDirectory.appendingPathComponent("Other.csv")
        try "id;name;description;promptTemplate\n".write(
            to: csvURL,
            atomically: true,
            encoding: .utf8
        )
        let configURL = configDirectory.appendingPathComponent("shared-root.conf")
        try """
        [SHAREDROOT]
        Description=Shared prompts root
        Abbreviation=Shared prompts root
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./prompts/
        AndBibleMinimumVersion=1115
        AndBibleProvidesPrompts=Other.csv
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        let addon = try XCTUnwrap(
            manager.admittedAddonModules().first {
                SwordJavaStringIdentity.equals($0.moduleInfo.name, "SHAREDROOT")
            }
        )
        XCTAssertNotNil(
            manager.admittedAddonModules().first {
                SwordJavaStringIdentity.equals($0.moduleInfo.name, "Prompts_Other")
            }
        )
        let repository = ModuleRepository(
            basePath: moduleRoot.appendingPathComponent("install-manager").path,
            swordPath: moduleRoot.path
        )

        XCTAssertThrowsError(try repository.uninstallAddon(addon.removalTarget)) { error in
            guard case ModuleStoreMutationError.installedOwnershipConflict(
                let moduleName,
                let owner
            ) = error else {
                return XCTFail("Expected protected-root rejection, received \(error)")
            }
            XCTAssertEqual(moduleName, "SHAREDROOT")
            XCTAssertEqual(owner, "prompts")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: promptsDirectory.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: moduleRoot.path)
                .contains { $0.hasPrefix(".module-transaction-") }
        )
    }

    /**
     Verifies admitted add-ons retain live cipher state and invalidate their cached projection.

     - Setup: Converts a genuine encrypted RawLD fixture to an And Bible book, captures it locked,
       then unlocks it with the fixture key after the projection cache is populated.
     - Expected result: Installed and add-on projections agree on abbreviation/encryption state,
       and the post-unlock add-on projection reports the same owner as unlocked.
     - Side effects: Creates encrypted fixture files and atomically persists the verified key.
     - Failure meaning: Picker unlock affordances or feature inventory can remain stale/diverge from
       the installed registry.
     */
    func testAdmittedAddonProjectionRetainsAndRefreshesCipherState() throws {
        let fixture = try makeEncryptedRawLDFixture(moduleName: "LOCKEDADDON")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var config = try String(contentsOf: fixture.configURL, encoding: .utf8)
        config = config.replacingOccurrences(
            of: "Category=Lexicons / Dictionaries",
            with: "Category=And Bible\nAbbreviation=Locked feature"
        )
        try config.write(to: fixture.configURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let installedBefore = try XCTUnwrap(
            manager.installedBookRegistrations().first { $0.moduleInfo.name == "LOCKEDADDON" }
        )
        let addonBefore = try XCTUnwrap(
            manager.admittedAddonModules().first { $0.moduleInfo.name == "LOCKEDADDON" }
        )
        XCTAssertEqual(installedBefore.abbreviation, "Locked feature")
        XCTAssertTrue(installedBefore.moduleInfo.isEncrypted)
        XCTAssertFalse(installedBefore.moduleInfo.isUnlocked)
        XCTAssertEqual(addonBefore.moduleInfo.isEncrypted, installedBefore.moduleInfo.isEncrypted)
        XCTAssertEqual(addonBefore.moduleInfo.isUnlocked, installedBefore.moduleInfo.isUnlocked)

        XCTAssertTrue(manager.unlockModule(named: "LOCKEDADDON", withCipherKey: fixture.cipherKey))
        let addonAfter = try XCTUnwrap(
            manager.admittedAddonModules().first { $0.moduleInfo.name == "LOCKEDADDON" }
        )
        XCTAssertTrue(addonAfter.moduleInfo.isEncrypted)
        XCTAssertTrue(addonAfter.moduleInfo.isUnlocked)
    }

    /**
     Verifies manager-lifetime add-on projection caches compatibility until explicit invalidation.

     - Setup: Reads one installed add-on, rewrites its minimum version above the supported Android
       boundary, then invalidates Swift-owned snapshots.
     - Expected result: Repeated access keeps the captured generation stable, while `refresh()`
       reparses the installed config and omits the now-incompatible book.
     - Side effects: Creates, mutates, reads, and removes one isolated SWORD config tree.
     - Failure meaning: Prompt and picker calls can disagree within one installed-state generation,
       or explicit invalidation leaves stale Android compatibility admission behind.
     */
    func testAdmittedAddonModulesCacheUntilManagerRefresh() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }

        func writeAddon(_ initials: String, minimumVersion: Int) throws {
            try FileManager.default.createDirectory(
                at: moduleRoot.appendingPathComponent("addons/\(initials.lowercased())"),
                withIntermediateDirectories: true
            )
            try """
            [\(initials)]
            Description=\(initials)
            Category=And Bible
            ModDrv=RawGenBook
            DataPath=./addons/\(initials.lowercased())/
            AndBibleMinimumVersion=\(minimumVersion)
            """.write(
                to: configDirectory.appendingPathComponent("\(initials.lowercased()).conf"),
                atomically: true,
                encoding: .utf8
            )
        }

        try writeAddon("FIRST", minimumVersion: 1115)
        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        XCTAssertEqual(manager.admittedAddonModules().map(\.moduleInfo.name), ["FIRST"])

        try writeAddon("FIRST", minimumVersion: 1116)
        XCTAssertEqual(manager.admittedAddonModules().map(\.moduleInfo.name), ["FIRST"])

        manager.refresh()
        XCTAssertTrue(manager.admittedAddonModules().isEmpty)
    }

    /**
     Verifies installed MyBible packages derive Android book metadata from their actual databases.

     Android adds downloaded MyBible packages to `Books.installed().books`. iOS stores those packages
     in a sidecar directory, but `SwordManager.installedModules()` must still expose them so Downloads,
     settings, and reader pickers do not each maintain a different installed-module definition.

     - Setup: Writes sidecars with deliberately stale manifest metadata beside real Bible and
       dictionary SQLite schemas whose filenames and `info` rows own different metadata.
     - Expected result: Direct and merged inventory derive initials, descriptions, language,
       categories, and drivers from the databases, order Bible before dictionary, and align count.
     - Failure meaning: MyBible package installs are only visible to Downloads and Android parity has
       regressed.
     */
    func testInstalledModulesIncludesMyBiblePackageSidecarModules() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let moduleDir = swordDir
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("MyBible-finrk_SQLite3", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metadata = InstalledMyBibleModule(
            name: "MyBible-finrk_SQLite3",
            description: "Finnish RK",
            category: ModuleCategory.bible.rawValue,
            language: "fi",
            version: "2026-06-27",
            sourceName: "Example MyBible",
            packageFileName: "finrk.SQLite3.zip",
            downloadURL: "https://example.test/finrk.SQLite3.zip",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        try JSONEncoder().encode(metadata).write(
            to: moduleDir.appendingPathComponent("module.json"),
            options: .atomic
        )
        try makeInstalledMyBibleDatabase(
            at: moduleDir.appendingPathComponent("finrk.SQLite3"),
            description: "Finnish RK from database",
            language: "fi",
            category: .bible
        )

        let dictionaryDirectory = swordDir
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("dictionary-container", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dictionaryDirectory,
            withIntermediateDirectories: true
        )
        let dictionaryMetadata = InstalledMyBibleModule(
            name: "AAA-dictionary",
            description: "Alphabetical Dictionary",
            category: ModuleCategory.dictionary.rawValue,
            language: "en",
            version: "1.0",
            sourceName: "Example MyBible",
            packageFileName: "dictionary.SQLite3.zip",
            downloadURL: "https://example.test/dictionary.SQLite3.zip",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        try JSONEncoder().encode(dictionaryMetadata).write(
            to: dictionaryDirectory.appendingPathComponent("module.json"),
            options: .atomic
        )
        try makeInstalledMyBibleDatabase(
            at: dictionaryDirectory.appendingPathComponent("dictionary.SQLite3"),
            description: "Dictionary from database",
            language: "de",
            category: .dictionary
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: swordDir.path))
        let modules = manager.installedModules()
        let finrk = try XCTUnwrap(modules.first { $0.name == "MyBible-finrk" })

        XCTAssertEqual(
            SwordManager.myBiblePackageInstalledModules(modulePath: swordDir.path).map(\.name),
            ["MyBible-finrk", "MyBible-dictionary"]
        )
        XCTAssertEqual(modules.map(\.name), ["MyBible-finrk", "MyBible-dictionary"])
        XCTAssertEqual(finrk.description, "Finnish RK from database")
        XCTAssertEqual(finrk.category, .bible)
        XCTAssertEqual(finrk.language, "fi")
        XCTAssertEqual(finrk.moduleDriver, "MyBibleBible")
        let dictionary = try XCTUnwrap(modules.first { $0.name == "MyBible-dictionary" })
        XCTAssertEqual(dictionary.description, "Dictionary from database")
        XCTAssertEqual(dictionary.category, .dictionary)
        XCTAssertEqual(dictionary.language, "de")
        XCTAssertEqual(dictionary.moduleDriver, "MyBibleDictionary")
        XCTAssertEqual(finrk.aboutMetadata.versification, "KJVA")
        XCTAssertTrue(finrk.isSupported)
        XCTAssertEqual(manager.moduleCount, modules.count)
    }

    /**
     Verifies stale MyBible sidecar metadata does not produce an installed-book row.

     Android's MyBible import only adds a book when the SQLite payload can be opened. iOS should not
     create a visible installed module from `module.json` alone.

     - Setup: Writes sidecar metadata without any SQLite/MyBible payload file.
     - Expected result: The package row is absent from `installedModules()`.
     - Failure meaning: Stale sidecars can make Downloads/settings/reader lists advertise unusable
       modules.
     */
    func testInstalledModulesSkipsMyBiblePackageSidecarWithoutPayload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let moduleDir = swordDir
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("MyBible-finrk_SQLite3", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metadata = InstalledMyBibleModule(
            name: "MyBible-finrk_SQLite3",
            description: "Finnish RK",
            category: ModuleCategory.bible.rawValue,
            language: "fi",
            version: "2026-06-27",
            sourceName: "Example MyBible",
            packageFileName: "finrk.SQLite3.zip",
            downloadURL: "https://example.test/finrk.SQLite3.zip",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        try JSONEncoder().encode(metadata).write(
            to: moduleDir.appendingPathComponent("module.json"),
            options: .atomic
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: swordDir.path))

        XCTAssertFalse(manager.installedModules().contains { $0.name == "MyBible-finrk_SQLite3" })
    }

    /**
     Verifies MyBible TreeSet order uses the payload-derived unsanitized abbreviation.

     - Setup: Writes two dictionary databases whose `a`/`A` abbreviations tie ignoring case while
       their sanitized exact initials sort in the opposite order from their sidecar names.
     - Expected result: The uppercase exact initials row sorts first after the abbreviation tie.
     - Side effects: Creates, opens, and removes two isolated SQLite package fixtures.
     - Failure meaning: Sidecar initials are still substituted for Android's database abbreviation.
     */
    func testMyBiblePackageOrderingUsesDatabaseFilenameAbbreviation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let myBibleRoot = root.appendingPathComponent("mybible", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let definitions = [
            ("z-sidecar", "a.a.SQLite3", "Lower payload"),
            ("a-sidecar", "A.z.SQLite3", "Upper payload"),
        ]
        for (directoryName, databaseName, description) in definitions {
            let directory = myBibleRoot.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sidecar = InstalledMyBibleModule(
                name: directoryName,
                description: "Manifest metadata must not order",
                category: ModuleCategory.bible.rawValue,
                language: "en",
                version: "1.0",
                sourceName: "Fixture",
                packageFileName: "\(databaseName).zip",
                downloadURL: "https://example.test/\(databaseName).zip",
                installedAt: Date(timeIntervalSince1970: 0)
            )
            try JSONEncoder().encode(sidecar).write(
                to: directory.appendingPathComponent("module.json"),
                options: .atomic
            )
            try makeInstalledMyBibleDatabase(
                at: directory.appendingPathComponent(databaseName),
                description: description,
                language: "en",
                category: .dictionary
            )
        }

        XCTAssertEqual(
            SwordManager.myBiblePackageInstalledModules(modulePath: root.path).map(\.name),
            ["MyBible-A_z", "MyBible-a_a"]
        )
    }

    /**
     Verifies Android's manual-MyBible pre-add lookup preserves an already registered native owner.

     - Setup: Installs a real native RawLD book, then a package database whose derived initials match
       the native book but whose description and backend are distinct.
     - Expected result: Combined inventory exposes only the native row; the standalone package scan
       still proves the database fixture was otherwise admissible.
     - Side effects: Creates/removes one native fixture plus one read-only SQLite package fixture.
     - Failure meaning: Manual MyBible admission later-replaces or duplicates a book Android skips.
     */
    func testMyBiblePackageAdmissionPreservesPriorNativeLookupOwner() throws {
        let fixture = try makePlainRawLDFixture(modules: [
            SwordManagerPlainRawLDDefinition(
                initials: "MyBible-collision",
                fullName: "Native collision owner",
                dataStem: "mybible-collision",
                entryText: "NATIVE_COLLISION_BACKEND"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.root
            .appendingPathComponent("mybible/package-container", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sidecar = InstalledMyBibleModule(
            name: "Remote package name",
            description: "Manifest collision",
            category: ModuleCategory.bible.rawValue,
            language: "en",
            version: "1.0",
            sourceName: "Fixture",
            packageFileName: "collision.SQLite3.zip",
            downloadURL: "https://example.test/collision.SQLite3.zip",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        try JSONEncoder().encode(sidecar).write(
            to: directory.appendingPathComponent("module.json"),
            options: .atomic
        )
        try makeInstalledMyBibleDatabase(
            at: directory.appendingPathComponent("collision.SQLite3"),
            description: "Database collision",
            language: "en",
            category: .dictionary
        )

        XCTAssertEqual(
            SwordManager.myBiblePackageInstalledModules(modulePath: fixture.root.path).map(\.name),
            ["MyBible-collision"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let collisions = manager.installedModules().filter { $0.name == "MyBible-collision" }
        XCTAssertEqual(collisions.map(\.description), ["Native collision owner"])
    }

    func testSearchOptionsDefaults() {
        let opts = SearchOptions(query: "love")
        XCTAssertEqual(opts.searchType, .multiWord)
        XCTAssertTrue(opts.caseInsensitive)
        XCTAssertNil(opts.scope)
    }

    /**
     Builds real unencrypted RawLD modules in one isolated native manager root.

     - Parameter modules: Exact config initials and unique metadata/data stems for each backend.
     - Returns: Temporary SWORD root containing every requested config, `.idx`, and `.dat` file.
     - Side effects: Creates directories and native RawLD fixture files under a random temporary URL.
     - Failure modes: Propagates filesystem writes and rejects entries too large for RawLD's two-byte
       record length. Callers own removal of the returned root.
     */
    private func makePlainRawLDFixture(
        modules: [SwordManagerPlainRawLDDefinition]
    ) throws -> SwordManagerPlainRawLDFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )

        for (index, definition) in modules.enumerated() {
            let relativeDataDirectory = "modules/lexdict/rawld/\(definition.dataStem)"
            let dataDirectory = root.appendingPathComponent(
                relativeDataDirectory,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true
            )

            let dataPrefix = dataDirectory.appendingPathComponent(definition.dataStem)
            let indexedRecord = Data(
                "ENTRY\r\n<entryFree><p>\(definition.entryText)</p></entryFree>".utf8
            )
            guard indexedRecord.count <= Int(UInt16.max) else {
                throw SwordManagerEncryptedFixtureError.entryTooLarge
            }
            try (indexedRecord + Data([0x0A])).write(
                to: dataPrefix.appendingPathExtension("dat")
            )
            let recordSize = UInt16(indexedRecord.count)
            try Data([
                0x00, 0x00, 0x00, 0x00,
                UInt8(recordSize & 0x00ff), UInt8(recordSize >> 8),
            ]).write(to: dataPrefix.appendingPathExtension("idx"))

            var configLines = ["[\(definition.initials)]"]
            if let fullName = definition.fullName {
                configLines.append("Description=\(fullName)")
            }
            if let abbreviation = definition.abbreviation {
                configLines.append("Abbreviation=\(abbreviation)")
            }
            configLines.append(contentsOf: [
                "Category=Lexicons / Dictionaries",
                "ModDrv=RawLD",
                "DataPath=./\(relativeDataDirectory)/\(definition.dataStem)",
                "SourceType=OSIS",
                "Encoding=UTF-8",
                "Lang=en",
                "Versification=KJV",
            ])
            try (configLines.joined(separator: "\n") + "\n").write(
                to: configDirectory.appendingPathComponent("identity-\(index).conf"),
                atomically: true,
                encoding: .utf8
            )
        }

        return SwordManagerPlainRawLDFixture(root: root)
    }

    /**
     Writes the bounded SQLite metadata/schema needed by installed MyBible inventory fixtures.

     - Parameters:
       - databaseURL: Exact database file to create.
       - description: Value stored under `info.description`.
       - language: Value stored under `info.language`.
       - category: Bible, commentary, or dictionary content table to materialize.
     - Side effects: Creates and writes one SQLite database at `databaseURL`.
     - Failure modes: Throws for unsupported categories or SQLite open/write failures.
     */
    private func makeInstalledMyBibleDatabase(
        at databaseURL: URL,
        description: String,
        language: String,
        category: ModuleCategory
    ) throws {
        let contentTable: String
        switch category {
        case .bible:
            contentTable = "verses"
        case .commentary:
            contentTable = "commentaries"
        case .dictionary:
            contentTable = "dictionary"
        default:
            throw SwordManagerMyBibleFixtureError.unsupportedCategory
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SwordManagerMyBibleFixtureError.openFailed
        }
        defer { sqlite3_close(database) }

        let escapedDescription = description.replacingOccurrences(of: "'", with: "''")
        let escapedLanguage = language.replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE info (name TEXT PRIMARY KEY, value TEXT);
        INSERT INTO info (name, value) VALUES ('description', '\(escapedDescription)');
        INSERT INTO info (name, value) VALUES ('language', '\(escapedLanguage)');
        CREATE TABLE \(contentTable) (fixture_id INTEGER);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SwordManagerMyBibleFixtureError.writeFailed
        }
    }

    /**
     Asserts that one decrypted fixture module can reconstruct its complete two-verse chapter range.

     - Parameters:
       - module: Readable RawText Bible handle from either the live unlock manager or a fresh one.
       - file: XCTest source location forwarded to assertion failures.
       - line: XCTest source line forwarded to assertion failures.
     - Side effects: Temporarily moves and restores the native module cursor while resolving
       ordinals and reading the bounded range.
     - Failure modes: Throws when SWORD cannot inspect the exact range; XCTest failures identify
       ciphertext leakage, missing verses, or loss of synthetic canonical text.
     */
    private func assertSyntheticEncryptedChapterReadable(
        in module: SwordModule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let startOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1),
            file: file,
            line: line
        )
        let endOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2),
            file: file,
            line: line
        )
        let chapter = try module.inspectVerseSourceRangeRestoringPrevious(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        XCTAssertEqual(chapter.sourceOSISRange, "Gen.1.1-Gen.1.2", file: file, line: line)
        XCTAssertEqual(
            chapter.entries.map(\.reference.osisRef),
            ["Gen.1.1", "Gen.1.2"],
            file: file,
            line: line
        )
        let sourceXML = chapter.entries.compactMap(\.osisFragment).joined()
        XCTAssertTrue(sourceXML.contains("Synthetic encrypted first verse"), file: file, line: line)
        XCTAssertTrue(
            sourceXML.contains("Synthetic encrypted second verse"),
            file: file,
            line: line
        )
        let canonicalText = try XCTUnwrap(chapter.canonicalText, file: file, line: line)
        XCTAssertTrue(
            canonicalText.contains("Synthetic encrypted first verse"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            canonicalText.contains("Synthetic encrypted second verse"),
            file: file,
            line: line
        )
    }

    /**
     Builds a genuine Sapphire-encrypted two-verse RawText Bible without licensed source material.

     The sparse records use pinned KJV RawText indexes: rows zero through three are introduction
     slots and Genesis 1:1/1:2 occupy rows four and five. Each independently encrypted record owns
     an encrypted trailing NUL because libsword's RawText cipher filter decrypts one scratch byte
     beyond the indexed payload before exposing a C string.

     - Returns: Temporary SWORD root, locked Bible config, and its deterministic plaintext key.
     - Side effects: Creates one config, OT/NT data files, and their complete KJV `.vss` indexes.
     - Failure modes: Propagates filesystem errors or rejects a record too large for RawText's
       two-byte length field.
     - Note: All verse text and the fixture key are synthetic and safe to distribute with tests.
     */
    private func makeEncryptedRawTextBibleFixture() throws -> SwordManagerEncryptedFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/texts/rawtext/lockedbible",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )

        let cipherKey = "rawtextcipherkey"
        let sourceEntries = [
            #"<verse osisID="Gen.1.1"><w>Synthetic encrypted first verse.</w></verse>"#,
            #"<verse osisID="Gen.1.2"><w>Synthetic encrypted second verse.</w></verse>"#,
        ]
        var oldTestamentData = Data()
        var oldTestamentIndex = [UInt8](repeating: 0, count: 24_115 * 6)
        for (entryOffset, sourceXML) in sourceEntries.enumerated() {
            var plaintext = Array(sourceXML.utf8)
            plaintext.append(0)
            guard plaintext.count <= Int(UInt16.max) else {
                throw SwordManagerEncryptedFixtureError.entryTooLarge
            }
            var cipher = SwordManagerTestSapphire(key: Array(cipherKey.utf8))
            let encrypted = plaintext.map { cipher.encrypt($0) }
            let dataOffset = UInt32(oldTestamentData.count)
            let entryLength = UInt16(encrypted.count)
            let indexOffset = (4 + entryOffset) * 6
            oldTestamentIndex[indexOffset] = UInt8(dataOffset & 0x0000_00ff)
            oldTestamentIndex[indexOffset + 1] = UInt8((dataOffset >> 8) & 0x0000_00ff)
            oldTestamentIndex[indexOffset + 2] = UInt8((dataOffset >> 16) & 0x0000_00ff)
            oldTestamentIndex[indexOffset + 3] = UInt8((dataOffset >> 24) & 0x0000_00ff)
            oldTestamentIndex[indexOffset + 4] = UInt8(entryLength & 0x00ff)
            oldTestamentIndex[indexOffset + 5] = UInt8((entryLength >> 8) & 0x00ff)
            oldTestamentData.append(contentsOf: encrypted)
            oldTestamentData.append(0x0A)
        }

        try oldTestamentData.write(to: dataDirectory.appendingPathComponent("ot"))
        try Data(oldTestamentIndex).write(to: dataDirectory.appendingPathComponent("ot.vss"))
        try Data().write(to: dataDirectory.appendingPathComponent("nt"))
        try Data(repeating: 0, count: 8_246 * 6).write(
            to: dataDirectory.appendingPathComponent("nt.vss")
        )

        let configURL = configDirectory.appendingPathComponent("lockedbible.conf")
        try """
        [LOCKEDBIBLE]
        Description=Synthetic Encrypted RawText Bible Fixture
        Category=Biblical Texts
        ModDrv=RawText
        DataPath=./modules/texts/rawtext/lockedbible/
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        CipherKey=
        """.write(to: configURL, atomically: true, encoding: .utf8)
        return SwordManagerEncryptedFixture(
            root: root,
            configURL: configURL,
            cipherKey: cipherKey
        )
    }

    /**
     Builds a native encrypted RawLD fixture whose ciphertext contains no embedded NUL.

     - Returns: Temporary SWORD root, config location, and the correct key.
     - Side effects: Creates one config plus RawLD `.dat` and six-byte `.idx` files in a unique
       temporary directory.
     - Failure Modes: Propagates filesystem errors, rejects oversized records, or fails if the
       bounded key search cannot produce C-string-safe fixture ciphertext.
     */
    private func makeEncryptedRawLDFixture(
        moduleName: String = "LOCKED"
    ) throws -> SwordManagerEncryptedFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/lexdict/rawld/locked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let plaintext = Data(
            "<entryFree><orth>cipher</orth><p>Encrypted dictionary entry.</p></entryFree>".utf8
        )
        var selectedKey: String?
        var encrypted = Data()
        for candidateIndex in 0..<256 {
            let candidateKey = "cipherkey\(candidateIndex)"
            var cipher = SwordManagerTestSapphire(key: Array(candidateKey.utf8))
            let candidateCiphertext = Data(plaintext.map { cipher.encrypt($0) })
            if !candidateCiphertext.contains(0) {
                selectedKey = candidateKey
                encrypted = candidateCiphertext
                break
            }
        }
        guard let cipherKey = selectedKey else {
            throw SwordManagerEncryptedFixtureError.ciphertextContainsNUL
        }
        let keyPrefix = Data("ENTRY\r\n".utf8)
        let recordSize = keyPrefix.count + encrypted.count
        guard recordSize <= Int(UInt16.max) else {
            throw SwordManagerEncryptedFixtureError.entryTooLarge
        }
        var record = keyPrefix
        record.append(encrypted)
        record.append(0x0A)
        let dataPrefix = dataDirectory.appendingPathComponent("locked")
        try record.write(to: dataPrefix.appendingPathExtension("dat"))
        var index = Data([0, 0, 0, 0])
        let entrySize = UInt16(recordSize)
        index.append(UInt8(entrySize & 0x00ff))
        index.append(UInt8((entrySize >> 8) & 0x00ff))
        try index.write(to: dataPrefix.appendingPathExtension("idx"))

        let configURL = configDirectory.appendingPathComponent("locked.conf")
        try """
        [\(moduleName)]
        Description=Encrypted RawLD Fixture
        Category=Lexicons / Dictionaries
        ModDrv=RawLD
        DataPath=./modules/lexdict/rawld/locked/locked
        SourceType=OSIS
        Encoding=UTF-8
        CipherKey=
        """.write(to: configURL, atomically: true, encoding: .utf8)
        return SwordManagerEncryptedFixture(
            root: root,
            configURL: configURL,
            cipherKey: cipherKey
        )
    }

    private static func makePseudoBooksMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PseudoBooksMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/**
 Defines one exact native RawLD module used by manager identity regression fixtures.

 Values are immutable and perform no I/O. `dataStem` must be a unique ASCII-safe relative-path
 component within one fixture; tests supply bounded entry text that fits RawLD's two-byte length.
 */
private struct SwordManagerPlainRawLDDefinition {
    /// Exact Java UTF-16 module initials written to the config section.
    let initials: String

    /// Exact JSword full name used by the installed-book name map.
    let fullName: String?

    /// Parsed JSword abbreviation controlling TreeSet order after category.
    let abbreviation: String?

    /// Unique ASCII path and data-file stem for this native backend.
    let dataStem: String

    /// Unique marker written only into this module's real RawLD entry.
    let entryText: String

    /**
     Creates one plain RawLD definition with optional JSword name/abbreviation metadata.

     - Parameters describe exact initials, optional comparator fields, a unique data stem, and one
       backend marker.
     - Side effects: None.
     - Failure modes: None; the fixture builder validates path/record constraints during materialization.
     */
    init(
        initials: String,
        fullName: String? = nil,
        abbreviation: String? = nil,
        dataStem: String,
        entryText: String
    ) {
        self.initials = initials
        self.fullName = fullName
        self.abbreviation = abbreviation
        self.dataStem = dataStem
        self.entryText = entryText
    }
}

/**
 Owns the temporary root returned by the real plain-RawLD fixture builder.

 The value performs no cleanup itself; each test removes `root` with `defer` after all native manager
 handles are released. Construction is deterministic for the supplied URL and cannot fail.
 */
private struct SwordManagerPlainRawLDFixture {
    /// Root containing `mods.d` and every definition's independent native data files.
    let root: URL
}

/**
 Carries the temporary paths and verified key for one native encrypted-module unlock test.

 The value owns no resources itself; its test creates and removes `root`. Construction performs no
 I/O, cannot fail, and is deterministic for the supplied values.
 */
private struct SwordManagerEncryptedFixture {
    /// SWORD root containing the encrypted native module.
    let root: URL

    /// Config whose `CipherKey` persistence is asserted.
    let configURL: URL

    /// Plain key used to produce the fixture ciphertext.
    let cipherKey: String

}

/**
 Describes deterministic failures while constructing a native encrypted fixture.

 Cases identify fixture limitations rather than production unlock failures. The enum has no side
 effects and is used only to fail a test before libsword is invoked.
 */
private enum SwordManagerEncryptedFixtureError: Error {
    /// The selected native record format cannot represent an entry in its two-byte length field.
    case entryTooLarge

    /// No bounded test key produced RawLD ciphertext without an embedded C-string terminator.
    case ciphertextContainsNUL

}

/** Identifies deterministic setup failures in installed MyBible SQLite test fixtures. */
private enum SwordManagerMyBibleFixtureError: Error {
    /// SQLite could not create/open the isolated fixture file.
    case openFailed

    /// SQLite rejected the bounded schema/metadata statements.
    case writeFailed

    /// A caller requested a category Android MyBible databases cannot represent.
    case unsupportedCategory
}

/**
 Test-only Sapphire II encryptor matching libsword's `Sapphire::encrypt` state transitions.

 Production decryption remains entirely inside libsword. This implementation only creates realistic
 ciphertext at runtime so unlock tests exercise native RawLD and RawText SWORD backends.
 */
private struct SwordManagerTestSapphire {
    private var cards = [UInt8](repeating: 0, count: 256)
    private var rotor: UInt8 = 0
    private var ratchet: UInt8 = 0
    private var avalanche: UInt8 = 0
    private var lastPlain: UInt8 = 0
    private var lastCipher: UInt8 = 0

    /**
     Initializes the exact keyed card permutation used by libsword.

     - Parameter key: One to 255 key bytes used to seed the Sapphire II permutation.
     - Side effects: Initializes only this value's stream state.
     - Failure modes: Traps when `key` is empty or exceeds Sapphire II's one-byte key length.
     - Postcondition: The next `encrypt` call emits the first byte of a deterministic keyed stream.
     */
    init(key: [UInt8]) {
        precondition(!key.isEmpty && key.count <= 255)
        for index in cards.indices {
            cards[index] = UInt8(index)
        }
        var toSwap: UInt8 = 0
        var keyPosition = 0
        var runningSum: UInt8 = 0
        for index in stride(from: 255, through: 0, by: -1) {
            toSwap = keyRandom(
                limit: index,
                key: key,
                runningSum: &runningSum,
                keyPosition: &keyPosition
            )
            cards.swapAt(index, Int(toSwap))
        }
        rotor = cards[1]
        ratchet = cards[3]
        avalanche = cards[5]
        lastPlain = cards[7]
        lastCipher = cards[Int(runningSum)]
    }

    /**
     Encrypts one byte with the fixture's Sapphire II state.

     - Parameter plaintext: Next plaintext byte in stream order.
     - Returns: Corresponding ciphertext byte.
     - Side effects: Advances the mutable card, rotor, ratchet, avalanche, and history state.
     - Failure modes: None after valid initialization; callers must preserve byte order.
     */
    mutating func encrypt(_ plaintext: UInt8) -> UInt8 {
        ratchet = ratchet &+ cards[Int(rotor)]
        rotor = rotor &+ 1
        let swapTemporary = cards[Int(lastCipher)]
        cards[Int(lastCipher)] = cards[Int(ratchet)]
        cards[Int(ratchet)] = cards[Int(lastPlain)]
        cards[Int(lastPlain)] = cards[Int(rotor)]
        cards[Int(rotor)] = swapTemporary
        avalanche = avalanche &+ cards[Int(swapTemporary)]

        let firstIndex = Int(cards[Int(ratchet)] &+ cards[Int(rotor)])
        let nestedIndex = Int(
            cards[Int(lastPlain)] &+ cards[Int(lastCipher)] &+ cards[Int(avalanche)]
        )
        lastCipher = plaintext ^ cards[firstIndex] ^ cards[Int(cards[nestedIndex])]
        lastPlain = plaintext
        return lastCipher
    }

    /**
     Selects one keyed permutation index using libsword's bounded retry rule.

     - Parameters:
       - limit: Inclusive upper bound used to construct the selection mask.
       - key: Non-empty Sapphire key bytes.
       - runningSum: Mutable key-schedule accumulator.
       - keyPosition: Mutable cursor into `key`.
     - Returns: One permutation index no greater than `limit`.
     - Side effects: Advances `runningSum` and `keyPosition` deterministically.
     - Failure modes: None; initialization enforces a non-empty key and supplies nonnegative limits.
     */
    private mutating func keyRandom(
        limit: Int,
        key: [UInt8],
        runningSum: inout UInt8,
        keyPosition: inout Int
    ) -> UInt8 {
        guard limit > 0 else { return 0 }
        var mask = 1
        while mask < limit {
            mask = (mask << 1) + 1
        }
        var retryCount = 0
        while true {
            runningSum = cards[Int(runningSum)] &+ key[keyPosition]
            keyPosition += 1
            if keyPosition >= key.count {
                keyPosition = 0
                runningSum = runningSum &+ UInt8(key.count)
            }
            retryCount += 1
            var candidate = mask & Int(runningSum)
            if retryCount > 11 {
                candidate %= limit
            }
            if candidate <= limit {
                return UInt8(candidate)
            }
        }
    }
}

private final class PseudoBooksMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            fatalError("PseudoBooksMockURLProtocol.requestHandler must be set before use")
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
