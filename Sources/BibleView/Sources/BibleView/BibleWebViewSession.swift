// BibleWebViewSession.swift — Per-window native WebView lifetime owner

import WebKit

/**
 Retains one bridge-backed WebView host for the lifetime of a reader window.

 Android's `BibleViewFactory.windowBibleViewMap` keeps the actual `BibleView` alive while its
 `BibleFrame` is detached for minimization. This session provides the same ownership boundary for
 iOS and macOS: SwiftUI may remove and later recreate a representable, but the pane controller keeps
 this session alive and the representable reattaches the already-bootstrapped `WKWebView`.

 The session owns the original `WebViewCoordinator` because WebKit delegate properties are weak.
 Keeping the coordinator beside the cached host preserves navigation, native interaction, and
 scroll callbacks across detach/reattach cycles.

 Side effects:
 - lazily retains the first `WKWebView` returned by a resolver factory
 - retains one coordinator bound to `bridge`
 - on iOS, serializes attachment of the cached WebView across transient SwiftUI controller hosts

 Failure modes:
 - callers must use the session only with the bridge supplied at initialization
 - WebView creation still propagates any failure behavior of the supplied factory
 - an iOS host that does not belong to this session triggers a programmer-error precondition

 Concurrency:
 - WebKit and representable lifecycle access must remain on the main thread
 - the iOS attachment lease permits exactly one current host and weakly registers every
   appearance-committed replacement; stale releases cannot detach a newer current host
 */
public final class BibleWebViewSession {
    /// Bridge shared by the cached WebView host and its owning reader controller.
    public let bridge: BibleBridge

    /**
     Coordinator retained independently of transient SwiftUI representable instances.

     WebKit stores navigation and scroll delegates weakly, so retaining this coordinator is required
     for a cached WebView to keep routing callbacks after the original representable is dismantled.
     */
    let coordinator: WebViewCoordinator

    /// Rendered Vue surface retained while its reader window is minimized or hidden by layout.
    private var cachedWebView: WKWebView?

    #if os(iOS)
    /**
     Current transient UIKit controller allowed to own the cached WebView hierarchy.

     The reference is weak because SwiftUI owns controller lifetime. Attachment and release access is
     main-thread-only through the lease methods below.
     */
    private weak var attachmentOwner: BibleWebViewController?

    /**
     Weak appearance-committed hosts eligible for deterministic ownership transfer.

     SwiftUI can overlap more than one replacement while changing layout. Keeping all visible
     candidates prevents a later speculative host from overwriting an earlier viable replacement.
     */
    private var attachmentRegistrations: [AttachmentRegistration] = []

    /// Monotonic ordering token used to choose the newest still-visible replacement host.
    private var attachmentGeneration: UInt64 = 0

    /**
     Weak registration for one controller whose UIKit appearance has committed.

     The session owns registration records but never controller lifetime. `generation` changes on
     every appearance so deterministic transfer prefers the most recently committed visible host.
     */
    private final class AttachmentRegistration {
        /// Appearance-committed controller retained weakly across SwiftUI overlap.
        weak var controller: BibleWebViewController?

        /// Monotonic appearance order used for newest-visible selection.
        var generation: UInt64

        /**
         Records one visible controller without extending its lifetime.

         - Parameters:
           - controller: Appearance-committed controller eligible for attachment.
           - generation: Session-local ordering token for this appearance.
         - Side Effects: Retains only the numeric generation; controller ownership remains with UIKit.
         - Failure Modes: The weak controller may become `nil` before the next lease operation.
         */
        init(controller: BibleWebViewController, generation: UInt64) {
            self.controller = controller
            self.generation = generation
        }
    }
    #endif

    /**
     Creates an empty per-window render session.

     - Parameter bridge: Window-scoped native/Vue bridge that must remain paired with the cached
       host for the session's complete lifetime.
     - Side Effects: Creates and retains a coordinator; no `WKWebView` or bundle navigation starts
       until the platform representable first requests a WebView.
     - Failure Modes: None.
     */
    public init(bridge: BibleBridge) {
        self.bridge = bridge
        self.coordinator = WebViewCoordinator(bridge: bridge)
    }

    /**
     Returns the existing rendered WebView or creates it exactly once.

     - Parameter create: Main-thread factory that builds the bridge-backed WebView on first use.
     - Returns: The identical `WKWebView` instance for every call during this session's lifetime.
     - Side Effects: Retains the first WebView produced by `create`.
     - Failure Modes: The factory is not called after a WebView has been cached.
     */
    func webView(create: () -> WKWebView) -> WKWebView {
        if let cachedWebView {
            return cachedWebView
        }
        let webView = create()
        cachedWebView = webView
        return webView
    }

    #if os(iOS)
    /**
     Registers an appearance-committed UIKit host and requests the exclusive WebView lease.

     `viewDidLoad` is intentionally insufficient: SwiftUI can load speculative replacement hosts that
     never enter the visible hierarchy. `viewWillAppear` commits the candidate early enough that an
     outgoing owner's later `viewDidDisappear` can transfer directly. The first appearing host
     attaches immediately; later appearing hosts remain weak candidates while the current owner is
     visible. This protects focused Vue editors without losing an earlier viable candidate when
     several replacements overlap.

     - Parameter controller: Controller created by a `BibleWebView` using this exact session.
     - Side Effects: Adds or refreshes a weak, ordered registration and attaches the cached WebView
       only when no current owner exists.
     - Failure Modes: Traps when the controller/session/WebView identities do not match; valid waiting
       hosts remain unattached until the current owner disappears.
     - Important: Must execute on the main actor because it mutates UIKit hierarchy and lease state.
     - Note: Repeating an appearance from the current owner is idempotent and repairs a missing
       attachment while refreshing that owner's ordering token.
     */
    @MainActor
    func attachmentHostWillAppear(_ controller: BibleWebViewController) {
        precondition(
            controller.session === self && controller.webView === cachedWebView,
            "BibleWebViewController must request attachment from its creating session"
        )

        pruneAttachmentRegistrations()
        attachmentGeneration &+= 1
        if let registration = attachmentRegistrations.first(where: { $0.controller === controller }) {
            registration.generation = attachmentGeneration
        } else {
            attachmentRegistrations.append(
                AttachmentRegistration(controller: controller, generation: attachmentGeneration)
            )
        }

        if attachmentOwner === controller {
            controller.attachSessionWebViewIfNeeded()
            return
        }

        guard attachmentOwner == nil else { return }
        _ = transferToNewestRegisteredHost()
    }

    /**
     Removes a disappearing host and transfers ownership to the newest still-visible replacement.

     Waiting hosts can disappear before becoming current; removing only their registration leaves the
     visible owner untouched and preserves every other candidate. A release from an older controller
     after ownership has already moved is stale and cannot remove the WebView or constraints from the
     newer owner.

     - Parameter controller: Current or pending controller being dismantled by SwiftUI.
     - Side Effects: Removes matching/deallocated registrations, detaches a matching current host,
       and may synchronously attach the cached WebView to the newest remaining visible replacement.
     - Failure Modes: Unknown and stale controllers are ignored without mutating the current host.
     - Important: Must execute on the main actor; transfer ordering is synchronous and deterministic.
     - Postcondition: The cached WebView is attached to at most one current controller.
    */
    @MainActor
    func attachmentHostDidDisappear(_ controller: BibleWebViewController) {
        attachmentRegistrations.removeAll {
            $0.controller == nil || $0.controller === controller
        }

        guard attachmentOwner === controller else {
            return
        }

        attachmentOwner = nil
        if transferToNewestRegisteredHost(from: controller) {
            return
        }
        controller.detachSessionWebViewIfOwned()
    }

    /**
     Removes weak registration records whose UIKit controllers have been released.

     - Side Effects: Mutates `attachmentRegistrations` in place while preserving visible ordering.
     - Failure Modes: None; live weak references and their generations remain unchanged.
     - Important: Called only on the main actor as part of a serialized lease operation.
     */
    @MainActor
    private func pruneAttachmentRegistrations() {
        attachmentRegistrations.removeAll { $0.controller == nil }
    }

    /**
     Grants a vacant lease to the most recently appeared controller that remains visible.

     When replacing a current owner, its constraints are deactivated but the WebView remains attached
     until `addSubview` moves it directly into the successor. This avoids an intermediate windowless
     state that could resign WebKit's focused editor.

     - Parameter previousOwner: Optional just-released owner whose hierarchy should remain intact until
       UIKit reparents the WebView directly into the selected successor.
     - Returns: `true` when a live host received the lease, otherwise `false`.
     - Side Effects: Prunes dead registrations, prepares an old owner when supplied, records
       `attachmentOwner`, and installs the cached WebView plus keyboard constraints in the selected host.
     - Failure Modes: With no live registered host, leaves the lease vacant and the WebView in its
       previous owner until the caller explicitly detaches it for session-only retention.
     - Important: Called only on the main actor after the prior owner's lease has been cleared.
     */
    @MainActor
    @discardableResult
    private func transferToNewestRegisteredHost(
        from previousOwner: BibleWebViewController? = nil
    ) -> Bool {
        pruneAttachmentRegistrations()
        guard attachmentOwner == nil,
              let registration = attachmentRegistrations.max(by: { $0.generation < $1.generation }),
              let controller = registration.controller else {
            return false
        }
        previousOwner?.prepareSessionWebViewForTransfer()
        attachmentOwner = controller
        controller.attachSessionWebViewIfNeeded()
        return true
    }
    #endif
}
