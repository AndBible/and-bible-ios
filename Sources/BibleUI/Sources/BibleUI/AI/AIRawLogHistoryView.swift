// AIRawLogHistoryView.swift -- Android-parity AI log history and detail screens

import BibleCore
import Foundation
import SwiftData
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/** Age choices shown by Android's Delete old logs overflow action. */
private enum AIRawLogDeletionChoice: Identifiable {
    /// Delete records older than seven days.
    case oneWeek
    /// Delete records older than thirty days.
    case oneMonth
    /// Delete records older than ninety days.
    case threeMonths
    /// Delete every raw log.
    case all

    /// Stable identity for the app-owned choice dialog.
    var id: Int {
        switch self {
        case .oneWeek: return 7
        case .oneMonth: return 30
        case .threeMonths: return 90
        case .all: return 0
        }
    }

    /// Android age cutoff in days, or nil for Delete all.
    var days: Int? { id == 0 ? nil : id }

    /// Android-localized choice text.
    var title: String {
        switch self {
        case .oneWeek:
            return String(localized: "raw_log_older_1_week", defaultValue: "Older than 1 week")
        case .oneMonth:
            return String(localized: "raw_log_older_1_month", defaultValue: "Older than 1 month")
        case .threeMonths:
            return String(localized: "raw_log_older_3_months", defaultValue: "Older than 3 months")
        case .all:
            return String(localized: "raw_log_delete_all", defaultValue: "Delete all")
        }
    }
}

/** App-owned list dialog matching Android's Delete old logs AlertDialog. */
private struct AIRawLogDeleteOldDialog: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Applies the selected Android cutoff immediately.
    let onChoose: (AIRawLogDeletionChoice) -> Void
    /// Closes the dialog without mutation.
    let onCancel: () -> Void

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "aiRawLogDeleteOldDialog",
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            AIAndroidDialogSurface(
                title: String(localized: "raw_log_delete_old", defaultValue: "Delete old logs…")
            ) {
                VStack(spacing: 0) {
                    ForEach([
                        AIRawLogDeletionChoice.oneWeek,
                        .oneMonth,
                        .threeMonths,
                        .all,
                    ]) { choice in
                        Button {
                            onChoose(choice)
                        } label: {
                            Text(choice.title)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } actions: {
                Spacer()
                AIAndroidDialogAction(
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    action: onCancel
                )
            }
        }
        .zIndex(20)
    }
}

/** App-owned confirmation matching Android's persisted-log Delete action. */
private struct AIRawLogDeleteConfirmationDialog: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Deletes the selected persisted log.
    let onDelete: () -> Void
    /// Returns to the raw log without deleting it.
    let onCancel: () -> Void

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "aiRawLogDeleteConfirmationDialog",
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            AIAndroidDialogSurface(title: "") {
                Text(String(localized: "are_you_sure", defaultValue: "Are you sure?"))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            } actions: {
                Spacer()
                AIAndroidDialogAction(
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    action: onCancel
                )
                AIAndroidDialogAction(
                    title: String(localized: "yes", defaultValue: "Yes"),
                    isDestructive: true,
                    action: onDelete
                )
            }
        }
        .zIndex(20)
    }
}

/** App-owned confirmation matching Android's supported-model AI bug-report action. */
private struct AIRawLogBugReportConfirmationDialog: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Builds the report and opens the platform share chooser.
    let onConfirm: () -> Void
    /// Returns to the raw log without creating an attachment.
    let onCancel: () -> Void

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "aiRawLogBugReportConfirmationDialog",
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            AIAndroidDialogSurface(
                title: String(localized: "send_ai_bug_report_title", defaultValue: "Report AI bug")
            ) {
                Text(
                    String(
                        localized: "bug_report_email_text",
                        defaultValue: "Next, please select your preferred email application (Gmail for example) to send the report to the developer team."
                    )
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            } actions: {
                Spacer()
                AIAndroidDialogAction(
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    action: onCancel
                )
                AIAndroidDialogAction(
                    title: String(localized: "okay", defaultValue: "OK"),
                    action: onConfirm
                )
            }
        }
        .zIndex(20)
    }
}

/**
 Android's full-screen raw-log history destination.

 Rows expose the same retained prompt, provider, model, token, cost, timestamp, and error metadata.
 A long press enters Android's contextual multi-selection mode; the overflow action deletes logs by
 age through the same four choices as RawLogHistoryActivity.
 */
struct AIRawLogHistoryView: View {
    /// Pops the log history activity for standalone callers.
    @Environment(\.dismiss) private var dismiss
    /// Current appearance used by the shared overflow surface.
    @Environment(\.colorScheme) private var colorScheme
    /// SwiftData context containing device-local raw logs.
    @Environment(\.modelContext) private var modelContext

    /// Newest-first local rows.
    @State private var logs: [LLMRawLogRecord] = []
    /// IDs selected through Android's contextual action mode.
    @State private var selectedIDs: Set<UUID> = []
    /// Row opened for full raw-log inspection.
    @State private var openedLog: LLMRawLogRecord?
    /// Prevents the release after a long press from immediately toggling the same row.
    @State private var suppressedTapID: UUID?
    /// Whether Android's age-choice dialog is visible.
    @State private var showsDeleteOldDialog = false
    /// Credential-free persistence failure.
    @State private var failureMessage: String?
    /// Whether Android's normal-mode overflow popup is visible.
    @State private var showsOverflowMenu = false

    /// Reader/workspace palette inherited from Connection settings.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command returning to Connection settings.
    let onBack: (() -> Void)?

    /** Creates the app-owned raw-log activity without reading local log payloads. */
    init(
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onBack: (() -> Void)? = nil
    ) {
        self.surfacePalette = surfacePalette
        self.onBack = onBack
    }

    /// Whether contextual multi-selection controls replace normal row navigation.
    private var isSelecting: Bool { !selectedIDs.isEmpty }

    var body: some View {
        Group {
            if let openedLog {
                AIRawLogDetailView(
                    log: openedLog,
                    surfacePalette: surfacePalette,
                    onBack: { self.openedLog = nil },
                    onDelete: {
                        self.openedLog = nil
                        loadLogs()
                    }
                )
            } else {
                rawLogHistoryRoot
            }
        }
    }

    /** Android raw-log list and contextual selection action bar. */
    private var rawLogHistoryRoot: some View {
        ZStack {
            AndroidActivityScreen(
                title: navigationTitle,
                accessibilityIdentifier: "aiRawLogHistoryTopAppBar",
                palette: surfacePalette,
                onBack: handleBack,
                actions: {
                    if isSelecting {
                        AndroidActivityTopAppBarActionButton(
                            icon: .asset("ActivityDelete"),
                            accessibilityLabel: String(
                                localized: "raw_log_delete_selected",
                                defaultValue: "Delete selected"
                            ),
                            accessibilityIdentifier: "aiRawLogDeleteSelectedButton",
                            foregroundColor: surfacePalette.toolbarForegroundColor,
                            action: deleteSelected
                        )
                    } else {
                        AndroidActivityTopAppBarActionButton(
                            icon: .asset("ToolbarOverflow"),
                            accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                            accessibilityIdentifier: "aiRawLogOverflowButton",
                            foregroundColor: surfacePalette.toolbarForegroundColor
                        ) {
                            showsOverflowMenu.toggle()
                        }
                        .androidPopupMenuAnchor(id: "aiRawLogOverflowAnchor")
                    }
                },
                content: {
                    if logs.isEmpty {
                        Text(String(localized: "raw_log_history_empty", defaultValue: "No saved logs"))
                            .font(.system(size: 17))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("aiRawLogHistoryEmpty")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(logs.enumerated()), id: \.element.id) { index, log in
                                    if index > 0 {
                                        AndroidPreferenceDivider(palette: surfacePalette)
                                    }
                                    Button {
                                        activate(log)
                                    } label: {
                                        AIRawLogHistoryRow(
                                            log: log,
                                            showsSelection: isSelecting,
                                            isSelected: selectedIDs.contains(log.id),
                                            surfacePalette: surfacePalette
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .onLongPressGesture {
                                        suppressedTapID = log.id
                                        selectedIDs.insert(log.id)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("aiRawLogHistoryList")
                    }
                }
            )
            .accessibilityHidden(showsDeleteOldDialog)
            .disabled(showsDeleteOldDialog || showsOverflowMenu)

            if showsDeleteOldDialog {
                AIRawLogDeleteOldDialog(
                    onChoose: deleteLogs,
                    onCancel: { showsDeleteOldDialog = false }
                )
            }
        }
        .androidAnchoredPopupMenu(
            anchorID: "aiRawLogOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 260,
            estimatedMenuHeight: 52,
            accessibilityIdentifier: "aiRawLogOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "aiRawLogOverflowMenu",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                AndroidPopupMenuRow(
                    title: String(
                        localized: "raw_log_delete_old",
                        defaultValue: "Delete old logs…"
                    ),
                    accessibilityIdentifier: "aiRawLogDeleteOldMenuItem"
                ) {
                    showsOverflowMenu = false
                    showsDeleteOldDialog = true
                }
            }
        }
        .task { loadLogs() }
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /** Exits contextual selection first, otherwise returns to Connection settings. */
    private func handleBack() {
        if isSelecting {
            selectedIDs = []
        } else if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }

    /// Android's contextual selection count or ordinary activity title.
    private var navigationTitle: String {
        guard isSelecting else {
            return String(localized: "raw_log_history_title", defaultValue: "AI Log History")
        }
        return String(
            format: String(localized: "raw_log_delete_confirm", defaultValue: "%d selected"),
            selectedIDs.count
        )
    }

    /** Opens a normal row or toggles it while contextual selection is active. */
    private func activate(_ log: LLMRawLogRecord) {
        if suppressedTapID == log.id {
            suppressedTapID = nil
            return
        }
        if isSelecting {
            if selectedIDs.contains(log.id) {
                selectedIDs.remove(log.id)
            } else {
                selectedIDs.insert(log.id)
            }
        } else {
            openedLog = log
        }
    }

    /** Loads local raw logs in Android's newest-first order. */
    private func loadLogs() {
        do {
            logs = try AISettingsStore(modelContext: modelContext).rawLogs()
            selectedIDs.formIntersection(Set(logs.map(\.id)))
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Deletes the current contextual selection and exits selection mode. */
    private func deleteSelected() {
        do {
            try AISettingsStore(modelContext: modelContext).deleteRawLogs(ids: selectedIDs)
            selectedIDs = []
            loadLogs()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Applies one Android age choice and refreshes the history list. */
    private func deleteLogs(_ choice: AIRawLogDeletionChoice) {
        showsDeleteOldDialog = false
        do {
            let store = AISettingsStore(modelContext: modelContext)
            if let days = choice.days {
                let milliseconds = Int64(days) * 24 * 60 * 60 * 1_000
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                try store.deleteRawLogs(olderThan: now - milliseconds)
            } else {
                try store.deleteRawLogs(olderThan: .max)
            }
            loadLogs()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/** Android's compact metadata row for one persisted raw log. */
private struct AIRawLogHistoryRow: View {
    /// Device-local raw-log metadata.
    let log: LLMRawLogRecord
    /// Whether contextual selection checkboxes are visible.
    let showsSelection: Bool
    /// Whether this row is currently selected.
    let isSelected: Bool
    /// Reader/workspace palette inherited from the history activity.
    let surfacePalette: ReaderThemeSurfacePalette

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsSelection {
                AndroidCheckboxIndicator(
                    isOn: isSelected,
                    uncheckedColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(log.promptName.isEmpty ? "-" : log.promptName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(surfacePalette.foregroundColor)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if log.wasError {
                        Text(String(localized: "raw_log_error_indicator", defaultValue: "Error"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Text(modelSummary)
                    .font(.caption)
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .lineLimit(1)
                HStack {
                    Text(tokenSummary)
                    Spacer(minLength: 8)
                    if log.estimatedCostUSD > 0 {
                        Text(Self.cost(log.estimatedCostUSD))
                    }
                }
                .font(.caption2)
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                Text(Self.timestamp(log.timestampMilliseconds))
                    .font(.caption2)
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Provider and model label matching Android's retained summary.
    private var modelSummary: String {
        guard let provider = LLMProvider(rawValue: log.providerType), provider != .custom else {
            return log.providerType.isEmpty ? log.modelName : "\(log.providerType) · \(log.modelName)"
        }
        return "\(AIProviderPresentation.displayName(for: provider)) · \(log.modelName)"
    }

    /// Localized token summary using Android's compact token formatter.
    private var tokenSummary: String {
        String(
            format: String(localized: "raw_log_item_tokens", defaultValue: "%1$@ in / %2$@ out"),
            Self.tokens(log.totalInputTokens),
            Self.tokens(log.totalOutputTokens)
        )
    }

    /** Formats tokens with Android's exact million/thousand thresholds. */
    static func tokens(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return String(count)
    }

    /** Formats positive estimated cost with Android's sub-cent precision rule. */
    static func cost(_ value: Double) -> String {
        String(format: value < 0.01 ? "$%.3f" : "$%.2f", value)
    }

    /** Formats timestamps like Android's yyyy-MM-dd HH:mm history rows. */
    static func timestamp(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}

/** Android's full-screen persisted raw-log reader with copy, share, and delete actions. */
private struct AIRawLogDetailView: View {
    /// Pops the detail after deletion.
    @Environment(\.dismiss) private var dismiss
    /// SwiftData context containing this local log.
    @Environment(\.modelContext) private var modelContext
    /// Current appearance used by the app-owned overflow menu.
    @Environment(\.colorScheme) private var colorScheme

    /// Persisted metadata and compressed payload.
    let log: LLMRawLogRecord
    /// Reader/workspace palette inherited from raw-log history.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up action returning to history.
    let onBack: (() -> Void)?
    /// Refresh callback for the history screen after deletion.
    let onDelete: () -> Void

    /// Decompressed Android-formatted transcript.
    @State private var text = ""
    /// Whether deletion confirmation is visible.
    @State private var showsDeleteConfirmation = false
    /// Whether Android's supported-model report confirmation is visible.
    @State private var showsBugReportConfirmation = false
    /// Addressed report handed to the platform's Android-equivalent mail composer.
    @State private var bugReportMail: AIBugReportMailPayload?
    /// Transient Android-style copy confirmation.
    @State private var toastMessage: String?
    /// Credential-free decoding or persistence failure.
    @State private var failureMessage: String?
    /// Whether Android's Delete/Report overflow popup is visible.
    @State private var showsOverflowMenu = false

    var body: some View {
        ZStack {
            AndroidActivityScreen(
                title: "\(log.modelName) — \(AIRawLogHistoryRow.timestamp(log.timestampMilliseconds))",
                accessibilityIdentifier: "aiRawLogDetailTopAppBar",
                palette: surfacePalette,
                onBack: performBack
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityCopy"),
                    accessibilityLabel: String(localized: "copy", defaultValue: "Copy"),
                    accessibilityIdentifier: "aiRawLogCopyButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: copyLog
                )
                .disabled(text.isEmpty)

                ShareLink(item: text) {
                    AndBibleIconView(name: "ActivityShare", size: 24)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(surfacePalette.toolbarForegroundColor)
                .disabled(text.isEmpty)
                .accessibilityLabel(String(localized: "share", defaultValue: "Share"))
                .accessibilityIdentifier("aiRawLogShareButton")

                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "aiRawLogDetailOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    showsOverflowMenu.toggle()
                }
                .androidPopupMenuAnchor(id: "aiRawLogDetailOverflowAnchor")
            } content: {
                VStack(spacing: 0) {
                    if log.estimatedCostUSD > 0 || log.totalInputTokens > 0 {
                        Text(totalSummary)
                            .font(.caption)
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                        Divider()
                    }
                    ScrollView {
                        Text(text.isEmpty
                            ? String(localized: "raw_llm_log_empty", defaultValue: "No raw log data available")
                            : text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(surfacePalette.foregroundColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .accessibilityHidden(showsDeleteConfirmation || showsBugReportConfirmation)
                .disabled(showsDeleteConfirmation || showsBugReportConfirmation || showsOverflowMenu)
            }

            if showsDeleteConfirmation {
                AIRawLogDeleteConfirmationDialog(
                    onDelete: deleteLog,
                    onCancel: { showsDeleteConfirmation = false }
                )
            }

            if showsBugReportConfirmation {
                AIRawLogBugReportConfirmationDialog(
                    onConfirm: prepareBugReport,
                    onCancel: { showsBugReportConfirmation = false }
                )
            }
        }
        .androidAnchoredPopupMenu(
            anchorID: "aiRawLogDetailOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 260,
            estimatedMenuHeight: 104,
            accessibilityIdentifier: "aiRawLogDetailOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "aiRawLogDetailOverflowMenu",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                VStack(spacing: 0) {
                    AndroidPopupMenuRow(
                        title: String(localized: "delete", defaultValue: "Delete"),
                        accessibilityIdentifier: "aiRawLogDeleteMenuItem"
                    ) {
                        showsOverflowMenu = false
                        showsDeleteConfirmation = true
                    }
                    Divider()
                    AndroidPopupMenuRow(
                        title: String(localized: "ai_bug_report_menu", defaultValue: "Report AI bug"),
                        accessibilityIdentifier: "aiRawLogReportBugMenuItem",
                        isEnabled: AIModelCatalog.isSupported(log.modelName)
                    ) {
                        showsOverflowMenu = false
                        showsBugReportConfirmation = true
                    }
                }
            }
        }
        .sheet(item: $bugReportMail) { payload in
            AIBugReportMailComposer(payload: payload) {
                bugReportMail = nil
            }
        }
        .task { decodeLog() }
        .androidToastFeedback(toastMessage)
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /// Android's total-token header with an optional estimated cost.
    private var totalSummary: String {
        let cost = log.estimatedCostUSD > 0 ? " · \(AIRawLogHistoryRow.cost(log.estimatedCostUSD))" : ""
        return String(
            format: String(localized: "raw_llm_log_total", defaultValue: "Total: in %1$@ / out %2$@%3$@"),
            AIRawLogHistoryRow.tokens(log.totalInputTokens),
            AIRawLogHistoryRow.tokens(log.totalOutputTokens),
            cost
        )
    }

    /** Decompresses the bounded local payload off the SwiftUI render path. */
    private func decodeLog() {
        do {
            text = try LLMRawLogPayloadDecoder.decode(log.logData)
        } catch {
            failureMessage = String(localized: "raw_llm_log_empty", defaultValue: "No raw log data available")
        }
    }

    /** Copies the decompressed log and shows Android's transient confirmation. */
    private func copyLog() {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        toastMessage = String(localized: "raw_llm_log_copied", defaultValue: "Log copied to clipboard")
        Task {
            try? await Task.sleep(for: .seconds(AndroidToastFeedback.shortDuration))
            toastMessage = nil
        }
    }

    /**
     Creates Android's gzip attachment and opens an addressed system mail composer.

     The report body includes the same prompt, provider, model, token, outcome, version, platform,
     and device fields as Android without including credentials.
     */
    private func prepareBugReport() {
        showsBugReportConfirmation = false
        guard AIModelCatalog.isSupported(log.modelName) else { return }
        guard AddressedMailComposer.capability == .available else {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
            return
        }

        do {
            let attachment = try LLMRawLogPayloadDecoder.gzipAttachmentData(log.logData)
            bugReportMail = AddressedMailPayload(
                recipient: "errors.andbible@gmail.com",
                subject: bugReportSubject,
                body: bugReportBody,
                attachments: [
                    AddressedMailAttachment(
                        data: attachment,
                        filename: "ai_raw_log.txt.gz",
                        mimeType: "application/gzip"
                    )
                ]
            )
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Android's persisted-log bug-report subject with the current app version. */
    private var bugReportSubject: String {
        let version = AndBibleAppVersionMetadata.current().marketingVersion
        return "AI Bug Report v\(version): \(log.promptName) (\(log.modelName))"
    }

    /** Android's credential-free persisted-log report body with iOS device metadata. */
    private var bugReportBody: String {
        let version = AndBibleAppVersionMetadata.current().marketingVersion
        #if os(iOS)
        let platform = "iOS: \(UIDevice.current.systemVersion)"
        let device = "Device: \(UIDevice.current.model)"
        #else
        let platform = "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let device = "Device: Mac"
        #endif
        var lines = [
            "--- AI Bug Report ---",
            "",
            "Please describe the issue:",
            "",
            "",
            "--- Details ---",
            "Prompt: \(log.promptName)",
        ]
        if let description = log.promptDescription, !description.isEmpty {
            lines.append("Description: \(description)")
        }
        lines.append(contentsOf: [
            "Model: \(log.modelName)",
            "Provider: \(log.providerType)",
            "Timestamp: \(AIRawLogHistoryRow.timestamp(log.timestampMilliseconds))",
            "Iterations: \(log.iterationCount)",
            "Tokens: \(log.totalInputTokens) in / \(log.totalOutputTokens) out",
            "Error: \(log.wasError)",
            "",
            "--- Device ---",
            "App: \(version)",
            platform,
            device,
            "",
            "Attached: ai_raw_log.txt.gz (gzipped raw LLM conversation log)",
        ])
        return lines.joined(separator: "\n")
    }

    /** Deletes this local record after Android's confirmation and returns to history. */
    private func deleteLog() {
        do {
            try AISettingsStore(modelContext: modelContext).deleteRawLogs(ids: Set([log.id]))
            showsDeleteConfirmation = false
            onDelete()
        } catch {
            showsDeleteConfirmation = false
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Returns through the explicit history owner or environment fallback. */
    private func performBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }
}
