import XCTest
import BibleCore
@testable import BibleUI

final class ProductFeedbackReportPreparationTests: XCTestCase {
    /** The prepared payload stays addressed, unsent, and truthful about every retained artifact. */
    @MainActor
    func testPreparedPayloadIncludesCrashEvidenceAndWarnings() {
        let screenshot = AddressedMailAttachment(data: Data([0x01]), filename: "current_window.jpg", mimeType: "image/jpeg")
        let crash = AddressedMailAttachment(data: Data([0x02]), filename: "recent_crash_diagnostic.json", mimeType: "application/json")

        let payload = ProductFeedbackReportPreparation.makePayload(
            metadata: AndBibleAppVersionMetadata(marketingVersion: "2.1", buildNumber: "42"),
            attachments: [screenshot, crash],
            warnings: ["Application log could not be captured."]
        )

        XCTAssertEqual(payload.recipient, "errors.andbible@gmail.com")
        XCTAssertEqual(payload.subject, "[42 manual] Bug report for AndBible 2.1")
        XCTAssertEqual(payload.attachments, [screenshot, crash])
        XCTAssertTrue(payload.body.contains("current_window.jpg, recent_crash_diagnostic.json"))
        XCTAssertTrue(payload.body.contains("Application log could not be captured."))
    }

    /**
     Failed optional collectors must leave available evidence intact and explain the omission.

     This protects the partial-evidence contract: screenshot/MetricKit failures are not allowed to
     cancel a user-initiated report or create a falsely complete attachment list.
     */
    @MainActor
    func testPartialEvidenceFailureRetainsAvailableAttachmentsAndWarning() {
        let metadata = AndBibleAppVersionMetadata(marketingVersion: "2.1", buildNumber: "42")
        let log = AddressedMailAttachment(data: Data("safe".utf8), filename: "current_application_log.txt", mimeType: "text/plain")

        let payload = ProductFeedbackReportPreparation.makePayload(
            metadata: metadata,
            attachments: [log],
            warnings: ["Current app-window screenshot could not be captured."]
        )

        XCTAssertEqual(payload.attachments, [log])
        XCTAssertTrue(payload.body.contains("current_application_log.txt"))
        XCTAssertTrue(payload.body.contains("Current app-window screenshot could not be captured."))
    }

    /**
     Export fallback must retain the exact report body and every attachment in one safe ZIP.

     The test uses a temporary directory and parses the produced ZIP through the shared bounded
     archive reader. A failure means unavailable Mail could silently lose evidence or export a
     different report than the user consented to prepare.
     */
    func testUnavailableMailExportContainsManifestBodyAndAllAttachments() throws {
        let payload = AddressedMailPayload(
            recipient: "errors.andbible@gmail.com",
            subject: "subject",
            body: "localized body",
            attachments: [
                .init(data: Data("log".utf8), filename: "log.txt", mimeType: "text/plain"),
                .init(data: Data("crash".utf8), filename: "crash.json", mimeType: "application/json")
            ]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("product-feedback-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let export = try ProductFeedbackReportExportBuilder.write(payload: payload, directory: directory)
        let entries = try ZipArchiveReader.entries(in: Data(contentsOf: export.fileURL))

        XCTAssertEqual(entries.map(\.name), ["manifest.json", "report.txt", "attachments/001.bin", "attachments/002.bin"])
        XCTAssertEqual(entries[1].data, Data("localized body".utf8))
        XCTAssertEqual(entries[2].data, Data("log".utf8))
        XCTAssertEqual(entries[3].data, Data("crash".utf8))
        ProductFeedbackReportExportBuilder.remove(export)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.fileURL.path))
    }

    /**
     The ZIP ceiling must reject an oversized complete report before archive assembly or sharing.

     A failure here means a malicious or unexpectedly large attachment could force an oversized
     in-memory archive despite the user-facing export limit.
     */
    func testUnavailableMailExportRejectsOversizedCompleteReportBeforeWriting() {
        let payload = AddressedMailPayload(
            recipient: "errors.andbible@gmail.com",
            subject: "subject",
            body: "body",
            attachments: [
                .init(
                    data: Data(repeating: 0, count: ProductFeedbackReportExportBuilder.maximumArchiveByteCount),
                    filename: "large.log",
                    mimeType: "text/plain"
                )
            ]
        )

        XCTAssertThrowsError(try ProductFeedbackReportExportBuilder.write(payload: payload)) { error in
            XCTAssertEqual(error as? ProductFeedbackReportExportError, .archiveTooLarge)
        }
    }

    /**
     Stored-ZIP headers must count toward the export ceiling before archive allocation begins.

     The payload bytes and generated manifest fit the 10 MiB limit by themselves; a failure here
     means ZIP metadata could bypass the user-visible bound until after a large archive allocation.
     */
    func testUnavailableMailExportCountsStoredZipMetadataInPreflightLimit() {
        let payload = AddressedMailPayload(
            recipient: "errors.andbible@gmail.com",
            subject: "subject",
            body: "",
            attachments: [
                .init(
                    data: Data(repeating: 0, count: ProductFeedbackReportExportBuilder.maximumArchiveByteCount - 512),
                    filename: "log.txt",
                    mimeType: "text/plain"
                )
            ]
        )

        XCTAssertThrowsError(try ProductFeedbackReportExportBuilder.write(payload: payload)) { error in
            XCTAssertEqual(error as? ProductFeedbackReportExportError, .archiveTooLarge)
        }
    }

    /**
     Credential-shaped values must never survive from a unified-log message into report evidence.

     This is a deterministic redaction seam; a failure means the user could export secrets after
     choosing a manual crash report.
     */
    func testApplicationLogRedactionRemovesCredentialShapes() {
        let secret = "should-not-survive"
        let redacted = ProductFeedbackLogRedactor.redact(
            "Authorization: \(secret) Bearer \(secret) token=\(secret) Cookie: session=\(secret) https://user:\(secret)@example.test/path?api_key=\(secret)"
        )

        XCTAssertFalse(redacted.contains(secret))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }
}
