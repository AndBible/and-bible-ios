// BibleReaderWindowDisplaySettingsMutation.swift -- window display-settings persistence helper

import BibleCore

/**
 Builds and persists window-scoped text-display overrides.

 Android stores window-level All Text Options on the pane's page manager and lets workspace/global
 parents continue to provide inherited values. This helper isolates that scope-reduction algorithm
 so active-pane mutations can be covered in fast package tests without launching the app.
 */
struct BibleReaderWindowDisplaySettingsMutation {
    /**
     Persists the editor result to one window's page manager.

     - Parameters:
       - editorSettings: Effective settings returned by the window text-options editor.
       - window: Target pane whose page manager should receive the scoped overrides.
       - parentSettings: Effective parent settings from workspace/global inheritance.
       - previousResolvedSettings: Effective window settings before the editor mutation.
     - Returns: `true` when a page manager was mutated, otherwise `false`.
     - Side effects: Mutates `window.pageManager.textDisplaySettings` when available.
     - Failure modes: Missing windows or page managers are reported as `false`; callers decide how
       to refresh in-memory state.
     */
    @discardableResult
    static func persist(
        editorSettings: TextDisplaySettings,
        for window: Window?,
        parentSettings: TextDisplaySettings,
        previousResolvedSettings: TextDisplaySettings
    ) -> Bool {
        guard let pageManager = window?.pageManager else {
            return false
        }
        pageManager.textDisplaySettings = windowScopedSettings(
            editorSettings: editorSettings,
            existingWindowSettings: pageManager.textDisplaySettings,
            parentSettings: parentSettings,
            previousResolvedSettings: previousResolvedSettings
        )
        return true
    }

    /**
     Reduces an effective editor value into persisted window-level overrides.

     - Parameters:
       - editorSettings: Effective settings from the window editor.
       - existingWindowSettings: Existing raw window overrides, used to preserve owned theme colors.
       - parentSettings: Effective parent settings used for redundant override clearing.
       - previousResolvedSettings: Effective settings before the editor changed.
     - Returns: Raw window-scoped overrides suitable for `PageManager.textDisplaySettings`.
     - Side effects: None.
     - Failure modes: None.
     */
    static func windowScopedSettings(
        editorSettings: TextDisplaySettings,
        existingWindowSettings: TextDisplaySettings?,
        parentSettings: TextDisplaySettings,
        previousResolvedSettings: TextDisplaySettings
    ) -> TextDisplaySettings {
        let hadWindowThemeColors = existingWindowSettings?.hasThemeColorOverrides ?? false
        let changedThemeColors = themeColorsDiffer(editorSettings, previousResolvedSettings)
        let shouldPersistThemeColors = hadWindowThemeColors || changedThemeColors
        var windowScopedSettings = editorSettings
        if !shouldPersistThemeColors {
            windowScopedSettings.clearThemeColors()
        }
        _ = windowScopedSettings.clearRedundantOverrides(matching: parentSettings)
        if shouldPersistThemeColors {
            windowScopedSettings.restoreThemeColors(from: editorSettings)
        }
        return windowScopedSettings
    }

    /**
     Compares the day/night theme color tuple between two display-settings values.

     - Parameters:
       - lhs: First display settings value.
       - rhs: Second display settings value.
     - Returns: `true` when any theme color or noise field differs.
     - Side effects: None.
     - Failure modes: None.
     */
    static func themeColorsDiffer(
        _ lhs: TextDisplaySettings,
        _ rhs: TextDisplaySettings
    ) -> Bool {
        lhs.dayTextColor != rhs.dayTextColor ||
            lhs.dayBackground != rhs.dayBackground ||
            lhs.dayNoise != rhs.dayNoise ||
            lhs.nightTextColor != rhs.nightTextColor ||
            lhs.nightBackground != rhs.nightBackground ||
            lhs.nightNoise != rhs.nightNoise
    }
}
