import XCTest
@testable import SwordKit

/**
 App-host-free package coverage for Android download metadata parsing.

 These tests protect the SwordKit-owned metadata contracts consumed by Downloads and startup
 default-module selection. Failures indicate repository metadata drift, not SwiftUI presentation or
 app bootstrap behavior.
 */
final class ModuleDownloadMetadataTests: XCTestCase {
    /**
     Verifies Android metadata tokens decode scoped sources and bad-document actions.

     Android metadata can identify a document by module only, module plus source, or module/source
     plus version and action. The decoder must preserve those forms so recommended/default rows,
     warning rows, hidden rows, and add-ons resolve the same way in iOS.
     */
    func testDownloadConfigurationDecodesAndroidMetadataEntries() throws {
        let data = """
        {
          "bibles": {"en": ["KJV::CrossWire", "ASV"]},
          "commentaries": {},
          "dictionaries": {},
          "books": {},
          "maps": {},
          "addons": {"en": ["AddonFonts::AndBible"]}
        }
        """.data(using: .utf8)!
        let recommended = try JSONDecoder().decode(ModuleDownloadConfiguration.self, from: data)
        let bad = ModuleDownloadConfiguration(
            bibles: ["en": ["KJV::CrossWire::2.3::W", "WEB::CrossWire::1.0::H"]],
            addons: ["en": ["AddonFonts::AndBible::1.0::W"]]
        )
        let kjv = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire",
            version: "2.3"
        )
        let asv = RemoteModuleInfo(
            name: "ASV",
            description: "American Standard Version",
            category: .bible,
            language: "en",
            sourceName: "Different",
            version: "1.0"
        )
        let web = RemoteModuleInfo(
            name: "WEB",
            description: "World English Bible",
            category: .bible,
            language: "en",
            sourceName: "CrossWire",
            version: "1.0"
        )
        let addon = RemoteModuleInfo(
            name: "AddonFonts",
            description: "Add-on font pack",
            category: .addon,
            language: "zxx",
            sourceName: "AndBible",
            version: "1.0"
        )

        XCTAssertTrue(recommended.contains(kjv))
        XCTAssertTrue(recommended.contains(asv))
        XCTAssertTrue(recommended.contains(addon))
        XCTAssertEqual(recommended.addons, ["en": ["AddonFonts::AndBible"]])
        XCTAssertEqual(bad.badDocumentAction(for: kjv), .warn)
        XCTAssertEqual(bad.badDocumentAction(for: addon), .warn)
        XCTAssertEqual(bad.badDocumentAction(for: web), .hide)
        XCTAssertEqual(bad.badDocumentAction(for: asv), .none)
    }

    /**
     Verifies iOS preserves Android's `InstallSize` units when parsing catalog rows.

     Android reads SWORD `KEY_INSTALL_SIZE` directly as bytes and formats that value as megabytes.
     iOS must not multiply it by 1024, because that inflates catalog sizes by three orders of
     magnitude and makes the Downloads browser disagree with Android for the same repository row.
     */
    func testCatalogModulePreservesAndroidInstallSizeBytes() {
        let module = CatalogModule(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            modDrv: "zText",
            dataPath: "modules/texts/ztext/kjv/",
            confContent: "",
            sourceName: "CrossWire",
            version: "1.0",
            size: "1260000"
        )

        XCTAssertEqual(module.remoteModuleInfo.installSizeBytes, 1_260_000)
    }
}
