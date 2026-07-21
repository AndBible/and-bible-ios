// ReaderThemeSurfacePalette.swift -- Reader-shell colors derived from text display settings

import SwiftUI
import BibleCore

/**
 Resolves Android's workspace chrome color from workspace metadata.

 Android stores `workspace_color` on `WorkspaceSettings`, not in text-display colors. The SwiftUI
 reader keeps the resolved value as its own chrome state so editing the workspace color can repaint
 native toolbar surfaces even when the page text/background settings did not change.

 Inputs:
 - `activeWindow`: preferred pane context. When present, its workspace owns the reader chrome.
 - `activeWorkspace`: fallback workspace used when no active window is available.

 Output:
 - a signed ARGB workspace color, falling back to Android's `#ff444444` default for nil legacy data

 Side effects: none.
 Failure modes: missing window/workspace metadata returns the Android default.
 Determinism: pure value derivation with no persistence or asynchronous work.
 */
enum ReaderWorkspaceChromeColor {
    static func resolved(activeWindow: BibleCore.Window?, activeWorkspace: Workspace?) -> Int {
        activeWindow?.workspace?.workspaceColor
            ?? activeWorkspace?.workspaceColor
            ?? Workspace.defaultWorkspaceColor
    }
}

/**
 Resolves the native reader shell colors from the same day/night theme settings used by the WebView.

 The Vue reader receives `TextDisplaySettings` through the bridge and applies those ARGB colors to
 document content. Native SwiftUI chrome around that document must derive content surfaces from the
 same values, while Android's action-bar chrome uses the workspace color in day mode, black in night
 mode, and black-on-white in monochrome mode.

 Inputs:
 - `settings`: a fully or partially resolved text-display settings value
 - `nightMode`: selects the day or night color tuple
 - `workspaceColor`: Android workspace accent color used by reader toolbar chrome
 - `monochromeMode`: Android e-ink mode forcing day toolbar chrome to black on white
 - `defaults`: fallback settings used when the selected tuple is missing values

 Outputs:
 - signed ARGB integers for testable parity with the WebView payload
 - SwiftUI `Color` projections for native content and toolbar surfaces

 Side effects: none.
 Failure modes: missing settings fall back to the hard-coded reader defaults.
 Determinism: pure value derivation with no shared state.
 */
struct ReaderThemeSurfacePalette: Equatable {
    /// Background color encoded with the Android/Vue signed ARGB convention.
    let backgroundColorInt: Int

    /// Foreground/text color encoded with the Android/Vue signed ARGB convention.
    let foregroundColorInt: Int

    /// Toolbar/action-bar background color encoded with Android's signed ARGB convention.
    let toolbarBackgroundColorInt: Int

    /// Toolbar/action-bar foreground color encoded with Android's signed ARGB convention.
    let toolbarForegroundColorInt: Int

    /// Navigation drawer/home affordance color encoded with Android's signed ARGB convention.
    let navigationDrawerColorInt: Int

    /// Default light-mode reader palette used by call sites that have not yet received settings.
    static let standard = ReaderThemeSurfacePalette(settings: .appDefaults, nightMode: false)

    /**
     Creates a reader-shell palette from resolved display settings.

     - Parameters:
       - settings: Active text-display settings for the relevant reader surface.
       - nightMode: Whether to select the night color tuple.
       - workspaceColor: Optional Android workspace accent color used by action-bar chrome.
       - monochromeMode: Whether Android's monochrome/e-ink preference is enabled.
       - defaults: Fallback values used when `settings` omits a color field.
     */
    init(
        settings: TextDisplaySettings,
        nightMode: Bool,
        workspaceColor: Int? = nil,
        monochromeMode: Bool = false,
        defaults: TextDisplaySettings = .appDefaults
    ) {
        if nightMode {
            backgroundColorInt = settings.nightBackground ?? defaults.nightBackground ?? -16777216
            foregroundColorInt = settings.nightTextColor ?? defaults.nightTextColor ?? -1
        } else {
            backgroundColorInt = settings.dayBackground ?? defaults.dayBackground ?? -1
            foregroundColorInt = settings.dayTextColor ?? defaults.dayTextColor ?? -16777216
        }

        let resolvedWorkspaceColor = workspaceColor ?? Workspace.defaultWorkspaceColor
        if nightMode {
            toolbarBackgroundColorInt = -16777216
            toolbarForegroundColorInt = -1
            navigationDrawerColorInt = resolvedWorkspaceColor
        } else if monochromeMode {
            toolbarBackgroundColorInt = -1
            toolbarForegroundColorInt = -16777216
            navigationDrawerColorInt = -16777216
        } else {
            toolbarBackgroundColorInt = resolvedWorkspaceColor
            toolbarForegroundColorInt = -1
            navigationDrawerColorInt = -1
        }
    }

    /// SwiftUI background color for reader chrome surfaces.
    var backgroundColor: Color {
        Color(argbInt: backgroundColorInt)
    }

    /// SwiftUI foreground color for reader chrome labels and icons.
    var foregroundColor: Color {
        Color(argbInt: foregroundColorInt)
    }

    /// SwiftUI background color for Android-parity reader toolbar/action-bar chrome.
    var toolbarBackgroundColor: Color {
        Color(argbInt: toolbarBackgroundColorInt)
    }

    /// SwiftUI foreground color for Android-parity reader toolbar/action-bar icons and labels.
    var toolbarForegroundColor: Color {
        Color(argbInt: toolbarForegroundColorInt)
    }

    /// SwiftUI foreground color for the navigation drawer/home affordance.
    var navigationDrawerColor: Color {
        Color(argbInt: navigationDrawerColorInt)
    }

    /// Low-contrast toolbar foreground color for inactive actions and secondary labels.
    var toolbarSecondaryForegroundColor: Color {
        toolbarForegroundColor.opacity(0.58)
    }

    /// Disabled toolbar foreground color for unavailable reader chrome controls.
    var toolbarDisabledForegroundColor: Color {
        toolbarSecondaryForegroundColor.opacity(0.55)
    }

    /// Low-contrast foreground color for secondary labels, inactive dots, and neutral borders.
    var secondaryForegroundColor: Color {
        foregroundColor.opacity(0.58)
    }

    /// Disabled foreground color for unavailable reader chrome controls.
    var disabledForegroundColor: Color {
        secondaryForegroundColor.opacity(0.55)
    }

    /// Subtle fill used for neutral controls on top of the reader background.
    var controlFillColor: Color {
        foregroundColor.opacity(0.10)
    }

    /// Border color for inactive chrome controls on top of the reader background.
    var inactiveBorderColor: Color {
        foregroundColor.opacity(0.24)
    }
}
