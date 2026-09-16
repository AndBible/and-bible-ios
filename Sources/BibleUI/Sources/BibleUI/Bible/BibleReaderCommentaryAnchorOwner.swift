// BibleReaderCommentaryAnchorOwner.swift -- Transient commentary viewport ownership

import Foundation
import SwiftData

/** Immutable pane owner captured at commentary publication rather than during scroll telemetry. */
struct BibleReaderCommentaryAnchorPaneOwner: Equatable, Sendable {
    /// Persistent identity of the PageManager row receiving the accepted commentary document.
    let pageManager: PersistentIdentifier
    /// Persistent identity of the Window row bound to this controller.
    let window: PersistentIdentifier
    /// Pane UUID already captured by the preparation request.
    let paneID: UUID?
    /// Workspace UUID already captured by the preparation request.
    let workspaceID: UUID?
}

/** Exact live owner of one accepted commentary document-local viewport anchor. */
struct BibleReaderCommentaryAnchorIdentity: Equatable, Sendable {
    /// Pane owner captured at accepted publication, before Vue can emit telemetry.
    let paneOwner: BibleReaderCommentaryAnchorPaneOwner
    /// Java-exact commentary module initials selected by the PageManager.
    let moduleInitials: BibleReaderPreparationExactText
    /// Rendered annotation route accepted for the visible document.
    let target: BibleReaderCommentaryNavigationTarget
    /// Immutable source handles and generations read while producing the document.
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/**
 Retains a commentary BVA only while its exact live pane, route, and source still own it.

 This owner deliberately has no persisted-state bootstrap. `PageManager.commentaryAnchorOrdinal`
 alone cannot identify the commentary key or source generation that produced an ordinal after
 process restoration. A future durable restoration path must provide that source witness rather
 than pairing the ordinal with the pane's later shared-Bible coordinate.
 */
struct BibleReaderCommentaryAnchorOwner {
    private struct Receipt: Equatable, Sendable {
        let identity: BibleReaderCommentaryAnchorIdentity
        let ordinal: Int
    }

    private var acceptedReceipt: Receipt?

    /**
     Retires a prior viewport after a full replacement accepts without a reusable owner.

     - Side effects: Clears the transient receipt.
     - Failure modes: None; clearing an empty owner is idempotent.
     */
    mutating func clear() {
        acceptedReceipt = nil
    }

    /**
     Records an anchor reported by an accepted, currently authorized commentary route.

     - Parameters:
       - ordinal: Nonnegative local BVA emitted by the accepted Vue document.
       - identity: Exact pane, module, rendered route, and immutable source owner.
     - Side effects: Replaces the prior transient receipt when `ordinal` is nonnegative.
     - Failure modes: Negative ordinals are ignored and cannot displace a good receipt.
     */
    mutating func acceptVisibleOrdinal(
        _ ordinal: Int,
        identity: BibleReaderCommentaryAnchorIdentity
    ) {
        guard ordinal >= 0 else { return }
        acceptedReceipt = Receipt(identity: identity, ordinal: ordinal)
    }

    /**
     Resolves the ordinal for one full commentary replacement.

     - Parameters:
       - identity: Owner captured by the replacement being published.
       - contentOrdinalRange: Local BVA domain present in the replacement document.
       - persistedOrdinal: Current anchor still owned by the same live PageManager.
     - Returns: The retained ordinal only for an exact owner and in-range BVA; otherwise zero,
       matching Android's invalidated commentary anchor.
     - Side effects: None. Publication must call `commitReplacement` only after bridge acceptance.
     - Failure modes: Missing, stale, cross-pane, cross-module, cross-route, and out-of-range
       receipts all fail closed to zero.
     */
    func replacementOrdinal(
        for identity: BibleReaderCommentaryAnchorIdentity,
        contentOrdinalRange: ClosedRange<Int>,
        persistedOrdinal: Int?
    ) -> Int {
        guard let acceptedReceipt,
              acceptedReceipt.identity == identity,
              persistedOrdinal == acceptedReceipt.ordinal,
              contentOrdinalRange.contains(acceptedReceipt.ordinal) else { return 0 }
        return acceptedReceipt.ordinal
    }

    /**
     Makes an accepted full replacement the new transient anchor owner.

     - Parameters:
       - ordinal: Exact setup ordinal accepted by the bridge.
       - identity: Owner of the accepted replacement.
     - Side effects: Replaces any older receipt, including one for a previously selected key.
     - Failure modes: Negative ordinals are normalized to zero; prepared failures and rejected or
       stale bridge publications must not call this method.
     */
    mutating func commitReplacement(
        ordinal: Int,
        identity: BibleReaderCommentaryAnchorIdentity
    ) {
        acceptedReceipt = Receipt(identity: identity, ordinal: max(0, ordinal))
    }
}
