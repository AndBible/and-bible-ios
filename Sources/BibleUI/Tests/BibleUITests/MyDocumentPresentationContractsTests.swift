// MyDocumentPresentationContractsTests.swift -- Android My Documents presentation contracts

import BibleCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import BibleUI

final class MyDocumentPresentationContractsTests: XCTestCase {
    /**
     Verifies a Markdown transfer record keeps Android's exact filename, payload, and MIME family.

     The app-owned manager must not rewrite filenames or coerce Markdown into an HTML handoff before
     SwiftUI performs the final platform file operation.

     - Inputs: A deterministic Markdown `MyDocumentExportFile` fixture.
     - Outputs: Assertions over the projected document and regular-file wrapper.
     - Side effects: Allocates an in-memory `FileWrapper`; no filesystem write occurs.
     - Failure modes: Fails when filename, content, type, or UTF-8 wrapper data drift.
     */
    func testMarkdownExportPreservesAndroidFilenameContentAndType() throws {
        let document = MyDocumentExportDocument(file: MyDocumentExportFile(
            fileName: "01 - Grace.md",
            contentType: "text/markdown",
            content: "# Grace\n"
        ))

        XCTAssertEqual(document.fileName, "01 - Grace.md")
        XCTAssertEqual(document.content, "# Grace\n")
        XCTAssertEqual(document.contentType, .plainText)

        let wrapper = document.makeFileWrapper()
        XCTAssertEqual(wrapper.preferredFilename, "01 - Grace.md")
        XCTAssertEqual(wrapper.regularFileContents, Data("# Grace\n".utf8))
    }

    /**
     Verifies HTML extensions select HTML without changing Android's transfer payload.

     - Inputs: A deterministic HTML `MyDocumentExportFile` fixture.
     - Outputs: Assertions over the projected filename, content, and `UTType`.
     - Side effects: None.
     - Failure modes: Fails when HTML detection or payload preservation regresses.
     */
    func testHTMLExportSelectsHTMLContentType() {
        let document = MyDocumentExportDocument(file: MyDocumentExportFile(
            fileName: "Sermon.htm",
            contentType: "text/html",
            content: "<h1>Sermon</h1>"
        ))

        XCTAssertEqual(document.fileName, "Sermon.htm")
        XCTAssertEqual(document.content, "<h1>Sermon</h1>")
        XCTAssertEqual(document.contentType, .html)
    }

    /**
     Verifies Android's document dialogs expose description editing only for that exact command.

     - Inputs: Every `MyDocumentMetadataEditorPurpose` case.
     - Outputs: Assertions over the derived field-semantics flag.
     - Side effects: None.
     - Failure modes: Fails if create, rename, or import accidentally gain the multiline description
       behavior, or if Edit description loses it.
     */
    func testDocumentDialogPurposesKeepAndroidFieldSemantics() {
        let documentID = UUID()

        XCTAssertFalse(MyDocumentMetadataEditorPurpose.create.editsDescription)
        XCTAssertFalse(MyDocumentMetadataEditorPurpose.rename(documentID: documentID).editsDescription)
        XCTAssertTrue(MyDocumentMetadataEditorPurpose.editDescription(documentID: documentID).editsDescription)
        XCTAssertFalse(MyDocumentMetadataEditorPurpose.importDocument.editsDescription)
    }

    /**
     Verifies only Android's Create page dialog exposes the Markdown/HTML type selection.

     - Inputs: Create and rename page-editor requests.
     - Outputs: Assertions over the derived content-type-selection contract.
     - Side effects: None.
     - Failure modes: Fails if Rename exposes an unsupported type mutation or Create hides it.
     */
    func testPageDialogAllowsContentTypeSelectionOnlyWhileCreating() {
        let create = MyDocumentPageEditorRequest(
            pageID: nil,
            title: "Create page",
            initialTitle: "",
            initialContentType: .markdown
        )
        let rename = MyDocumentPageEditorRequest(
            pageID: UUID(),
            title: "Rename page",
            initialTitle: "Grace",
            initialContentType: .html
        )

        XCTAssertTrue(create.allowsContentTypeSelection)
        XCTAssertFalse(rename.allowsContentTypeSelection)
    }
}
