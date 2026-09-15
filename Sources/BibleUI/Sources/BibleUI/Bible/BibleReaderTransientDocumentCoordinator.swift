import BibleCore

/**
 Immutable description of a transient Vue `MultiDocument` render request.

 Android stores special links-window pages as fake documents while Vue renders the actual
 `MultiDocument` payload. This request carries both halves of that contract: the serialized Vue
 document plus the native rendered-content and optional PageManager identity that must survive
 client-ready replay and same-session reloads.

 - Side effects: None; this type is a value payload.
 - Failure modes: The coordinator does not validate `documentJSON`; callers keep responsibility for
   building valid bridge payloads before storing or emitting the request.
 */
struct BibleReaderTransientDocumentRequest: Equatable, Sendable {
    /// Serialized Vue `MultiDocument` payload to emit.
    let documentJSON: String

    /// Rendered-content book token for accessibility and tab display.
    let renderedBook: String

    /// Rendered-content key token for accessibility and tab display.
    let renderedKey: String

    /// Rendered-content category token.
    let renderedCategory: DocumentCategory

    /// Optional rendered module token.
    let renderedModuleName: String?

    /// Optional PageManager category to persist for Android fake-document parity.
    let pageCategory: DocumentCategory?

    /// Optional PageManager document initials to persist for Android fake-document parity.
    let pageDocumentInitials: String?

    /// Optional PageManager key to persist for Android fake-document parity.
    let pageKey: String?

    /// Exact copied source owners for the already-prepared document.
    let sourceProvenance: BibleReaderRenderSourceProvenance?

    /// Source-owned authorization checked throughout destination publication and replay.
    let sourceAuthorization: BibleReaderRoutedSourceAuthorization

    init(
        documentJSON: String,
        renderedBook: String,
        renderedKey: String,
        renderedCategory: DocumentCategory,
        renderedModuleName: String?,
        pageCategory: DocumentCategory?,
        pageDocumentInitials: String?,
        pageKey: String?,
        sourceProvenance: BibleReaderRenderSourceProvenance? = nil,
        sourceAuthorization: BibleReaderRoutedSourceAuthorization
    ) {
        self.documentJSON = documentJSON
        self.renderedBook = renderedBook
        self.renderedKey = renderedKey
        self.renderedCategory = renderedCategory
        self.renderedModuleName = renderedModuleName
        self.pageCategory = pageCategory
        self.pageDocumentInitials = pageDocumentInitials
        self.pageKey = pageKey
        self.sourceProvenance = sourceProvenance
        self.sourceAuthorization = sourceAuthorization
    }
}

/**
 Owns pending and active transient `MultiDocument` state for one reader pane.

 `BibleReaderController` still builds and emits bridge payloads, but this coordinator owns the
 state rule for special documents that can be requested before the WebView client is ready. A
 pre-ready request must be active immediately for same-session reload checks and pending exactly
 once for client-ready replay; a client-ready request remains active without creating stale replay
 work. This mirrors Android links-window fake-document behavior without making the controller own
 hidden pending slots.

 - Side effects: Mutates only in-memory pending/active request slots.
 - Failure modes: None; invalid bridge payloads are treated as opaque strings and remain caller
   responsibility, preserving the previous controller contract.
 - Note: `activeRequest(isShowingAndroidMultiDocument:)` intentionally gates the stored active
   request on the caller's current Android fake-document predicate so stale active requests cannot
   override ordinary category loading.
 */
struct BibleReaderTransientDocumentCoordinator {
    /// Last transient special document visible in this pane, used for same-session reloads.
    private var activeRequest: BibleReaderTransientDocumentRequest?

    /// Transient document that should be replayed once the Vue client has finished bootstrapping.
    private var pendingClientReadyRequest: BibleReaderTransientDocumentRequest?

    /**
     Stores a transient document request using the current client-ready state.

     - Parameters:
       - request: Opaque transient document payload and native identity to remember.
       - clientReady: Whether the Vue client can currently receive bridge document events.
     - Side effects: Replaces the active request and either stores or clears the pending replay
       request.
     - Failure modes: None; callers emit the request separately after storage.
     */
    mutating func store(_ request: BibleReaderTransientDocumentRequest, clientReady: Bool) {
        activeRequest = request
        pendingClientReadyRequest = clientReady ? nil : request
    }

    /**
     Returns the active transient request only while native state is on Android's fake document.

     - Parameter isShowingAndroidMultiDocument: Caller-computed predicate for the current
       PageManager/controller category and document identity.
     - Returns: Stored active request when the caller is still showing Android `Multi`; otherwise
       `nil`.
     - Side effects: None.
     - Failure modes: None; stale active requests are suppressed by the predicate.
     */
    func activeRequest(isShowingAndroidMultiDocument: Bool) -> BibleReaderTransientDocumentRequest? {
        isShowingAndroidMultiDocument ? activeRequest : nil
    }

    /**
     Consumes the pending client-ready replay request.

     - Returns: The pre-ready transient request to replay, or `nil` when none is pending.
     - Side effects: Clears the pending replay slot so client-ready replay happens once.
     - Failure modes: None.
     */
    mutating func consumePendingClientReadyRequest() -> BibleReaderTransientDocumentRequest? {
        let request = pendingClientReadyRequest
        pendingClientReadyRequest = nil
        return request
    }

    /**
     Evicts prepared transient bytes when their captured source authorization is obsolete.

     - Side effects: Clears both active and pending replay slots only for an invalid authorization.
     - Failure modes: None. Independently owned or still-current source content remains replayable.
     */
    mutating func invalidatePreparedReplayForInstalledSourceChange() {
        guard let activeRequest, !activeRequest.sourceAuthorization.isCurrent() else { return }
        self.activeRequest = nil
        pendingClientReadyRequest = nil
    }
}
