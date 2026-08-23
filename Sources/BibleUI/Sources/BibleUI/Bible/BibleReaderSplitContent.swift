import SwiftUI
import BibleCore

/**
 Computes Android-parity split orientation and pane extents while reserving fixed separators.

 Without this reservation, weighted pane frames consume the entire parent extent before SwiftUI
 adds separators, causing the stack to overflow by one separator per adjacent pair. Orientation uses
 native window geometry so keyboard-safe-area changes cannot masquerade as device rotation.
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

    /**
     Resolves the split axis from the stable native window geometry.

     Android derives `SplitBibleArea` orientation from `Configuration.orientation`, which does not
     change when the IME reduces the reader's usable height. The iOS equivalent must therefore use
     the owning window bounds rather than a keyboard-adjusted SwiftUI child geometry.

     - Parameters:
       - stableWindowSize: Bounds of the native window that owns the reader. Zero dimensions resolve
         to the natural portrait direction until the window observer publishes usable bounds. A
         valid square resolves as Android's non-portrait `Configuration.orientation` does.
       - reverseSplitMode: Workspace preference that inverts Android's natural split direction.
     - Returns: `true` for a horizontal pane stack and `false` for a vertical pane stack.
     - Side Effects: None.
     - Failure Modes: Missing or zero window geometry deterministically uses the natural portrait
       direction before applying reverse mode; a later valid window observation recomputes the result.
     */
    static func isHorizontal(stableWindowSize: CGSize, reverseSplitMode: Bool) -> Bool {
        let hasUsableGeometry = stableWindowSize.width > 0 && stableWindowSize.height > 0
        let naturalHorizontal = hasUsableGeometry
            && stableWindowSize.width >= stableWindowSize.height
        return reverseSplitMode ? !naturalHorizontal : naturalHorizontal
    }
}

/**
 Lays out visible reader panes and separators for one workspace.

 `BibleReaderView` owns pane callbacks and workspace state. This view observes its exact native window
 for Android configuration-orientation parity, chooses an `AnyLayout` axis without changing child
 identity, and uses local SwiftUI geometry only for current weight-based extents.

 Data dependencies:
 - `WindowManager` supplies effective pane weights
 - `windows`, `reverseSplitMode`, and the owning iOS window bounds determine layout

 Side effects:
 - on iOS, the background bounds reader updates `stableWindowSize` after true window resize/rotation

 Failure modes:
 - before the first iOS window observation, natural orientation defaults to vertical; shared
   `AnyLayout` identity prevents that first resolved-axis update from reconstructing pane content
 */
struct BibleReaderSplitContent<Pane: View>: View {
    @Environment(WindowManager.self) private var windowManager

    #if os(iOS)
    /// Owning native-window bounds used exclusively for keyboard-invariant split-axis selection.
    @State private var stableWindowSize: CGSize = .zero
    #endif

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
            #if os(iOS)
            let orientationSize = stableWindowSize
            #else
            let orientationSize = geometry.size
            #endif
            let isHorizontal = BibleReaderSplitLayout.isHorizontal(
                stableWindowSize: orientationSize,
                reverseSplitMode: reverseSplitMode
            )
            let effectiveWeights = windows.map(windowManager.effectiveLayoutWeight)
            let totalWeight = effectiveWeights.reduce(0, +)
            let normalizedTotal = max(totalWeight, 0.001)
            let paneExtent = BibleReaderSplitLayout.availablePaneExtent(
                totalExtent: isHorizontal ? geometry.size.width : geometry.size.height,
                paneCount: windows.count
            )

            let stack = isHorizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))

            // A shared AnyLayout/ForEach identity lets legitimate rotations change axis without
            // reconstructing pane representables or their focused WebView sessions.
            stack {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    let weightedExtent = windows.count > 1
                        ? paneExtent * CGFloat(
                            windowManager.effectiveLayoutWeight(for: window) / normalizedTotal
                        )
                        : nil
                    pane(window)
                        .frame(
                            width: isHorizontal ? weightedExtent : nil,
                            height: isHorizontal ? nil : weightedExtent
                        )

                    if index < windows.count - 1 {
                        WindowSeparator(
                            window1: window,
                            window2: windows[index + 1],
                            isVertical: !isHorizontal,
                            totalPaneCount: windows.count,
                            parentSize: isHorizontal ? geometry.size.width : geometry.size.height
                        )
                    }
                }
            }
        }
        #if os(iOS)
        .background {
            BibleReaderWindowBoundsReader(windowSize: $stableWindowSize)
        }
        #endif
    }
}
