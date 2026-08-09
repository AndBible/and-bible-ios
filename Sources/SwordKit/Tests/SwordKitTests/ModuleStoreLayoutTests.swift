import Foundation
import XCTest
@testable import SwordKit

/**
 Security and ownership coverage for the canonical SWORD installed-layout resolver.

 Every fixture uses raw config content because the transactional install contract requires validation before parser
 normalization can hide lexical traversal. Failures indicate archive or installed-config paths can
 escape `modules/`, claim another module's payload, or publish an incomplete module.
 */
final class ModuleStoreLayoutTests: XCTestCase {
    /**
     Verifies directory and filename-prefix drivers bind their whole data directory like Android.

     Failure means stem modules cannot ship auxiliary files (`BuildModule`, `images/`) beside their
     stem data as real CrossWire packages do, or any driver can claim a sibling module's directory.
     */
    func testResolverBindsDirectoryAndFilenamePrefixDriverLayouts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let resolver = ModuleStoreInstalledLayoutResolver(moduleRootURL: root)

        let directory = try resolver.resolve(configuration(
            name: "KJV",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/kjv/"
        ))
        XCTAssertEqual(directory.payloadShape, .directory)
        XCTAssertTrue(directory.ownsPayload(atRelativePath: "modules/texts/rawtext/kjv/ot"))
        XCTAssertFalse(directory.ownsPayload(atRelativePath: "modules/texts/rawtext/kjva/ot"))

        let prefix = try resolver.resolve(configuration(
            name: "STRONGS",
            driver: "RawLD4",
            dataPath: "./modules/lexdict/rawld4/strongs/strongs"
        ))
        XCTAssertEqual(prefix.payloadShape, .filenamePrefix("strongs"))
        XCTAssertTrue(prefix.ownsPayload(atRelativePath: "modules/lexdict/rawld4/strongs/strongs.dat"))
        XCTAssertTrue(prefix.ownsPayload(atRelativePath: "modules/lexdict/rawld4/strongs/BuildModule"))
        XCTAssertFalse(prefix.ownsPayload(atRelativePath: "modules/lexdict/rawld4/other/strongs.dat"))
    }

    /**
     Verifies stem layouts own auxiliary files and nested subdirectories like Android extraction.

     Failure means real CrossWire stem modules that ship `BuildModule` scripts or ThML `images/`
     directories beside their stem files (EpiphanyMaps, OpenHymnal, WebstersLinked,
     StrongsRealGreek) are rejected at install even though Android installs them verbatim.
     */
    func testResolverBindsStemDriverAuxiliaryAndNestedPayload() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let resolver = ModuleStoreInstalledLayoutResolver(moduleRootURL: root)

        let maps = try resolver.resolve(configuration(
            name: "EpiphanyMaps",
            driver: "RawLD4",
            dataPath: "./modules/lexdict/rawld4/epiphany-maps/maps"
        ))
        XCTAssertEqual(maps.payloadShape, .filenamePrefix("maps"))
        XCTAssertTrue(maps.ownsPayload(atRelativePath: "modules/lexdict/rawld4/epiphany-maps/maps.dat"))
        XCTAssertTrue(maps.ownsPayload(
            atRelativePath: "modules/lexdict/rawld4/epiphany-maps/images/israjesu.jpg"
        ))
        XCTAssertTrue(maps.ownsPayload(atRelativePath: "modules/lexdict/rawld4/epiphany-maps/BuildModule"))
        XCTAssertFalse(maps.ownsPayload(atRelativePath: "modules/lexdict/rawld4/other/images/israjesu.jpg"))

        let hymnal = try resolver.resolve(configuration(
            name: "OpenHymnal",
            driver: "RawGenBook",
            dataPath: "./modules/genbook/rawgenbook/openhymnal/openhymnal"
        ))
        XCTAssertEqual(hymnal.payloadShape, .filenamePrefix("openhymnal"))
        XCTAssertTrue(hymnal.ownsPayload(
            atRelativePath: "modules/genbook/rawgenbook/openhymnal/openhymnal.bdt"
        ))
        XCTAssertTrue(hymnal.ownsPayload(
            atRelativePath: "modules/genbook/rawgenbook/openhymnal/images/Abide_With_Me-Eventide.gif"
        ))
    }

    /**
     Verifies a trailing-slash `DataPath` binds directory ownership even for stem-capable drivers.

     Failure means font add-ons such as FontPack (RawGenBook with a directory `DataPath` whose
     payload lives in nested subdirectories) are rejected at install for owning payload "outside"
     their own declared data directory.
     */
    func testResolverBindsTrailingSlashStemDriverDataPathAsDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let resolver = ModuleStoreInstalledLayoutResolver(moduleRootURL: root)

        let fontPack = try resolver.resolve(configuration(
            name: "FontPack",
            driver: "RawGenBook",
            dataPath: "./modules/texts/ztext/FontPack/"
        ))
        XCTAssertEqual(fontPack.payloadShape, .directory)
        XCTAssertEqual(fontPack.dataDirectoryRelativePath, "modules/texts/ztext/FontPack")
        XCTAssertTrue(fontPack.ownsPayload(
            atRelativePath: "modules/texts/ztext/FontPack/and-bible/AntiochText.ttf"
        ))
        XCTAssertTrue(fontPack.ownsPayload(atRelativePath: "modules/texts/ztext/FontPack/readme.txt"))
        XCTAssertFalse(fontPack.ownsPayload(atRelativePath: "modules/texts/ztext/FontPack2/font.ttf"))
        XCTAssertFalse(fontPack.ownsPayload(atRelativePath: "modules/texts/ztext/other/font.ttf"))
    }

    /**
     Verifies every forbidden lexical `DataPath` form is rejected from raw config text.

     Failure means an absolute, empty, dot-component, backslash, encoded traversal, repeated
     separator, or disguised second leading-dot path can reach URL construction.
     */
    func testResolverRejectsUnsafeRawDataPathForms() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let resolver = ModuleStoreInstalledLayoutResolver(moduleRootURL: root)
        let unsafePaths = [
            "",
            ".",
            "..",
            "/modules/texts/rawtext/kjv",
            "modules\\texts\\rawtext\\kjv",
            "modules/texts/../rawtext/kjv",
            "modules/texts/./rawtext/kjv",
            "modules//texts/rawtext/kjv",
            "modules/%2e%2e/escape",
            "././modules/texts/rawtext/kjv",
            "./../modules/texts/rawtext/kjv",
            "mods.d/kjv",
        ]

        for dataPath in unsafePaths {
            XCTAssertThrowsError(
                try resolver.resolve(configuration(name: "KJV", driver: "RawText", dataPath: dataPath)),
                "Expected unsafe DataPath to fail: \(dataPath)"
            ) { error in
                guard case ModuleStoreMutationError.unsafeDataPath = error else {
                    return XCTFail("Unexpected error for \(dataPath): \(error)")
                }
            }
        }
    }

    /**
     Verifies canonical containment rejects a `modules` symlink that points outside the SWORD root.

     Failure means lexical validation can be bypassed with a filesystem alias before publication.
     */
    func testResolverRejectsCanonicalSymlinkEscape() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("sword", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("modules"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let resolver = ModuleStoreInstalledLayoutResolver(moduleRootURL: root)
        XCTAssertThrowsError(try resolver.resolve(configuration(
            name: "KJV",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/kjv/"
        ))) { error in
            guard case ModuleStoreMutationError.canonicalPathEscape = error else {
                return XCTFail("Expected canonical escape, received \(error)")
            }
        }
    }

    /**
     Verifies distinct in-root symlink aliases cannot give two configs ownership of one payload.

     Failure means lexical `DataPath` comparison can miss a canonical collision and uninstall or
     replacement can move data still owned by another installed config.
     */
    func testResolverRejectsCanonicalSymlinkAliasOwnership() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let payloadParent = root.appendingPathComponent("modules/texts/rawtext", isDirectory: true)
        let canonicalPayload = payloadParent.appendingPathComponent("shared", isDirectory: true)
        let aliasPayload = payloadParent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalPayload, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasPayload, withDestinationURL: canonicalPayload)

        let resolver = ModuleStoreInstalledLayoutResolver(moduleRootURL: root)
        let canonical = configuration(
            name: "ONE",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/shared/"
        )
        let aliased = configuration(
            name: "TWO",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/alias/"
        )

        XCTAssertThrowsError(try resolver.validateStagedInstall(
            configurations: [canonical, aliased],
            payloadRelativePaths: [
                "modules/texts/rawtext/shared/ot",
                "modules/texts/rawtext/alias/nt",
            ]
        )) { error in
            guard case ModuleStoreMutationError.overlappingModuleTargets = error else {
                return XCTFail("Expected canonical target collision, received \(error)")
            }
        }
    }

    /**
     Verifies staged validation rejects duplicate initials and config files owned by another module.

     Failure means archive metadata can replace a different module's config or make publication
     order decide which duplicate initials survive.
     */
    func testStagedPlanRejectsDuplicateInitialsAndOtherModuleConfiguration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let resolver = ModuleStoreInstalledLayoutResolver(moduleRootURL: root)
        let duplicate = configuration(
            name: "KJV",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/kjv/"
        )

        XCTAssertThrowsError(try resolver.validateStagedInstall(
            configurations: [duplicate, duplicate],
            payloadRelativePaths: ["modules/texts/rawtext/kjv/ot"]
        )) { error in
            guard case ModuleStoreMutationError.duplicateModuleInitials = error else {
                return XCTFail("Expected duplicate initials, received \(error)")
            }
        }

        let mismatched = ModuleStoreStagedConfiguration(
            relativePath: "mods.d/asv.conf",
            content: String(data: configData(
                name: "KJV",
                driver: "RawText",
                dataPath: "./modules/texts/rawtext/kjv/"
            ), encoding: .utf8)!
        )
        XCTAssertThrowsError(try resolver.validateStagedInstall(
            configurations: [mismatched],
            payloadRelativePaths: ["modules/texts/rawtext/kjv/ot"]
        )) { error in
            guard case ModuleStoreMutationError.configNameMismatch = error else {
                return XCTFail("Expected config ownership mismatch, received \(error)")
            }
        }
    }

    /**
     Verifies every staged payload has exactly one owner and every config has payload.

     Failure means unrelated files can hitchhike into the live tree, incomplete configs can be
     installed, or two modules can claim one target.
     */
    func testStagedPlanRejectsMissingUnownedAndOverlappingPayloadOwnership() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let resolver = ModuleStoreInstalledLayoutResolver(moduleRootURL: root)
        let kjv = configuration(
            name: "KJV",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/kjv/"
        )

        XCTAssertThrowsError(try resolver.validateStagedInstall(
            configurations: [kjv],
            payloadRelativePaths: ["modules/texts/rawtext/asv/ot"]
        )) { error in
            guard case ModuleStoreMutationError.unownedPayload = error else {
                return XCTFail("Expected unowned payload, received \(error)")
            }
        }

        XCTAssertThrowsError(try resolver.validateStagedInstall(
            configurations: [kjv],
            payloadRelativePaths: []
        )) { error in
            guard case ModuleStoreMutationError.missingPayload = error else {
                return XCTFail("Expected missing payload, received \(error)")
            }
        }

        let sharedOne = configuration(
            name: "ONE",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/shared/"
        )
        let sharedTwo = configuration(
            name: "TWO",
            driver: "RawText",
            dataPath: "./modules/texts/rawtext/shared/"
        )
        XCTAssertThrowsError(try resolver.validateStagedInstall(
            configurations: [sharedOne, sharedTwo],
            payloadRelativePaths: ["modules/texts/rawtext/shared/ot"]
        )) { error in
            guard case ModuleStoreMutationError.overlappingModuleTargets = error else {
                return XCTFail("Expected overlapping targets, received \(error)")
            }
        }
    }

    /** Creates a temporary SWORD root with canonical `mods.d` and `modules` subtrees. */
    private func makeRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mods.d", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("modules", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    /** Builds one raw staged config while preserving the supplied `DataPath` text. */
    private func configuration(
        name: String,
        driver: String,
        dataPath: String
    ) -> ModuleStoreStagedConfiguration {
        ModuleStoreStagedConfiguration(
            relativePath: "mods.d/\(name.lowercased()).conf",
            content: String(
                data: configData(name: name, driver: driver, dataPath: dataPath),
                encoding: .utf8
            )!
        )
    }

    /** Builds minimal UTF-8 SWORD config data for layout fixtures. */
    private func configData(name: String, driver: String, dataPath: String) -> Data {
        Data(
            """
            [\(name)]
            ModDrv=\(driver)
            DataPath=\(dataPath)
            Description=\(name)

            """.utf8
        )
    }
}
