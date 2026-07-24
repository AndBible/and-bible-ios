import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView

/**
 End-to-end controller tests for EPUBs presented through Android's general-book contract.

 Each test installs a real EPUB ZIP into the app library, restores or navigates a reader controller,
 and inspects both durable `PageManager` state and the emitted Vue payload. This catches regressions
 that adapter-only tests cannot see, including reintroduction of iOS-only EPUB identity fields.
 */
@MainActor
final class EpubReaderControllerParityTests: XCTestCase {
    /**
     Restores an EPUB from Android-compatible general-book state and renders its exact numeric key.

     Setup installs a two-spine EPUB, persists the second numeric fragment key under the EPUB's
     module initials, and creates a controller without SWORD initialization. The expected result is
     a `GENERAL_BOOK` native-HTML payload whose key, initials, and ordinal range come from that exact
     indexed fragment. A failure means cold-start restore can select the wrong section or leak the
     former iOS-only EPUB identity into the reader contract.
     */
    func testRestoreUsesGeneralBookIdentityAndRendersPersistedNumericKey() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try EpubReader.install(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let expected = try XCTUnwrap(reader.content(forKey: "2"))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = makeWindow(
            category: DocumentCategory.generalBook.pageManagerKey,
            generalBookDocument: reader.initials,
            generalBookKey: expected.persistedKey
        )
        controller.activeWindow = window

        controller.restoreSavedPosition()
        controller.loadCurrentContent()

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeGeneralBookModuleName, reader.initials)
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertEqual(controller.currentGeneralBookKey, expected.persistedKey)
        XCTAssertNil(window.pageManager?.epubIdentifier)
        XCTAssertNil(window.pageManager?.epubHref)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["bookInitials"] as? String, reader.initials)
        XCTAssertEqual(payload["bookCategory"] as? String, DocumentCategory.generalBook.rawValue)
        XCTAssertEqual(payload["bookName"] as? String, reader.title)
        XCTAssertEqual(payload["key"] as? String, expected.persistedKey)
        XCTAssertEqual(payload["isNativeHtml"] as? Bool, true)
        XCTAssertEqual(
            payload["ordinalRange"] as? [Int],
            [expected.ordinalRange.lowerBound, expected.ordinalRange.upperBound]
        )
        let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
        XCTAssertEqual(fragment["key"] as? String, "\(reader.initials)--\(expected.persistedKey)")
        XCTAssertEqual(fragment["keyName"] as? String, expected.title)
        XCTAssertEqual(fragment["bookInitials"] as? String, reader.initials)
    }

    /**
     Adopts an explicitly rebuilt EPUB generation without losing Android general-book position.

     The controller opens the second numeric key, BibleCore atomically publishes a replacement
     index generation, and the controller adopts it through the same activation contract used by
     ordinary EPUB switching. The current key and PageManager identity must remain exact. A reader
     from a separately installed EPUB must be rejected without changing the adopted generation.
     Failure means Rebuild index can jump content, leave resource URLs on a pruned generation, or
     replace the active pane after a stale cross-document callback.
     */
    func testRebuiltEpubGenerationAdoptionPreservesKeyAndRejectsDifferentDocument() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try EpubReader.install(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)
        controller.loadEpubEntry(key: "2")
        let originalGeneration = try XCTUnwrap(controller.activeEpubReader).generationIdentifier

        let rebuiltReader = try EpubReader.rebuildSearchIndex(identifier: identifier)

        XCTAssertTrue(controller.adoptRebuiltEpubReader(rebuiltReader))
        XCTAssertNotEqual(rebuiltReader.generationIdentifier, originalGeneration)
        XCTAssertEqual(
            controller.activeEpubReader?.generationIdentifier,
            rebuiltReader.generationIdentifier
        )
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookDocument, rebuiltReader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")

        let foreignArchiveURL = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: foreignArchiveURL.deletingLastPathComponent())
        }
        let foreignIdentifier = try EpubReader.install(epubURL: foreignArchiveURL)
        defer { try? EpubReader.delete(identifier: foreignIdentifier) }
        let foreignReader = try XCTUnwrap(EpubReader(identifier: foreignIdentifier))

        XCTAssertFalse(controller.adoptRebuiltEpubReader(foreignReader))
        XCTAssertEqual(
            controller.activeEpubReader?.generationIdentifier,
            rebuiltReader.generationIdentifier
        )
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
    }

    /**
     Migrates legacy EPUB fields into Android's durable general-book identity exactly once.

     Setup persists the legacy package identifier and an XHTML href with an anchor. Restore must
     resolve that href through the indexed manifest/id mapping, write module initials plus numeric
     key, clear the old fields, and request persistence once. A failure means existing local tabs
     can reopen at the wrong fragment or remain permanently outside Android's page-state model.
     */
    func testRestoreMigratesLegacyEpubHrefIntoGeneralBookState() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try EpubReader.install(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        let window = makeWindow(category: DocumentCategory.epub.pageManagerKey)
        window.pageManager?.epubIdentifier = identifier
        window.pageManager?.epubHref = "OPS/text/second.xhtml#target"
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.restoreSavedPosition()

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(window.pageManager?.generalBookDocument, reader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        XCTAssertNil(window.pageManager?.epubIdentifier)
        XCTAssertNil(window.pageManager?.epubHref)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Routes transformed EPUB references only within their originating general-book document.

     Setup restores the first numeric fragment, sends links carrying foreign and case-only impostor
     initials, then the equivalent link carrying the active EPUB initials and manifest id. Both
     impostors must be inert; the valid request must persist key `2`, emit that fragment, and
     preserve its `target` jump id. A failure means overlapping hrefs from distinct EPUB identities
     can cross-navigate or internal anchors can lose their exact destination at the bridge boundary.
     */
    func testInternalLinkRequiresMatchingInitialsAndNavigatesToIndexedAnchor() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try EpubReader.install(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = makeWindow(
            category: DocumentCategory.generalBook.pageManagerKey,
            generalBookDocument: reader.initials,
            generalBookKey: "1"
        )
        controller.activeWindow = window
        controller.restoreSavedPosition()

        controller.bridge(bridge, openEpubLink: "Epub-Foreign", toKey: "second", toId: "target")
        XCTAssertEqual(controller.currentGeneralBookKey, "1")
        XCTAssertTrue(recordedScripts().isEmpty)

        let caseOnlyImpostor = reader.initials.uppercased()
        XCTAssertNotEqual(caseOnlyImpostor, reader.initials)
        controller.bridge(bridge, openEpubLink: caseOnlyImpostor, toKey: "second", toId: "target")
        XCTAssertEqual(controller.currentGeneralBookKey, "1")
        XCTAssertTrue(recordedScripts().isEmpty)

        controller.bridge(bridge, openEpubLink: reader.initials, toKey: "second", toId: "target")

        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookDocument, reader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["key"] as? String, "2")
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(setup["jumpToId"] as? String, "target")
    }

    /**
     Releases an active deleted EPUB and clears its persisted general-book identity.

     The fixture opens a real EPUB without a SWORD Bible, commits storage deletion, and reconciles
     the owning controller. The reader must release its immutable generation, enter the Bible
     category, and clear every EPUB/general-book page-manager field. A failure leaves deleted local
     content active indefinitely or allows a later restore to resurrect its stale identity.
     */
    func testCommittedEpubDeletionReturnsActivePaneToBibleState() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try EpubReader.install(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window

        controller.switchEpub(identifier: identifier)
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertNotNil(window.pageManager?.generalBookDocument)

        try EpubReader.delete(identifier: identifier)
        controller.reconcileDeletedEpub(identifier: identifier)

        XCTAssertNil(controller.activeEpubReader)
        XCTAssertNil(controller.activeEpubIdentifier)
        XCTAssertNil(controller.activeGeneralBookModuleName)
        XCTAssertNil(controller.currentGeneralBookKey)
        XCTAssertEqual(controller.currentCategory, .bible)
        XCTAssertEqual(window.pageManager?.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertNil(window.pageManager?.generalBookDocument)
        XCTAssertNil(window.pageManager?.generalBookKey)
        XCTAssertNil(window.pageManager?.epubIdentifier)
        XCTAssertNil(window.pageManager?.epubHref)
    }

    /**
     Creates an unpersisted window with one explicit page-manager document state.

     - Parameters:
       - category: Persisted Android page-manager category key.
       - generalBookDocument: Optional general-book module initials.
       - generalBookKey: Optional durable numeric/general-book key.
     - Returns: Detached window whose page manager is ready for controller restore.
     - Side effects: Allocates in-memory SwiftData model objects without inserting a context.
     - Failure modes: None.
     */
    private func makeWindow(
        category: String,
        generalBookDocument: String? = nil,
        generalBookKey: String? = nil
    ) -> Window {
        let window = Window()
        let pageManager = PageManager(id: window.id, currentCategoryName: category)
        pageManager.generalBookDocument = generalBookDocument
        pageManager.generalBookKey = generalBookKey
        window.pageManager = pageManager
        return window
    }

    /**
     Writes a real two-spine EPUB 3 archive with one cross-spine anchor target.

     - Returns: Temporary `.epub` URL whose parent directory is owned by the caller.
     - Side effects: Creates one temporary directory and stored ZIP archive.
     - Throws: File-system or ZIP-writer errors.
     */
    private func makeArchive() throws -> URL {
        let title = "EPUB Controller Fixture \(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-controller-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("\(title).epub")
        let entries: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """),
            ("OPS/package.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="first" href="text/first.xhtml" media-type="application/xhtml+xml"/>
                <item id="second" href="text/second.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="first"/><itemref idref="second"/></spine>
            </package>
            """),
            ("OPS/nav.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body><nav epub:type="toc"><ol>
                <li><a href="text/first.xhtml#start">First</a></li>
                <li><a href="text/second.xhtml#target">Second</a></li>
              </ol></nav></body>
            </html>
            """),
            ("OPS/text/first.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <section id="start"><p>First section.</p><a href="second.xhtml#target">Next</a></section>
            </body></html>
            """),
            ("OPS/text/second.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <section id="target"><p>Second section. Exact restore target.</p></section>
            </body></html>
            """)
        ]
        let archive = try ZipArchiveWriter.storedArchive(entries: entries.map {
            ZipArchiveWriterEntry(name: $0.0, data: Data($0.1.utf8))
        })
        try archive.write(to: archiveURL, options: .atomic)
        return archiveURL
    }
}
