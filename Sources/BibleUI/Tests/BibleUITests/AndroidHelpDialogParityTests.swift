import XCTest
@testable import BibleUI

/** Locks the typed Android full-help and compact feature-help presentation contracts. */
final class AndroidHelpDialogParityTests: XCTestCase {
    /**
     Verifies every compact help route uses Android's exact documentation destination.

     The expected list mirrors each `CommonUtils.showHelpDialog` call site on Android. A missing,
     reordered, or iOS-invented topic fails before a screen can silently lose its manual link.
     The test performs no localization writes, network requests, or URL opening.
     */
    func testFeatureHelpTopicsMatchAndroidDocumentationRoutes() {
        let expected: [(AndroidFeatureHelpTopic, String)] = [
            (.aiSettings, "https://docs.andbible.org/en/latest/ai.html"),
            (.aiConnection, "https://docs.andbible.org/en/latest/ai.html#getting-started"),
            (.aiProviders, "https://docs.andbible.org/en/latest/ai.html#choosing-a-provider"),
            (.aiModels, "https://docs.andbible.org/en/latest/ai.html#available-models"),
            (
                .globalToolPermissions,
                "https://docs.andbible.org/en/latest/ai.html#setting-permissions"
            ),
            (.promptEditor, "https://docs.andbible.org/en/latest/ai.html#custom-prompts"),
            (.toolInfo, "https://docs.andbible.org/en/latest/ai.html#ai-tools"),
            (
                .aiDocumentFilter,
                "https://docs.andbible.org/en/latest/ai.html#available-data-and-documents"
            ),
            (.readingProgress, "https://docs.andbible.org/en/latest/reading_progress.html"),
            (.documentSync, "https://docs.andbible.org/en/latest/document_sync.html"),
            (.memorize, "https://docs.andbible.org/en/latest/memorize.html"),
        ]

        XCTAssertEqual(AndroidFeatureHelpTopic.allCases, expected.map(\.0))
        for (topic, expectedURL) in expected {
            XCTAssertEqual(topic.documentationURL.absoluteString, expectedURL)
        }
    }

    /**
     Verifies Android Help remains the only outside-dismissible AI configuration dialog.

     Android feature help is informational and closes through its scrim or positive action.
     Setup, credential, permission, and destructive workflows must remain explicit-action-only.
     This pure state-policy test performs no persistence or presentation side effects.
     */
    func testOnlyFeatureHelpAllowsOutsideDismissal() {
        XCTAssertTrue(AIConfigurationDialog.help(.aiSettings).allowsOutsideDismissal)
        XCTAssertFalse(AIConfigurationDialog.disclaimerInformation.allowsOutsideDismissal)
        XCTAssertFalse(
            AIConfigurationDialog.commentaryResponseLimit(2_000).allowsOutsideDismissal
        )
        XCTAssertFalse(AIConfigurationDialog.resetUsage.allowsOutsideDismissal)
    }

    /**
     Verifies Study Pads uses Android's full-help topic links rather than compact AI help.

     Android `showHelp` supplies the Study Pads tutorial playlist and manual page together with the
     full Help footer. This test locks those topic-owned destinations without opening either URL.
     */
    func testStudyPadsFullHelpTopicMatchesAndroidLinks() {
        XCTAssertEqual(
            AndroidHelpTopic.studyPads.tutorialURL?.absoluteString,
            "https://www.youtube.com/playlist?list=PLD-W_Iw-N2MkMiGz7cjGASOYjElr1Q76m"
        )
        XCTAssertEqual(
            AndroidHelpTopic.studyPads.documentationURL?.absoluteString,
            "https://docs.andbible.org/en/latest/study_pads.html"
        )
    }
}
