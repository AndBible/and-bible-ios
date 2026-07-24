import XCTest
@testable import BibleUI

/**
 Covers the platform-neutral payload resolution behind the macOS share fallback.

 The fallback view renders exactly one representable payload. A failure here means a file export
 (such as the bug-report ZIP) degrades to an empty share panel with an inert action, or that
 shareable text stops reaching the copy path.
 */
final class ShareSheetFallbackPayloadTests: XCTestCase {
    /** Text items resolve to the copyable-text payload. */
    func testTextItemResolvesToCopyableText() {
        XCTAssertEqual(ShareSheetFallbackPayload.resolve(from: ["hello"]), .text("hello"))
    }

    /** Local file URLs resolve to the reveal-in-Finder payload instead of degrading to nothing. */
    func testFileURLResolvesToFilePayload() {
        let file = URL(fileURLWithPath: "/tmp/report.zip")

        XCTAssertEqual(ShareSheetFallbackPayload.resolve(from: [file]), .fileURL(file))
    }

    /** Web URLs stay copyable as their absolute string rather than claiming a local file. */
    func testWebURLResolvesToCopyableAbsoluteString() {
        let url = URL(string: "https://example.test/passage")!

        XCTAssertEqual(ShareSheetFallbackPayload.resolve(from: [url]), .text("https://example.test/passage"))
    }

    /** The first representable item wins in caller order; unrepresentable items are skipped. */
    func testFirstRepresentableItemWinsAndUnsupportedItemsAreSkipped() {
        let file = URL(fileURLWithPath: "/tmp/report.zip")

        XCTAssertEqual(ShareSheetFallbackPayload.resolve(from: [Data(), "text", file]), .text("text"))
        XCTAssertEqual(ShareSheetFallbackPayload.resolve(from: [Data(), file, "text"]), .fileURL(file))
    }

    /** Items with no fallback representation resolve to the explicit unsupported state. */
    func testUnrepresentableItemsResolveToUnsupported() {
        XCTAssertEqual(ShareSheetFallbackPayload.resolve(from: [Data()]), .unsupported)
        XCTAssertEqual(ShareSheetFallbackPayload.resolve(from: []), .unsupported)
    }
}
