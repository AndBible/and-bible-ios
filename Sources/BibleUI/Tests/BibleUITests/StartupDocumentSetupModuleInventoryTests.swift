import Foundation
import XCTest

@testable import BibleUI
import SwordKit

/** Cross-backend integration coverage for the reader's fresh startup module inventory. */
final class StartupDocumentSetupModuleInventoryTests: XCTestCase {
    /**
     Verifies native full-name ownership shadows a colliding readable SQLite Bible at startup.

     - Setup: Supplies one locked native Bible whose full description equals a readable SQLite
       Bible's initials, reproducing the global lookup path that differs from initials-only merging.
     - Expected result: The merge keeps only the native row and startup remains classified as
       locked-only instead of treating the runtime-shadowed SQLite row as readable.
     - Failure meaning: Startup can enter the reader with a Bible that later resolves to the locked
       native owner, producing an unlock or navigation failure after setup was dismissed.
     - Side effects: None.
     */
    func testLockedNativeFullNameShadowsReadableSQLiteStartupCollision() {
        let lockedNative = ModuleInfo(
            name: "NET",
            description: "MyBible-CollisionToken",
            category: .bible,
            language: "en",
            moduleDriver: "RawText",
            isEncrypted: true,
            isUnlocked: false
        )
        let readableSQLite = ModuleInfo(
            name: "MyBible-CollisionToken",
            description: "Manual SQLite Bible",
            category: .bible,
            language: "en",
            moduleDriver: "MyBibleBible"
        )

        let inventory = StartupDocumentSetupModuleInventory.merge(
            nativeModules: [lockedNative],
            sqliteBibleModules: [readableSQLite]
        )

        XCTAssertEqual(inventory.map(\.name), ["NET"])
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(in: inventory),
            .lockedBibleModules
        )
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
}
