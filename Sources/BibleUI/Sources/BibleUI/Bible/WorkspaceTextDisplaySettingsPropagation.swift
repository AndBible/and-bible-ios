// WorkspaceTextDisplaySettingsPropagation.swift -- Android workspace text-options persistence rules

import BibleCore

/**
 Pure helpers for Android workspace-level Text Options propagation.

 Android persists workspace text-display changes on the workspace and then clears child window
 overrides only when a changed field now matches the workspace parent value. Keeping this logic in a
 small value helper lets tests verify the inheritance contract without driving SwiftUI private state.
 */
enum WorkspaceTextDisplaySettingsPropagation {
    /**
     Builds the workspace-scoped override payload that should be persisted after editing.

     - Parameters:
       - editorSettings: Fully resolved settings value emitted by the workspace editor.
       - previousResolvedSettings: Fully resolved workspace settings before the edit.
       - existingWorkspaceSettings: Existing workspace-owned overrides, used to preserve explicit
         theme colors when the workspace already owned them.
       - globalSettings: Current global parent settings.
     - Returns: A workspace override value with redundant global matches cleared.
     - Side effects: none.
     - Failure modes: none; all inputs are value types and every field is optional.
     */
    static func workspaceScopedSettings(
        editorSettings: TextDisplaySettings,
        previousResolvedSettings: TextDisplaySettings,
        existingWorkspaceSettings: TextDisplaySettings?,
        globalSettings: TextDisplaySettings
    ) -> TextDisplaySettings {
        let hadWorkspaceThemeColors = existingWorkspaceSettings?.hasThemeColorOverrides ?? false
        let changedThemeColors = themeColorsDiffer(editorSettings, previousResolvedSettings)
        let shouldPersistThemeColors = hadWorkspaceThemeColors || changedThemeColors
        var workspaceScopedSettings = editorSettings
        if !shouldPersistThemeColors {
            workspaceScopedSettings.clearThemeColors()
        }
        _ = workspaceScopedSettings.clearRedundantOverrides(matching: globalSettings)
        if shouldPersistThemeColors {
            workspaceScopedSettings.restoreThemeColors(from: editorSettings)
        }
        return workspaceScopedSettings
    }

    /**
     Applies Android's workspace dirty-field cleanup to one window override value.

     - Parameters:
       - windowSettings: Current window/page-manager overrides to normalize.
       - currentWorkspaceParentSettings: Fully resolved workspace parent after the workspace edit.
       - previousWorkspaceSettings: Fully resolved workspace settings before the edit.
       - currentWorkspaceEditorSettings: Fully resolved workspace editor value after the edit.
     - Returns: Window overrides with matching changed fields cleared and intentional differing
       overrides preserved.
     - Side effects: none.
     - Failure modes: none; fields that are absent or do not match the parent are left untouched.
     */
    static func windowSettingsAfterWorkspaceChange(
        _ windowSettings: TextDisplaySettings,
        currentWorkspaceParentSettings: TextDisplaySettings,
        previousWorkspaceSettings: TextDisplaySettings,
        currentWorkspaceEditorSettings: TextDisplaySettings
    ) -> TextDisplaySettings {
        var propagatedSettings = windowSettings
        _ = propagatedSettings.clearOverridesMatchingParent(
            currentWorkspaceParentSettings,
            changedFrom: previousWorkspaceSettings,
            to: currentWorkspaceEditorSettings
        )
        return propagatedSettings
    }

    /**
     Compares the day/night theme color tuple between two settings values.

     - Parameters:
       - lhs: First display settings value.
       - rhs: Second display settings value.
     - Returns: `true` when any theme color or noise field differs.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func themeColorsDiffer(
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
