// SelectionAIActionConfigurationTests.swift -- Native-to-Vue AI selection configuration coverage

import BibleCore
import XCTest
@testable import BibleUI

/**
 Protects the native app-settings fields that control Vue AI selection-action reachability.

 The suite builds the same typed `set_config` payload emitted by a reader controller. It performs no
 WebKit, SwiftData, Keychain, filesystem, or network work.
 */
final class SelectionAIActionConfigurationTests: XCTestCase {
    /**
     Verifies the live controller call site forwards Android's provider-row predicate to Vue.

     - Setup: Attaches a recording bridge to a controller whose injected provider query is true.
     - Expected result: The client-ready `set_config` emission carries `llmConfigured=true`.
     - Failure meaning: The complete Vue action contract could remain hidden in the running app
       even after a provider has been saved.
     - Side effects: Drives the in-memory reader bridge lifecycle without persistence or WebKit.
     */
    @MainActor
    func testControllerProjectsLiveProviderPredicateIntoReaderConfiguration() throws {
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        controller.isAIProviderConfigured = { true }

        controller.bridgeDidSetClientReady(bridge)

        let payload = try setConfigPayload(from: scripts())
        let appSettings = try XCTUnwrap(payload["appSettings"] as? [String: Any])
        XCTAssertEqual(appSettings["llmConfigured"] as? Bool, true)
    }

    /**
     Verifies configured state and the native-localized label survive JSON projection unchanged.

     The enabled fixture must encode `llmConfigured=true` and the localized Android `llm_actions`
     value. The disabled fixture must encode `false`, allowing Vue to fail closed before a provider
     exists. A failure makes the selection action either unreachable after setup or visible before
     Android's configuration prerequisite is met.
     */
    func testReaderConfigurationCarriesAISelectionVisibilityAndLocalizedLabel() throws {
        let coordinator = BibleReaderConfigurationCoordinator()
        let enabled = try encodedAppSettings(
            coordinator.configPayload(context: context(llmConfigured: true))
        )
        let disabled = try encodedAppSettings(
            coordinator.configPayload(context: context(llmConfigured: false))
        )

        XCTAssertEqual(enabled["llmConfigured"] as? Bool, true)
        XCTAssertEqual(disabled["llmConfigured"] as? Bool, false)
        XCTAssertEqual(
            enabled["llmActionLabel"] as? String,
            String(localized: "llm_actions", defaultValue: "AI actions")
        )
        XCTAssertFalse((enabled["llmActionLabel"] as? String ?? "").isEmpty)
    }

    /**
     Creates one fully resolved reader context with only provider-row readiness varied by the test.

     - Parameter llmConfigured: Simulated result of Android's provider-count prerequisite.
     - Returns: A deterministic context with no user data and the supplied AI visibility state.
     - Side effects: None; no SwiftData container or native reader is created.
     - Failure modes: None; every context field is an in-memory fixture value.
     */
    private func context(llmConfigured: Bool) -> BibleReaderConfigurationContext {
        BibleReaderConfigurationContext(
            displaySettings: .appDefaults,
            defaults: .appDefaults,
            nightMode: false,
            errorBox: false,
            favouriteLabelIds: [],
            recentLabelIds: [],
            studyPadCursors: [:],
            autoAssignLabelIds: [],
            hiddenCompareDocuments: [],
            activeWindowState: BibleReaderActiveWindowState(
                isActive: true,
                hasActiveIndicator: false
            ),
            disableBibleModalButtons: [],
            disableGenericModalButtons: [],
            monochromeMode: false,
            disableAnimations: false,
            disableClickToEdit: false,
            notesContentType: "HTML",
            fontSizeMultiplier: 1,
            enabledExperimentalFeatures: [],
            llmConfigured: llmConfigured,
            autoTrackReading: false,
            readingProgressSettings: ReadingProgressSettingsBundle(
                settings: ReadingProgressSettingsSnapshot()
            )
        )
    }

    /**
     Encodes the typed bridge payload for exact app-settings key assertions.

     - Parameter payload: Native `set_config` payload under test.
     - Returns: The decoded top-level `appSettings` JSON object.
     - Side effects: None; encoding and decoding are in-memory and deterministic.
     - Throws: JSON encoding errors or `XCTUnwrap` failures when the wire shape regresses.
     */
    private func encodedAppSettings(
        _ payload: BibleReaderSetConfigPayload
    ) throws -> [String: Any] {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        return try XCTUnwrap(object["appSettings"] as? [String: Any])
    }
}
