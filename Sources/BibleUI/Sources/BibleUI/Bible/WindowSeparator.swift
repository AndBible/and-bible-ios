// WindowSeparator.swift -- Draggable separator between Bible windows

import SwiftUI
import BibleCore

/**
 Renders the draggable divider between two visible Bible panes.

 The separator routes effective-weight changes through `WindowManager` using the same proportional
 drag logic as Android's `Separator.kt`: the drag distance is normalized by the average pane size,
 applied as a clamped weight delta, and persisted when the gesture ends.
 */
struct WindowSeparator: View {
    @Environment(WindowManager.self) private var windowManager

    /// Leading or upper window whose layout weight grows when dragged toward it.
    let window1: BibleCore.Window

    /// Trailing or lower window whose layout weight shrinks when dragged toward `window1`.
    let window2: BibleCore.Window

    /// `true` for a horizontal separator between vertically stacked panes.
    let isVertical: Bool

    /// Number of currently visible panes used to compute the average pane size.
    let totalPaneCount: Int

    /// Total available width or height of the parent container, depending on orientation.
    let parentSize: CGFloat

    /// Stateful production resize seam shared by gesture updates and completion.
    @State private var dragSession = WindowSeparatorDragSession()

    /// Visual thickness of the separator bar itself.
    private let separatorThickness = BibleReaderSplitLayout.separatorThickness

    /**
     Renders the draggable separator and persists the final adjacent-pane weights.

     - Returns: Separator rectangle with an expanded drag target.
     - Side Effects: Updates effective pane weights during dragging and saves them on gesture end.
     - Failure Modes: Zero-sized parent geometry suppresses weight updates; invalid weights are
       clamped by `WindowManager`.
     */
    var body: some View {
        Rectangle()
            .fill(dragSession.isDragging ? Color.accentColor : Color.gray.opacity(0.5))
            .frame(
                width: isVertical ? nil : separatorThickness,
                height: isVertical ? separatorThickness : nil
            )
            .contentShape(Rectangle().inset(by: -20)) // expanded touch target
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let translation = isVertical ? value.translation.height : value.translation.width
                        dragSession.update(
                            translation: translation,
                            parentSize: parentSize,
                            totalPaneCount: totalPaneCount,
                            firstWindow: window1,
                            secondWindow: window2,
                            target: windowManager
                        )
                    }
                    .onEnded { _ in
                        dragSession.finish(
                            firstWindow: window1,
                            secondWindow: window2,
                            target: windowManager
                        )
                    }
            )
            .onHover { hovering in
                #if os(macOS)
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
                #endif
            }
    }
}
