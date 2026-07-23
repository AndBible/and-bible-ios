// AndroidIndeterminateProgressDialog.swift -- Shared app-owned Android hourglass presentation

import SwiftUI

/**
 Presents Android's non-cancelable indeterminate `Hourglass` contract in an app-owned dialog.

 Android archive, restore, and synchronization flows replace their initiating dialog with a
 `ProgressDialog` whose localized message defaults to `please_wait`. This shared view retains that
 ownership on iOS by composing `AndroidDialogWindow`, the global AppCompat palette, and a reusable
 Material-style indicator instead of invoking an iOS sheet or native progress presentation.

 Inputs: localized progress message and stable accessibility identifier

 Output: centered non-dismissible progress dialog over the owning application surface

 Side effects: animation time updates rotate the indicator while Reduce Motion is disabled

 Failure modes: none; callers remain responsible for removing the view when work completes
 */
struct AndroidIndeterminateProgressDialog: View {
    /// Active appearance used by the shared AppCompat palette and dialog surface.
    @Environment(\.colorScheme) private var colorScheme

    /// Localized operation message shown beside the indicator.
    let message: String

    /// Stable UI-test identity for the modal progress surface.
    let accessibilityIdentifier: String

    /**
     Creates one shared Android hourglass dialog.

     - Parameters:
       - message: Localized operation text; defaults to Android's `please_wait` resource.
       - accessibilityIdentifier: Stable semantic identity supplied by the owning workflow.
     - Side effects: none until SwiftUI renders the animated indicator.
     - Failure modes: none.
     */
    init(
        message: String = String(localized: "please_wait", defaultValue: "Please wait…"),
        accessibilityIdentifier: String = "androidIndeterminateProgressDialog"
    ) {
        self.message = message
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: accessibilityIdentifier,
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            HStack(spacing: 20) {
                AndroidIndeterminateProgressIndicator()

                Text(message)
                    .font(.system(size: 17))
                    .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 380)
        }
    }
}

/**
 Draws the shared Material-style indeterminate indicator used by app-owned Android progress dialogs.

 Inputs: current AppCompat scheme and the system Reduce Motion preference

 Output: fixed-size circular indicator using the globally managed dialog accent

 Side effects: reads animation time while motion is enabled

 Failure modes: none; Reduce Motion renders a stationary but recognizable progress arc
 */
struct AndroidIndeterminateProgressIndicator: View {
    /// Active appearance used to resolve the global dialog accent.
    @Environment(\.colorScheme) private var colorScheme

    /// Accessibility preference that suppresses continuous rotation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Optional owner-resolved track color for non-dialog activity use.
    let trackColor: Color?

    /// Optional owner-resolved accent color for non-dialog activity use.
    let accentColor: Color?

    /**
     Creates the shared indicator for a dialog or an owner-themed activity.

     - Parameters:
       - trackColor: Explicit activity track color, or nil to use the global dialog palette.
       - accentColor: Explicit activity accent color, or nil to use the global dialog palette.
     - Side effects: None until the animation timeline renders.
     - Failure modes: Supplying only one color safely falls back for the omitted role.
     */
    init(trackColor: Color? = nil, accentColor: Color? = nil) {
        self.trackColor = trackColor
        self.accentColor = accentColor
    }

    var body: some View {
        Group {
            if reduceMotion {
                indicator(rotationDegrees: 0)
            } else {
                TimelineView(.animation) { context in
                    indicator(rotationDegrees: rotationDegrees(at: context.date))
                }
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    /** Builds one progress arc at a supplied rotation without mutating view state. */
    private func indicator(rotationDegrees: Double) -> some View {
        ZStack {
            Circle()
                .stroke(
                    trackColor
                        ?? AndroidDialogSurfacePalette.secondaryText(for: colorScheme).opacity(0.22),
                    lineWidth: 4
                )

            Circle()
                .trim(from: 0.08, to: 0.76)
                .stroke(
                    accentColor ?? AndroidDialogSurfacePalette.accent(for: colorScheme),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(rotationDegrees))
        }
    }

    /**
     Resolves a stable clockwise phase for the animation timeline.

     - Parameter date: Timeline sample supplied by SwiftUI.
     - Returns: Rotation in degrees over a 0.9-second Material-style cycle.
     - Side effects: none.
     - Failure modes: none; reference time is finite for every `Date`.
     */
    private func rotationDegrees(at date: Date) -> Double {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9)
        return (cycle / 0.9) * 360
    }
}

/**
 Renders the shared Material-style determinate bar used by app-owned Android activity workflows.

 Inputs: normalized completion value plus owner-resolved track and accent colors

 Output: one fixed-height horizontal progress bar

 Side effects: none

 Failure modes: non-finite or out-of-range input is clamped to the closed zero-to-one interval
 */
struct AndroidDeterminateProgressIndicator: View {
    /// Caller-reported normalized progress.
    let fraction: Double

    /// Low-emphasis track color supplied by the owning palette.
    let trackColor: Color

    /// Filled progress color supplied by the owning palette.
    let accentColor: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule()
                    .fill(accentColor)
                    .frame(width: geometry.size.width * normalizedFraction)
            }
        }
        .frame(height: 4)
        .accessibilityValue("\(Int(normalizedFraction * 100))%")
    }

    /** Finite completion value clamped to Android's normalized progress range. */
    private var normalizedFraction: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}
