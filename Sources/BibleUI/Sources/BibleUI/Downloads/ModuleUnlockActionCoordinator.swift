// ModuleUnlockActionCoordinator.swift -- Shared encrypted-module unlock behavior

import Foundation
import SwordKit

/**
 Coordinates the synchronous encrypted-module unlock contract shared by Downloads and the reader
 document picker.

 Android startup and Choose Document submit selected module initials and passphrases to the
 installed-book manager. iOS also keeps Downloads' exposed Unlock action functional through this
 same operation. Surface owners refresh or select only after the key is accepted, so no entrypoint
 persists or reports keys through a separate path.

 Side effects:
 - invokes the supplied unlock closure exactly once per non-empty submission
 - invokes the accepted callback exactly once after a successful unlock

 Failure modes:
 - an empty key returns `false` without invoking the manager or accepted callback
 - a manager-rejected key returns `false` without invoking the accepted callback
 - manager-specific validation and persistence failures are represented by the unlock closure's
   `false` result
 */
enum ModuleUnlockActionCoordinator {
    /**
     Submits one passphrase through the manager-backed unlock operation.

     - Parameters:
       - module: Installed encrypted module selected by the user.
       - cipherKey: Passphrase entered in the shared unlock prompt.
       - unlockModule: Manager adapter that validates and persists the passphrase for module initials.
       - onAccepted: Surface-specific success work, such as clearing prompt state, refreshing module
         inventory, and selecting the newly unlocked reader document.
     - Returns: `true` only when the manager accepts the passphrase.
     - Side effects: For a non-empty key, calls `unlockModule` once and calls `onAccepted` once on
       success.
     - Failure modes: An empty key returns `false` before `unlockModule` is called. Manager rejection
       returns `false`; no success work runs and callers retain responsibility for retry feedback.
     */
    @discardableResult
    static func submit(
        module: ModuleInfo,
        cipherKey: String,
        unlockModule: (String, String) -> Bool,
        onAccepted: () -> Void
    ) -> Bool {
        guard !cipherKey.isEmpty else {
            return false
        }
        guard unlockModule(module.name, cipherKey) else {
            return false
        }
        onAccepted()
        return true
    }

    /**
     Builds Android's module-scoped passphrase prompt title.

     - Parameter module: Locked installed module being unlocked.
     - Returns: Localized title containing the module initials.
     - Side effects: Reads localization resources.
     - Failure modes: Missing localization uses the supplied English format string.
     */
    static func promptTitle(for module: ModuleInfo) -> String {
        String(
            format: String(
                localized: "give_passphrase_for_module",
                defaultValue: "Document %@ is encrypted and needs passphrase to be unlocked"
            ),
            module.name
        )
    }

}

/**
 Owns Android's complete one-module credential decision independently from picker navigation,
 Downloads refresh, and startup queue order.

 Android presents the same module passphrase until the manager accepts it or the user declines the
 explicit retry decision. A rejected key and Cancel both lead to that Yes/No decision; neither can
 silently dismiss or advance the owning workflow. Surface owners react only to the terminal outcome.

 Inputs:
 - exact installed module metadata
 - exact passphrase edited through the shared presenter

 Outputs:
 - passphrase, retry-confirmation, or terminal accepted/declined presentation

 Side effects:
 - `submit` invokes the supplied manager adapter at most once for a non-empty passphrase

 Failure modes:
 - empty passphrases do not invoke the manager and still reach Android's explicit retry decision
 - rejected passphrases clear input and retain the same module for an explicit retry decision
 - stale commands outside their owning phase are ignored
 */
struct ModuleUnlockSession {
    /// Stable one-presentation identity used to reject queued actions after owner replacement.
    struct ID: Hashable {
        fileprivate let rawValue: UUID
    }

    /// Terminal choice emitted to the surface that owns post-credential work.
    enum Outcome: Equatable {
        /// The manager accepted and persisted the exact submitted key.
        case accepted

        /// The user declined another attempt after rejection or cancellation.
        case declined
    }

    /// App-owned dialog currently required for this module.
    enum Presentation: Equatable {
        /// The module's passphrase editor is visible.
        case passphrase

        /// Android's explicit Yes/No retry decision is visible.
        case retryConfirmation

        /// Installed-module About temporarily covers the credential editor for the same module.
        case information

        /// The surface owner must consume this outcome exactly once and dismiss this session.
        case completed(Outcome)
    }

    /// Immutable installed module owned for the complete credential session.
    let module: ModuleInfo

    /// Stable identity for this one module presentation lifetime.
    let id: ID

    /// Exact passphrase input. Whitespace and an owner-supplied persisted key are preserved.
    var cipherKey: String

    /// Android `book.unlockKey` value restored whenever this module's prompt is created again.
    private let promptCipherKey: String

    /// Current dialog phase or terminal outcome.
    private(set) var presentation: Presentation = .passphrase

    /** Creates one passphrase session and preselectable Android `unlockKey` value. */
    init(module: ModuleInfo, initialCipherKey: String = "") {
        self.module = module
        id = ID(rawValue: UUID())
        promptCipherKey = initialCipherKey
        cipherKey = initialCipherKey
    }

    /**
     Mutates an optional surface-owned session only when it is still the presented owner.

     - Parameters:
       - owner: Optional session stored by the picker, Downloads, or startup queue.
       - expectedID: Identity captured by the rendered control that issued the command.
       - mutation: Synchronous state transition to apply to that exact session.
     - Returns: `true` only when the expected session was still installed and was updated.
     - Side effects: Replaces `owner` with the mutated value after the closure returns.
     - Failure modes: Nil, replaced, and already-dismissed owners reject stale actions unchanged.
     */
    @discardableResult
    static func mutateOwnedSession(
        _ owner: inout ModuleUnlockSession?,
        expectedID: ID,
        mutation: (inout ModuleUnlockSession) -> Void
    ) -> Bool {
        guard var current = owner, current.id == expectedID else { return false }
        mutation(&current)
        guard owner?.id == expectedID else { return false }
        owner = current
        return true
    }

    /**
     Submits the current passphrase once and advances only from the manager's real result.

     - Parameter unlockModule: Manager adapter that validates and persists the exact module/key pair.
     - Returns: `.accepted` only after manager acceptance; otherwise `nil` while this session remains active.
     - Side effects: Invokes `unlockModule` once for a non-empty passphrase and clears input afterward.
     - Failure modes: Empty submissions skip the manager and present retry confirmation. Stale
       submissions outside the passphrase phase do nothing. Manager rejection presents retry.
     */
    mutating func submit(
        unlockModule: (String, String) -> Bool
    ) -> Outcome? {
        guard presentation == .passphrase else { return nil }
        let submittedKey = cipherKey
        let accepted = ModuleUnlockActionCoordinator.submit(
            module: module,
            cipherKey: submittedKey,
            unlockModule: unlockModule,
            onAccepted: {}
        )
        cipherKey = ""
        guard accepted else {
            presentation = .retryConfirmation
            return nil
        }
        presentation = .completed(.accepted)
        return .accepted
    }

    /** Converts Cancel into Android's explicit retry decision for the same module. */
    mutating func cancelPassphrase() {
        guard presentation == .passphrase else { return }
        cipherKey = ""
        presentation = .retryConfirmation
    }

    /** Returns a rejected/cancelled session to the same module's passphrase editor. */
    mutating func retry() {
        guard presentation == .retryConfirmation else { return }
        cipherKey = promptCipherKey
        presentation = .passphrase
    }

    /** Completes the session only after the user explicitly declines another attempt. */
    mutating func decline() -> Outcome? {
        guard presentation == .retryConfirmation else { return nil }
        cipherKey = ""
        presentation = .completed(.declined)
        return .declined
    }

    /** Clears transient input and lets About cover the passphrase dialog without ending the session. */
    mutating func prepareForInformation() {
        guard presentation == .passphrase else { return }
        cipherKey = ""
        presentation = .information
    }

    /** Returns from About to the same exact module's persisted-key passphrase editor. */
    mutating func resumeAfterInformation() {
        guard presentation == .information else { return }
        cipherKey = promptCipherKey
        presentation = .passphrase
    }
}
