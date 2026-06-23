// BibleReaderBridgeEventRouter.swift -- Host-side bridge event routing for reader panes

import Foundation

/**
 Routes bridge events that only coordinate host callbacks or pane-local modal state.

 `BibleReaderController` remains the orchestration boundary for document payloads, SWORD state,
 and reader persistence. This collaborator owns the existing routing rules for simple
 bridge events whose effects are limited to keyboard/modal handling or host UI callbacks. Keeping
 those rules here avoids hiding controller complexity in extensions while preserving existing
 bridge method names and payload semantics.

 Side effects are injected through closures so tests can validate routing deterministically and the
 controller can keep platform-specific UI presentation, preference lookup, and bridge emission at
 the pane boundary.
 */
final class BibleReaderBridgeEventRouter {
    private let emitBridgeEvent: (String) -> Bool
    private let navigatePrevious: () -> Void
    private let navigateNext: () -> Void
    private let showToastHandler: (String) -> Void
    private let shareHtmlHandler: (String) -> Void
    private let openDownloadsHandler: (String?) -> Void
    private let shouldToggleFullScreen: () -> Bool
    private let toggleFullScreenHandler: () -> Void

    /// Whether the Vue reader client currently reports an open modal for this pane.
    private(set) var webModalIsOpen = false

    /**
     Creates a router with explicit host-side effects.

     - Parameters:
       - emitBridgeEvent: Emits a Vue event name into the pane bridge. Return value is ignored for
         compatibility with the previous fire-and-forget close-modal behavior.
       - navigatePrevious: Moves the pane to the previous chapter for ArrowLeft events.
       - navigateNext: Moves the pane to the next chapter for ArrowRight events.
       - showToast: Presents a toast/banner message through the owning SwiftUI surface.
       - shareHtml: Presents HTML sharing through the owning SwiftUI surface.
       - openDownloads: Presents Downloads with optional search seed semantics.
       - shouldToggleFullScreen: Reads the current preference gate for double-tap fullscreen.
       - toggleFullScreen: Requests the owning surface to toggle fullscreen.

     Side effects:
     - stores closures for later bridge-event handling

     Failure modes:
     - none; invalid bridge payloads are rejected by `BibleBridge` before these methods are called.
     */
    init(
        emitBridgeEvent: @escaping (String) -> Bool,
        navigatePrevious: @escaping () -> Void,
        navigateNext: @escaping () -> Void,
        showToast: @escaping (String) -> Void,
        shareHtml: @escaping (String) -> Void,
        openDownloads: @escaping (String?) -> Void,
        shouldToggleFullScreen: @escaping () -> Bool,
        toggleFullScreen: @escaping () -> Void
    ) {
        self.emitBridgeEvent = emitBridgeEvent
        self.navigatePrevious = navigatePrevious
        self.navigateNext = navigateNext
        self.showToastHandler = showToast
        self.shareHtmlHandler = shareHtml
        self.openDownloadsHandler = openDownloads
        self.shouldToggleFullScreen = shouldToggleFullScreen
        self.toggleFullScreenHandler = toggleFullScreen
    }

    /**
     Records modal visibility reported by the Vue reader.

     - Parameter isOpen: Whether the web client currently reports a modal in this pane.
     - Side effects: Updates pane-local modal state used by keyboard routing.
     - Failure modes: Duplicate reports are accepted idempotently.
     */
    func reportModalState(_ isOpen: Bool) {
        webModalIsOpen = isOpen
    }

    /**
     Receives web-client input focus changes.

     iOS currently has no host-side behavior for this signal, but keeping it on the router preserves
     a named ownership point for future parity work without leaving a no-op delegate method in the
     controller.

     - Parameter focused: Whether a text input inside the web client is focused.
     - Side effects: None.
     - Failure modes: None.
     */
    func reportInputFocus(_ focused: Bool) {}

    /**
     Handles keyboard events forwarded by the web client.

     - Parameter key: Logical key name from the shared Vue reader.
     - Side effects: Navigates chapters for left/right arrows when no modal is open, or emits
       `close_modals` for Escape while a modal is open.
     - Failure modes: Unsupported keys are ignored; modal-open non-Escape keys intentionally do not
       navigate so native host navigation does not steal web modal focus.
     */
    func handleKeyDown(_ key: String) {
        guard !webModalIsOpen else {
            if key == "Escape" || key == "Esc" {
                _ = closeWebModalIfNeeded()
            }
            return
        }

        switch key {
        case "ArrowLeft":
            navigatePrevious()
        case "ArrowRight":
            navigateNext()
        default:
            break
        }
    }

    /**
     Requests that the Vue reader close pane-local modals.

     - Returns: `true` when a close request was emitted because the last reported modal state was
       open; otherwise `false`.
     - Side effects: Emits `close_modals` through `emitBridgeEvent`. The reported modal state is not
       mutated here; the next Vue `reportModalState` callback remains authoritative.
     - Failure modes: Returns `false` and emits nothing when no modal is reported open.
     */
    @discardableResult
    func closeWebModalIfNeeded() -> Bool {
        guard webModalIsOpen else { return false }
        _ = emitBridgeEvent("close_modals")
        return true
    }

    /**
     Forwards a toast/banner request to the host UI.

     - Parameter text: Localized or web-provided message text.
     - Side effects: Invokes the injected toast handler.
     - Failure modes: None; absent host presentation is represented by a no-op handler.
     */
    func showToast(_ text: String) {
        showToastHandler(text)
    }

    /**
     Forwards HTML sharing content to the host UI.

     - Parameter html: HTML fragment supplied by the shared reader.
     - Side effects: Invokes the injected share handler.
     - Failure modes: None; absent host presentation is represented by a no-op handler.
     */
    func shareHtml(_ html: String) {
        shareHtmlHandler(html)
    }

    /**
     Requests the native Downloads surface.

     - Parameter searchText: Optional search seed, usually module initials from a `download://`
       pseudo-link.
     - Side effects: Invokes the injected downloads handler.
     - Failure modes: None; absent host presentation is represented by a no-op handler.
     */
    func requestOpenDownloads(searchText: String? = nil) {
        openDownloadsHandler(searchText)
    }

    /**
     Requests fullscreen only when the injected preference gate allows it.

     - Side effects: Invokes the injected fullscreen handler when allowed.
     - Failure modes: Returns without side effects when the preference gate is disabled.
     */
    func requestToggleFullScreen() {
        guard shouldToggleFullScreen() else { return }
        toggleFullScreenHandler()
    }

    /**
     Extracts the module-initials search seed from a Downloads pseudo-link.

     - Parameter link: A `download://` link emitted by rendered document content, optionally with
       an `initials` query item such as `download://?initials=KJV`.
     - Returns: The decoded, trimmed `initials` value when present and non-empty; otherwise `nil`.
     - Side effects: None.
     - Failure modes: Malformed or non-download links return `nil`, preserving the standard
       unfiltered Downloads presentation path.
     */
    static func downloadSearchText(from link: String) -> String? {
        guard link.hasPrefix("download://"),
              let components = URLComponents(string: link),
              let value = components.queryItems?.first(where: { $0.name == "initials" })?.value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
