// AndroidTapLongPressButton.swift -- Mutually exclusive Android click and long-click owner

import SwiftUI

/**
 Renders app-owned content with Android's mutually exclusive click and long-click behavior.

 A real SwiftUI `Button` owns ordinary touch, pointer, keyboard, and accessibility activation. A
 simultaneous long press marks a completed long-click so the button can consume its release, while
 activity lifecycle resets prevent that transient state from surviving child navigation. This
 avoids the duplicate click produced by an uncoordinated simultaneous long press and the lost click
 produced by a high-priority long press.

 Inputs: minimum long-press duration, contextual-active state, click and long-click commands, and
 caller-owned label content

 Output: one plain app-owned button with mutually exclusive Android interaction semantics

 Side effects: invokes exactly one supplied command for each completed interaction

 Failure modes: cancelled or dragged-away interactions invoke neither command
 */
struct AndroidTapLongPressButton<Label: View>: View {
    /// Hold duration matching the app's Android contextual-row convention.
    let minimumDuration: Double

    /// Whether the long-click result currently remains active in Android contextual mode.
    let isLongPressActionActive: Bool

    /// Ordinary Android click command.
    let onTap: () -> Void

    /// Android long-click command.
    let onLongPress: () -> Void

    /// Caller-owned visual content.
    let label: Label

    /// Whether the current press already dispatched its long-click command.
    @State private var didRecognizeLongPress = false

    /**
     Creates one mutually exclusive Android click/long-click control.

     - Parameters:
       - minimumDuration: Hold duration required before dispatching `onLongPress`.
       - isLongPressActionActive: Whether this row currently participates in contextual mode.
       - onTap: Command dispatched for an ordinary button activation.
       - onLongPress: Command dispatched once when the hold threshold is reached.
       - label: Visual button content.
     - Side effects: none until the user interacts with the returned control.
     - Failure modes: none.
     */
    init(
        minimumDuration: Double = 0.45,
        isLongPressActionActive: Bool,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.minimumDuration = minimumDuration
        self.isLongPressActionActive = isLongPressActionActive
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.label = label()
    }

    /** Builds the real button and its release-aware long-click recognizer. */
    var body: some View {
        Button(action: activateTap) {
            label
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(
                minimumDuration: minimumDuration,
                maximumDistance: 10
            )
            .onEnded { _ in recognizeLongPress() }
        )
        .onAppear(perform: resetRecognition)
        .onDisappear(perform: resetRecognition)
        .onChange(of: isLongPressActionActive) { wasActive, isActive in
            if wasActive, !isActive {
                resetRecognition()
            }
        }
    }

    /** Dispatches a click unless the current release belongs to a completed long-click. */
    private func activateTap() {
        guard !didRecognizeLongPress else {
            didRecognizeLongPress = false
            return
        }
        onTap()
    }

    /** Dispatches the long-click once and marks its possible Button release for consumption. */
    private func recognizeLongPress() {
        didRecognizeLongPress = true
        onLongPress()
    }

    /** Clears press-local recognition whenever navigation removes or restores this control. */
    private func resetRecognition() {
        didRecognizeLongPress = false
    }
}
