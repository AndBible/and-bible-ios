import SwiftUI
import BibleCore

/**
 Lays out visible reader panes and separators for one workspace.

 `BibleReaderView` owns the state and pane callbacks; this view owns only the geometry-driven
 horizontal/vertical split decision and weight-based sizing.
 */
struct BibleReaderSplitContent<Pane: View>: View {
    private let windows: [Window]
    private let reverseSplitMode: Bool
    private let pane: (Window) -> Pane

    init(
        windows: [Window],
        reverseSplitMode: Bool,
        @ViewBuilder pane: @escaping (Window) -> Pane
    ) {
        self.windows = windows
        self.reverseSplitMode = reverseSplitMode
        self.pane = pane
    }

    var body: some View {
        GeometryReader { geometry in
            let naturalHorizontal = geometry.size.width > geometry.size.height
            let isHorizontal = reverseSplitMode ? !naturalHorizontal : naturalHorizontal
            let totalWeight = windows.map(\.layoutWeight).reduce(0, +)
            let normalizedTotal = max(totalWeight, 0.001)

            // Keep the same stack container shape regardless of pane count so WebViews survive.
            if isHorizontal {
                HStack(spacing: 0) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        pane(window)
                            .frame(width: windows.count > 1
                                ? geometry.size.width * CGFloat(window.layoutWeight / normalizedTotal)
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
                                ? geometry.size.height * CGFloat(window.layoutWeight / normalizedTotal)
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
