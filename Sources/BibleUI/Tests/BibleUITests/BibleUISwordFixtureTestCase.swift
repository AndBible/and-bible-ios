import Foundation
import SwiftData
import XCTest
@testable import BibleCore
import SwordKit

/**
 Base test case for BibleUI package tests that need temporary SWORD modules.

 The fixture mirrors the app-host test helper's behavior without depending on the shared
 `AndBibleTests` superclass. Each test receives a copied test-only SWORD tree under a unique
 temporary directory, and teardown removes every path registered through
 `makeTemporarySwordFixturePath()`.
 */
class BibleUISwordFixtureTestCase: XCTestCase {
    private var temporarySwordModulePaths: [String] = []
    private var retainedModelContainer: ModelContainer?
    private var retainedModelContext: ModelContext?

    /**
     Creates the per-test SwiftData owner required by detached reader model fixtures.

     iOS 17 resolves `Window`/`PageManager` relationship backing against a currently loaded schema
     even before a test inserts its graph. Retaining one isolated workspace container and context
     lets tests construct those values safely; tests that exercise persistence continue to insert
     their complete root graph into their own explicit contexts.

     - Side effects: Allocates one in-memory workspace model container and main context per test.
     - Failure modes: Propagates SwiftData schema/container initialization failures to XCTest.
     - Concurrency: XCTest owns these references for one test case and releases them in teardown.
     */
    override func setUpWithError() throws {
        try super.setUpWithError()
        let container = try makeWorkspaceModelContainer()
        retainedModelContainer = container
        retainedModelContext = ModelContext(container)
    }

    /**
     Removes every temporary SWORD directory created by the test.

     - Side effects: Deletes filesystem paths registered during the test and clears the registry.
     - Failure modes: Cleanup errors are intentionally ignored so the original test failure remains
       the reported XCTest failure.
     */
    override func tearDown() {
        let fileManager = FileManager.default
        for path in temporarySwordModulePaths {
            try? fileManager.removeItem(atPath: path)
        }
        temporarySwordModulePaths.removeAll()
        retainedModelContext = nil
        retainedModelContainer = nil
        super.tearDown()
    }

    /**
     Attaches a detached reader window and its relationship graph to the retained test context.

     iOS 17 requires relationship-backed `Window` values to belong to a live container before code
     reads optional inverse relationships such as `workspace`. Inserting only the root lets
     SwiftData discover its attached `PageManager` without the duplicate child insertion that
     crashes the supported runtime. Tests that already inserted the window into their own explicit
     context remain unchanged.

     - Parameter window: Reader window graph that will be assigned to a controller.
     - Side effects: Inserts a detached root into the fixture's retained in-memory context.
     - Failure modes: Records an XCTest failure when fixture setup did not retain a context.
     */
    func retainReaderWindowGraph(_ window: BibleCore.Window) {
        guard window.modelContext == nil else { return }
        guard let retainedModelContext else {
            XCTFail("Expected a retained SwiftData context before attaching a reader window")
            return
        }
        retainedModelContext.insert(window)
    }

    /** Inserts detached window/page nodes before wiring their inverse relationship on iOS 17. */
    func retainReaderWindowGraph(
        _ window: BibleCore.Window,
        attaching pageManager: BibleCore.PageManager
    ) {
        guard window.modelContext == nil, pageManager.modelContext == nil else {
            window.pageManager = pageManager
            return
        }
        guard let retainedModelContext else {
            XCTFail("Expected a retained SwiftData context before attaching a reader window")
            return
        }
        retainedModelContext.insert(window)
        retainedModelContext.insert(pageManager)
        window.pageManager = pageManager
    }

    /**
     Copies the repository test SWORD fixture into an isolated temporary module root.

     - Returns: Filesystem path to the temporary `sword` directory containing `mods.d` and module
       data files.
     - Side effects: Creates a temporary directory, copies test fixture files into it, and removes
       any generated libsword module cache from the copy so per-test descriptors are discovered.
     - Failure modes: Throws filesystem errors from directory creation, recursive copying, or stale
       cache removal; records an XCTest failure if the repository fixture path cannot be found.
     */
    func makeTemporarySwordFixturePath() throws -> String {
        let fileManager = FileManager.default
        let sourceRoot = try BibleUITestSourceLocator.repositoryRoot(
            containing: "Sources/BibleUI/Tests/BibleUITests/Fixtures/sword"
        )
        let fixtureSwordURL = sourceRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("BibleUI", isDirectory: true)
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("BibleUITests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        XCTAssertTrue(
            fileManager.fileExists(atPath: fixtureSwordURL.path),
            "Expected test SWORD resources at \(fixtureSwordURL.path)"
        )

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try copyDirectoryContents(from: fixtureSwordURL, to: tempRoot)
        let copiedModuleCacheURL = tempRoot
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("modules-conf.cache", isDirectory: false)
        if fileManager.fileExists(atPath: copiedModuleCacheURL.path) {
            try fileManager.removeItem(at: copiedModuleCacheURL)
        }

        temporarySwordModulePaths.append(tempRoot.path)
        return tempRoot.path
    }

    /**
     Recursively copies all source directory contents into a destination directory.

     - Parameters:
       - source: Directory whose children should be copied.
       - destination: Directory that will receive the copied children.
     - Side effects: Creates destination directories and copies files.
     - Failure modes: Propagates filesystem enumeration, metadata, directory creation, and copy
       errors.
     */
    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try copyDirectoryContents(from: item, to: target)
            } else {
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }

    /**
     Seeds a deterministic empty SWORD commentary module into a temporary module directory.

     The test fixture intentionally carries only KJV, but reader parity tests need an
     installed verse-key commentary category so the SWORD coordinator exercises Android-compatible
     commentary discovery and fallback behavior without redistributing another module.

     - Parameters:
       - moduleName: SWORD module initials to publish in `mods.d`.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
       - features: Optional SWORD `Feature` values written in declaration order.
     - Side effects: Writes a `.conf` file and empty `RawCom` data files under `modulePath`.
     - Failure modes: Propagates filesystem write errors.
     */
    func seedEmptyRawCommentaryModule(named moduleName: String = "UITestComm", in modulePath: String) throws {
        let fileManager = FileManager.default
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let modsDURL = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let dataURL = moduleRoot
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("comments", isDirectory: true)
            .appendingPathComponent("rawcom", isDirectory: true)
            .appendingPathComponent(moduleName.lowercased(), isDirectory: true)

        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
        for fileName in ["ot", "ot.vss", "nt", "nt.vss"] {
            let fileURL = dataURL.appendingPathComponent(fileName, isDirectory: false)
            if !fileManager.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
        }

        let conf = """
        [\(moduleName)]
        Description=UI Test Commentary
        DataPath=./modules/comments/rawcom/\(moduleName.lowercased())/
        ModDrv=RawCom
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        About=Deterministic empty commentary module for iOS parity tests.
        """
        try conf.write(
            to: modsDURL.appendingPathComponent("\(moduleName.lowercased()).conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    /**
     Seeds a deterministic empty SWORD dictionary module into a temporary module directory.

     Reader coordinator parity tests need a real dictionary category because Android's multi-window
     state tracks auxiliary documents separately from Bible/commentary documents. The empty RawLD
     payload is enough for SWORD discovery and controller switching without fixture content. Tests
     may also publish definition features so an empty module can model an installed Strong's source
     whose requested entry is absent.

     - Parameters:
       - moduleName: SWORD module initials to publish in `mods.d`.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
       - category: SWORD category string used to exercise global book selection independently from
         the RawLD backend's exact-key capability.
       - features: Optional SWORD `Feature` values, such as `GreekDef`, written in declaration order.
       - caseSensitiveKeys: Optional RawLD `CaseSensitiveKeys` value; `nil` omits the config entry.
       - strongsPadding: Optional RawLD `StrongsPadding` value; `nil` omits the config entry.
     - Side effects: Writes a `.conf` file and empty `RawLD` data files under `modulePath`.
     - Failure modes: Propagates filesystem write errors.
     */
    func seedEmptyRawDictionaryModule(
        named moduleName: String = "UITestDict",
        in modulePath: String,
        category: String = "Lexicons / Dictionaries",
        features: [String] = [],
        caseSensitiveKeys: Bool? = nil,
        strongsPadding: Bool? = nil
    ) throws {
        let fileManager = FileManager.default
        let moduleKey = moduleName.lowercased()
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let modsDURL = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let dataURL = moduleRoot
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("lexdict", isDirectory: true)
            .appendingPathComponent("rawld", isDirectory: true)
            .appendingPathComponent(moduleKey, isDirectory: true)

        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
        for fileName in ["\(moduleKey).dat", "\(moduleKey).idx"] {
            let fileURL = dataURL.appendingPathComponent(fileName, isDirectory: false)
            if !fileManager.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
        }

        let featureEntries = features.map { "Feature=\($0)" }.joined(separator: "\n")
        let keyBehaviorEntries = [
            caseSensitiveKeys.map { "CaseSensitiveKeys=\($0 ? "true" : "false")" },
            strongsPadding.map { "StrongsPadding=\($0 ? "true" : "false")" },
        ].compactMap { $0 }.joined(separator: "\n")
        let conf = """
        [\(moduleName)]
        Description=UI Test Dictionary
        Category=\(category)
        DataPath=./modules/lexdict/rawld/\(moduleKey)/\(moduleKey)
        ModDrv=RawLD
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        \(featureEntries)
        \(keyBehaviorEntries)
        About=Deterministic empty dictionary module for iOS parity tests.
        """
        try conf.write(
            to: modsDURL.appendingPathComponent("\(moduleKey).conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    /**
     Seeds one readable RawLD entry for exact-key SWORD switch preflight.

     - Parameters:
       - moduleName: SWORD module initials published by the empty dictionary fixture helper.
       - entryKey: Exact dictionary key written into the RawLD record.
       - entryXML: Structural definition body stored after the RawLD key header.
       - modulePath: Temporary SWORD module root.
     - Side effects: Writes the descriptor plus one RawLD data/index record under the fixture root.
     - Failure modes: Propagates fixture setup and file-write errors; rejects records that exceed
       RawLD's two-byte record-length field.
     */
    func seedReadableRawDictionaryModule(
        named moduleName: String,
        entryKey: String,
        entryXML: String = "<div type=\"entry\">Readable fixture</div>",
        in modulePath: String
    ) throws {
        try seedEmptyRawDictionaryModule(named: moduleName, in: modulePath)
        let moduleKey = moduleName.lowercased()
        let prefix = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("modules/lexdict/rawld/\(moduleKey)/\(moduleKey)")
        let record = Data("\(entryKey)\r\n\(entryXML)".utf8)
        var recordLength = try XCTUnwrap(UInt16(exactly: record.count)).littleEndian
        var index = Data([0, 0, 0, 0])
        withUnsafeBytes(of: &recordLength) { index.append(contentsOf: $0) }
        var data = record
        data.append(0x0A)
        try data.write(to: prefix.appendingPathExtension("dat"))
        try index.write(to: prefix.appendingPathExtension("idx"))
    }

    /**
     Seeds a deterministic empty SWORD general-book module into a temporary module directory.

     Android exposes general books as auxiliary documents in the same document-switching model as
     dictionaries and maps. This fixture gives package-level reader tests a discoverable module
     category without carrying redistributable book content.

     - Parameters:
       - moduleName: SWORD module initials to publish in `mods.d`.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
     - Side effects: Writes a `.conf` file and empty `RawGenBook` data files under `modulePath`.
     - Failure modes: Propagates filesystem write errors.
     */
    func seedEmptyRawGeneralBookModule(
        named moduleName: String = "UITestGB",
        in modulePath: String,
        features: [String] = []
    ) throws {
        let fileManager = FileManager.default
        let moduleKey = moduleName.lowercased()
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let modsDURL = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let dataURL = moduleRoot
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("genbook", isDirectory: true)
            .appendingPathComponent("rawgenbook", isDirectory: true)
            .appendingPathComponent(moduleKey, isDirectory: true)

        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
        for fileName in ["\(moduleKey).dat", "\(moduleKey).idx"] {
            let fileURL = dataURL.appendingPathComponent(fileName, isDirectory: false)
            if !fileManager.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
        }

        let featureEntries = features.map { "Feature=\($0)" }.joined(separator: "\n")
        let conf = """
        [\(moduleName)]
        Description=UI Test General Book
        Category=Generic Books
        DataPath=./modules/genbook/rawgenbook/\(moduleKey)/\(moduleKey)
        ModDrv=RawGenBook
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        \(featureEntries)
        About=Deterministic empty general book module for iOS parity tests.
        """
        try conf.write(
            to: modsDURL.appendingPathComponent("\(moduleKey).conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    /**
     Seeds a deterministic empty SWORD map module into a temporary module directory.

     Android treats map modules as selectable documents. Reader coordinator tests need a real map
     category from SWORD discovery so iOS can verify the same current-document transition without
     carrying map payloads.

     - Parameters:
       - moduleName: SWORD module initials to publish in `mods.d`.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
     - Side effects: Writes a `.conf` file and empty `RawGenBook` data files under `modulePath`.
     - Failure modes: Propagates filesystem write errors.
     */
    func seedEmptyRawMapModule(named moduleName: String = "UITestMap", in modulePath: String) throws {
        let fileManager = FileManager.default
        let moduleKey = moduleName.lowercased()
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let modsDURL = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let dataURL = moduleRoot
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("genbook", isDirectory: true)
            .appendingPathComponent("rawgenbook", isDirectory: true)
            .appendingPathComponent(moduleKey, isDirectory: true)

        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
        for fileName in ["\(moduleKey).dat", "\(moduleKey).idx"] {
            let fileURL = dataURL.appendingPathComponent(fileName, isDirectory: false)
            if !fileManager.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
        }

        let conf = """
        [\(moduleName)]
        Description=UI Test Map
        Category=Maps
        DataPath=./modules/genbook/rawgenbook/\(moduleKey)/\(moduleKey)
        ModDrv=RawGenBook
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        About=Deterministic empty map module for iOS parity tests.
        """
        try conf.write(
            to: modsDURL.appendingPathComponent("\(moduleKey).conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    /**
     Seeds an additional Bible module identity that reuses the KJV test fixture payload.

     Reader coordinator and quick-selector parity tests need multiple installed Bible module
     initials so they can exercise Android's selection and fallback contracts through
     `SwordManager`. The alias keeps the canonical KJV data files untouched and only writes a
     separate `.conf` descriptor with a different abbreviation, description, and language code.

     - Parameters:
       - moduleName: SWORD module initials to publish in `mods.d`.
       - description: Human-readable module name stored in the alias descriptor.
       - language: ISO language code used by quick-selector ordering and labels.
       - versification: SWORD canon name assigned to the alias descriptor.
       - moduleDriver: Optional driver override for metadata/classification tests.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
     - Side effects: Writes a `.conf` file under `modulePath/mods.d`.
     - Failure modes: Propagates filesystem read/write errors, including a missing KJV test fixture
       descriptor in the temporary fixture.
     */
    func seedBibleAliasModule(
        named moduleName: String,
        description: String,
        language: String = "en",
        versification: String = "KJV",
        moduleDriver: String? = nil,
        in modulePath: String
    ) throws {
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let modsDURL = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let kjvConfigURL = modsDURL.appendingPathComponent("kjv.conf", isDirectory: false)
        var config = try String(contentsOf: kjvConfigURL, encoding: .utf8)
        config = config.replacingOccurrences(of: "[KJV]", with: "[\(moduleName)]")
        config = replaceConfigLine(named: "Description", with: description, in: config)
        config = replaceConfigLine(named: "Lang", with: language, in: config)
        config = replaceConfigLine(named: "Versification", with: versification, in: config)
        if let moduleDriver {
            config = replaceConfigLine(named: "ModDrv", with: moduleDriver, in: config)
        }

        try config.write(
            to: modsDURL.appendingPathComponent("\(moduleName.lowercased()).conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    /**
     Seeds licensed-safe RawText entries against their declared JSword/SWORD versification.

     Reusing compressed KJV byte indexes behind Vulgate or LXX metadata makes native block lookups
     read incompatible offsets. This helper instead creates one sparse old-testament RawText index
     whose physical row numbers come from libsword's declared canon while test coordinates come
     from the pinned JSword contract. Each requested entry has distinct synthetic OSIS source text
     so integration tests can prove the selected module supplied content as well as identity.

     - Parameters:
       - moduleName: Exact installed module initials.
       - description: Human-readable module description.
       - versification: Pinned JSword/SWORD canon name.
       - entries: Old-testament coordinates and synthetic OSIS source stored at those exact rows.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
     - Side effects: Writes a config plus sparse RawText data/index files under the temporary root.
     - Failure modes: Unsupported canons, invalid or new-testament coordinates, oversized records,
       and filesystem failures throw before a partial module becomes observable to a manager.
     */
    func seedSyntheticRawTextBibleModule(
        named moduleName: String,
        description: String,
        versification: String,
        entries: [(osisBookID: String, chapter: Int, verse: Int, text: String)],
        in modulePath: String
    ) throws {
        let indexedEntries = try entries.map { entry in
            guard let row = SwordVersification.referenceIndex(
                for: .init(
                    osisBookId: entry.osisBookID,
                    chapter: entry.chapter,
                    verse: entry.verse
                ),
                versification: versification
            ) else {
                throw SyntheticRawTextBibleFixtureError.invalidOldTestamentReference(
                    "\(entry.osisBookID).\(entry.chapter).\(entry.verse)"
                )
            }
            return (row: row, entry: entry)
        }
        guard let highestRow = indexedEntries.map(\.row).max() else {
            throw SyntheticRawTextBibleFixtureError.missingEntries
        }
        let moduleKey = moduleName.lowercased()
        let root = URL(fileURLWithPath: modulePath, isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/texts/rawtext/\(moduleKey)",
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

        var data = Data()
        var index = [UInt8](repeating: 0, count: (highestRow + 1) * 6)
        for (row, entry) in indexedEntries {
            let record = Data(entry.text.utf8)
            guard record.count <= Int(UInt16.max), data.count <= Int(UInt32.max) else {
                throw SyntheticRawTextBibleFixtureError.recordTooLarge
            }
            let dataOffset = UInt32(data.count)
            let recordLength = UInt16(record.count)
            let indexOffset = row * 6
            index[indexOffset] = UInt8(dataOffset & 0x0000_00ff)
            index[indexOffset + 1] = UInt8((dataOffset >> 8) & 0x0000_00ff)
            index[indexOffset + 2] = UInt8((dataOffset >> 16) & 0x0000_00ff)
            index[indexOffset + 3] = UInt8((dataOffset >> 24) & 0x0000_00ff)
            index[indexOffset + 4] = UInt8(recordLength & 0x00ff)
            index[indexOffset + 5] = UInt8((recordLength >> 8) & 0x00ff)
            data.append(record)
            data.append(0x0A)
        }

        try data.write(to: dataDirectory.appendingPathComponent("ot", isDirectory: false))
        try Data(index).write(
            to: dataDirectory.appendingPathComponent("ot.vss", isDirectory: false)
        )
        try Data().write(to: dataDirectory.appendingPathComponent("nt", isDirectory: false))
        try Data().write(to: dataDirectory.appendingPathComponent("nt.vss", isDirectory: false))
        try """
        [\(moduleName)]
        Description=\(description)
        Abbreviation=\(moduleName)
        Category=Biblical Texts
        DataPath=./modules/texts/rawtext/\(moduleKey)/
        ModDrv=RawText
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=\(versification)
        """.write(
            to: configDirectory.appendingPathComponent("\(moduleKey).conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    /**
     Replaces one SWORD `.conf` key/value line while preserving the rest of the descriptor.

     - Parameters:
       - key: Configuration key to replace.
       - value: Replacement value written after the equals sign.
       - config: Full descriptor text.
     - Returns: The updated descriptor, or the original descriptor with a new line appended when the
       key was absent.
     - Side effects: none.
     - Failure modes: none; malformed input simply receives an appended key/value line.
     */
    private func replaceConfigLine(named key: String, with value: String, in config: String) -> String {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(?m)^\#(escapedKey)=.*$"#
        guard let range = config.range(of: pattern, options: .regularExpression) else {
            return config + "\n\(key)=\(value)\n"
        }
        var updatedConfig = config
        updatedConfig.replaceSubrange(range, with: "\(key)=\(value)")
        return updatedConfig
    }
}

/** Errors raised before a sparse synthetic Bible fixture can become installed. */
private enum SyntheticRawTextBibleFixtureError: Error {
    /// A source-valid fixture must declare at least one exact entry.
    case missingEntries
    /// The requested entry is invalid or not in the old-testament index used by the fixture.
    case invalidOldTestamentReference(String)
    /// RawText's fixed-width index cannot represent the entry or accumulated data offset.
    case recordTooLarge
}
