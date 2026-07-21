import BibleCore
import XCTest

@testable import BibleUI

/**
 Protects Android's ordering contract between generated-page cache reuse and pane-local run state.

 Tests use synchronous recorder closures so ordering assertions have no clocks, tasks, or scheduling
 assumptions. A failure means iOS could flash an activity sheet, reject an otherwise valid cache
 hit, or consult local pane state before Android's cache decision.
 */
final class AIReaderRunLifecycleTests: XCTestCase {
  /**
   Verifies Android's regeneration status is emitted as a transient Vue error document.

   - Setup: Presents the localized loading state through a controller backed by a recording bridge.
   - Expected result: Vue receives a normal-severity `ErrorDocument` plus clear/setup events.
   - Failure meaning: Regeneration status could be persisted as a My Documents page or rendered
     through a payload shape Android's reader does not understand.
   - Side effects: Records bridge scripts in memory; no model container or sync journal is used.
   */
  @MainActor
  func testRegenerationStatusUsesTransientReaderDocument() throws {
    let (bridge, scripts) = makeRecordingBridge()
    let controller = BibleReaderController(bridge: bridge, initializesSword: false)

    controller.loadTransientAIDocument(
      AIReaderTransientDocument(
        message: "Regenerating AI document…",
        severity: .normal
      )
    )

    let emittedScripts = scripts()
    XCTAssertTrue(emittedScripts.contains { $0.contains("bibleView.emit('clear_document'") })
    XCTAssertTrue(emittedScripts.contains { $0.contains("bibleView.emit('setup_content'") })
    let payload = try XCTUnwrap(
      try bridgeEmissionPayload(from: emittedScripts, event: "add_documents") as? [String: Any]
    )
    XCTAssertEqual(payload["type"] as? String, "error")
    XCTAssertEqual(payload["errorMessage"] as? String, "Regenerating AI document…")
    XCTAssertEqual(payload["severity"] as? String, "NORMAL")
  }

  /**
   Verifies a cache hit returns immediately without consulting pane-local running state.

   - Setup: The cache closure returns one durable page and the pane closure would report active.
   - Expected result: Only the cache closure runs and the decision opens the cached page.
   - Failure meaning: A cached action could show `agent_already_running` or visible running state.
   - Side effects: Records closure calls in memory only.
   */
  func testCacheHitPrecedesAndSkipsLocalRunCheck() throws {
    var events: [String] = []
    let location = AIGeneratedPageLocation(
      pageID: UUID(),
      documentInitials: "AIDocuments",
      pageKey: "ai_cached"
    )

    let decision = try AIReaderRunPreflight.decide(
      skipCache: false,
      cachedPage: {
        events.append("cache")
        return location
      },
      isLocalRunActive: {
        events.append("pane")
        return true
      }
    )

    XCTAssertEqual(decision, .openCachedPage(location))
    XCTAssertEqual(events, ["cache"])
  }

  /**
   Verifies a cache miss consults pane-local state only after lookup completes.

   - Setup: The cache closure returns nil and the pane reports an active run.
   - Expected result: Call order is cache then pane, producing local-run rejection.
   - Failure meaning: iOS would deviate from Android's `findCachedPage`-before-session ordering.
   - Side effects: Records closure calls in memory only.
   */
  func testCacheMissChecksLocalRunStateSecond() throws {
    var events: [String] = []

    let decision = try AIReaderRunPreflight.decide(
      skipCache: false,
      cachedPage: {
        events.append("cache")
        return nil
      },
      isLocalRunActive: {
        events.append("pane")
        return true
      }
    )

    XCTAssertEqual(decision, .localRunAlreadyActive)
    XCTAssertEqual(events, ["cache", "pane"])
  }

  /**
   Verifies regeneration bypasses cache while still enforcing pane-local run exclusivity.

   - Setup: `skipCache` is true and the cache closure fails the test if invoked.
   - Expected result: Only pane state is evaluated and an idle pane begins execution.
   - Failure meaning: Regeneration could accidentally reopen its prior cache entry instead of
     producing a fresh result.
   - Side effects: Records closure calls in memory only.
   */
  func testRegenerationSkipsCacheAndChecksLocalRunState() throws {
    var events: [String] = []

    let decision = try AIReaderRunPreflight.decide(
      skipCache: true,
      cachedPage: {
        XCTFail("Regeneration must not consult generated-page cache")
        return nil
      },
      isLocalRunActive: {
        events.append("pane")
        return false
      }
    )

    XCTAssertEqual(decision, .beginExecution)
    XCTAssertEqual(events, ["pane"])
  }

  /**
   Verifies runtime reference defaults cross the coordinator boundary without being dropped.

   - Setup: Supplies distinct search, Hebrew, Greek, and morphology identities through a recording
     main-actor provider.
   - Expected result: The provider runs once and all four identities appear in the system message.
   - Failure meaning: Tool defaults and prompt instructions could select different installed modules.
   - Side effects: Records one synchronous provider invocation in memory.
   */
  @MainActor
  func testRunMessagesIncludeEveryResolvedReferenceEnvironmentField() {
    var invocationCount = 0
    let prompt = AgentPrompt(
      id: UUID(),
      name: "Explain",
      promptTemplate: "Explain",
      showIn: [.verseSelection]
    )
    let context = AgentExecutionContext(promptId: prompt.id)

    let messages = AIReaderRunMessageAssembler.messages(
      prompt: prompt,
      context: context,
      appLanguage: "English",
      agentSystemPrompt: "System prompt\n",
      transformationSystemPrompt: "Transformation prompt",
      installedDocuments: nil,
      commentaryEntries: nil,
      referenceEnvironmentProvider: {
        invocationCount += 1
        return AIReaderReferenceEnvironmentResolver.Environment(
          defaultSearchBible: AIReaderMessageComposer.SearchBible(
            initials: "KJV",
            language: "English"
          ),
          preferredStrongsHebrew: "BDB",
          preferredStrongsGreek: "Thayer",
          preferredGreekMorphology: "Robinson"
        )
      }
    )

    XCTAssertEqual(invocationCount, 1)
    let systemMessage = messages.first?.content ?? ""
    XCTAssertTrue(systemMessage.contains("Default search Bible (for searchBible tool): KJV (English)"))
    XCTAssertTrue(systemMessage.contains("- Strong's Hebrew: BDB"))
    XCTAssertTrue(systemMessage.contains("- Strong's Greek: Thayer"))
    XCTAssertTrue(systemMessage.contains("- Greek morphology: Robinson"))
  }

  /**
   Verifies SWORD add-on prompts expose Android's set-default model option.

   - Setup: Evaluates the policy with a named SWORD prompt-pack origin.
   - Expected result: The selection can be persisted through the repository-owned path.
   - Failure meaning: Add-on prompts would lose an Android-visible picker capability in iOS.
   - Side effects: None.
   */
  func testSwordAddOnPromptAllowsPersistingSelectedModel() {
    XCTAssertTrue(
      AIReaderPromptModelSelectionPolicy.allowsPersistingSelection(
        for: .swordPack(moduleName: "StudyPrompts")
      )
    )
  }
}
