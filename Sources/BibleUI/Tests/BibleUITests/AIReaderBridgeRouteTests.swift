import SwiftData
import XCTest

@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Verifies Android-compatible AI bridge requests select the exact app-owned reader destination.

 The suite constructs the pane coordinator over in-memory persistence and deterministic adapters.
 It exercises route state directly so failures cannot be hidden by SwiftUI presentation timing.
 */
final class AIReaderBridgeRouteTests: BibleUISwordFixtureTestCase {
  /**
   Verifies one AI document marker opens directly while multiple markers present the chooser.

   - Setup: Supplies distinct My Documents markers to a coordinator with a recording open route.
   - Expected result: One marker opens its exact initials/key pair; two markers are retained in
     order and select the app-owned chooser without opening either destination.
   - Failure meaning: iOS could diverge from Android by showing an unnecessary chooser, choosing
     an arbitrary page, or replacing explicit marker identity with active-reader state.
   - Side effects: Creates in-memory SwiftData and a temporary SWORD fixture only.
   */
  @MainActor
  func testDocumentMarkersOpenOneDirectlyAndPresentChooserForMany() throws {
    let fixture = try makeRouteFixture()
    let first = AIDocumentPageMarker(
      title: "First result",
      documentInitials: "AIDocuments",
      pageKey: "page_first"
    )
    let second = AIDocumentPageMarker(
      title: "Second result",
      documentInitials: "Research",
      pageKey: "page_second"
    )

    fixture.coordinator.presentDocumentMarkers([first])

    XCTAssertEqual(
      fixture.recorder.openedDocuments,
      [AIReaderOpenedDocument(documentInitials: "AIDocuments", pageKey: "page_first")]
    )
    XCTAssertNil(fixture.coordinator.presentation)
    XCTAssertEqual(fixture.coordinator.documentMarkers, [])

    fixture.coordinator.presentDocumentMarkers([first, second])

    XCTAssertEqual(
      fixture.recorder.openedDocuments,
      [AIReaderOpenedDocument(documentInitials: "AIDocuments", pageKey: "page_first")]
    )
    XCTAssertEqual(fixture.coordinator.documentMarkers, [first, second])
    guard let presentation = fixture.coordinator.presentation,
      case .documentChooser = presentation
    else {
      return XCTFail("Expected the app-owned AI document chooser route")
    }
  }

  /**
   Verifies prompt editing opens only for an identity resolved by the source-aware repository.

   - Setup: Persists one user prompt, then sends its UUID and an unrelated missing UUID through
     separate coordinators.
   - Expected result: The existing prompt opens its exact editor route; the missing prompt leaves
     editor state empty and emits Android's credential-free unavailable-prompt failure.
   - Failure meaning: A stale bridge marker could open the wrong prompt, silently do nothing, or
     expose a native editor for an identity Android no longer resolves.
   - Side effects: Creates isolated in-memory SwiftData stores and temporary SWORD fixtures.
   */
  @MainActor
  func testPromptEditorOpensExistingPromptAndRejectsMissingPromptVisibly() throws {
    let existingFixture = try makeRouteFixture()
    let prompt = AgentPrompt(
      name: "Explain context",
      promptTemplate: "Explain the selected context.",
      showIn: [.verseSelection]
    )
    try AISettingsStore(modelContext: existingFixture.modelContext).insertPrompt(prompt)

    existingFixture.coordinator.presentPromptEditor(prompt.id)

    XCTAssertEqual(existingFixture.coordinator.promptEditorID, prompt.id)
    guard let presentation = existingFixture.coordinator.presentation,
      case .promptEditor(_, let routedPromptID) = presentation
    else {
      return XCTFail("Expected the app-owned prompt editor route")
    }
    XCTAssertEqual(routedPromptID, prompt.id)
    XCTAssertNil(existingFixture.coordinator.failureMessage)
    XCTAssertEqual(existingFixture.recorder.toasts, [])

    let missingFixture = try makeRouteFixture()
    let missingPromptID = UUID()
    missingFixture.coordinator.presentPromptEditor(missingPromptID)

    let expectedFailure = AIReaderRunError.promptUnavailable.localizedDescription
    XCTAssertNil(missingFixture.coordinator.promptEditorID)
    XCTAssertNil(missingFixture.coordinator.presentation)
    XCTAssertEqual(missingFixture.coordinator.failureMessage, expectedFailure)
    XCTAssertEqual(missingFixture.recorder.toasts, [expectedFailure])
  }

  /**
   Creates one coordinator fixture with every persistence and app-domain dependency isolated.

   - Returns: Coordinator, context, and recording presentation boundaries retained by one fixture.
   - Side effects: Allocates an in-memory model container and copies the test SWORD module tree.
   - Failure modes: Throws SwiftData, fixture-copy, or SWORD-manager construction failures.
   */
  @MainActor
  private func makeRouteFixture() throws -> AIReaderBridgeRouteFixture {
    let models =
      AIModelRegistration.cloudSyncableModels
      + AIModelRegistration.localOnlyModels
      + [
        MyDocument.self,
        MyDocumentPage.self,
        MyDocumentPageContent.self,
        AiPageCacheEntry.self,
      ]
    let schema = Schema(models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let modelContext = container.mainContext
    let swordManager = try XCTUnwrap(
      SwordManager(modulePath: makeTemporarySwordFixturePath())
    )
    let recorder = AIReaderBridgeRouteRecorder()
    let coordinator = AIReaderRunCoordinator(
      modelContext: modelContext,
      swordManager: swordManager,
      domain: AIReaderBridgeRouteAgentDomain(),
      myDocumentStore: MyDocumentStore(modelContext: modelContext),
      textTargetBacking: AIReaderBridgeRouteTextBacking(),
      isInstalledBible: { _ in false },
      openMyDocument: { documentInitials, pageKey in
        recorder.openedDocuments.append(
          AIReaderOpenedDocument(documentInitials: documentInitials, pageKey: pageKey)
        )
      },
      openStudyPad: { _, _ in },
      showTransientDocument: { _ in },
      showToast: { recorder.toasts.append($0) }
    )
    return AIReaderBridgeRouteFixture(
      container: container,
      modelContext: modelContext,
      coordinator: coordinator,
      recorder: recorder
    )
  }
}

/** Retains one complete route-test dependency graph for the lifetime of an assertion. */
@MainActor
private struct AIReaderBridgeRouteFixture {
  let container: ModelContainer
  let modelContext: ModelContext
  let coordinator: AIReaderRunCoordinator
  let recorder: AIReaderBridgeRouteRecorder
}

/** Exact My Documents destination recorded by the coordinator's navigation boundary. */
private struct AIReaderOpenedDocument: Equatable {
  let documentInitials: String
  let pageKey: String
}

/** Main-actor recorder for synchronous presentation closures used by route tests. */
@MainActor
private final class AIReaderBridgeRouteRecorder {
  var openedDocuments: [AIReaderOpenedDocument] = []
  var toasts: [String] = []
}

/** Domain adapter that fails if a presentation-only route unexpectedly starts tool execution. */
private actor AIReaderBridgeRouteAgentDomain: BibleUIAgentToolExecuting {
  func execute(
    _ request: BibleUIAgentToolRequest,
    context: AgentExecutionContext
  ) async throws -> AgentToolResult {
    throw AIReaderBridgeRouteTestError.unexpectedToolExecution
  }

  func isAIDocument(documentID: UUID?, initials: String?) async -> Bool {
    false
  }
}

/** Text adapter that exposes no mutable target to presentation-only route tests. */
private actor AIReaderBridgeRouteTextBacking: AITextTargetBacking {
  func read(_ target: AITextTarget) async throws -> AITextTargetValue? {
    nil
  }

  func compareAndWrite(
    _ value: AITextTargetValue,
    to target: AITextTarget,
    replacing expectedValue: AITextTargetValue
  ) async throws -> AITextTargetWriteResult {
    .targetNotFound
  }
}

/** Failure proving a route-only test crossed the coordinator's execution boundary. */
private enum AIReaderBridgeRouteTestError: Error {
  case unexpectedToolExecution
}
