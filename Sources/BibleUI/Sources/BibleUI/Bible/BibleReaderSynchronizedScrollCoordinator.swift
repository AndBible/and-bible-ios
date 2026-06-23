// BibleReaderSynchronizedScrollCoordinator.swift -- Sync-scroll feedback state for reader panes

import Foundation

/**
 Owns synchronized-scroll feedback suppression for one reader pane.

 Android keeps inactive synchronized windows passive while a source pane scrolls them. The target
 pane may report intermediate visible-verse callbacks and native scroll deltas while WebKit is
 settling, but those signals are still feedback until explicit interaction makes the pane a new
 source. This coordinator isolates that state machine from `BibleReaderController` so the
 controller can orchestrate bridge and navigation work without directly owning the feedback guard.

 Side effects:
 - stores pending synchronized target ordinals for client-ready replay and scroll acknowledgement
 - tracks whether native/WebView scroll telemetry should remain passive

 Failure modes:
 - if the exact target ordinal never arrives, feedback remains suppressed until explicit
   interaction clears it, matching Android's touch-driven source handoff
 */
final class BibleReaderSynchronizedScrollCoordinator {
    /// Latest ordinal expected from a sync-origin visible-verse callback.
    private var pendingSynchronizedScrollOrdinal: Int?

    /// Latest sync-origin scroll target received before the Vue reader reports client-ready.
    private var pendingClientReadySynchronizedScrollOrdinal: Int?

    /// Whether target-pane scroll telemetry should remain passive feedback.
    private var feedbackSuppressionActive = false

    /**
     Indicates whether native scroll deltas should be forwarded as user-origin input.

     - Returns: `true` when no synchronized feedback guard is active.
     - Side effects: None.
     - Failure modes: Returns `false` for programmatic target-pane movement until explicit
       interaction clears the guard.
     */
    var shouldTreatNativeScrollDeltaAsUserInteraction: Bool {
        !feedbackSuppressionActive
    }

    /**
     Arms feedback suppression for a synchronized target ordinal.

     - Parameter ordinal: Target-local SWORD/JSword ordinal expected from the web client.
     - Side effects: Replaces the pending acknowledgement ordinal, clears stale client-ready
       deferrals, and suppresses native/WebView feedback.
     - Failure modes: None.
     */
    func armSynchronizedFeedback(ordinal: Int) {
        pendingSynchronizedScrollOrdinal = ordinal
        pendingClientReadySynchronizedScrollOrdinal = nil
        feedbackSuppressionActive = true
    }

    /**
     Defers a synchronized scroll target until the Vue reader reports client-ready.

     - Parameter ordinal: Target-local SWORD/JSword ordinal that content replay should land on.
     - Side effects: Replaces the pending client-ready ordinal and suppresses feedback immediately
       so bootstrap scroll telemetry cannot become a source-window handoff.
     - Failure modes: Does not clear the current acknowledgement ordinal, preserving existing
       controller behavior when a ready scroll is superseded by a pre-ready replay request.
     */
    func deferUntilClientReady(ordinal: Int) {
        pendingClientReadySynchronizedScrollOrdinal = ordinal
        feedbackSuppressionActive = true
    }

    /**
     Consumes the pending client-ready replay target.

     - Returns: Deferred target ordinal, or `nil` when no pre-ready synchronized target is pending.
     - Side effects: Clears the client-ready deferral slot so replay happens once.
     - Failure modes: Does not change feedback suppression; callers promote the returned ordinal
       after the content replay has been queued.
     */
    func consumeDeferredClientReadyOrdinalForReplay() -> Int? {
        let ordinal = pendingClientReadySynchronizedScrollOrdinal
        pendingClientReadySynchronizedScrollOrdinal = nil
        return ordinal
    }

    /**
     Marks a just-replayed client-ready synchronized target as awaiting visible-verse feedback.

     - Parameter ordinal: Target-local SWORD/JSword ordinal replayed into the web client.
     - Side effects: Replaces the pending acknowledgement ordinal.
     - Failure modes: None.
     */
    func markClientReadyReplayPending(ordinal: Int) {
        pendingSynchronizedScrollOrdinal = ordinal
    }

    /**
     Classifies a visible-verse callback while synchronized feedback may be active.

     - Parameter ordinal: Ordinal reported by the web client after visible-position movement.
     - Returns: `true` when the callback should be treated as sync-origin feedback; otherwise
       `false` so normal user-origin scrolling may broadcast.
     - Side effects: Clears pending target and client-ready state when the matching ordinal arrives.
     - Failure modes: Nonmatching/intermediate ordinals remain passive while suppression is active.
     */
    func acknowledgeVisibleOrdinal(_ ordinal: Int) -> Bool {
        guard feedbackSuppressionActive else { return false }
        if pendingSynchronizedScrollOrdinal == ordinal {
            pendingSynchronizedScrollOrdinal = nil
            pendingClientReadySynchronizedScrollOrdinal = nil
        }
        return true
    }

    /**
     Clears synchronized feedback state because this pane received explicit user interaction.

     - Side effects: Drops pending synchronized ordinals and allows future native/WebView scroll
       telemetry to become source-window input.
     - Failure modes: None.
     */
    func clearForUserInteraction() {
        pendingSynchronizedScrollOrdinal = nil
        pendingClientReadySynchronizedScrollOrdinal = nil
        feedbackSuppressionActive = false
    }
}
