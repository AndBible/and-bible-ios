import Foundation
import XCTest

@testable import BibleCore

/**
 Protects Android cache bytes, complete tool semantics, permission routing, and conflict-safe note
 transformation writeback.

 The suite uses actors for every async double, so ordering is deterministic and no app model,
 database, UI, or network service is touched.
 */
final class AIAgentAndTextTargetBehaviorTests: XCTestCase {
  /**
   Verifies declaration-order JSON, default-null omission, and Android's 16-byte SHA-256 prefix.

   The expected string is the golden kotlinx.serialization output for the same field values.
   Failure means strict My Documents cache entries would diverge across Android and iOS.
   */
  func testCacheableContextSerializationAndHashMatchAndroidGoldenBehavior() throws {
    let context = CacheableContext(
      kjvOrdinalStart: 123,
      kjvOrdinalEnd: 125,
      activeDocumentInitials: "KJV",
      selectedContent: "In the beginning",
      selectedText: nil,
      highlightedText: "beginning",
      selectionStartOffset: 3,
      selectionEndOffset: 12,
      selectionStartOrdinal: 7,
      selectionEndOrdinal: 9,
      userSpecification: "short",
      sourceBookKey: "Gen.1.1"
    )
    let golden =
      #"{"kjvOrdinalStart":123,"kjvOrdinalEnd":125,"activeDocumentInitials":"KJV","selectedContent":"In the beginning","selectedText":null,"highlightedText":"beginning","selectionStartOffset":3,"selectionEndOffset":12,"selectionStartOrdinal":7,"selectionEndOrdinal":9,"userSpecification":"short","sourceBookKey":"Gen.1.1"}"#

    XCTAssertEqual(try context.canonicalJSON(), golden)
    XCTAssertEqual(try context.computeHash(), "09c7758e540f07b746de387db3f1c264")
  }

  /**
   Verifies every Android tool round-trips its wire name and complete registry construction routes
   two distinct writes through typed permission and execution boundaries.

   The first approval grants writes for the run, so the second write must execute without another
   approval request. Failure means the implementation has collapsed tools, omitted enum cases, or
   changed Android permission precedence.
   */
  func testCompleteToolRegistryAndAskOncePermissionRouteTypedInvocations() async throws {
    for tool in AgentTool.allCases {
      XCTAssertEqual(AgentTool(wireName: tool.wireName), tool)
    }
    let excluded = AgentToolVisibilityPolicy.excludedTools(
      permanentlyDeniedTools: [.searchBible, .deleteBookmark],
      promptDeniedTools: [.finishWithoutDocument],
      promptAvailableTools: [.searchBible]
    )
    XCTAssertFalse(excluded.contains(.searchBible))
    XCTAssertTrue(excluded.contains(.deleteBookmark))
    XCTAssertFalse(excluded.contains(.finishWithoutDocument))
    XCTAssertEqual(
      AgentToolVisibilityPolicy.excludedTools(
        permanentlyDeniedTools: [],
        promptDeniedTools: nil,
        promptAvailableTools: nil,
        isTextTransformation: true
      ),
      Set(AgentTool.allCases).subtracting(BuiltInPromptCatalog.structuralTools)
    )

    let dispatcher = RecordingAgentToolDispatcher()
    let registry = try AgentToolRegistry(dispatcher: dispatcher)
    let definitions = registry.definitions()
    XCTAssertEqual(definitions.count, AgentTool.allCases.count)
    let bookmarkDefinition = try XCTUnwrap(
      definitions.first(where: { $0.tool == .createBookmark })
    )
    let bookmarkSchema = try XCTUnwrap(
      bookmarkDefinition.parameters["properties"]?.objectValue
    )
    XCTAssertNotNil(bookmarkSchema["taskComplete"])
    let calls = [
      LLMToolCall(
        id: "bookmark", tool: .createBookmark, arguments: ["verse": .string("John.3.16")]),
      LLMToolCall(id: "label", tool: .createLabel, arguments: ["name": .string("Study")]),
    ]
    let client = SequencedLLMClient(
      completions: [
        LLMCompletion(content: "Working", toolCalls: calls),
        LLMCompletion(content: "Done"),
      ]
    )
    let requester = RecordingPermissionRequester(grant: .allowOnce)
    let coordinator = AgentExecutionCoordinator(
      client: client,
      registry: registry,
      permissionRequester: requester
    )
    let model = ResolvedLLMModel(
      configuredModelId: UUID(),
      providerConfigId: UUID(),
      modelId: "model",
      apiFormat: .openAI,
      endpoint: URL(string: "https://api.example.test/v1")!,
      credential: "secret"
    )

    let result = try await coordinator.execute(
      model: model,
      messages: [LLMMessage(role: .user, content: "Organize this")],
      context: AgentExecutionContext(promptId: UUID()),
      permissionSettings: AgentPermissionSettings(globalMode: .askOncePerRun)
    )

    let requestCount = await requester.requestCount
    let executedTools = await dispatcher.executedTools
    XCTAssertEqual(result.content, "Done")
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(executedTools, [.createBookmark, .createLabel])
  }

  /**
   Verifies task completion waits until every tool call in the provider's parallel batch executes.

   Failure means a completion hint on an early call could silently skip later requested writes.
   */
  func testTaskCompleteWaitsForEveryParallelToolCall() async throws {
    let dispatcher = RecordingAgentToolDispatcher()
    let calls = [
      LLMToolCall(
        id: "bookmark",
        tool: .createBookmark,
        arguments: [
          "taskComplete": .bool(true),
          "taskCompleteMessage": .string("Organized"),
        ]
      ),
      LLMToolCall(id: "label", tool: .createLabel, arguments: [:]),
    ]
    let coordinator = AgentExecutionCoordinator(
      client: SequencedLLMClient(completions: [LLMCompletion(content: nil, toolCalls: calls)]),
      registry: try AgentToolRegistry(dispatcher: dispatcher)
    )

    let result = try await coordinator.execute(
      model: resolvedModel(),
      messages: [LLMMessage(role: .user, content: "Organize")],
      context: AgentExecutionContext(promptId: UUID()),
      permissionSettings: AgentPermissionSettings(globalMode: .allowAll)
    )

    XCTAssertEqual(result.output, .withoutDocument(message: "Organized"))
    let executedTools = await dispatcher.executedTools
    XCTAssertEqual(executedTools, [.createBookmark, .createLabel])
  }

  /**
   Verifies a structural StudyPad tool returns typed navigation metadata without another API call.

   Failure means a successful finish tool would be treated as an ordinary tool and loop back to
   the provider, losing its destination contract.
   */
  func testStudyPadFinishReturnsTypedDestinationWithoutAnotherProviderCall() async throws {
    let dispatcher = RecordingAgentToolDispatcher()
    let coordinator = AgentExecutionCoordinator(
      client: SequencedLLMClient(
        completions: [
          LLMCompletion(
            content: nil,
            toolCalls: [
              LLMToolCall(id: "finish", tool: .finishWithStudyPad, arguments: [:])
            ]
          )
        ]
      ),
      registry: try AgentToolRegistry(dispatcher: dispatcher)
    )

    let result = try await coordinator.execute(
      model: resolvedModel(),
      messages: [LLMMessage(role: .user, content: "Finish")],
      context: AgentExecutionContext(promptId: UUID()),
      permissionSettings: AgentPermissionSettings(globalMode: .allowAll)
    )

    XCTAssertEqual(
      result.output,
      .studyPad(
        labelId: RecordingAgentToolDispatcher.studyPadID,
        scrollToEntryId: nil,
        message: "StudyPad ready"
      )
    )
  }

  /**
   Verifies regeneration sections enter the provider request, progress remains ordered, and a
   title-only structural call combines with the next response as a typed document result.

   Failure means regeneration instructions could be dropped, UI progress could race execution,
   or AI document creation could lose its accepted title between provider iterations.
   */
  func testRegenerationProgressAndPendingTitleProduceTypedDocumentResult() async throws {
    let dispatcher = RecordingAgentToolDispatcher()
    let client = SequencedLLMClient(
      completions: [
        LLMCompletion(
          content: nil,
          toolCalls: [
            LLMToolCall(id: "title", tool: .setDocumentTitle, arguments: [:])
          ],
          usage: LLMUsage(inputTokens: 8, outputTokens: 2)
        ),
        LLMCompletion(
          content: "Document body",
          usage: LLMUsage(inputTokens: 4, outputTokens: 3)
        ),
      ]
    )
    let reporter = RecordingExecutionProgressReporter()
    let coordinator = AgentExecutionCoordinator(
      client: client,
      registry: try AgentToolRegistry(dispatcher: dispatcher),
      progressReporter: reporter
    )
    let context = AgentExecutionContext(
      promptId: UUID(),
      previousResponse: "Earlier answer",
      additionalInstructions: "Use a table"
    )

    let result = try await coordinator.execute(
      model: resolvedModel(),
      messages: [LLMMessage(role: .user, content: "Explain")],
      context: context,
      permissionSettings: AgentPermissionSettings(globalMode: .allowAll)
    )

    XCTAssertEqual(
      result.output,
      .document(title: "Generated title", content: "Document body")
    )
    XCTAssertEqual(result.usage, LLMUsage(inputTokens: 12, outputTokens: 5))
    let requests = await client.requests
    let firstRequest = try XCTUnwrap(requests.first)
    let userContent = try XCTUnwrap(firstRequest.messages.last?.content)
    XCTAssertTrue(userContent.contains("--- Previous Response"))
    XCTAssertTrue(userContent.contains("Earlier answer"))
    XCTAssertTrue(userContent.contains("--- Additional Instructions ---\nUse a table"))

    let events = await reporter.events
    XCTAssertEqual(events.first, .started(model: "model"))
    XCTAssertTrue(events.contains(.iterationStarted(1)))
    XCTAssertTrue(events.contains(.iterationStarted(2)))
    XCTAssertTrue(
      events.contains(
        .toolCompleted(iteration: 1, callID: "title", tool: .setDocumentTitle, isError: false)
      )
    )
    XCTAssertEqual(events.last, .completed(result))
  }

  /**
   Verifies zero and negative iteration settings both preserve Android's unlimited-run behavior.

   Each run requires a second provider call to finish. Failure means a negative Android setting
   was reinterpreted as an already-exhausted cap on iOS.
   */
  func testNonPositiveIterationLimitsRemainUnlimited() async throws {
    for limit in [0, -4] {
      let client = SequencedLLMClient(
        completions: [
          LLMCompletion(
            content: nil,
            toolCalls: [
              LLMToolCall(id: "search", tool: .searchBible, arguments: [:])
            ]
          ),
          LLMCompletion(content: "Done"),
        ]
      )
      let coordinator = AgentExecutionCoordinator(
        client: client,
        registry: try AgentToolRegistry(dispatcher: RecordingAgentToolDispatcher())
      )

      let result = try await coordinator.execute(
        model: resolvedModel(),
        messages: [LLMMessage(role: .user, content: "Search")],
        context: AgentExecutionContext(promptId: UUID()),
        permissionSettings: AgentPermissionSettings(globalMode: .allowAll),
        maximumIterations: limit
      )

      XCTAssertEqual(result.content, "Done")
      XCTAssertEqual(result.iterationCount, 2)
    }
  }

  /**
   Verifies a positive iteration cap asks after each block and honors both user outcomes.

   Approval permits exactly one additional block; rejection retains the stable cap error. Failure
   means iOS either stops without Android's prompt or silently runs beyond the configured block.
   */
  func testIterationLimitContinuationHonorsApprovalAndRejection() async throws {
    let approvingRequester = RecordingIterationContinuationRequester(decisions: [true])
    let approvedCoordinator = AgentExecutionCoordinator(
      client: SequencedLLMClient(
        completions: [
          LLMCompletion(
            content: nil,
            toolCalls: [
              LLMToolCall(id: "search", tool: .searchBible, arguments: [:])
            ]
          ),
          LLMCompletion(content: "Continued"),
        ]
      ),
      registry: try AgentToolRegistry(dispatcher: RecordingAgentToolDispatcher()),
      iterationContinuationRequester: approvingRequester
    )

    let approved = try await approvedCoordinator.execute(
      model: resolvedModel(),
      messages: [LLMMessage(role: .user, content: "Search")],
      context: AgentExecutionContext(promptId: UUID()),
      permissionSettings: AgentPermissionSettings(globalMode: .allowAll),
      maximumIterations: 1
    )

    XCTAssertEqual(approved.content, "Continued")
    XCTAssertEqual(approved.iterationCount, 2)
    let approvingRequests = await approvingRequester.requests
    XCTAssertEqual(approvingRequests, [IterationContinuationRequest(iteration: 1, increment: 1)])

    let rejectingRequester = RecordingIterationContinuationRequester(decisions: [false])
    let rejectedCoordinator = AgentExecutionCoordinator(
      client: SequencedLLMClient(
        completions: [
          LLMCompletion(
            content: nil,
            toolCalls: [
              LLMToolCall(id: "search", tool: .searchBible, arguments: [:])
            ]
          )
        ]
      ),
      registry: try AgentToolRegistry(dispatcher: RecordingAgentToolDispatcher()),
      iterationContinuationRequester: rejectingRequester
    )

    do {
      _ = try await rejectedCoordinator.execute(
        model: resolvedModel(),
        messages: [LLMMessage(role: .user, content: "Search")],
        context: AgentExecutionContext(promptId: UUID()),
        permissionSettings: AgentPermissionSettings(globalMode: .allowAll),
        maximumIterations: 1
      )
      XCTFail("Expected iteration-cap rejection")
    } catch {
      XCTAssertEqual(error as? AgentExecutionError, .maximumIterationsReached(1))
    }
    let rejectingRequests = await rejectingRequester.requests
    XCTAssertEqual(rejectingRequests, [IterationContinuationRequest(iteration: 1, increment: 1)])
  }

  /**
   Verifies three repeated tool-and-argument signatures inject Android's corrective loop note.

   Provider call identifiers vary and dictionary key order changes, proving the signature uses
   only typed tool identity and normalized JSON arguments. The note must enter only the provider
   conversation, while all three requested tools still execute.
   */
  func testRepeatedToolCallsInjectAndroidLoopCorrectionIntoProviderConversation() async throws {
    let dispatcher = RecordingAgentToolDispatcher()
    let calls = [
      LLMToolCall(
        id: "search-1",
        tool: .searchBible,
        arguments: ["query": .string("grace"), "limit": .number(5)]
      ),
      LLMToolCall(
        id: "search-2",
        tool: .searchBible,
        arguments: ["limit": .number(5), "query": .string("grace")]
      ),
      LLMToolCall(
        id: "search-3",
        tool: .searchBible,
        arguments: ["query": .string("grace"), "limit": .number(5)]
      ),
    ]
    let client = SequencedLLMClient(
      completions: calls.map { LLMCompletion(content: nil, toolCalls: [$0]) }
        + [LLMCompletion(content: "Done")]
    )
    let coordinator = AgentExecutionCoordinator(
      client: client,
      registry: try AgentToolRegistry(dispatcher: dispatcher)
    )

    let result = try await coordinator.execute(
      model: resolvedModel(),
      messages: [LLMMessage(role: .user, content: "Search")],
      context: AgentExecutionContext(promptId: UUID()),
      permissionSettings: AgentPermissionSettings(globalMode: .allowAll)
    )

    XCTAssertEqual(result.content, "Done")
    let requests = await client.requests
    let finalRequest = try XCTUnwrap(requests.last)
    let lastToolResult = try XCTUnwrap(
      finalRequest.messages.last(where: { $0.role == .tool })?.content
    )
    XCTAssertTrue(lastToolResult.contains("SYSTEM NOTE: You appear to be repeating"))
    let executedTools = await dispatcher.executedTools
    XCTAssertEqual(executedTools, [.searchBible, .searchBible, .searchBible])
  }

  /**
   Verifies a page created by the run can be edited without a second always-ask approval.

   Failure means the coordinator discarded Android's session-owned page identities between tool
   calls, causing redundant permission prompts for the agent's own new content.
   */
  func testCreatedPageContextAllowsSessionOwnedEditWithoutSecondApproval() async throws {
    let dispatcher = RecordingAgentToolDispatcher()
    let pageID = RecordingAgentToolDispatcher.pageID
    let calls = [
      LLMToolCall(id: "add", tool: .addMyDocumentPage, arguments: [:]),
      LLMToolCall(
        id: "edit",
        tool: .editMyDocumentPage,
        arguments: ["pageId": .string(pageID.uuidString)]
      ),
    ]
    let requester = RecordingPermissionRequester(grant: .allowOnce)
    let coordinator = AgentExecutionCoordinator(
      client: SequencedLLMClient(
        completions: [
          LLMCompletion(content: nil, toolCalls: calls),
          LLMCompletion(content: "Done"),
        ]
      ),
      registry: try AgentToolRegistry(dispatcher: dispatcher),
      permissionRequester: requester
    )

    _ = try await coordinator.execute(
      model: resolvedModel(),
      messages: [LLMMessage(role: .user, content: "Create and edit")],
      context: AgentExecutionContext(promptId: UUID()),
      permissionSettings: AgentPermissionSettings(globalMode: .alwaysAsk)
    )

    let requestCount = await requester.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  /**
   Verifies a provider cannot invoke a tool hidden from that run, even under allow-all permission.

   Failure means omission from provider definitions could be bypassed by a malicious response.
   */
  func testExecutionRejectsProviderCallsForExcludedToolsBeforeDispatch() async throws {
    let dispatcher = RecordingAgentToolDispatcher()
    let coordinator = AgentExecutionCoordinator(
      client: SequencedLLMClient(
        completions: [
          LLMCompletion(
            content: nil,
            toolCalls: [
              LLMToolCall(id: "delete", tool: .deleteBookmark, arguments: [:])
            ]
          )
        ]
      ),
      registry: try AgentToolRegistry(dispatcher: dispatcher)
    )
    let model = ResolvedLLMModel(
      configuredModelId: UUID(),
      providerConfigId: UUID(),
      modelId: "model",
      apiFormat: .openAI,
      endpoint: URL(string: "https://api.example.test/v1")!,
      credential: "secret"
    )

    do {
      _ = try await coordinator.execute(
        model: model,
        messages: [LLMMessage(role: .user, content: "Delete")],
        context: AgentExecutionContext(promptId: UUID()),
        permissionSettings: AgentPermissionSettings(globalMode: .allowAll),
        excludedTools: [.deleteBookmark]
      )
      XCTFail("Expected excluded-tool rejection")
    } catch {
      XCTAssertEqual(error as? AgentExecutionError, .toolUnavailable(.deleteBookmark))
    }
    let executedTools = await dispatcher.executedTools
    XCTAssertTrue(executedTools.isEmpty)
  }

  /**
   Verifies generic-book bookmark notes are first-class targets, stale edits block writeback, and a
   successful retry preserves HTML content type.

   Failure means AI output could overwrite a concurrent editor change, lose generic-book routing,
   or silently convert stored markup format.
   */
  func testGenericBookmarkWritebackRequiresFreshCapturedDigestAndPreservesContentType() async throws
  {
    let target = AITextTarget.genericBookmarkNote(UUID())
    let backing = InMemoryTextTargetBacking(
      values: [target: AITextTargetValue(content: "<p>Original</p>", contentType: .html)]
    )
    let store = AITextTargetStore(backing: backing)
    let capture = try await store.capture(target)
    XCTAssertEqual(capture.target.noteEditorEntityType, .bookmarkNote)
    XCTAssertEqual(capture.contentType, .html)

    await backing.replace(
      AITextTargetValue(content: "<p>User edit</p>", contentType: .html),
      at: target
    )
    do {
      _ = try await store.write(
        content: "<p>AI output</p>",
        to: target,
        capturedInputDigest: capture.capturedInputDigest
      )
      XCTFail("Expected stale-content rejection")
    } catch {
      XCTAssertEqual(error as? AITextTargetStoreError, .staleContent)
    }

    let raceCapture = try await store.capture(target)
    await backing.replaceBeforeNextWrite(
      AITextTargetValue(content: "<p>Last-second edit</p>", contentType: .html)
    )
    do {
      _ = try await store.write(
        content: "<p>Racing output</p>",
        to: target,
        capturedInputDigest: raceCapture.capturedInputDigest
      )
      XCTFail("Expected atomic stale-content rejection")
    } catch {
      XCTAssertEqual(error as? AITextTargetStoreError, .staleContent)
    }

    let fresh = try await store.capture(target)
    let committed = try await store.write(
      content: "<p>Improved</p>",
      to: target,
      capturedInputDigest: fresh.capturedInputDigest
    )
    let persisted = await backing.value(at: target)
    XCTAssertEqual(committed.contentType, .html)
    XCTAssertEqual(persisted?.content, "<p>Improved</p>")
    XCTAssertEqual(persisted?.contentType, .html)
  }

  /** Verifies writeback rejects an omitted captured-input digest before touching the backend. */
  func testTextTargetWritebackRejectsMissingCapturedDigest() async throws {
    let target = AITextTarget.myDocumentPage(UUID())
    let backing = InMemoryTextTargetBacking(
      values: [target: AITextTargetValue(content: "Text", contentType: .markdown)]
    )
    let store = AITextTargetStore(backing: backing)

    do {
      _ = try await store.write(content: "Changed", to: target, capturedInputDigest: "")
      XCTFail("Expected missing-digest rejection")
    } catch {
      XCTAssertEqual(error as? AITextTargetStoreError, .missingCapturedInputDigest)
    }
    let writeCount = await backing.writeCount
    XCTAssertEqual(writeCount, 0)
  }

  /** Builds a secret-bearing resolved model for in-memory coordinator tests only. */
  private func resolvedModel() -> ResolvedLLMModel {
    ResolvedLLMModel(
      configuredModelId: UUID(),
      providerConfigId: UUID(),
      modelId: "model",
      apiFormat: .openAI,
      endpoint: URL(string: "https://api.example.test/v1")!,
      credential: "secret"
    )
  }
}

/**
 Actor-backed LLM double that returns configured completions in strict call order.

 Exhaustion throws a stable malformed-response error. No request data is persisted or logged.
 */
private actor SequencedLLMClient: LLMCompleting {
  /// Remaining completions in call order.
  private var completions: [LLMCompletion]
  /// Requests received in exact call order.
  private(set) var requests: [LLMCompletionRequest] = []

  /// Creates a client over a finite deterministic response sequence.
  init(completions: [LLMCompletion]) {
    self.completions = completions
  }

  /// Returns and removes the next completion without network I/O.
  func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletion {
    requests.append(request)
    guard !completions.isEmpty else { throw LLMClientError.malformedResponse }
    return completions.removeFirst()
  }
}

/**
 Actor-backed complete tool dispatcher that records exact enum identities.

 It marks Android write tools as permission-requiring and returns a typed success payload. The double
 intentionally does not emulate domain services beyond routing evidence.
 */
private actor RecordingAgentToolDispatcher: AgentToolDispatching {
  /// Stable destination emitted by the structural StudyPad test adapter.
  nonisolated static let studyPadID = UUID(uuidString: "774164eb-385a-4aef-8d4f-67e1d266c5cc")!
  /// Stable page identity used to verify session-owned page permission routing.
  nonisolated static let pageID = UUID(uuidString: "4756778c-b802-4603-b082-ceb87e1bdd6d")!

  /// Typed tools executed in exact order.
  private(set) var executedTools: [AgentTool] = []

  /// Supplies a typed nonempty schema for every exact Android tool.
  nonisolated func definition(for tool: AgentTool) -> LLMToolDefinition {
    LLMToolDefinition(
      tool: tool,
      description: "Execute \(tool.wireName).",
      parameters: [
        "type": .string("object"),
        "properties": .object([
          "value": .object(["type": .string("string")])
        ]),
      ]
    )
  }

  /// Applies static enum access semantics to the invocation.
  func requiresPermission(
    for tool: AgentTool,
    arguments: [String: JSONValue],
    context: AgentExecutionContext
  ) async throws -> Bool {
    if tool == .editMyDocumentPage,
      let rawPageID = arguments["pageId"]?.stringValue,
      let pageID = UUID(uuidString: rawPageID),
      context.createdPageIds.contains(pageID)
    {
      return false
    }
    return tool.access == .write
  }

  /// Records the exact tool and returns a typed success payload.
  func execute(
    tool: AgentTool,
    arguments: [String: JSONValue],
    context: AgentExecutionContext
  ) async throws -> AgentToolResult {
    executedTools.append(tool)
    if tool == .finishWithStudyPad {
      return AgentToolResult(
        data: .object(["labelId": .string(Self.studyPadID.uuidString)]),
        completion: .studyPad(
          labelId: Self.studyPadID,
          scrollToEntryId: nil,
          message: "StudyPad ready"
        )
      )
    }
    if tool == .addMyDocumentPage {
      return AgentToolResult(
        data: .object(["pageId": .string(Self.pageID.uuidString)]),
        createdPageIds: [Self.pageID]
      )
    }
    if tool == .setDocumentTitle {
      return AgentToolResult(data: .object(["title": .string("Generated title")]))
    }
    return AgentToolResult(data: .object(["ok": .bool(true)]))
  }
}

/** Actor-backed observer that retains ordered non-persistent execution progress for assertions. */
private actor RecordingExecutionProgressReporter: AgentExecutionProgressReporting {
  /// Events received in exact coordinator order.
  private(set) var events: [AgentExecutionProgress] = []

  /// Appends one progress event without additional side effects.
  func report(_ progress: AgentExecutionProgress) async {
    events.append(progress)
  }
}

/** Actor-backed approval host that records requests and returns one configured grant. */
private actor RecordingPermissionRequester: AgentPermissionRequesting {
  /// Grant returned for every request.
  private let grant: AgentPermissionGrant
  /// Number of approval requests observed.
  private(set) var requestCount = 0

  /// Creates a deterministic approval host.
  init(grant: AgentPermissionGrant) {
    self.grant = grant
  }

  /// Records one request and returns the configured grant.
  func requestPermission(_ request: AgentPermissionRequest) async -> AgentPermissionGrant {
    requestCount += 1
    return grant
  }
}

/// One recorded iteration-extension request with stable value semantics for assertions.
private struct IterationContinuationRequest: Equatable {
  let iteration: Int
  let increment: Int
}

/** Actor-backed iteration decision host that returns configured answers in strict order. */
private actor RecordingIterationContinuationRequester: AgentIterationContinuationRequesting {
  /// Remaining answers in request order.
  private var decisions: [Bool]
  /// Exact cap requests observed by the host.
  private(set) var requests: [IterationContinuationRequest] = []

  /// Creates a continuation host over a finite deterministic answer sequence.
  init(decisions: [Bool]) {
    self.decisions = decisions
  }

  /// Records the cap and returns the next answer, defaulting safely to rejection.
  func shouldContinueAfterIterationLimit(
    currentIteration: Int,
    increment: Int
  ) async -> Bool {
    requests.append(
      IterationContinuationRequest(iteration: currentIteration, increment: increment)
    )
    guard !decisions.isEmpty else { return false }
    return decisions.removeFirst()
  }
}

/**
 Actor-backed text adapter covering all typed target cases through one dictionary.

 It records writes for side-effect assertions and performs compare-and-write atomically in the
 actor, matching the production adapter contract.
 */
private actor InMemoryTextTargetBacking: AITextTargetBacking {
  /// Current values keyed by typed target identity.
  private var values: [AITextTarget: AITextTargetValue]
  /// Number of committed writes.
  private(set) var writeCount = 0
  /// Independent mutation injected immediately before the next conditional write.
  private var replacementBeforeNextWrite: AITextTargetValue?

  /// Creates a backing adapter with exact initial values.
  init(values: [AITextTarget: AITextTargetValue]) {
    self.values = values
  }

  /// Returns the current value without mutation.
  func read(_ target: AITextTarget) async throws -> AITextTargetValue? {
    values[target]
  }

  /// Atomically compares, replaces, and records one target.
  func compareAndWrite(
    _ value: AITextTargetValue,
    to target: AITextTarget,
    replacing expectedValue: AITextTargetValue
  ) async throws -> AITextTargetWriteResult {
    if let replacementBeforeNextWrite {
      values[target] = replacementBeforeNextWrite
      self.replacementBeforeNextWrite = nil
    }
    guard let current = values[target] else { return .targetNotFound }
    guard current == expectedValue else { return .staleContent }
    values[target] = value
    writeCount += 1
    return .written
  }

  /// Simulates an independent UI or sync edit outside `AITextTargetStore`.
  func replace(_ value: AITextTargetValue, at target: AITextTarget) {
    values[target] = value
  }

  /// Schedules an independent edit inside the next atomic compare-and-write operation.
  func replaceBeforeNextWrite(_ value: AITextTargetValue) {
    replacementBeforeNextWrite = value
  }

  /// Returns the current value for assertions.
  func value(at target: AITextTarget) -> AITextTargetValue? {
    values[target]
  }
}
