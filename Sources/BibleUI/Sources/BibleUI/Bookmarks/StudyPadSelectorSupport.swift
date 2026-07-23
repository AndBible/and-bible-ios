// StudyPadSelectorSupport.swift -- Android Study Pad selector presentation components

import BibleCore
import SwiftUI

/// Android `ManageLabels.SearchMode` ordinals persisted by both platforms.
enum StudyPadSelectorSearchMode: Int, CaseIterable, Hashable {
    case nameStart
    case nameContains
    case content

    /// Localized popup-row title from Android resources.
    var localizedTitle: String {
        switch self {
        case .nameStart:
            String(localized: "search_mode_name_start", defaultValue: "Name (from start)")
        case .nameContains:
            String(localized: "search_mode_name_contains", defaultValue: "Name (contains)")
        case .content:
            String(localized: "search_mode_content", defaultValue: "Content")
        }
    }

    /// Exact compact text from Android's untranslated search-mode resources.
    var compactTitle: String {
        switch self {
        case .nameStart: "Ab*"
        case .nameContains: "*ab*"
        case .content: "📄"
        }
    }

    /// Android fills name-contains and content modes with `blue_200`.
    var isVisuallyActive: Bool { self != .nameStart }
}

/// Mutually exclusive popup menus owned by the Study Pad selector.
enum StudyPadSelectorPopup: Hashable {
    case searchMode
    case overflow
}

/**
 App-owned Android multiselect dialog for Study Pad export labels.

 The dialog uses the same `AndroidCheckboxRow` and `AndroidDialogWindow` as other management
 surfaces. Selection includes Android's Unlabelled label because the Android export command starts
 from all `assignableLabels`, unlike the normal Study Pad selector list.
 */
struct StudyPadExportSelectionDialog: View {
    let labels: [BibleCore.Label]
    @Binding var selectedLabelIDs: Set<UUID>
    let isExporting: Bool
    let onCancel: () -> Void
    let onExport: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "studyPadExportSelectionDialog",
            allowsOutsideDismissal: !isExporting,
            onOutsideTap: onCancel
        ) {
            AndroidMultiselectDialogContent(
                title: String(
                    format: String(localized: "export_something", defaultValue: "Export %@"),
                    String(localized: "studypads", defaultValue: "Study Pads")
                ),
                rows: labels.map { label in
                    AndroidMultiselectDialogRow(
                        id: label.id,
                        title: AndroidLabelPresentation.displayName(for: label),
                        accessibilityIdentifier: "studyPadExportLabel::\(label.id.uuidString)"
                    )
                },
                selectedIDs: $selectedLabelIDs,
                isBusy: isExporting,
                accessibilityIdentifier: "studyPadExportSelectionDialogContent",
                accessibilityPrefix: "studyPadExport",
                onCancel: onCancel,
                onConfirm: { _ in onExport() }
            )
        }
    }
}

/** App-owned Android confirmation dialog for an inspected Study Pad import. */
struct StudyPadImportConfirmationDialog: View {
    let summary: AndroidStudyPadArchiveSummary
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "studyPadImportConfirmationDialog",
            allowsOutsideDismissal: !isImporting,
            onOutsideTap: onCancel
        ) {
            AndroidDialogScaffold(
                title: String(
                    format: String(localized: "import_items", defaultValue: "Import %@"),
                    String(localized: "studypads", defaultValue: "Study Pads")
                )
            ) {
                Text(String(
                    format: String(
                        localized: "studypad_import_summary_format",
                        defaultValue: "%1$d labels, %2$d Bible bookmarks, %3$d document bookmarks, %4$d text entries"
                    ),
                    summary.labelCount,
                    summary.bibleBookmarkCount,
                    summary.genericBookmarkCount,
                    summary.textEntryCount
                ))
                .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "cancel"),
                    isEnabled: !isImporting,
                    action: onCancel
                )
                AndroidDialogTextAction(
                    title: String(localized: "import"),
                    isEnabled: !isImporting,
                    accessibilityIdentifier: "studyPadImportConfirmButton",
                    action: onImport
                )
            }
        }
    }
}

/** Android's normal 40dp Study Pad label row. */
struct StudyPadSelectorLabelRow: View {
    let label: BibleCore.Label
    let isActive: Bool
    let surfacePalette: ReaderThemeSurfacePalette
    let onOpen: () -> Void
    let onEdit: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                AndBibleIconView(name: "LabelTag", size: 24)
                    .foregroundStyle(Color(argbInt: label.color))
                    .frame(width: 26)

                Text(AndroidLabelPresentation.displayName(for: label))
                    .font(.system(size: 18, weight: isActive ? .bold : .regular))
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .lineLimit(1)

                Spacer()

                if let customIcon = label.customIcon {
                    AndroidLabelIconView(name: customIcon, size: 20)
                        .foregroundStyle(Color(argbInt: label.color))
                }
            }
            .frame(minHeight: 40)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture().onEnded { _ in onEdit() })
        .accessibilityIdentifier("studyPadSelectorRow::\(label.id.uuidString)")
        .accessibilityLabel(AndroidLabelPresentation.displayName(for: label))
    }
}

/** Android's 60dp grouped Study Pad content-search result row. */
struct StudyPadSelectorContentResultRow: View {
    let result: StudyPadContentSearchResult
    let surfacePalette: ReaderThemeSurfacePalette
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                AndBibleIconView(name: "LabelTag", size: 24)
                    .foregroundStyle(Color(argbInt: result.labelColor))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(result.labelName)
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(1)
                        Spacer()
                        Text(matchCountText)
                            .font(.system(size: 13))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    }

                    if let firstMatch = result.matches.first {
                        Text(highlightedSnippet(firstMatch))
                            .font(.system(size: 13).italic())
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            .lineLimit(2)
                    }
                }
            }
            .frame(minHeight: 60, alignment: .top)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(surfacePalette.foregroundColor)
        .accessibilityIdentifier("studyPadContentResult::\(result.labelID.uuidString)")
    }

    /// Android singular/plural match-count copy.
    private var matchCountText: String {
        if result.matchCount == 1 {
            return String(localized: "search_results_match", defaultValue: "1 match")
        }
        return String(
            format: String(localized: "search_results_matches", defaultValue: "%d matches"),
            result.matchCount
        )
    }

    /// Applies Android's `yellow_200` first-match background highlight.
    private func highlightedSnippet(_ match: StudyPadContentMatch) -> AttributedString {
        var attributed = AttributedString(match.textSnippet)
        guard match.matchStart >= 0,
              match.matchEnd >= match.matchStart,
              match.matchEnd <= match.textSnippet.utf16.count else {
            return attributed
        }
        let stringStart = String.Index(utf16Offset: match.matchStart, in: match.textSnippet)
        let stringEnd = String.Index(utf16Offset: match.matchEnd, in: match.textSnippet)
        guard let attributedStart = AttributedString.Index(stringStart, within: attributed),
              let attributedEnd = AttributedString.Index(stringEnd, within: attributed) else {
            return attributed
        }
        attributed[attributedStart..<attributedEnd].backgroundColor = Color(
            argbInt: Int(Int32(bitPattern: 0xFFFFF59D))
        )
        return attributed
    }
}
