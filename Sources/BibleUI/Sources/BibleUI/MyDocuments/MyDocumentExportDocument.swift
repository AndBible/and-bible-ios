// MyDocumentExportDocument.swift -- FileDocument projection for Android My Documents exports

import BibleCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/**
 Projects one Android-compatible Markdown or HTML export entry into SwiftUI's system file handoff.

 Android exports a document as individually named page files and exports a page with its matching
 text MIME type. The wrapper preserves BibleCore's deterministic filename and UTF-8 payload while
 allowing the app-owned manager to hand only the final filesystem operation to the platform.

 Inputs: one `MyDocumentExportFile` produced by `MyDocumentTransferService`

 Output: a regular file wrapper with the Android filename retained as `preferredFilename`

 Side effects: none until SwiftUI writes the returned wrapper to a user-selected destination

 Failure modes: importing malformed non-UTF-8 data throws Cocoa's file-read error
 */
struct MyDocumentExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .html, .text]

    let fileName: String
    let content: String
    let contentType: UTType

    /** Creates an export wrapper from BibleCore's deterministic transfer record. */
    init(file: MyDocumentExportFile) {
        fileName = file.fileName
        content = file.content
        contentType = file.fileName.lowercased().hasSuffix(".html")
            || file.fileName.lowercased().hasSuffix(".htm")
            ? .html
            : .plainText
    }

    /** Reconstructs a wrapper when required by the `FileDocument` protocol. */
    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        fileName = configuration.file.preferredFilename ?? "page.md"
        content = decoded
        contentType = configuration.contentType
    }

    /** Returns one UTF-8 regular-file wrapper without rewriting the Android filename. */
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        makeFileWrapper()
    }

    /**
     Builds the deterministic wrapper independently of SwiftUI's platform-only write configuration.

     Tests call this seam because SwiftUI intentionally exposes no public initializer for
     `FileDocumentWriteConfiguration`; production delegates to the same implementation.
     */
    func makeFileWrapper() -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: Data(content.utf8))
        wrapper.preferredFilename = fileName
        return wrapper
    }
}
