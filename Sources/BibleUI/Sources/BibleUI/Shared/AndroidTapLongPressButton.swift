// AndroidTapLongPressButton.swift -- Mutually exclusive Android click and long-click owner

import SwiftUI

/**
 Renders app-owned content with Android's mutually exclusive click and long-click behavior.

 A real SwiftUI `Button` retains pointer, keyboard, and accessibility semantics. Its primitive style
 owns one press sequence and resolves that sequence once: a completed hold invokes the long-click,
 a completed short tap triggers the Button, and a dragged-away or cancelled sequence does nothing.
 The decision carries no state into the next press or across view reconciliation.

 Inputs: minimum long-press duration, click and long-click commands, and caller-owned label content

 Output: one plain app-owned button with mutually exclusive Android interaction semantics

 Side effects: invokes exactly one supplied command for each completed interaction

 Failure modes: cancelled or dragged-away interactions invoke neither command
 */
struct AndroidTapLongPressButton<Label: View>: View {
    /// Hold duration matching the app's Android contextual-row convention.
    let minimumDuration: Double

    /// Ordinary Android click command.
    let onTap: () -> Void

    /// Android long-click command.
    let onLongPress: () -> Void

    /// Caller-owned visual content.
    let label: Label

    /**
     Creates one mutually exclusive Android click/long-click control.

     - Parameters:
       - minimumDuration: Hold duration required before dispatching `onLongPress`.
       - onTap: Command dispatched for an ordinary button activation.
       - onLongPress: Command dispatched once when the hold threshold is reached.
       - label: Visual button content.
     - Side effects: none until the user interacts with the returned control.
     - Failure modes: none.
     */
    init(
        minimumDuration: Double = 0.45,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.minimumDuration = minimumDuration
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.label = label()
    }

    /** Builds the real button with one stateless primitive interaction owner. */
    var body: some View {
        Button(action: onTap) {
            label
        }
        .buttonStyle(
            AndroidTapLongPressPrimitiveButtonStyle(
                minimumDuration: minimumDuration,
                onLongPress: onLongPress
            )
        )
    }
}

/** Primitive Button style that resolves each tap/hold sequence without sticky suppression state. */
private struct AndroidTapLongPressPrimitiveButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    /// Hold duration matching the owning Android surface.
    let minimumDuration: Double

    /// Contextual action for a completed hold.
    let onLongPress: () -> Void

    /** Supplies the Button's one concrete touch/pointer gesture while preserving semantic trigger. */
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(
                    minimumDuration: minimumDuration,
                    maximumDistance: 10
                )
                .simultaneously(with: TapGesture())
                .onEnded { value in
                    guard isEnabled else { return }
                    if value.first == true {
                        onLongPress()
                    } else if value.second != nil {
                        configuration.trigger()
                    }
                }
            )
    }
}

/**
 Owns mutually exclusive tap and completed-hold dispatch for a container with nested controls.

 Document-selection rows contain independent About and transfer controls, so wrapping the whole row
 in a `Button` would create nested buttons. One simultaneous gesture value instead resolves the row
 background interaction at release: a completed hold wins, a short tap invokes the primary row
 action, and a drag that cancels both gestures invokes neither. Descendant Buttons retain their
 normal gesture priority.
 */
private struct AndroidTapLongPressContainerModifier: ViewModifier {
    /// Hold duration matching the owning Android surface.
    let minimumDuration: Double

    /// Primary row action for a completed short tap.
    let onTap: () -> Void

    /// Contextual action for a completed hold.
    let onLongPress: (() -> Void)?

    /** Installs the one row-background gesture owner. */
    @ViewBuilder
    func body(content: Content) -> some View {
        if let onLongPress {
            content.gesture(
                LongPressGesture(
                    minimumDuration: minimumDuration,
                    maximumDistance: 10
                )
                .simultaneously(with: TapGesture())
                .onEnded { value in
                    if value.first == true {
                        onLongPress()
                    } else if value.second != nil {
                        onTap()
                    }
                }
            )
        } else {
            content.onTapGesture(perform: onTap)
        }
    }
}

extension View {
    /** Adds one mutually exclusive tap/hold owner without wrapping nested controls in a Button. */
    func androidTapLongPressContainer(
        minimumDuration: Double = 0.45,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)?
    ) -> some View {
        modifier(
            AndroidTapLongPressContainerModifier(
                minimumDuration: minimumDuration,
                onTap: onTap,
                onLongPress: onLongPress
            )
        )
    }
}
