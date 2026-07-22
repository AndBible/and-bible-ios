// ProductFeedbackReportExport.swift -- bounded, user-controlled diagnostic report export

import BibleCore
import Foundation

/** A temporary ZIP prepared for export when an addressed Mail account is unavailable. */
struct ProductFeedbackReportExport: Identifiable {
    /// Stable SwiftUI identity for one export presentation.
    let id = UUID()
    /// Complete ZIP containing the manifest, report body, and every retained attachment.
    let fileURL: URL
}

/** Builds a bounded ZIP export without sending any diagnostic data. */
enum ProductFeedbackReportExportBuilder {
    /// Android-equivalent total attachment ceiling, including generated manifest and body entries.
    static let maximumArchiveByteCount = 10 * 1_024 * 1_024

    /**
     Writes a complete report ZIP to temporary storage for an explicit user export action.

     - Parameters:
     - payload: The exact addressed report that was prepared before consent.
     - directory: Temporary output directory, injectable for deterministic tests.
     - Returns: A ZIP URL that the caller owns until the share/export surface terminates.
     - Side effects: Creates one temporary file; does not upload, send, or retain it after caller cleanup.
     - Throws: `ProductFeedbackReportExportError` for unsafe/oversized inputs or filesystem failure.
     */
    static func write(
        payload: AddressedMailPayload,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> ProductFeedbackReportExport {
        let manifest = ProductFeedbackExportManifest(payload: payload)
        let manifestData = try JSONEncoder().encode(manifest)
        let reportData = Data(payload.body.utf8)
        var entries = [
            ZipArchiveWriterEntry(name: "manifest.json", data: manifestData),
            ZipArchiveWriterEntry(name: "report.txt", data: reportData)
        ]
        for (index, attachment) in payload.attachments.enumerated() {
            guard attachment.data.count <= maximumArchiveByteCount else {
                throw ProductFeedbackReportExportError.attachmentTooLarge(attachment.filename)
            }
            entries.append(
                ZipArchiveWriterEntry(
                    name: String(format: "attachments/%03d.bin", index + 1),
                    data: attachment.data
                )
            )
        }
        guard !projectedArchiveExceedsLimit(entries) else {
            throw ProductFeedbackReportExportError.archiveTooLarge
        }
        let archive = try ZipArchiveWriter.storedArchive(entries: entries)
        guard archive.count <= maximumArchiveByteCount else {
            throw ProductFeedbackReportExportError.archiveTooLarge
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("andbible-bug-report-\(UUID().uuidString.lowercased()).zip")
        try archive.write(to: url, options: .atomic)
        return ProductFeedbackReportExport(fileURL: url)
    }

    /** Removes only the temporary ZIP created by this exporter after a terminal export result. */
    static func remove(_ export: ProductFeedbackReportExport) {
        try? FileManager.default.removeItem(at: export.fileURL)
    }

    /**
     Calculates the exact stored-ZIP byte count before the writer allocates archive output.

     - Parameter entries: Complete ordered archive entries whose names and payloads will be stored.
     - Returns: `true` when payload bytes plus all stored-ZIP metadata exceed the archive ceiling.
     - Side effects: none.
     - Note: `ZipArchiveWriter.storedArchive` emits 30-byte local headers, 46-byte central headers,
       two copies of each UTF-8 name, and a 22-byte end-of-central-directory record.
     */
    private static func projectedArchiveExceedsLimit(_ entries: [ZipArchiveWriterEntry]) -> Bool {
        let endOfCentralDirectoryByteCount = 22
        var byteCount = endOfCentralDirectoryByteCount
        for entry in entries {
            let entryByteCount = entry.data.count + 76 + (2 * entry.name.lengthOfBytes(using: .utf8))
            guard entryByteCount <= maximumArchiveByteCount - byteCount else { return true }
            byteCount += entryByteCount
        }
        return false
    }
}

/** Typed export failures ensure callers never imply an unavailable export was delivered. */
enum ProductFeedbackReportExportError: LocalizedError, Equatable {
    case attachmentTooLarge(String)
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .attachmentTooLarge(let name): "Attachment is too large to export: \(name)"
        case .archiveTooLarge: "The complete bug report is too large to export."
        }
    }
}

/** JSON manifest maps safe ZIP paths to the original user-visible attachment metadata. */
private struct ProductFeedbackExportManifest: Codable {
    let recipient: String
    let subject: String
    let attachments: [Attachment]

    struct Attachment: Codable {
        let archivePath: String
        let filename: String
        let mimeType: String
        let byteCount: Int
    }

    init(payload: AddressedMailPayload) {
        recipient = payload.recipient
        subject = payload.subject
        attachments = payload.attachments.enumerated().map { index, attachment in
            Attachment(
                archivePath: String(format: "attachments/%03d.bin", index + 1),
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                byteCount: attachment.data.count
            )
        }
    }
}
