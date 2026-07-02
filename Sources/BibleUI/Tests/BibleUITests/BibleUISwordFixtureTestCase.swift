import Foundation
import XCTest

/**
 Base test case for BibleUI package tests that need temporary SWORD modules.

 The fixture mirrors the app-host test helper's behavior without depending on the shared
 `AndBibleTests` superclass. Each test receives a copied test-only SWORD tree under a unique
 temporary directory, and teardown removes every path registered through
 `makeTemporarySwordFixturePath()`.
 */
class BibleUISwordFixtureTestCase: XCTestCase {
    private var temporarySwordModulePaths: [String] = []

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
        super.tearDown()
    }

    /**
     Copies the repository test SWORD fixture into an isolated temporary module root.

     - Returns: Filesystem path to the temporary `sword` directory containing `mods.d` and module
       data files.
     - Side effects: Creates a temporary directory and copies test fixture files into it.
     - Failure modes: Throws filesystem errors from directory creation or recursive copying; records
       an XCTest failure if the repository fixture path cannot be found.
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
     payload is enough for SWORD discovery and controller switching without fixture content.

     - Parameters:
       - moduleName: SWORD module initials to publish in `mods.d`.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
     - Side effects: Writes a `.conf` file and empty `RawLD` data files under `modulePath`.
     - Failure modes: Propagates filesystem write errors.
     */
    func seedEmptyRawDictionaryModule(named moduleName: String = "UITestDict", in modulePath: String) throws {
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

        let conf = """
        [\(moduleName)]
        Description=UI Test Dictionary
        Category=Lexicons / Dictionaries
        DataPath=./modules/lexdict/rawld/\(moduleKey)/\(moduleKey)
        ModDrv=RawLD
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        About=Deterministic empty dictionary module for iOS parity tests.
        """
        try conf.write(
            to: modsDURL.appendingPathComponent("\(moduleKey).conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
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
    func seedEmptyRawGeneralBookModule(named moduleName: String = "UITestGB", in modulePath: String) throws {
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
        Description=UI Test General Book
        Category=Generic Books
        DataPath=./modules/genbook/rawgenbook/\(moduleKey)/\(moduleKey)
        ModDrv=RawGenBook
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
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
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
     - Side effects: Writes a `.conf` file under `modulePath/mods.d`.
     - Failure modes: Propagates filesystem read/write errors, including a missing KJV test fixture
       descriptor in the temporary fixture.
     */
    func seedBibleAliasModule(
        named moduleName: String,
        description: String,
        language: String = "en",
        in modulePath: String
    ) throws {
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let modsDURL = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        let kjvConfigURL = modsDURL.appendingPathComponent("kjv.conf", isDirectory: false)
        var config = try String(contentsOf: kjvConfigURL, encoding: .utf8)
        config = config.replacingOccurrences(of: "[KJV]", with: "[\(moduleName)]")
        config = replaceConfigLine(named: "Description", with: description, in: config)
        config = replaceConfigLine(named: "Lang", with: language, in: config)

        try config.write(
            to: modsDURL.appendingPathComponent("\(moduleName.lowercased()).conf", isDirectory: false),
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
