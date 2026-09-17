// StartupLockedBibleUnlockQueue.swift -- Android-parity startup credential queue

import SwiftUI
import SwordKit

/**
 Tracks Android's app-owned startup passphrase sequence independently from reader navigation.

 Android snapshots every initially locked Bible in installed-book order, asks for each credential in
 sequence, and does not stop after the first successful unlock. A rejected or cancelled credential
 first asks whether the same module should be retried; declining advances to the next snapshotted
 module. The reader performs one fresh access reconciliation only after this queue completes.

 Inputs:
 - one inclusive installed-module snapshot in registration order

 Outputs:
 - the current locked Bible
 - a completed state after every initially locked Bible has been processed

 Side effects: None; owners perform manager unlocks and final inventory reconciliation.

 Failure modes:
 - non-Bible, unencrypted, and already-unlocked rows are excluded from the immutable queue snapshot
 - an empty locked snapshot starts completed so callers can fail closed to setup
 */
struct StartupLockedBibleUnlockQueue {
    /// Immutable locked-Bible snapshot in the manager's installed registration order.
    let lockedBibleModules: [ModuleInfo]

    /// Index of the module currently being processed.
    private(set) var currentIndex: Int

    /**
     Creates one immutable Android-order locked-Bible snapshot.

     - Parameter installedModules: Inclusive installed inventory in manager registration order.
     - Side effects: None.
     - Failure modes: If no locked Bible exists, the queue starts completed.
     */
    init(installedModules: [ModuleInfo]) {
        lockedBibleModules = Self.lockedBibleModules(in: installedModules)
        currentIndex = 0
    }

    /// Locked Bible currently awaiting acceptance or an explicit decision not to retry.
    var currentModule: ModuleInfo? {
        guard lockedBibleModules.indices.contains(currentIndex) else { return nil }
        return lockedBibleModules[currentIndex]
    }

    /// Whether every module from the immutable startup snapshot has been processed.
    var isCompleted: Bool {
        currentModule == nil
    }

    /**
     Filters an inclusive installed inventory without changing registration order.

     - Parameter modules: Installed rows in the order supplied by `SwordManager`.
     - Returns: Only encrypted, not-yet-unlocked Bible rows, preserving input order and duplicates.
     - Side effects: None.
     - Failure modes: Stale access metadata is intentionally retained because Android also queues
       from one initial snapshot; the final fresh reconciliation determines reader eligibility.
     */
    static func lockedBibleModules(in modules: [ModuleInfo]) -> [ModuleInfo] {
        modules.filter {
            $0.category == .bible && $0.isEncrypted && !$0.isUnlocked
        }
    }

    /**
     Records a successful credential and advances to the next initial locked row.

     - Side effects: Advances queue state only; it never selects or activates a reader document.
     - Failure modes: Calls after completion are ignored.
     */
    mutating func acceptCurrentModule() {
        guard currentModule != nil else { return }
        advance()
    }

    /**
     Records Android's negative retry response and advances to the next initial locked row.

     - Side effects: Advances queue state only.
     - Failure modes: Calls after completion are ignored; credential phase validity belongs to the
       one-module session that emits this terminal decision.
     */
    mutating func declineCurrentModule() {
        guard currentModule != nil else { return }
        advance()
    }

    /**
     Advances exactly once within the immutable snapshot.

     - Side effects: Increments `currentIndex`.
     - Failure modes: This internal helper assumes a guarded current row.
     - Note: Input order remains unchanged, and no inventory is re-read during advancement.
     */
    private mutating func advance() {
        currentIndex += 1
    }
}

/**
 Presents the startup queue through the same unlock operation and Android dialogs as the picker.

 Inputs:
 - installedModules: Immutable startup snapshot used to initialize the queue
 - initialCipherKey: Manager-owned persisted key reader for Android prompt prefill
 - unlockModule: Manager-owned credential validator/persistence operation
 - onComplete: Reader-owned final refresh and readability reconciliation

 Side effects:
 - submits non-empty credentials through `ModuleUnlockActionCoordinator`
 - displays installed-module About metadata when unlock information is requested
 - invokes `onComplete` exactly once after every initial locked Bible is processed

 Failure modes:
 - rejected and cancelled credentials remain on the same module until the user chooses Retry or No
 - an unexpectedly empty queue reports completion without exposing a reader document
 */
struct StartupLockedBibleUnlockQueueView: View {
    /// State machine owning the immutable Android-order module snapshot.
    @State private var queue: StartupLockedBibleUnlockQueue

    /// Shared one-module credential owner for the queue's current exact row.
    @State private var unlockSession: ModuleUnlockSession?

    /// Prevents repeated completion callbacks if SwiftUI re-runs appearance work.
    @State private var didReportCompletion = false

    /// Manager adapter used by the shared unlock operation.
    let unlockModule: (String, String) -> Bool

    /// Manager adapter used to prefill and select Android's persisted `book.unlockKey` value.
    let initialCipherKey: (String) -> String

    /// Reader callback that owns the single fresh post-queue reconciliation.
    let onComplete: () -> Void

    /**
     Creates a queue presenter from one inclusive installed snapshot.

     - Parameters:
       - installedModules: Installed manager rows in Android registration order.
       - initialCipherKey: Exact persisted manager key used to prefill each module prompt.
       - unlockModule: Credential validator that accepts module initials and a submitted key.
       - onComplete: Called once after the last queued row is accepted or declined.
     - Side effects: None until the rendered controls are used.
     - Failure modes: An empty locked snapshot completes on first appearance.
     */
    init(
        installedModules: [ModuleInfo],
        initialCipherKey: @escaping (String) -> String,
        unlockModule: @escaping (String, String) -> Bool,
        onComplete: @escaping () -> Void
    ) {
        let initialQueue = StartupLockedBibleUnlockQueue(installedModules: installedModules)
        _queue = State(initialValue: initialQueue)
        _unlockSession = State(
            initialValue: initialQueue.currentModule.map { module in
                ModuleUnlockSession(
                    module: module,
                    initialCipherKey: initialCipherKey(module.name)
                )
            }
        )
        self.initialCipherKey = initialCipherKey
        self.unlockModule = unlockModule
        self.onComplete = onComplete
    }

    /**
     Renders the blocking Android dialog required by the current queue phase.

     - Returns: A passphrase, retry-confirmation, About, or empty completed overlay.
     - Side effects: User actions mutate queue/input state and may invoke the supplied unlock or
       completion closure; first appearance reports an unexpectedly empty queue once.
     - Failure modes: Missing current metadata renders no credential dialog and leaves the
       fail-closed queue owner in control.
     */
    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .overlay {
                ModuleUnlockFlowView(
                    session: $unlockSession,
                    unlockModule: unlockModule,
                    onAccepted: acceptCurrentCredential,
                    onDeclined: declineCurrentCredential
                )
            }
            .onAppear(perform: reportCompletionIfNeeded)
            .accessibilityIdentifier("startupLockedBibleUnlockQueue")
    }

    /**
     Advances the immutable queue after the shared session accepts its exact current module.

     - Parameter module: Exact module whose manager validation succeeded.
     - Side effects: Advances once, installs the next one-module session, and may report completion.
     - Failure modes: A stale callback for another exact module is ignored.
     */
    private func acceptCurrentCredential(_ module: ModuleInfo) {
        guard isCurrent(module) else { return }
        queue.acceptCurrentModule()
        installSessionForCurrentModule()
        reportCompletionIfNeeded()
    }

    /**
     Advances after the shared session records Android's explicit negative retry decision.

     - Parameter module: Exact module whose retry decision completed.
     - Side effects: Advances the queue once, installs the next session, and may report completion.
     - Failure modes: A stale callback for another exact module is ignored.
     */
    private func declineCurrentCredential(_ module: ModuleInfo) {
        guard isCurrent(module) else { return }
        queue.declineCurrentModule()
        installSessionForCurrentModule()
        reportCompletionIfNeeded()
    }

    /// Replaces the one-module session only when the immutable queue advances to another row.
    private func installSessionForCurrentModule() {
        unlockSession = queue.currentModule.map { module in
            ModuleUnlockSession(
                module: module,
                initialCipherKey: initialCipherKey(module.name)
            )
        }
    }

    /// Uses Java UTF-16 identity so canonically equivalent module initials cannot cross-authorize.
    private func isCurrent(_ module: ModuleInfo) -> Bool {
        guard let currentModule = queue.currentModule else { return false }
        return SwordJavaExactStringIdentity(currentModule.name)
            == SwordJavaExactStringIdentity(module.name)
    }

    /**
     Invokes the reader's final reconciliation once after the immutable queue is exhausted.

     - Side effects: Sets the one-shot callback guard and invokes `onComplete` synchronously.
     - Failure modes: Incomplete queues and repeated SwiftUI appearances are ignored.
     - Note: The callback runs on the main UI action path used by this SwiftUI view.
     */
    private func reportCompletionIfNeeded() {
        guard queue.isCompleted, !didReportCompletion else { return }
        didReportCompletion = true
        onComplete()
    }
}
