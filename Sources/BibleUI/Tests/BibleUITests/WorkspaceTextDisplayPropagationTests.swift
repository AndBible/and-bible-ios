import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 App-host-free package coverage for BibleUI's Android workspace text-options propagation helper.

 The helper lives in BibleUI because it normalizes settings emitted by reader/settings UI before
 persistence. This suite keeps that UI-owned inheritance contract out of the app-host test bundle
 while preserving Android parity coverage.
 */
final class WorkspaceTextDisplayPropagationTests: XCTestCase {
    /**
     Protects Android workspace text-display dirty-field propagation.

     Android's `TextDisplaySettings.kt` saves workspace edits to `WindowRepository.textDisplaySettings`
     and then calls `updateWindowTextDisplaySettingsValues`, which clears only child window fields
     that now equal the workspace value for fields changed by the workspace edit. Differing window
     overrides and unchanged matching values remain window-owned.

     Expected result:
     - workspace-scoped persisted settings keep changed values and drop redundant global values
     - window overrides equal to the new workspace values are cleared for changed fields
     - window overrides that intentionally differ from the workspace stay present
     - unchanged window values are not cleared just because they match a parent value

     Failure meaning:
     - iOS can regress from Android's workspace inheritance semantics by pinning stale window values
       or erasing intentional per-window overrides after a workspace text-options edit.
     */
    func testWorkspaceTextDisplayPropagationClearsOnlyDirtyMatchingWindowOverrides() {
        var globalSettings = TextDisplaySettings.appDefaults
        globalSettings.fontSize = 18
        globalSettings.showVerseNumbers = true
        globalSettings.showFootNotes = false
        globalSettings.lineSpacing = 10

        let existingWorkspaceSettings = TextDisplaySettings()
        let previousWorkspaceSettings = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: existingWorkspaceSettings,
            global: globalSettings
        )

        var workspaceEditorSettings = previousWorkspaceSettings
        workspaceEditorSettings.fontSize = 20
        workspaceEditorSettings.showVerseNumbers = false
        workspaceEditorSettings.showFootNotes = true

        let persistedWorkspaceSettings = WorkspaceTextDisplaySettingsPropagation.workspaceScopedSettings(
            editorSettings: workspaceEditorSettings,
            previousResolvedSettings: previousWorkspaceSettings,
            existingWorkspaceSettings: existingWorkspaceSettings,
            globalSettings: globalSettings
        )

        XCTAssertEqual(persistedWorkspaceSettings.fontSize, 20)
        XCTAssertEqual(persistedWorkspaceSettings.showVerseNumbers, false)
        XCTAssertEqual(persistedWorkspaceSettings.showFootNotes, true)
        XCTAssertNil(persistedWorkspaceSettings.lineSpacing)

        let currentWorkspaceParentSettings = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: persistedWorkspaceSettings,
            global: globalSettings
        )
        var windowSettings = TextDisplaySettings()
        windowSettings.fontSize = 20
        windowSettings.showVerseNumbers = false
        windowSettings.showFootNotes = false
        windowSettings.lineSpacing = 10

        let propagatedWindowSettings = WorkspaceTextDisplaySettingsPropagation.windowSettingsAfterWorkspaceChange(
            windowSettings,
            currentWorkspaceParentSettings: currentWorkspaceParentSettings,
            previousWorkspaceSettings: previousWorkspaceSettings,
            currentWorkspaceEditorSettings: workspaceEditorSettings
        )

        XCTAssertNil(propagatedWindowSettings.fontSize)
        XCTAssertNil(propagatedWindowSettings.showVerseNumbers)
        XCTAssertEqual(propagatedWindowSettings.showFootNotes, false)
        XCTAssertEqual(propagatedWindowSettings.lineSpacing, 10)
    }
}
