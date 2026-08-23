#if os(iOS)
import SwiftUI
import UIKit

/**
 Bridges the reader's owning `UIWindow` bounds into SwiftUI without observing keyboard-safe-area
 changes as orientation changes.

 The transparent probe is embedded in the split surface, so it resolves the exact scene/window that
 owns that reader instead of consulting a process-global key window. Its binding changes only when
 the native window bounds change, including rotation, Split View, or Stage Manager resizing.

 Data dependencies:
 - `windowSize` receives the last non-empty bounds published by the probe's actual `UIWindow`

 Side effects:
 - schedules a main-queue binding update when the native window bounds change

 Failure modes:
 - before attachment to a window, the binding retains its previous value
 */
struct BibleReaderWindowBoundsReader: UIViewRepresentable {
    /// Stable native window size consumed by the split-axis resolver.
    @Binding var windowSize: CGSize

    /**
     Creates the transparent UIKit observation surface.

     - Parameter context: SwiftUI representable context; no coordinator state is required.
     - Returns: A non-interactive view that reports its owning window bounds.
     - Side Effects: Installs a callback that may asynchronously update `windowSize` on the main queue.
     - Failure Modes: No value is emitted until UIKit attaches the view to a window.
     */
    func makeUIView(context: Context) -> BibleReaderWindowBoundsObservationView {
        BibleReaderWindowBoundsObservationView(onWindowSizeChange: publish)
    }

    /**
     Refreshes the binding callback after SwiftUI updates the representable.

     - Parameters:
       - uiView: Existing observation view owned by SwiftUI.
       - context: Current representable context; no coordinator state is consumed.
     - Side Effects: Replaces the callback and asks the view to publish newly available bounds.
     - Failure Modes: A detached view leaves `windowSize` unchanged.
     */
    func updateUIView(_ uiView: BibleReaderWindowBoundsObservationView, context: Context) {
        uiView.onWindowSizeChange = publish
        uiView.publishWindowSizeIfNeeded()
    }

    /**
     Delivers one changed native window size to SwiftUI outside UIKit's active layout pass.

     - Parameter size: Non-empty `UIWindow.bounds.size` reported by the observation view.
     - Side Effects: Schedules a main-queue write to `windowSize` when its value differs.
     - Failure Modes: Duplicate or empty values are ignored; a superseded asynchronous update checks
       the binding again before writing.
     - Important: UIKit invokes this callback on the main thread; asynchronous delivery avoids
       mutating SwiftUI state synchronously from `layoutSubviews`.
     */
    private func publish(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != windowSize else {
            return
        }
        DispatchQueue.main.async {
            guard size != windowSize else { return }
            windowSize = size
        }
    }
}

/**
 Observes the bounds of the exact `UIWindow` containing the reader split surface.

 Keyboard presentation changes the child safe area and keyboard layout guide but not `UIWindow`
 bounds. Publishing from `didMoveToWindow` and `layoutSubviews` therefore follows real window
 rotation/resizing without misclassifying an IME transition as an orientation change.

 Side effects:
 - calls `onWindowSizeChange` once for each distinct non-empty owning-window size

 Failure modes:
 - detached views and zero-sized windows produce no callback
 */
final class BibleReaderWindowBoundsObservationView: UIView {
    /// Callback receiving each distinct non-empty owning-window size.
    var onWindowSizeChange: (CGSize) -> Void

    /// Last size emitted, used to keep repeated UIKit layout passes idempotent.
    private var lastPublishedWindowSize: CGSize = .zero

    /**
     Creates a transparent, non-interactive window-bounds observer.

     - Parameter onWindowSizeChange: Callback invoked on the main thread for changed window bounds.
     - Side Effects: Disables user interaction so the background probe cannot intercept reader input.
     - Failure Modes: None; observation begins when UIKit attaches the view to a window.
     */
    init(onWindowSizeChange: @escaping (CGSize) -> Void) {
        self.onWindowSizeChange = onWindowSizeChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    /// Storyboard construction is unsupported because SwiftUI creates the observer programmatically.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /**
     Publishes the first usable bounds whenever UIKit moves the probe into a window.

     - Side Effects: May invoke `onWindowSizeChange` through `publishWindowSizeIfNeeded()`.
     - Failure Modes: Detachment produces no value and retains the last published size.
     */
    override func didMoveToWindow() {
        super.didMoveToWindow()
        publishWindowSizeIfNeeded()
    }

    /**
     Detects native window rotation and resizable-scene bounds changes during UIKit layout.

     - Side Effects: May invoke `onWindowSizeChange` once for a newly observed window size.
     - Failure Modes: Keyboard-only layout passes are ignored because `UIWindow.bounds` is unchanged.
     */
    override func layoutSubviews() {
        super.layoutSubviews()
        publishWindowSizeIfNeeded()
    }

    /**
     Emits the owning window's bounds exactly once per distinct non-empty size.

     - Side Effects: Updates `lastPublishedWindowSize` and synchronously invokes the callback on the
       UIKit main thread.
     - Failure Modes: Missing windows, zero dimensions, and duplicate values are ignored.
     */
    func publishWindowSizeIfNeeded() {
        guard let size = window?.bounds.size,
              size.width > 0,
              size.height > 0,
              size != lastPublishedWindowSize else {
            return
        }
        lastPublishedWindowSize = size
        onWindowSizeChange(size)
    }
}
#endif
