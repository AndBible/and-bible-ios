import BibleCore

/**
 Native state transition plan for Android-style transient special documents.

 Android stores links-window `Multi` pages as fake `general_book/Multi` pages while Vue renders the
 actual multi-document payload. This value describes the native category and optional PageManager
 mutation that the controller must apply before emitting the Vue payload.

 - Side effects: None; this is an immutable transition plan.
 - Failure modes: Malformed transient requests produce a non-persisting general-book transition so
   invalid bridge payloads cannot erase the last restorable Android `Multi` key.
 */
struct BibleReaderSpecialDocumentPageIdentityUpdate {
    /// Category that should become the controller's current category.
    let currentCategory: DocumentCategory

    /// Whether the controller should clear its concrete general-book module reference.
    let clearsActiveGeneralBookModule: Bool

    /// General-book document initials to expose when the transition targets Android `Multi`.
    let activeGeneralBookModuleName: String?

    /// General-book key to expose when the request has a durable fake-document key.
    let currentGeneralBookKey: String?

    /// PageManager category key to persist, or `nil` when no durable page identity should be saved.
    let pageManagerCategoryName: String?

    /// PageManager general-book document initials to persist.
    let pageManagerGeneralBookDocument: String?

    /// PageManager general-book key to persist.
    let pageManagerGeneralBookKey: String?

    /// Whether applying the PageManager fields should trigger pane/workspace persistence.
    let persistsPageManagerState: Bool
}

/**
 Coordinates Android-style special document state for one reader pane.

 This coordinator owns the transient `MultiDocument` pending/active slots and the PageManager
 identity rules for Android fake documents. The controller remains responsible for actually
 mutating its fields and emitting bridge events, but it no longer owns the decision logic for when
 a transient document is active, when it should replay after client-ready, or how a request maps to
 durable `general_book/Multi` state.

 - Side effects: Mutates only in-memory pending/active transient request state.
 - Failure modes: Invalid document JSON is treated as an opaque string, preserving the bridge
   contract that payload builders validate before requesting a transient render. Invalid durable
   fake-document fields produce a non-persisting identity update.
 - Note: Android parity is centered on `FakeBookFactory.multiDocument`: special link-result pages
   use `general_book/Multi` for native state and Vue `MultiDocument` for rendered content.
 */
struct BibleReaderSpecialDocumentCoordinator {
    /// Pending/active transient request state machine.
    private var transientDocumentCoordinator = BibleReaderTransientDocumentCoordinator()

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
        transientDocumentCoordinator.store(request, clientReady: clientReady)
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
        transientDocumentCoordinator.activeRequest(isShowingAndroidMultiDocument: isShowingAndroidMultiDocument)
    }

    /**
     Consumes the pending client-ready replay request.

     - Returns: The pre-ready transient request to replay, or `nil` when none is pending.
     - Side effects: Clears the pending replay slot so client-ready replay happens once.
     - Failure modes: None.
     */
    mutating func consumePendingClientReadyRequest() -> BibleReaderTransientDocumentRequest? {
        transientDocumentCoordinator.consumePendingClientReadyRequest()
    }

    /**
     Builds the native identity transition for a transient rendered document.

     Requests without a durable page category preserve the legacy transient-Bible identity. Android
     `Multi` requests become `general_book/Multi` pages and persist only when both document initials
     and key are non-empty; that prevents malformed transient payloads from overwriting the last
     restorable `Multi` key.

     - Parameter request: Transient request carrying optional durable PageManager fields.
     - Returns: A native state transition plan for the controller to apply.
     - Side effects: None.
     - Failure modes: Missing required durable general-book fields yield a non-persisting update
       rather than throwing.
     */
    func pageIdentityUpdate(
        for request: BibleReaderTransientDocumentRequest
    ) -> BibleReaderSpecialDocumentPageIdentityUpdate {
        guard let pageCategory = request.pageCategory else {
            return BibleReaderSpecialDocumentPageIdentityUpdate(
                currentCategory: .bible,
                clearsActiveGeneralBookModule: false,
                activeGeneralBookModuleName: nil,
                currentGeneralBookKey: nil,
                pageManagerCategoryName: nil,
                pageManagerGeneralBookDocument: nil,
                pageManagerGeneralBookKey: nil,
                persistsPageManagerState: false
            )
        }

        if pageCategory == .generalBook {
            guard let pageDocumentInitials = request.pageDocumentInitials, !pageDocumentInitials.isEmpty,
                  let pageKey = request.pageKey, !pageKey.isEmpty else {
                return BibleReaderSpecialDocumentPageIdentityUpdate(
                    currentCategory: pageCategory,
                    clearsActiveGeneralBookModule: true,
                    activeGeneralBookModuleName: request.pageDocumentInitials,
                    currentGeneralBookKey: nil,
                    pageManagerCategoryName: nil,
                    pageManagerGeneralBookDocument: nil,
                    pageManagerGeneralBookKey: nil,
                    persistsPageManagerState: false
                )
            }
            return BibleReaderSpecialDocumentPageIdentityUpdate(
                currentCategory: pageCategory,
                clearsActiveGeneralBookModule: true,
                activeGeneralBookModuleName: pageDocumentInitials,
                currentGeneralBookKey: pageKey,
                pageManagerCategoryName: pageCategory.pageManagerKey,
                pageManagerGeneralBookDocument: pageDocumentInitials,
                pageManagerGeneralBookKey: pageKey,
                persistsPageManagerState: true
            )
        }

        return BibleReaderSpecialDocumentPageIdentityUpdate(
            currentCategory: pageCategory,
            clearsActiveGeneralBookModule: false,
            activeGeneralBookModuleName: nil,
            currentGeneralBookKey: nil,
            pageManagerCategoryName: pageCategory.pageManagerKey,
            pageManagerGeneralBookDocument: nil,
            pageManagerGeneralBookKey: nil,
            persistsPageManagerState: true
        )
    }
}
