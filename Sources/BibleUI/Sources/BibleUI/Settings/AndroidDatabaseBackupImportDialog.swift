// AndroidDatabaseBackupImportDialog.swift -- Android database restore/import dialog sequence

import BibleCore
import SwiftUI

/**
 Pure dialog coordinator for Android's database-backup restore sequence.

 Android first asks which valid database sections to process when an archive contains more than
 one, then asks Restore or Import for each sync-capable database, and finally confirms each
 destructive Restore. This state machine preserves archive order and produces one ordered batch for
 `AndroidDatabaseBackupService`, keeping presentation parity independent of asynchronous apply work.

 Inputs: validated archive sections and user decisions

 Output: the next app-owned dialog phase or one final ordered apply batch

 Side effects: none outside this value; mutating methods only update the draft

 Failure modes: unsupported sections and unsafe modes are excluded before any outcome is emitted
 */
struct AndroidDatabaseBackupDialogState: Equatable {
    /// One visible Android dialog or terminal transition in the restore sequence.
    enum Phase: Equatable {
        case unavailable
        case sectionSelection
        case modeChoice(AndroidDatabaseBackupCategory)
        case overwriteConfirmation(AndroidDatabaseBackupCategory)
        case readyToApply
        case finished
    }

    /// Owner command produced by one state transition.
    enum Outcome: Equatable {
        case awaitingInput
        case dismiss
        case apply([AndroidDatabaseBackupSelection])
    }

    /// Supported categories in Android's validated archive order, with duplicates removed.
    let orderedSupportedCategories: [AndroidDatabaseBackupCategory]

    /// Mutable checkbox draft used only by the optional section-selection dialog.
    var selectedCategories: Set<AndroidDatabaseBackupCategory>

    /// Current dialog or terminal phase.
    private(set) var phase: Phase

    /// Ordered safe decisions collected before the owner starts one atomic service batch.
    private(set) var selections: [AndroidDatabaseBackupSelection]

    /// Selected categories that have not yet reached a mode/confirmation decision.
    private var pendingCategories: [AndroidDatabaseBackupCategory]

    /**
     Creates the Android restore sequence from validated archive sections.

     - Parameter sections: Archive sections in Android database-file order.
     - Side effects: none.
     - Failure modes: Unsupported, duplicate, and no-safe-mode sections are excluded. With no safe
       sections, the state begins at `unavailable`.
     */
    init(sections: [AndroidDatabaseBackupSection]) {
        var seen = Set<AndroidDatabaseBackupCategory>()
        let categories = sections.compactMap { section -> AndroidDatabaseBackupCategory? in
            guard section.support.isSupported,
                  section.category.supportsApply,
                  seen.insert(section.category).inserted else {
                return nil
            }
            return section.category
        }

        orderedSupportedCategories = categories
        selectedCategories = Set(categories)
        selections = []
        pendingCategories = categories.count == 1 ? categories : []

        if categories.isEmpty {
            phase = .unavailable
        } else if categories.count > 1 {
            phase = .sectionSelection
        } else {
            phase = .finished
            _ = advanceToNextCategory()
        }
    }

    /**
     Accepts Android's multiselect snapshot and begins per-category decisions.

     - Returns: Dismissal for an empty selection, otherwise the next-input transition.
     - Side effects: snapshots selected categories in archive order and advances `phase`.
     - Failure modes: Calls outside `sectionSelection` are ignored.
     */
    mutating func confirmSectionSelection() -> Outcome {
        guard phase == .sectionSelection else { return .awaitingInput }
        pendingCategories = orderedSupportedCategories.filter(selectedCategories.contains)
        guard !pendingCategories.isEmpty else {
            phase = .finished
            return .dismiss
        }
        return advanceToNextCategory()
    }

    /**
     Records Android's Restore-or-Import decision for the current category.

     - Parameter mode: Safe operation selected by the user.
     - Returns: The next-input transition; Restore first exposes overwrite confirmation.
     - Side effects: Appends a safe Import selection or advances `phase` to confirmation.
     - Failure modes: Invalid phases or modes unsupported by the current category are ignored.
     */
    mutating func chooseMode(_ mode: AndroidDatabaseBackupApplyMode) -> Outcome {
        guard case .modeChoice(let category) = phase,
              category.supportedApplyModes.contains(mode) else {
            return .awaitingInput
        }

        switch mode {
        case .restore:
            phase = .overwriteConfirmation(category)
            return .awaitingInput
        case .import:
            selections.append(.init(category: category, mode: .import))
            return advanceToNextCategory()
        }
    }

    /**
     Confirms destructive replacement for the current Android database category.

     - Returns: The next-input transition after recording Restore.
     - Side effects: Appends one ordered Restore selection and advances `phase`.
     - Failure modes: Calls outside overwrite confirmation are ignored.
     */
    mutating func confirmOverwrite() -> Outcome {
        guard case .overwriteConfirmation(let category) = phase else {
            return .awaitingInput
        }
        selections.append(.init(category: category, mode: .restore))
        return advanceToNextCategory()
    }

    /**
     Implements Android's per-category Cancel behavior by skipping only the current category.

     - Returns: Dismissal if every category was skipped, otherwise the next-input transition.
     - Side effects: Advances `phase` without appending a selection.
     - Failure modes: Calls from non-category phases are ignored.
     */
    mutating func skipCurrentCategory() -> Outcome {
        switch phase {
        case .modeChoice, .overwriteConfirmation:
            return advanceToNextCategory()
        case .unavailable, .sectionSelection, .readyToApply, .finished:
            return .awaitingInput
        }
    }

    /**
     Consumes the final ordered batch exactly once when the progress phase appears.

     - Returns: One apply outcome from `readyToApply`; otherwise `awaitingInput`.
     - Side effects: moves `phase` to `finished` to prevent duplicate service application.
     - Failure modes: none.
     */
    mutating func takeReadyOutcome() -> Outcome {
        guard phase == .readyToApply else { return .awaitingInput }
        phase = .finished
        return .apply(selections)
    }

    /**
     Advances through automatic categories until another Android decision is required.

     Restore-only non-sync Android databases are queued automatically, matching Android's direct
     copy path. Sync databases always retain overwrite confirmation. Categories with both safe
     modes expose Android's Restore-or-Import dialog.

     - Returns: Dismissal if no decisions remain and none were accepted; otherwise input awaits.
     - Side effects: consumes `pendingCategories`, appends automatic safe selections, and updates
       `phase`.
     - Failure modes: Categories whose safe mode list becomes empty are skipped.
     */
    private mutating func advanceToNextCategory() -> Outcome {
        while let category = pendingCategories.first {
            pendingCategories.removeFirst()
            let modes = category.supportedApplyModes

            if modes.contains(.restore), modes.contains(.import) {
                phase = .modeChoice(category)
                return .awaitingInput
            }
            if modes == [.restore] {
                if Self.androidConfirmsRestore(for: category) {
                    phase = .overwriteConfirmation(category)
                    return .awaitingInput
                }
                selections.append(.init(category: category, mode: .restore))
                continue
            }
            if modes == [.import] {
                selections.append(.init(category: category, mode: .import))
            }
        }

        guard !selections.isEmpty else {
            phase = .finished
            return .dismiss
        }
        phase = .readyToApply
        return .awaitingInput
    }

    /** Whether Android's sync-database restore path asks `overwrite_something` for this category. */
    private static func androidConfirmsRestore(for category: AndroidDatabaseBackupCategory) -> Bool {
        switch category {
        case .bookmarks, .workspaces, .readingPlans, .myDocuments, .aiSettings, .progress:
            true
        case .settings, .repositories, .modules, .epubs:
            false
        }
    }
}

/**
 Adapts Android database sections to the shared app-owned multiselect dialog content.

 The view intentionally has no navigation stack, list, toggle, picker, toolbar, or platform sheet.
 Unsupported Android databases are filtered before this content is created, matching Android's
 validation path, and every visible row uses Android's exact shared category resource.
 */
struct AndroidDatabaseBackupSectionDialogContent: View {
    /// Supported validated sections in Android database-file order.
    let sections: [AndroidDatabaseBackupSection]

    /// Parent-owned checkbox draft.
    @Binding var selectedCategories: Set<AndroidDatabaseBackupCategory>

    /// Whether owner apply work has disabled all dialog interactions.
    let isBusy: Bool

    /// Explicit cancellation callback.
    let onCancel: () -> Void

    /// Confirmation callback after the shared content commits its filtered selected identities.
    let onConfirm: () -> Void

    /** Builds Android's section title, checked rows, neutral toggle, and Cancel/OK actions. */
    var body: some View {
        AndroidMultiselectDialogContent(
            title: String(
                localized: "restore_backup_sections",
                defaultValue: "Which backup sections do you want to restore?"
            ),
            rows: Self.multiselectRows(for: sections),
            selectedIDs: $selectedCategories,
            isBusy: isBusy,
            accessibilityIdentifier: "androidDatabaseBackupSectionDialogContent",
            accessibilityPrefix: "androidDatabaseBackup",
            onCancel: onCancel,
            onConfirm: confirmSelection
        )
    }

    /**
     Adapts validated section metadata to exact Android category labels.

     - Parameter sections: Supported sections in visible order.
     - Returns: Shared app-owned checkbox rows.
     - Side effects: Resolves Android-sourced localization resources.
     - Failure modes: none.
     */
    static func multiselectRows(
        for sections: [AndroidDatabaseBackupSection]
    ) -> [AndroidMultiselectDialogRow<AndroidDatabaseBackupCategory>] {
        sections.map { section in
            AndroidMultiselectDialogRow(
                id: section.category,
                title: section.category.localizedBackupSectionName,
                accessibilityIdentifier: "androidBackupSectionToggle.\(section.category.rawValue)"
            )
        }
    }

    /** Commits only enabled visible identities before advancing to per-category decisions. */
    private func confirmSelection(_ identities: [AndroidDatabaseBackupCategory]) {
        selectedCategories = Set(identities)
        onConfirm()
    }
}

/**
 Presents Android's complete database restore/import AlertDialog sequence as app-owned UI.

 Inputs: one staged archive, parent apply state, and explicit dismiss/apply callbacks

 Output: section multiselect, sequential mode and overwrite dialogs, or shared hourglass progress

 Side effects: mutates only the local pure coordinator until emitting one owner apply batch

 Failure modes: no supported sections show Android's unsuccessful-restore message; busy state
 prevents dismissal and duplicate application
 */
struct AndroidDatabaseBackupImportDialog: View {
    /// Active application scheme supplied to shared AppCompat dialog surfaces.
    @Environment(\.colorScheme) private var colorScheme

    /// Staged validated Android archive retained by the owner through apply completion.
    let archive: AndroidDatabaseBackupArchive

    /// Whether the owner is applying the emitted selection batch.
    let isApplying: Bool

    /// Owner cleanup and dismissal callback.
    let onDismiss: () -> Void

    /// Owner callback for one ordered, safe apply batch.
    let onApply: ([AndroidDatabaseBackupSelection]) -> Void

    /// Pure sequential dialog draft initialized from the staged archive.
    @State private var dialogState: AndroidDatabaseBackupDialogState

    /**
     Creates the app-owned Android restore/import dialog sequence.

     - Parameters:
       - archive: Staged validated Android database archive.
       - isApplying: Owner apply state controlling progress and dismissal.
       - onDismiss: Owner cleanup/dismiss callback.
       - onApply: Owner batch-apply callback.
     - Side effects: initializes only local dialog state.
     - Failure modes: Unsupported sections initialize the unavailable phase.
     */
    init(
        archive: AndroidDatabaseBackupArchive,
        isApplying: Bool,
        onDismiss: @escaping () -> Void,
        onApply: @escaping ([AndroidDatabaseBackupSelection]) -> Void
    ) {
        self.archive = archive
        self.isApplying = isApplying
        self.onDismiss = onDismiss
        self.onApply = onApply
        _dialogState = State(
            initialValue: AndroidDatabaseBackupDialogState(sections: archive.sections)
        )
    }

    /** Renders only the app-owned surface for the current Android restore phase. */
    var body: some View {
        ZStack {
            if isApplying {
                AndroidIndeterminateProgressDialog(
                    accessibilityIdentifier: "androidDatabaseBackupApplyProgressDialog"
                )
            } else {
                phaseContent
            }
        }
        .androidDialogAccessibilityIdentity(
            accessibilityIdentifier: "androidDatabaseBackupImportDialog"
        )
    }

    /** Maps each pure state-machine phase to the corresponding shared application component. */
    @ViewBuilder
    private var phaseContent: some View {
        switch dialogState.phase {
        case .unavailable:
            unavailableDialog
        case .sectionSelection:
            sectionSelectionDialog
        case .modeChoice(let category):
            modeChoiceDialog(for: category)
        case .overwriteConfirmation(let category):
            overwriteConfirmationDialog(for: category)
        case .readyToApply:
            AndroidIndeterminateProgressDialog(
                accessibilityIdentifier: "androidDatabaseBackupApplyProgressDialog"
            )
            .onAppear(perform: applyReadySelections)
        case .finished:
            Color.clear
                .accessibilityHidden(true)
        }
    }

    /** Android feedback shown when validation left no safely applicable database sections. */
    private var unavailableDialog: some View {
        AndroidDecisionDialog(
            title: "",
            message: String(
                localized: "restore_unsuccessfull",
                defaultValue: "Restore was unsuccessful"
            ),
            actions: [
                .init(
                    id: "okay",
                    title: String(localized: "okay", defaultValue: "OK"),
                    style: .normal,
                    perform: dismissIfIdle
                ),
            ],
            accessibilityIdentifier: "androidDatabaseBackupUnavailableDialog"
        )
    }

    /** Android's checked-by-default category multiselect, shown only for multiple valid sections. */
    private var sectionSelectionDialog: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidDatabaseBackupSectionDialog",
            allowsOutsideDismissal: true,
            onOutsideTap: dismissIfIdle
        ) {
            AndroidDatabaseBackupSectionDialogContent(
                sections: supportedSections,
                selectedCategories: $dialogState.selectedCategories,
                isBusy: isApplying,
                onCancel: dismissIfIdle,
                onConfirm: confirmSectionSelection
            )
        }
    }

    /** Builds Android's neutral Cancel, negative Import, and positive Restore decision dialog. */
    private func modeChoiceDialog(for category: AndroidDatabaseBackupCategory) -> some View {
        AndroidDecisionDialog(
            title: category.localizedBackupSectionName,
            message: String(
                format: String(
                    localized: "ask_restore_or_import",
                    defaultValue: "Database for %@ can be either restored (i.e. existing database is removed and selected database is loaded) or imported (selected database is imported into existing database). What do you want to do?"
                ),
                category.localizedBackupSectionName
            ),
            actions: [
                .init(
                    id: "cancel",
                    title: String(localized: "cancel"),
                    style: .normal,
                    placement: .neutral,
                    perform: skipCurrentCategory
                ),
                .init(
                    id: "import",
                    title: String(localized: "import2", defaultValue: "Import"),
                    style: .normal
                ) { chooseMode(.import) },
                .init(
                    id: "restore",
                    title: String(localized: "restore", defaultValue: "Restore"),
                    style: .normal
                ) { chooseMode(.restore) },
            ],
            accessibilityIdentifier: "androidDatabaseBackupModeDialog"
        )
    }

    /** Builds Android's separate `are_you_sure` overwrite confirmation for one Restore choice. */
    private func overwriteConfirmationDialog(
        for category: AndroidDatabaseBackupCategory
    ) -> some View {
        AndroidDecisionDialog(
            title: String(localized: "are_you_sure", defaultValue: "Are you sure?"),
            message: String(
                format: String(
                    localized: "overwrite_something",
                    defaultValue: "Overwrite %@?"
                ),
                category.localizedBackupSectionName
            ),
            actions: [
                .init(
                    id: "cancel",
                    title: String(localized: "cancel"),
                    style: .normal,
                    perform: skipCurrentCategory
                ),
                .init(
                    id: "okay",
                    title: String(localized: "okay", defaultValue: "OK"),
                    style: .normal,
                    perform: confirmOverwrite
                ),
            ],
            accessibilityIdentifier: "androidDatabaseBackupOverwriteDialog"
        )
    }

    /** Supported archive sections in the state machine's exact Android order. */
    private var supportedSections: [AndroidDatabaseBackupSection] {
        let categories = Set(dialogState.orderedSupportedCategories)
        return archive.sections.filter { categories.contains($0.category) }
    }

    /** Cancels and cleans up only while no owner apply operation is active. */
    private func dismissIfIdle() {
        guard !isApplying else { return }
        onDismiss()
    }

    /** Commits the category checkbox draft and advances to Android's first per-category prompt. */
    private func confirmSectionSelection() {
        guard !isApplying else { return }
        handle(dialogState.confirmSectionSelection())
    }

    /** Records one safe mode decision and advances the pure coordinator. */
    private func chooseMode(_ mode: AndroidDatabaseBackupApplyMode) {
        guard !isApplying else { return }
        handle(dialogState.chooseMode(mode))
    }

    /** Skips only the current Android database category. */
    private func skipCurrentCategory() {
        guard !isApplying else { return }
        handle(dialogState.skipCurrentCategory())
    }

    /** Records confirmed Restore for the current category. */
    private func confirmOverwrite() {
        guard !isApplying else { return }
        handle(dialogState.confirmOverwrite())
    }

    /** Emits the final batch exactly once when the ready/progress phase becomes visible. */
    private func applyReadySelections() {
        guard !isApplying else { return }
        handle(dialogState.takeReadyOutcome())
    }

    /** Routes pure state outcomes to the two owner callbacks without embedding service work. */
    private func handle(_ outcome: AndroidDatabaseBackupDialogState.Outcome) {
        switch outcome {
        case .awaitingInput:
            break
        case .dismiss:
            onDismiss()
        case .apply(let selections):
            guard !selections.isEmpty else {
                onDismiss()
                return
            }
            onApply(selections)
        }
    }
}
