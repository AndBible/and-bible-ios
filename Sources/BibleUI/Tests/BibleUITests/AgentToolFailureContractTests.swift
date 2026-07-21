import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Protects strict argument validation, cancellation, recoverable failures, bounded requests, and
 secret-free model-history envelopes for the production dispatcher.
 */
final class AgentToolFailureContractTests: XCTestCase {
    /**
     Verifies malformed inputs fail before any domain service executes.

     The cases cover missing values, UUIDs, fractional integers, enums, offset pairs, primary-label
     membership, empty edits, compound item ranges, completion metadata, and request-size bounds.
     */
    func testMalformedArgumentsReturnStableErrorsBeforeDomainExecution() async throws {
        let domain = ControlledFailureAgentDomain(behavior: .success)
        let dispatcher = BibleUIAgentToolDispatcher(domain: domain)
        let oversized = String(
            repeating: "x",
            count: BibleUIAgentToolRequestParser.maximumTextCharacters + 1
        )
        let labelID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let otherLabelID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let cases: [(AgentTool, [String: JSONValue], String)] = [
            (.createLabel, [:], "INVALID_ARGS"),
            (.deleteBookmark, ["bookmarkId": .string("not-a-uuid")], "INVALID_ARGS"),
            (.searchBible, ["query": .string("love"), "maxResults": .number(1.5)], "INVALID_ARGS"),
            (.addMyDocumentPage, ["title": .string("Page"), "content": .string(oversized)], "LIMIT_EXCEEDED"),
            (.searchByStrongs, ["strongsNumber": .string("7225")], "INVALID_STRONGS"),
            (.manageWindow, [
                "windowId": .string(UUID().uuidString),
                "action": .string("HIDE"),
            ], "INVALID_ARGS"),
            (.createBookmark, [
                "verseRef": .string("John.3.16"),
                "startOffset": .number(2),
            ], "INVALID_ARGS"),
            (.createBookmark, [
                "verseRef": .string("John.3.16"),
                "labelIds": .array([.string(labelID.uuidString)]),
                "primaryLabelId": .string(otherLabelID.uuidString),
            ], "INVALID_ARGS"),
            (.editMyDocumentPage, ["pageId": .string(UUID().uuidString)], "INVALID_ARGS"),
            (.getMyDocumentPages, [:], "INVALID_ARGS"),
            (.createStudyPad, [
                "name": .string("Study"),
                "items": .array([.object([
                    "type": .string("text"),
                    "text": .string("Entry"),
                    "indentLevel": .number(4),
                ])]),
            ], "INVALID_ARGS"),
            (.getAllLabels, ["taskComplete": .string("yes")], "INVALID_ARGS"),
        ]

        for (tool, arguments, expectedCode) in cases {
            let result = try await dispatcher.execute(
                tool: tool,
                arguments: arguments,
                context: AgentExecutionContext(promptId: UUID())
            )
            XCTAssertTrue(result.isError, tool.rawValue)
            XCTAssertEqual(result.errorCode, expectedCode, tool.rawValue)
        }
        let executionCount = await domain.executionCount()
        XCTAssertEqual(executionCount, 0)
    }

    /**
     Verifies permission classification uses the same strict parser as execution.

     Failure would let malformed identities reach an ownership lookup or classify a call under
     different arguments than the domain operation later receives.
     */
    func testMalformedPermissionArgumentsThrowTypedValidationFailure() async throws {
        let dispatcher = BibleUIAgentToolDispatcher(
            domain: ControlledFailureAgentDomain(behavior: .success)
        )

        do {
            _ = try await dispatcher.requiresPermission(
                for: .editMyDocumentPage,
                arguments: ["pageId": .string("invalid"), "title": .string("Title")],
                context: AgentExecutionContext(promptId: UUID())
            )
            XCTFail("Expected typed argument failure")
        } catch let error as BibleUIAgentArgumentError {
            XCTAssertEqual(error.code, "INVALID_ARGS")
            XCTAssertEqual(error.message, "pageId must be a valid UUID")
        }
    }

    /**
     Verifies typed missing-entity failures retain their Android code and safe message.

     Failure means recoverable store misses could be converted to infrastructure errors or throw
     out of the agent loop instead of returning an actionable tool result.
     */
    func testMissingEntityDomainFailureRemainsRecoverable() async throws {
        let domain = ControlledFailureAgentDomain(
            behavior: .domain(
                BibleUIAgentDomainError(
                    code: "PAGE_NOT_FOUND",
                    message: "Page not found"
                )
            )
        )
        let dispatcher = BibleUIAgentToolDispatcher(domain: domain)
        let result = try await dispatcher.execute(
            tool: .deleteMyDocumentPage,
            arguments: ["pageId": .string(UUID().uuidString)],
            context: AgentExecutionContext(promptId: UUID())
        )

        XCTAssertEqual(result.errorCode, "PAGE_NOT_FOUND")
        XCTAssertEqual(result.errorMessage, "Page not found")
        XCTAssertEqual(
            try result.modelContent(),
            #"{"code":"PAGE_NOT_FOUND","message":"Page not found","status":"error"}"#
        )
    }

    /**
     Verifies cooperative cancellation is rethrown rather than serialized as a model-visible error.

     Failure would leave a cancelled run executing more tools or tell the model that cancellation
     was an ordinary recoverable domain failure.
     */
    func testCancellationPropagatesOutOfDispatcher() async throws {
        let dispatcher = BibleUIAgentToolDispatcher(
            domain: ControlledFailureAgentDomain(behavior: .cancelled)
        )

        do {
            _ = try await dispatcher.execute(
                tool: .getAllLabels,
                arguments: [:],
                context: AgentExecutionContext(promptId: UUID())
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected terminal cancellation.
        }
    }

    /**
     Verifies unexpected infrastructure details never enter the tool result or model history.

     The thrown fixture embeds an API credential and raw transcript marker. Only the stable generic
     execution failure may be returned.
     */
    func testUnexpectedFailureDoesNotExposeCredentialsOrRawModelLogs() async throws {
        let secret = "sk-live-do-not-expose RAW_MODEL_TRANSCRIPT"
        let dispatcher = BibleUIAgentToolDispatcher(
            domain: ControlledFailureAgentDomain(
                behavior: .unexpected(UnsafeFixtureError(message: secret))
            )
        )
        let result = try await dispatcher.execute(
            tool: .getAllLabels,
            arguments: [:],
            context: AgentExecutionContext(promptId: UUID())
        )
        let modelContent = try result.modelContent()

        XCTAssertEqual(result.errorCode, "EXECUTION_ERROR")
        XCTAssertEqual(result.errorMessage, "The app could not complete this tool operation.")
        XCTAssertFalse(modelContent.contains("sk-live"))
        XCTAssertFalse(modelContent.contains("RAW_MODEL_TRANSCRIPT"))
    }

    /**
     Verifies success and error results serialize to Android's deterministic outer envelopes.

     Failure means provider history can diverge in status, data nesting, code placement, or key
     ordering even when domain execution itself succeeds.
     */
    func testResultEnvelopesMatchAndroidStatusAndDataShape() throws {
        let success = AgentToolResult(data: .object([
            "count": .number(2),
            "values": .array([.string("a"), .string("b")]),
        ]))
        let failure = AgentToolResult(errorMessage: "Not found", errorCode: "NOT_FOUND")

        XCTAssertEqual(
            try success.modelContent(),
            #"{"data":{"count":2,"values":["a","b"]},"status":"success"}"#
        )
        XCTAssertEqual(
            try failure.modelContent(),
            #"{"code":"NOT_FOUND","message":"Not found","status":"error"}"#
        )
    }

    /**
     Verifies canonical KJVA parsing accepts deuterocanonical input and rejects invalid or oversized
     ranges before bookmark and SQLite operations receive raw ordinals.

     Failure would silently reinterpret cross-versification input, accept reversed ranges, or allow
     an unbounded canonical expansion.
     */
    func testCanonicalReferenceValidationHandlesCrossVersificationAndBounds() throws {
        let deuterocanonical = try BibleUIAgentKJVAReferenceParser.parse("Tob.1.1-Tob.1.2")
        XCTAssertEqual(deuterocanonical.map(\.osisReference), ["Tob.1.1", "Tob.1.2"])

        XCTAssertThrowsError(try BibleUIAgentKJVAReferenceParser.parse("John.3.17-John.3.16")) {
            XCTAssertEqual(($0 as? BibleUIAgentDomainError)?.code, "INVALID_REFERENCE")
        }
        XCTAssertThrowsError(
            try BibleUIAgentKJVAReferenceParser.parse("Gen.1", maximum: 2)
        ) {
            XCTAssertEqual(($0 as? BibleUIAgentDomainError)?.code, "LIMIT_EXCEEDED")
        }
    }
}

/** Execution modes used to prove dispatcher failure boundaries deterministically. */
private actor ControlledFailureAgentDomain: BibleUIAgentToolExecuting {
    enum Behavior: Sendable {
        case success
        case domain(BibleUIAgentDomainError)
        case cancelled
        case unexpected(UnsafeFixtureError)
    }

    private let behavior: Behavior
    private var count = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func execute(
        _ request: BibleUIAgentToolRequest,
        context: AgentExecutionContext
    ) async throws -> AgentToolResult {
        count += 1
        switch behavior {
        case .success:
            return AgentToolResult(data: .object(["ok": .bool(true)]))
        case .domain(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        case .unexpected(let error):
            throw error
        }
    }

    func isAIDocument(documentID: UUID?, initials: String?) async -> Bool {
        false
    }

    func executionCount() -> Int {
        count
    }
}

/** Unsafe infrastructure fixture whose description must never be reflected to model history. */
private struct UnsafeFixtureError: Error, CustomStringConvertible, Sendable {
    let message: String
    var description: String { message }
}
