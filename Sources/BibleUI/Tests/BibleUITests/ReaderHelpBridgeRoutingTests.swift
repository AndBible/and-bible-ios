import XCTest
@testable import BibleUI
@testable import BibleView

/** Focused coverage for native reader help content and bridge-to-presentation routing. */
final class ReaderHelpBridgeRoutingTests: XCTestCase {
    /**
     Verifies `helpBookmarks` preserves Android's localized structure and exact tutorial URL.

     The controller receives the same delegate callback emitted by `BibleBridge` and must forward
     one semantic presentation through its pane-owned callback. The assertion locks the shared
     title, link, bold-tip, and body keys in display order while proving the link remains tappable.
     No persistence, WebKit, localization mutation, or external URL opening occurs.
     */
    @MainActor
    func testBookmarkHelpRoutesExactAndroidContentToNativePresentation() throws {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        var captured: AIReaderHelpPresentation?
        controller.onShowReaderHelp = { captured = $0 }

        controller.bridgeDidRequestBookmarkHelp(bridge)

        let presentation = try XCTUnwrap(captured)
        XCTAssertEqual(presentation.title, .localized("bookmarks_and_mynotes_title"))
        XCTAssertEqual(presentation.tutorialLink?.labelKey, "watch_tutorial_video")
        XCTAssertEqual(
            presentation.tutorialLink?.destination.absoluteString,
            "https://www.youtube.com/playlist?list=PLD-W_Iw-N2MlzNt0Zpna-QoTBpEpWSden"
        )
        XCTAssertEqual(presentation.tutorialLink?.isItalic, true)
        XCTAssertEqual(presentation.emphasizedTextKey, "verse_tip")
        XCTAssertEqual(presentation.body, .localized("help_bookmarks_text"))
        XCTAssertNil(presentation.documentationLink)
    }

    /**
     Verifies scoped Memorize help uses only Android's allowlisted content and documentation URL.

     Calling the typed delegate route avoids JavaScript input ambiguity. The expected presentation
     uses the shared `help` title and `help_memorize_text` body plus Android's read-more label and
     exact documentation page. The test performs no network or URL-opening side effects.
     */
    @MainActor
    func testMemorizeHelpRoutesLocalizedContentAndExactDocumentationPage() throws {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        var captured: AIReaderHelpPresentation?
        controller.onShowReaderHelp = { captured = $0 }

        controller.bridge(bridge, showHelp: .memorize)

        let presentation = try XCTUnwrap(captured)
        XCTAssertEqual(presentation.featureTopic, .memorize)
        XCTAssertEqual(presentation.title, .localized("help"))
        XCTAssertEqual(presentation.body, .localized("help_memorize_text"))
        XCTAssertEqual(presentation.documentationLink?.labelKey, "help_read_more_link")
        XCTAssertEqual(
            presentation.documentationLink?.destination.absoluteString,
            "https://docs.andbible.org/en/latest/memorize.html"
        )
    }
}
