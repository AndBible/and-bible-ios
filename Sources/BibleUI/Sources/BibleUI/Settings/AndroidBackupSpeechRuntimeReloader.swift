// AndroidBackupSpeechRuntimeReloader.swift -- Live speech reload after Android backup restore

import BibleCore

/** Applies restored Android speech preferences to the running service when relevant sections land. */
enum AndroidBackupSpeechRuntimeReloader {
    /**
     Reloads the live speech runtime after settings or workspace restore.

     - Parameters:
       - selections: Successfully applied Android backup categories.
       - settingsStore: Store containing the newly restored Android preferences.
       - activeWorkspaceSettings: Lazily resolved settings for the restored active workspace.
       - speakService: Running speech service, when the current shell owns one.
     - Returns: `true` only when a live service was rebound and reloaded.
     - Side effects: Rebinds `SpeakService.settingsStore` and immediately reapplies synthesis state.
     - Failure modes: Missing service and unrelated backup categories are deterministic no-ops.
     - Important: Runs on the main actor because the live speech service owns UI-observable
       playback and settings state there.
     */
    @MainActor
    @discardableResult
    static func reloadIfNeeded(
        selections: [AndroidDatabaseBackupSelection],
        settingsStore: SettingsStore,
        activeWorkspaceSettings: @autoclosure () -> SpeakSettings?,
        speakService: SpeakService?
    ) -> Bool {
        guard let speakService,
              selections.contains(where: {
                  $0.category == .settings || $0.category == .workspaces
              }) else {
            return false
        }
        speakService.settingsStore = settingsStore
        speakService.reloadAfterBackupRestore(
            activeWorkspaceSettings: activeWorkspaceSettings()
        )
        return true
    }
}
