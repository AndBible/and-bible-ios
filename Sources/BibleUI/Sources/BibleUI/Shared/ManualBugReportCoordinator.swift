// ManualBugReportCoordinator.swift -- deterministic state transitions for user-controlled reports

import Foundation

/**
 Visible phase for one manual crash-evidence report flow.

 A phase never represents a report as delivered except while the user controls Mail; all other
 paths keep the prepared report local and explicitly unsent.
 */
enum ManualBugReportPhase: Equatable {
    /// No report collection or handoff is active.
    case idle
    /// Evidence collection is running; repeat launches are ignored.
    case collecting
    /// Evidence exists locally and awaits explicit user consent.
    case awaitingConsent
    /// The system Mail composer owns the next user action.
    case presentingMail
    /// Mail cannot compose; the local report can be explicitly exported.
    case mailUnavailable
    /// A ZIP is being built only after the unavailable-Mail explanation.
    case exporting
    /// ZIP creation failed; the report remains local and available for another explicit attempt.
    case exportFailed
}

/**
 Serializes manual report actions so cancellation, duplicate taps, and terminal Mail outcomes
 cannot create accidental delivery or multiple system presentations.

 The coordinator stores phase only; the view owns the immutable payload and temporary ZIP so no
 diagnostic bytes are retained here. All methods are deterministic and side-effect free.
 */
struct ManualBugReportCoordinator {
    /// Current user-visible phase; mutations happen on the reader's main-actor state.
    private(set) var phase: ManualBugReportPhase = .idle

    /** Begins evidence collection once, rejecting duplicate launches while a flow is active. */
    mutating func beginCollection() -> Bool {
        guard phase == .idle else { return false }
        phase = .collecting
        return true
    }

    /** Advances a still-active collection to local consent; cancelled work is ignored. */
    mutating func completeCollection() -> Bool {
        guard phase == .collecting else { return false }
        phase = .awaitingConsent
        return true
    }

    /** Cancels a local report before or after consent without opening a delivery surface. */
    mutating func cancel() {
        phase = .idle
    }

    /** Opens Mail only when capability was checked after explicit consent. */
    mutating func requestMail(capability: AddressedMailCapability) -> Bool {
        guard phase == .awaitingConsent else { return false }
        phase = capability == .available ? .presentingMail : .mailUnavailable
        return true
    }

    /** Closes Mail after any truthful terminal result; only `.sent` signifies delivery. */
    mutating func finishMail(_ result: AddressedMailResult) {
        guard phase == .presentingMail else { return }
        phase = .idle
    }

    /** Starts a user-requested local ZIP build only from the unavailable-Mail state. */
    mutating func beginExport() -> Bool {
        guard phase == .mailUnavailable || phase == .exportFailed else { return false }
        phase = .exporting
        return true
    }

    /** Records export success or failure without claiming that any destination received the ZIP. */
    mutating func completeExport(success: Bool) {
        guard phase == .exporting else { return }
        phase = success ? .idle : .exportFailed
    }
}
