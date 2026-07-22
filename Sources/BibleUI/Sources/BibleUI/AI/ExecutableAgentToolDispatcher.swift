// ExecutableAgentToolDispatcher.swift -- Complete typed AI tool registration

import BibleCore
import Foundation

/**
 Domain execution boundary consumed by the complete agent tool dispatcher.

 Production uses BibleUIAgentDomainAdapter. Tests can supply deterministic fakes while still
 exercising exact definitions, argument validation, permission routing, and registry closures.
 */
public protocol BibleUIAgentToolExecuting: Sendable {
    /**
     Executes one validated domain request.

     - Parameters:
       - request: Typed request whose coarse validation has completed.
       - context: Immutable execution context for ownership and active-state fallback.
     - Returns: Android-shaped result data or typed structural completion.
     - Side effects: Depends on the request and concrete domain adapter.
     - Failure modes: Throws only typed safe domain failures or infrastructure failures whose
       details are not reflected into model history.
     */
    func execute(
        _ request: BibleUIAgentToolRequest,
        context: AgentExecutionContext
    ) async throws -> AgentToolResult

    /**
     Resolves whether a page target belongs to Android's protected AI Documents collection.

     - Parameters:
       - documentID: Optional durable document identifier.
       - initials: Optional durable document initials.
     - Returns: True only for a currently existing AI Documents target. Both values must identify
       the same row when both are supplied.
     - Side effects: Reads the My Documents store.
     - Failure modes: Missing or mismatched identities return false.
     */
    func isAIDocument(documentID: UUID?, initials: String?) async -> Bool
}

/** Safe domain failure that may be returned to model history. */
public struct BibleUIAgentDomainError: Error, Equatable, LocalizedError, Sendable {
    public let code: String
    public let message: String

    /**
     Creates a stable domain failure.

     - Parameters:
       - code: Machine-readable failure code.
       - message: Credential-free and log-free model-facing explanation.
     - Side effects: None.
     - Failure modes: None.
     */
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/**
 Production AgentToolDispatching implementation for every Android tool.

 Definitions come from the exact Android snapshot. Every invocation is decoded to a distinct typed
 enum case before permission checks or execution, preventing accidental text-command fallbacks.
 */
public struct BibleUIAgentToolDispatcher: AgentToolDispatching, Sendable {
    private let domain: any BibleUIAgentToolExecuting

    /**
     Creates a complete dispatcher over an injected app-domain adapter.

     - Parameter domain: Production or deterministic domain executor.
     - Side effects: None.
     - Failure modes: None; AgentToolRegistry validates all definitions at registration.
     */
    public init(domain: any BibleUIAgentToolExecuting) {
        self.domain = domain
    }

    /** Returns the exact provider-facing Android definition for one tool. */
    public func definition(for tool: AgentTool) -> LLMToolDefinition {
        AndroidAgentToolDefinitionCatalog.definition(for: tool)
    }

    /**
     Classifies one concrete invocation using Android's dynamic page-ownership exceptions.

     Read and structural tools never request write permission. Ordinary writes always do.
     Adding to AI Documents and editing a page created during the current run are permission-free.
     */
    public func requiresPermission(
        for tool: AgentTool,
        arguments: [String: JSONValue],
        context: AgentExecutionContext
    ) async throws -> Bool {
        let request = try BibleUIAgentToolRequestParser.parse(
            tool: tool,
            arguments: arguments
        )
        switch request {
        case .addMyDocumentPage(let documentID, let initials, _, _, _):
            if initials == MyDocumentManagementSession.aiDocumentsInitials { return false }
            guard documentID != nil else { return true }
            return !(await domain.isAIDocument(
                documentID: documentID,
                initials: nil
            ))
        case .editMyDocumentPage(let pageID, _, _, _):
            return !context.createdPageIds.contains(pageID)
        default:
            switch tool.access {
            case .read, .structural:
                return false
            case .write:
                return true
            }
        }
    }

    /**
     Validates and executes one exact tool without exposing raw infrastructure failures.

     Validation and safe domain failures are recoverable result envelopes. Unexpected thrown
     failures become a stable execution error without embedding credentials, database messages, or
     model logs.
     */
    public func execute(
        tool: AgentTool,
        arguments: [String: JSONValue],
        context: AgentExecutionContext
    ) async throws -> AgentToolResult {
        let request: BibleUIAgentToolRequest
        do {
            request = try BibleUIAgentToolRequestParser.parse(
                tool: tool,
                arguments: arguments
            )
        } catch let error as BibleUIAgentArgumentError {
            return AgentToolResult(errorMessage: error.message, errorCode: error.code)
        }

        do {
            return try await domain.execute(request, context: context)
        } catch let error as BibleUIAgentDomainError {
            return AgentToolResult(errorMessage: error.message, errorCode: error.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return AgentToolResult(
                errorMessage: "The app could not complete this tool operation.",
                errorCode: "EXECUTION_ERROR"
            )
        }
    }
}

/** Discoverable production-name alias for app composition roots. */
public typealias ProductionAgentToolDispatcher = BibleUIAgentToolDispatcher
