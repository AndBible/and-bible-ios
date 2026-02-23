// WindowSeparator.swift — Draggable separator between Bible windows
//
// Replicates Android's Separator.kt weight calculation:
// aveScreenSize = parentSize / totalPaneCount
// variationPercent = dragTranslation / aveScreenSize
// newWeight = max(0.1, startWeight ± variationPercent)

import SwiftUI
import BibleCore

/// A draggable separator between two Bible window panes.
/// Adjusts `layoutWeight` of adjacent windows on drag.
struct WindowSeparator: View {
    let window1: Window
    let window2: Window
    /// true = horizontal bar between vertically-stacked panes
    let isVertical: Bool
    let totalPaneCount: Int
    /// total available height (vertical) or width (horizontal) of parent
    let parentSize: CGFloat

    @State private var isDragging = false
    @State private var startWeight1: Float = 1.0
    @State private var startWeight2: Float = 1.0

    private let separatorThickness: CGFloat = 4
    private let minWeight: Float = 0.1

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.gray.opacity(0.5))
            .frame(
                width: isVertical ? nil : separatorThickness,
                height: isVertical ? separatorThickness : nil
            )
            .contentShape(Rectangle().inset(by: -20)) // expanded touch target
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            startWeight1 = window1.layoutWeight
                            startWeight2 = window2.layoutWeight
                        }

                        let aveScreenSize = parentSize / CGFloat(totalPaneCount)
                        guard aveScreenSize > 0 else { return }

                        let translation = isVertical ? value.translation.height : value.translation.width
                        let variationPercent = Float(translation / aveScreenSize)

                        window1.layoutWeight = max(minWeight, startWeight1 + variationPercent)
                        window2.layoutWeight = max(minWeight, startWeight2 - variationPercent)
                    }
                    .onEnded { _ in
                        isDragging = false
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
