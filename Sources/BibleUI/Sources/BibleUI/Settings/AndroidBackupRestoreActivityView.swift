// AndroidBackupRestoreActivityView.swift -- App-owned Android BackupActivity presentation

import BibleCore
import SwiftUI
import SwordKit

/**
 Renders Android's BackupActivity layout from caller-owned workflow state and commands.

 This presentation component follows `backup_view.xml`: an app-owned action bar, vertically
 scrolling content, Database/Documents radio groups with supporting text, full-width raised
 Backup/Restore commands, and ordered database-reset actions. Platform Files and share presenters
 remain in `ImportExportView`, outside this view, because they are external handoff boundaries rather
 than application presentation.

 Inputs: active reader/workspace palette, persisted radio bindings, busy/progress state, reset
 categories, semantic state, and explicit workflow callbacks

 Output: one app-owned Android Backup & Restore activity

 Side effects: radio rows mutate their bindings and buttons invoke caller-owned commands

 Failure modes: command failures are rendered by the parent's dialog/toast layer
 */
struct AndroidBackupRestoreActivityView: View {
    /// Active AppCompat appearance used for shared interactive accents.
    @Environment(\.colorScheme) private var colorScheme

    let surfacePalette: ReaderThemeSurfacePalette
    @Binding var backupTarget: BackupWorkflowTarget
    @Binding var restoreTarget: RestoreWorkflowTarget
    let resetCategories: [AndroidBackupResetCategory]
    let isBackingUp: Bool
    let isRestoringOrImporting: Bool
    let isWorkflowBusy: Bool
    let documentInstallProgress: ModuleInstallProgress?
    let accessibilityValue: String
    let onBack: () -> Void
    let onBackup: () -> Void
    let onRestoreOrImport: () -> Void
    let onReset: (AndroidBackupResetCategory) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(localized: "backup_and_restore", defaultValue: "Backup & Restore"),
                accessibilityIdentifier: "backupRestoreAppBar",
                palette: surfacePalette,
                onBack: onBack
            ) {
                EmptyView()
            } content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                    sectionTitle(String(
                        localized: "backup_and_restore",
                        defaultValue: "Backup & Restore"
                    ))

                    ForEach(BackupWorkflowTarget.allCases) { target in
                        BackupWorkflowOptionRow(
                            title: target.localizedTitle,
                            description: target.localizedDescription,
                            value: target,
                            selection: $backupTarget,
                            isEnabled: !isWorkflowBusy,
                            foregroundColor: surfacePalette.foregroundColor,
                            secondaryColor: surfacePalette.secondaryForegroundColor,
                            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
                            accessibilityIdentifier: "backupWorkflowTarget.\(target.rawValue)Button"
                        )
                        .padding(.horizontal, 10)
                    }

                    workflowButton(
                        title: String(localized: "backup_to", defaultValue: "Backup to…"),
                        isRunning: isBackingUp,
                        accessibilityIdentifier: "backupWorkflowBackupButton",
                        action: onBackup
                    )

                    sectionTitle(String(
                        localized: "backup_restore2",
                        defaultValue: "Restore or Import"
                    ))
                    .padding(.top, 20)

                    ForEach(RestoreWorkflowTarget.allCases) { target in
                        BackupWorkflowOptionRow(
                            title: target.localizedTitle,
                            description: target.localizedDescription,
                            value: target,
                            selection: $restoreTarget,
                            isEnabled: !isWorkflowBusy,
                            foregroundColor: surfacePalette.foregroundColor,
                            secondaryColor: surfacePalette.secondaryForegroundColor,
                            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
                            accessibilityIdentifier: "restoreWorkflowTarget.\(target.rawValue)Button"
                        )
                        .padding(.horizontal, 10)
                    }

                    workflowButton(
                        title: String(
                            localized: "backup_restore_from2",
                            defaultValue: "Restore or Import from…"
                        ),
                        isRunning: isRestoringOrImporting,
                        accessibilityIdentifier: "backupWorkflowRestoreButton",
                        action: onRestoreOrImport
                    )

                    if let documentInstallProgress {
                        installProgress(documentInstallProgress)
                    }

                    sectionTitle(String(
                        localized: "reset_databases_title",
                        defaultValue: "Reset Databases"
                    ))
                    .padding(.top, 20)

                    Text(String(
                        localized: "reset_databases_description",
                        defaultValue: "Reset individual databases to their initial empty state. This cannot be undone."
                    ))
                    .font(.system(size: 15))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                    VStack(spacing: 8) {
                        ForEach(resetCategories) { category in
                            AndroidRaisedTextButton(
                                title: category.localizedBackupResetButtonTitle,
                                foregroundColor: surfacePalette.foregroundColor,
                                backgroundColor: surfacePalette.controlFillColor,
                                isEnabled: !isWorkflowBusy,
                                accessibilityIdentifier: category.backupResetAccessibilityIdentifier
                            ) {
                                onReset(category)
                            }
                        }
                    }
                    }
                    .padding(10)
                }
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "backup_and_restore", defaultValue: "Backup & Restore"),
                accessibilityIdentifier: "importExportScreen",
                accessibilityValue: accessibilityValue,
                surfaceColor: surfacePalette.backgroundColor
            )
        }
    }

    /** Builds one bold Android layout heading using the owning content color. */
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(surfacePalette.foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /** Builds Android's centered raised Backup or Restore command. */
    private func workflowButton(
        title: String,
        isRunning: Bool,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AndroidRaisedTextButton(
            title: title,
            foregroundColor: surfacePalette.foregroundColor,
            backgroundColor: surfacePalette.controlFillColor,
            isEnabled: !isWorkflowBusy,
            isRunning: isRunning,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        )
        .padding(.horizontal, 50)
        .padding(.top, 10)
    }

    /** Renders document-install phase text with shared app-owned Android progress indicators. */
    private func installProgress(_ progress: ModuleInstallProgress) -> some View {
        HStack(spacing: 12) {
            Text(ModuleBrowserView.installPhaseText(
                progress.phase,
                progressPercent: progress.percent
            ))
            .font(.system(size: 13))
            .foregroundStyle(surfacePalette.secondaryForegroundColor)

            Spacer(minLength: 8)

            if let fraction = progress.fraction {
                AndroidDeterminateProgressIndicator(
                    fraction: fraction,
                    trackColor: surfacePalette.inactiveBorderColor,
                    accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
                )
                .frame(width: 84)
            } else {
                AndroidIndeterminateProgressIndicator()
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.top, 10)
        .accessibilityIdentifier("documentInstallProgress")
    }
}
