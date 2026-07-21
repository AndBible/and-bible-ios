import Foundation

/**
 URLSession-backed LLM client with endpoint, redirect, cancellation, and redaction enforcement.

 The injected session makes requests interceptable by a custom `URLProtocol` in tests. A per-task
 redirect delegate rejects every HTTPS downgrade and every authenticated cross-origin redirect
 before URLSession can forward provider headers. Returned errors contain no response body, complete
 URL, underlying network message, API key, or user prompt content.
 */
public final class LLMHTTPClient: LLMTransportTranscriptCompleting, @unchecked Sendable {
    /// Maximum successful response bytes copied into one local diagnostic transcript entry.
    public static let maximumTranscriptResponseByteCount = 512 * 1_024

    /// Injected URL loading session.
    private let session: URLSession

    /**
     Creates the production client with an ephemeral, non-caching, cookieless session.

     - Side effects: Creates an in-memory URLSession; no request occurs until `complete(_:)`.
     - Failure modes: none.
     */
    public convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.init(session: URLSession(configuration: configuration))
    }

    /**
     Creates a network client over an injected session.

     - Parameter session: URLSession configured by the app or with test `protocolClasses`.
     - Side effects: none until `complete(_:)` is awaited.
     */
    public init(session: URLSession) {
        self.session = session
    }

    /**
     Executes one provider call and parses the successful response.

     - Parameter request: Fully resolved provider-neutral request.
     - Returns: Parsed provider-neutral completion.
     - Side effects: Performs one cancellable HTTPS request and may follow same-origin HTTPS redirects.
     - Throws:
       - `CancellationError` when the task is cancelled
       - `LLMClientError.authenticatedCrossOriginRedirect` before forwarding credentials cross-origin
       - stable endpoint, HTTP, transport, or malformed-response errors with secret-free payloads
     */
    public func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletion {
        try await perform(request, transcriptReporter: nil)
    }

    /**
     Executes one provider call while reporting the bounded successful body before parsing.

     Transport failures are reduced to stable credential-free text. A malformed successful body is
     still reported before the adapter rejects it, matching Android's raw-log ordering.
     */
    public func complete(
        _ request: LLMCompletionRequest,
        transcriptReporter: LLMTransportTranscriptReporter
    ) async throws -> LLMCompletion {
        try await perform(request, transcriptReporter: transcriptReporter)
    }

    /** Shared implementation for ordinary calls and run-scoped transcript capture. */
    private func perform(
        _ request: LLMCompletionRequest,
        transcriptReporter: LLMTransportTranscriptReporter?
    ) async throws -> LLMCompletion {
        try Task.checkCancellation()
        let adapter: any LLMAPIAdapting = switch request.apiFormat {
        case .openAI: OpenAICompatibleAdapter()
        case .anthropic: AnthropicMessagesAdapter()
        }
        let urlRequest: URLRequest
        do {
            urlRequest = try adapter.makeRequest(from: request)
        } catch {
            await transcriptReporter?.report(.failure(Self.transcriptFailure(for: error)))
            throw error
        }
        let redirectGuard = AuthenticatedRedirectGuard(originalRequest: urlRequest)

        let data: Data
        do {
            let response: URLResponse
            (data, response) = try await session.data(for: urlRequest, delegate: redirectGuard)
            try Task.checkCancellation()
            if let rejection = redirectGuard.rejection {
                throw rejection
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMClientError.transportFailure
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw LLMClientError.httpStatus(httpResponse.statusCode)
            }
        } catch is CancellationError {
            await transcriptReporter?.report(.failure("ERROR: Cancelled"))
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            await transcriptReporter?.report(.failure("ERROR: Cancelled"))
            throw CancellationError()
        } catch let error as LLMClientError {
            await transcriptReporter?.report(.failure(Self.transcriptFailure(for: error)))
            throw error
        } catch {
            await transcriptReporter?.report(.failure("ERROR: Transport failure"))
            throw LLMClientError.transportFailure
        }

        await transcriptReporter?.report(
            .responseBody(Self.transcriptBody(from: data))
        )
        return try adapter.parseResponse(data)
    }

    /** Returns a bounded UTF-8 representation without retaining an additional full response copy. */
    private static func transcriptBody(from data: Data) -> String {
        guard data.count > maximumTranscriptResponseByteCount else {
            return String(decoding: data, as: UTF8.self)
        }
        let prefix = data.prefix(maximumTranscriptResponseByteCount)
        return String(decoding: prefix, as: UTF8.self)
            + "\n[Response truncated for local diagnostics]"
    }

    /** Maps known client failures to stable raw-log text without reflecting provider data. */
    private static func transcriptFailure(for error: Error) -> String {
        guard let clientError = error as? LLMClientError else {
            return "ERROR: Request preparation failed"
        }
        switch clientError {
        case .httpStatus(let status):
            return "ERROR: HTTP status \(status)"
        case .invalidEndpoint:
            return "ERROR: Invalid endpoint"
        case .insecureEndpoint:
            return "ERROR: Insecure endpoint"
        case .endpointContainsCredentials:
            return "ERROR: Endpoint contains credentials"
        case .missingCredential:
            return "ERROR: Missing credential"
        case .reservedHeader, .invalidHeader:
            return "ERROR: Invalid request header"
        case .invalidRequest, .invalidMessage:
            return "ERROR: Invalid request"
        case .authenticatedCrossOriginRedirect:
            return "ERROR: Authenticated cross-origin redirect rejected"
        case .malformedResponse:
            return "ERROR: Malformed response"
        case .unknownTool, .malformedToolArguments:
            return "ERROR: Invalid provider tool call"
        case .transportFailure:
            return "ERROR: Transport failure"
        }
    }
}

/**
 Pure redirect security policy shared by URLSession delegation and focused tests.

 Authenticated requests may follow only same-origin HTTPS redirects. Unauthenticated requests may
 cross origins but may never downgrade from HTTPS or acquire URL user-info credentials.
 */
public enum LLMRedirectPolicy {
    /**
     Returns the stable rejection for a redirect, or `nil` when it may proceed.

     - Parameters:
       - originalRequest: Initial provider request.
       - redirectRequest: URLSession's proposed redirected request.
     - Returns: Secret-free rejection reason, or `nil`.
     - Side effects: none.
     */
    public static func rejection(
        originalRequest: URLRequest,
        redirectRequest: URLRequest
    ) -> LLMClientError? {
        guard let url = redirectRequest.url,
              url.scheme?.lowercased() == "https",
              let targetOrigin = HTTPOrigin(url: url) else {
            return .insecureEndpoint
        }
        guard url.user == nil, url.password == nil else {
            return .endpointContainsCredentials
        }
        let isAuthenticated = originalRequest.value(forHTTPHeaderField: "Authorization") != nil
            || originalRequest.value(forHTTPHeaderField: "x-api-key") != nil
        if isAuthenticated,
           targetOrigin != originalRequest.url.flatMap(HTTPOrigin.init(url:)) {
            return .authenticatedCrossOriginRedirect
        }
        return nil
    }
}

/**
 Per-task redirect delegate that prevents authenticated origin changes and HTTPS downgrades.
 */
private final class AuthenticatedRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Initial authenticated request used by the pure redirect policy.
    private let originalRequest: URLRequest

    /// Synchronizes delegate writes with async response reads.
    private let lock = NSLock()

    /// First redirect rejection recorded by the delegate.
    private var storedRejection: LLMClientError?

    /// Thread-safe redirect rejection exposed after URLSession returns the original redirect response.
    var rejection: LLMClientError? {
        lock.lock()
        defer { lock.unlock() }
        return storedRejection
    }

    /** Captures origin and authentication state from the validated initial request. */
    init(originalRequest: URLRequest) {
        self.originalRequest = originalRequest
    }

    /**
     Allows only HTTPS redirects that do not move authenticated requests to another origin.

     - Side effects: Records a stable rejection and returns `nil` to URLSession when disallowed.
     - Failure modes: Missing or malformed redirect URLs are treated as insecure and rejected.
     */
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let rejection = LLMRedirectPolicy.rejection(
            originalRequest: originalRequest,
            redirectRequest: request
        ) {
            record(rejection)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /** Records only the first redirect rejection. */
    private func record(_ rejection: LLMClientError) {
        lock.lock()
        if storedRejection == nil {
            storedRejection = rejection
        }
        lock.unlock()
    }
}

/** Normalized HTTP origin used for redirect comparisons. */
private struct HTTPOrigin: Equatable, Sendable {
    /// Lowercased URL scheme.
    let scheme: String

    /// Lowercased DNS host.
    let host: String

    /// Explicit or scheme-default port.
    let port: Int

    /** Creates an origin only for URLs with a scheme and host. */
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}
