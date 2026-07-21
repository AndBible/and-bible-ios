// MyDocumentNativeFileTransfer.swift -- Native URL adaptation for My Documents import/export

import BibleCore
import Foundation

/**
 Adapts security-scoped native file URLs to BibleCore's deterministic transfer contracts.
 */
enum MyDocumentNativeFileTransfer {
    /** Reads selected UTF-8 text URLs without retaining security-scoped access. */
    static func importFiles(at urls: [URL]) throws -> [MyDocumentImportFile] {
        try urls.map { url in
            let gainedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gainedAccess { url.stopAccessingSecurityScopedResource() }
            }
            return MyDocumentImportFile(
                fileName: url.lastPathComponent,
                content: try String(contentsOf: url, encoding: .utf8)
            )
        }
    }

    /**
     Writes export payloads into a fresh temporary directory for the native share/save surface.
     */
    static func exportURLs(
        for files: [MyDocumentExportFile],
        directoryName: String
    ) throws -> [URL] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("andbible-mydocuments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(sanitizedDirectoryName(directoryName), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try files.map { file in
            let url = root.appendingPathComponent(file.fileName, isDirectory: false)
            try Data(file.content.utf8).write(to: url, options: .atomic)
            return url
        }
    }

    private static func sanitizedDirectoryName(_ value: String) -> String {
        let sanitized = MyDocumentTransferService.sanitizedExportTitle(value)
        return sanitized.isEmpty ? "My Documents" : sanitized
    }
}
