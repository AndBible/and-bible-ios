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
 - the current locked Bible and presentation phase
 - a completed state after every initially locked Bible has been processed

 Side effects: None; owners perform manager unlocks and final inventory reconciliation.

 Failure modes:
 - non-Bible, unencrypted, and already-unlocked rows are excluded from the immutable queue snapshot
 - an empty locked snapshot starts completed so callers can fail closed to setup
 */
struct StartupLockedBibleUnlockQueue {
    /// Dialog state for the current snapshotted module.
    enum Presentation: Equatable {
        /// Request a passphrase for the current module.
        case passphrase

        /// Ask whether a rejected or cancelled passphrase should be retried.
        case retryConfirmation

        /// Every initially locked module has been accepted or declined.
        case completed
    }

    /// Immutable locked-Bible snapshot in the manager's installed registration order.
    let lockedBibleModules: [ModuleInfo]

    /// Index of the module currently being processed.
    private(set) var currentIndex: Int

    /// Dialog state for the current module, or completion after the final row.
    private(set) var presentation: Presentation

    /**
     Creates one immutable Android-order locked-Bible snapshot.

     - Parameter installedModules: Inclusive installed inventory in manager registration order.
     - Side effects: None.
     - Failure modes: If no locked Bible exists, the queue starts in `.completed`.
     */
    init(installedModules: [ModuleInfo]) {
        lockedBibleModules = Self.lockedBibleModules(in: installedModules)
        currentIndex = 0
        presentation = lockedBibleModules.isEmpty ? .completed : .passphrase
    }

    /// Locked Bible currently awaiting acceptance or an explicit decision not to retry.
    var currentModule: ModuleInfo? {
        guard lockedBibleModules.indices.contains(currentIndex) else { return nil }
        return lockedBibleModules[currentIndex]
    }

    /// Whether every module from the immutable startup snapshot has been processed.
    var isCompleted: Bool {
        presentation == .completed
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
     Moves from the passphrase prompt to Android's retry confirmation for the same module.

     - Side effects: Mutates only queue presentation state.
     - Failure modes: Calls after completion or outside the passphrase phase are ignored.
     */
    mutating func requestRetryConfirmation() {
        guard presentation == .passphrase, currentModule != nil else { return }
        presentation = .retryConfirmation
    }

    /**
     Returns from retry confirmation to the same module's passphrase prompt.

     - Side effects: Mutates only queue presentation state; the queue index does not change.
     - Failure modes: Calls outside retry confirmation are ignored.
     */
    mutating func retryCurrentModule() {
        guard presentation == .retryConfirmation, currentModule != nil else { return }
        presentation = .passphrase
    }

    /**
     Records a successful credential and advances to the next initial locked row.

     - Side effects: Advances queue state only; it never selects or activates a reader document.
     - Failure modes: Calls outside the passphrase phase are ignored.
     */
    mutating func acceptCurrentModule() {
        guard presentation == .passphrase, currentModule != nil else { return }
        advance()
    }

    /**
     Records Android's negative retry response and advances to the next initial locked row.

     - Side effects: Advances queue state only.
     - Failure modes: Calls outside retry confirmation are ignored.
     */
    mutating func declineRetryForCurrentModule() {
        guard presentation == .retryConfirmation, currentModule != nil else { return }
        advance()
    }

    /**
     Advances exactly once within the immutable snapshot.

     - Side effects: Increments `currentIndex` and selects either the next passphrase phase or final
       completion.
     - Failure modes: This internal helper assumes a guarded current row; callers enforce the valid
       phase before invoking it.
     - Note: Input order remains unchanged, and no inventory is re-read during advancement.
     */
    private mutating func advance() {
        currentIndex += 1
        presentation = currentIndex < lockedBibleModules.count ? .passphrase : .completed
    }
}

/**
 Presents the startup queue through the same unlock operation and Android dialogs as the picker.

 Inputs:
 - installedModules: Immutable startup snapshot used to initialize the queue
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

    /// Passphrase entered for the current module only.
    @State private var cipherKey = ""

    /// Installed-module About payload temporarily covering the passphrase prompt.
    @State private var selectedModuleDetails: ModuleBrowserModuleDetails?

    /// Prevents repeated completion callbacks if SwiftUI re-runs appearance work.
    @State private var didReportCompletion = false

    /// Manager adapter used by the shared unlock operation.
    let unlockModule: (String, String) -> Bool

    /// Reader callback that owns the single fresh post-queue reconciliation.
    let onComplete: () -> Void

    /**
     Creates a queue presenter from one inclusive installed snapshot.

     - Parameters:
       - installedModules: Installed manager rows in Android registration order.
       - unlockModule: Credential validator that accepts module initials and a submitted key.
       - onComplete: Called once after the last queued row is accepted or declined.
     - Side effects: None until the rendered controls are used.
     - Failure modes: An empty locked snapshot completes on first appearance.
     */
    init(
        installedModules: [ModuleInfo],
        unlockModule: @escaping (String, String) -> Bool,
        onComplete: @escaping () -> Void
    ) {
        _queue = State(
            initialValue: StartupLockedBibleUnlockQueue(
                installedModules: installedModules
            )
        )
        self.unlockModule = unlockModule
        self.onComplete = onComplete
    }

    /**
     Renders the blocking Android dialog required by the current queue phase.

     - Returns: A passphrase, retry-confirmation, About, or empty completed overlay.
     - Side effects: User actions mutate queue/input state and may invoke the supplied unlock or
       completion closure; first appearance reports an unexpectedly empty queue once.
     - Failure modes: Missing current metadata in the passphrase phase renders no credential dialog
       and leaves the fail-closed queue owner in control.
     */
    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .overlay {
                switch queue.presentation {
                case .passphrase:
                    if let module = queue.currentModule {
                        ModulePickerUnlockDialog(
                            title: ModuleUnlockActionCoordinator.promptTitle(for: module),
                            message: String(
                                localized: "enter_module_passphrase",
                                defaultValue: "Enter the module passphrase."
                            ),
                            cipherKey: $cipherKey,
                            showUnlockInfo: !module.aboutMetadata.unlockInfo.isEmpty,
                            onUnlock: { attemptUnlock(module) },
                            onShowUnlockInfo: { showUnlockInformation(for: module) },
                            onCancel: cancelCurrentCredential
                        )
                    }
                case .retryConfirmation:
                    retryConfirmationDialog
                case .completed:
                    EmptyView()
                }
            }
            .moduleBrowserModuleDetailsDialog(details: selectedModuleDetails) {
                selectedModuleDetails = nil
            }
            .onAppear(perform: reportCompletionIfNeeded)
            .accessibilityIdentifier("startupLockedBibleUnlockQueue")
    }

    /**
     Builds Android's Yes/No decision after either cancellation or a rejected key.

     - Returns: The shared app-owned decision dialog with Android action ordering.
     - Side effects: Yes returns to the same row; No advances to the next snapshotted row.
     - Failure modes: The state machine ignores actions delivered after the phase changes.
     */
    private var retryConfirmationDialog: some View {
        ModulePickerDecisionDialog(
            title: String(
                localized: "try_again_passphrase",
                defaultValue: "Passphrase did not work, try again?"
            ),
            message: "",
            actions: [
                .init(
                    id: "yes",
                    title: String(localized: "yes", defaultValue: "Yes"),
                    role: nil,
                    perform: retryCurrentCredential
                ),
                .init(
                    id: "no",
                    title: String(localized: "no", defaultValue: "No"),
                    role: nil,
                    perform: declineRetryForCurrentCredential
                ),
            ]
        )
    }

    /**
     Submits one credential without selecting or activating the accepted module.

     - Parameter module: Current immutable queue row.
     - Side effects: Validates/persists the key once, then advances only on acceptance; rejection
       opens retry confirmation for the same row.
     - Failure modes: Empty and rejected keys follow the same Android retry-confirmation path.
     */
    private func attemptUnlock(_ module: ModuleInfo) {
        let submittedKey = cipherKey
        let accepted = ModuleUnlockActionCoordinator.submit(
            module: module,
            cipherKey: submittedKey,
            unlockModule: unlockModule,
            onAccepted: {
                cipherKey = ""
                queue.acceptCurrentModule()
                reportCompletionIfNeeded()
            }
        )
        guard !accepted else { return }

        cipherKey = ""
        queue.requestRetryConfirmation()
    }

    /**
     Converts passphrase cancellation into Android's explicit retry decision.

     - Side effects: Clears transient input and changes the current phase to retry confirmation.
     - Failure modes: A stale cancellation after the phase changes is ignored by the state machine.
     */
    private func cancelCurrentCredential() {
        cipherKey = ""
        queue.requestRetryConfirmation()
    }

    /**
     Returns to the same snapshotted module after Android's positive retry decision.

     - Side effects: Clears transient input and restores the passphrase phase without advancing.
     - Failure modes: A stale action outside retry confirmation is ignored.
     */
    private func retryCurrentCredential() {
        cipherKey = ""
        queue.retryCurrentModule()
    }

    /**
     Advances after Android's negative retry decision and reports final completion when due.

     - Side effects: Clears input, advances exactly one row, and may invoke `onComplete` once.
     - Failure modes: A stale action outside retry confirmation cannot advance the queue.
     */
    private func declineRetryForCurrentCredential() {
        cipherKey = ""
        queue.declineRetryForCurrentModule()
        reportCompletionIfNeeded()
    }

    /**
     Displays the shared installed-module About dialog, then returns to the same queue row.

     - Parameter module: Current locked Bible whose provider metadata should be shown.
     - Side effects: Clears transient input and presents app-owned About metadata.
     - Failure modes: The unlock dialog only exposes this path when unlock information is non-empty.
     */
    private func showUnlockInformation(for module: ModuleInfo) {
        cipherKey = ""
        selectedModuleDetails = ModuleBrowserModuleDetails(installedModule: module)
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
