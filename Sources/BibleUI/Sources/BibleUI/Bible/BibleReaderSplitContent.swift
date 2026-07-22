import SwiftUI
import BibleCore

/**
 Computes stable pane geometry while reserving the fixed separators between panes.

 Without this reservation, weighted pane frames consume the entire parent extent before SwiftUI
 adds separators, causing the stack to overflow by one separator per adjacent pair.
 */
enum BibleReaderSplitLayout {
    /// Visible separator thickness shared by horizontal and vertical split layouts.
    static let separatorThickness: CGFloat = 4

    /**
     Returns the parent extent available to weighted pane frames.

     - Parameters:
       - totalExtent: Full width or height supplied by the parent geometry.
       - paneCount: Number of visible panes in the stack.
     - Returns: Non-negative extent remaining after all fixed separators are reserved.
     - Side Effects: None.
     - Failure Modes: Non-positive pane counts reserve no separators; undersized extents clamp to zero.
     */
    static func availablePaneExtent(totalExtent: CGFloat, paneCount: Int) -> CGFloat {
        let separatorCount = max(paneCount - 1, 0)
        return max(0, totalExtent - CGFloat(separatorCount) * separatorThickness)
    }
}

/**
 Lays out visible reader panes and separators for one workspace.

 `BibleReaderView` owns the state and pane callbacks; this view owns only the geometry-driven
 horizontal/vertical split decision and weight-based sizing.
 */
struct BibleReaderSplitContent<Pane: View>: View {
    @Environment(WindowManager.self) private var windowManager

    private let windows: [BibleCore.Window]
    private let reverseSplitMode: Bool
    private let pane: (BibleCore.Window) -> Pane

    init(
        windows: [BibleCore.Window],
        reverseSplitMode: Bool,
        @ViewBuilder pane: @escaping (BibleCore.Window) -> Pane
    ) {
        self.windows = windows
        self.reverseSplitMode = reverseSplitMode
        self.pane = pane
    }

    var body: some View {
        GeometryReader { geometry in
            let naturalHorizontal = geometry.size.width > geometry.size.height
            let isHorizontal = reverseSplitMode ? !naturalHorizontal : naturalHorizontal
            let effectiveWeights = windows.map(windowManager.effectiveLayoutWeight)
            let totalWeight = effectiveWeights.reduce(0, +)
            let normalizedTotal = max(totalWeight, 0.001)
            let paneExtent = BibleReaderSplitLayout.availablePaneExtent(
                totalExtent: isHorizontal ? geometry.size.width : geometry.size.height,
                paneCount: windows.count
            )

            // Keep the same stack container shape regardless of pane count so WebViews survive.
            if isHorizontal {
                HStack(spacing: 0) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        pane(window)
                            .frame(width: windows.count > 1
                                ? paneExtent * CGFloat(
                                    windowManager.effectiveLayoutWeight(for: window) / normalizedTotal
                                )
                                : nil)

                        if index < windows.count - 1 {
                            WindowSeparator(
                                window1: window,
                                window2: windows[index + 1],
                                isVertical: false,
                                totalPaneCount: windows.count,
                                parentSize: geometry.size.width
                            )
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        pane(window)
                            .frame(height: windows.count > 1
                                ? paneExtent * CGFloat(
                                    windowManager.effectiveLayoutWeight(for: window) / normalizedTotal
                                )
                                : nil)

                        if index < windows.count - 1 {
                            WindowSeparator(
                                window1: window,
                                window2: windows[index + 1],
                                isVertical: true,
                                totalPaneCount: windows.count,
                                parentSize: geometry.size.height
                            )
                        }
                    }
                }
            }
        }
    }
}
