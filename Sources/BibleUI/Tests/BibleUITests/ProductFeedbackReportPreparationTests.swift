import XCTest
@testable import BibleUI

final class ProductFeedbackReportPreparationTests: XCTestCase {
    /** The prepared payload stays addressed, unsent, and truthful about every retained artifact. */
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
}
