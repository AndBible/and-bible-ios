// AndroidChapterReadHistoryDialog.swift -- Shared Android ReadHistoryDialog presentation

import BibleCore
import SwiftUI

/**
 Identifies the three selections accepted by Android `ReadHistoryDialog`.

 Reading Progress opens book and day selections while the Bible reader bridge opens a fixed chapter.
 Keeping selection and filtering in one semantic model guarantees every entry point uses the same
 current-cycle rows, localized subject, chapter-reference policy, and staged-delete dialog.

 Inputs: captured chapter, book, or local-day identity

 Output: immutable query semantics for `AndroidReadHistoryDialog`

 Side effects: none

 Failure modes: invalid stored KJVA identities have already been quarantined by `ReadingProgressStore`
 */
enum AndroidReadHistorySelection: Equatable {
    /// A single chapter launched from the reader or a chapter heatmap long press.
    case chapter(ChapterReadHistoryTarget)

    /// Every chapter in one KJVA book for the active cycle.
    case book(kjvBookOrdinal: Int, longName: String)

    /// Every chapter read during one captured local calendar day.
    case day(startMilliseconds: Int64)

    /// Android shows chapter references only when the selection can span multiple chapters.
    var showsChapterReference: Bool {
        if case .chapter = self { return false }
        return true
    }

    /**
     Resolves Android's subject inserted into `reading_progress_history_for`.

     - Returns: short chapter reference, long book name, or device-local short date.
     - Side effects: none.
     - Failure modes: invalid chapter identity falls back to the captured book name.
     */
    var localizedSubject: String {
        switch self {
        case .chapter(let target):
            let shortName = ReadingProgressKJVAIdentity(
                androidKJVBookOrdinal: target.kjvBookOrdinal,
                chapter: target.chapter
            )?.book.shortName ?? target.bookName
            return "\(shortName) \(target.chapter)"
        case .book(_, let longName):
            return longName
        case .day(let startMilliseconds):
            return Self.subjectDateFormatter.string(
                from: AndroidTimestamp.date(from: startMilliseconds)
            )
        }
    }

    /**
     Filters current-cycle history using Android's chapter, book, or local-day query semantics.

     - Parameter store: Captured reader progress store.
     - Returns: newest-first matching rows.
     - Side effects: reads one normalized store snapshot.
     - Failure modes: a missing store returns an empty collection.
     */
    func rows(in store: ReadingProgressStore?) -> [ReadingProgressHistoryRow] {
        guard let store else { return [] }
        switch self {
        case .chapter(let target):
            return store.chapterReadHistory(
                kjvBookOrdinal: target.kjvBookOrdinal,
                chapter: target.chapter
            )
        case .book(let kjvBookOrdinal, _):
            return store.presentation(recentLimit: .max).recentRows.filter {
                $0.kjvBookOrdinal == kjvBookOrdinal
            }
        case .day(let startMilliseconds):
            let calendar = Calendar.current
            let start = calendar.startOfDay(
                for: AndroidTimestamp.date(from: startMilliseconds)
            )
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return store.presentation(recentLimit: .max).recentRows.filter {
                let readDate = AndroidTimestamp.date(from: $0.readAt)
                return readDate >= start && readDate < end
            }
        }
    }

    /// Device-local short date format used by Android's subject line.
    private static let subjectDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

/**
 Renders Android's book/day/chapter Read History `AlertDialog` as an app-owned window.

 Rows reproduce Android's two-line formatting and ×/↶ staged-delete behavior. Deletions are applied
 once, atomically, when the user taps OK, taps outside, or the captured dialog disappears because its
 owner closes. The dialog intentionally has no navigation stack, native list, sheet, or material.

 Inputs: captured progress store and selection plus dismissal/change callbacks

 Output: centered shared Android dialog containing at most sixty percent-height history content

 Side effects: stages row IDs locally; dialog dismissal persists them through one store transaction

 Failure modes: persistence failure keeps the dialog open, preserves staged IDs, and presents the
 shared error decision dialog so the user can retry dismissal
 */
struct AndroidReadHistoryDialog: View {
    /// Captured store belonging to the originating pane.
    let store: ReadingProgressStore?

    /// Captured Android selection.
    let selection: AndroidReadHistorySelection

    /// Owner dismissal callback.
    let onDismiss: () -> Void

    /// Optional refresh callback after a successful mutation.
    let onChanged: (() -> Void)?

    /// Active scheme used by the shared AppCompat dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Row IDs toggled to Android's pending-delete appearance.
    @State private var pendingDeleteIDs: Set<UUID> = []

    /// Persistence failure shown above the still-open history window.
    @State private var persistenceFailure = false

    /**
     Creates one captured Read History dialog.

     - Parameters:
       - store: Originating pane's progress store.
       - selection: Chapter, book, or local day selected by the user.
       - onDismiss: Owner command that removes the dialog.
       - onChanged: Optional activity refresh after rows are removed.
     - Side effects: none until a row or dismissal command is tapped.
     - Failure modes: none during construction.
     */
    init(
        store: ReadingProgressStore?,
        selection: AndroidReadHistorySelection,
        onDismiss: @escaping () -> Void,
        onChanged: (() -> Void)? = nil
    ) {
        self.store = store
        self.selection = selection
        self.onDismiss = onDismiss
        self.onChanged = onChanged
    }

    var body: some View {
        ZStack {
            AndroidDialogWindow(
                colorScheme: colorScheme,
                accessibilityIdentifier: "androidReadHistoryDialog",
                allowsOutsideDismissal: !persistenceFailure,
                onOutsideTap: commitAndDismiss
            ) {
                dialogContent
            }

            if persistenceFailure {
                AndroidDecisionDialog(
                    title: String(
                        localized: "reading_progress_save_failed",
                        defaultValue: "Unable to save progress"
                    ),
                    message: String(
                        localized: "reading_progress_save_failed_message",
                        defaultValue: "Your existing progress was left unchanged. Try again."
                    ),
                    actions: [
                        .init(
                            id: "okay",
                            title: String(localized: "okay", defaultValue: "OK"),
                            style: .normal
                        ) {
                            persistenceFailure = false
                        },
                    ],
                    accessibilityIdentifier: "androidReadHistorySaveFailureDialog"
                )
            }
        }
        .onDisappear {
            _ = commitPendingDeletes()
        }
    }

    /// AppCompat dialog title, scrollable rows, and positive action.
    private var dialogContent: some View {
        let rows = selection.rows(in: store)
        return VStack(alignment: .leading, spacing: 12) {
            Text(dialogTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            AndroidAdaptiveDialogScrollView {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty {
                        Text(String(
                            localized: "reading_progress_history_no_entries",
                            defaultValue: "No read entries for this selection."
                        ))
                        .font(.system(size: 14))
                        .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        ForEach(rows, id: \.id) { row in
                            historyRow(row)
                            Divider()
                                .overlay(AndroidDialogSurfacePalette.secondaryText(for: colorScheme).opacity(0.3))
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(
                    String(localized: "okay", defaultValue: "OK"),
                    action: commitAndDismiss
                )
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                .buttonStyle(.plain)
                .accessibilityIdentifier("androidReadHistoryDialogOKButton")
            }
        }
        .padding(22)
        .frame(maxWidth: 560)
    }

    /// Localized title matching Android `reading_progress_history_for` formatting.
    private var dialogTitle: String {
        String(
            format: String(
                localized: "reading_progress_history_for",
                defaultValue: "Reading progress for %@"
            ),
            selection.localizedSubject
        )
    }

    /** Builds one exact two-line Android history row with staged delete/undo treatment. */
    private func historyRow(_ row: ReadingProgressHistoryRow) -> some View {
        let isPending = pendingDeleteIDs.contains(row.id)
        return HStack(spacing: 8) {
            AndroidReadHistoryRowText(
                row: row,
                showsChapterReference: selection.showsChapterReference
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if isPending {
                    pendingDeleteIDs.remove(row.id)
                } else {
                    pendingDeleteIDs.insert(row.id)
                }
            } label: {
                Text(isPending ? "↶" : "×")
                    .font(.system(size: 24))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                isPending
                    ? Color(argbInt: Int(Int32(bitPattern: AndroidReadingProgressHeatmap.chapterMaximumARGB)))
                    : AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
            )
            .accessibilityLabel(
                isPending
                    ? String(localized: "undo", defaultValue: "Undo")
                    : String(localized: "delete", defaultValue: "Delete")
            )
            .accessibilityIdentifier("androidReadHistoryDelete::\(row.id.uuidString)")
        }
        .padding(.vertical, 4)
        .opacity(isPending ? 0.45 : 1)
    }

    /// Persists the current staged set and removes the owner-held dialog only after success.
    private func commitAndDismiss() {
        guard commitPendingDeletes() else { return }
        onDismiss()
    }

    /**
     Applies Android's complete staged-delete set through one store save.

     - Returns: `true` when dismissal may continue.
     - Side effects: may persist history, clear staged IDs, and notify the activity owner.
     - Failure modes: returns false and raises the error dialog when persistence throws.
     */
    @discardableResult
    private func commitPendingDeletes() -> Bool {
        guard !pendingDeleteIDs.isEmpty else { return true }
        guard let store else {
            pendingDeleteIDs.removeAll()
            return true
        }
        do {
            let removedCount = try store.deleteHistoryEntries(ids: pendingDeleteIDs)
            pendingDeleteIDs.removeAll()
            if removedCount > 0 { onChanged?() }
            return true
        } catch {
            persistenceFailure = true
            return false
        }
    }
}

/**
 Formats one Android Read History row independently of the dialog selection and mutation state.

 Fixed-chapter rows display date/time above the source module. Book/day rows display the KJVA
 chapter reference and time above date/module, exactly matching Android `ReadHistoryDialog`.
 */
private struct AndroidReadHistoryRowText: View {
    /// Persisted history row.
    let row: ReadingProgressHistoryRow

    /// Whether the selection can span chapters.
    let showsChapterReference: Bool

    /// Active AppCompat DayNight appearance for implicit Android `TextView` text.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(primaryText)
                .font(.system(size: 16))
                .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
            Text(secondaryText)
                .font(.system(size: 12))
                .foregroundStyle(AndroidResourcePalette.gray)
        }
    }

    /// Android primary row content for a broad or fixed-chapter selection.
    private var primaryText: String {
        if showsChapterReference {
            return "\(row.androidDisplayReference) · \(timeText)"
        }
        return "\(dateText) \(timeText)"
    }

    /// Android secondary row content for a broad or fixed-chapter selection.
    private var secondaryText: String {
        showsChapterReference ? "\(dateText) · \(versionText)" : versionText
    }

    /// Device-local short date used by Android `DateFormat.getDateFormat`.
    private var dateText: String { Self.dateFormatter.string(from: readDate) }

    /// Device-local short time used by Android `DateFormat.getTimeFormat`.
    private var timeText: String { Self.timeFormatter.string(from: readDate) }

    /// Stored module initials or Android's localized unknown-version fallback.
    private var versionText: String {
        row.androidDisplayVersion ?? String(
            localized: "reading_progress_history_version_unknown",
            defaultValue: "Unknown version"
        )
    }

    /// Persisted epoch milliseconds converted for device formatters.
    private var readDate: Date { AndroidTimestamp.date(from: row.readAt) }

    /// Shared device-local short date formatter.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    /// Shared device-local short time formatter.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/**
 Preserves the reader bridge's fixed-chapter entry point while delegating all presentation and
 mutation behavior to the shared three-selection Android dialog.
 */
struct AndroidChapterReadHistoryDialog: View {
    let store: ReadingProgressStore?
    let target: ChapterReadHistoryTarget
    let onDismiss: () -> Void

    var body: some View {
        AndroidReadHistoryDialog(
            store: store,
            selection: .chapter(target),
            onDismiss: onDismiss
        )
    }
}
