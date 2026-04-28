import SwiftUI

/// Top-level header layouts shown above the focused reader pane.
enum BibleReaderDocumentHeaderMode: Equatable {
    case myNotes
    case studyPad(title: String)
    case auxiliary(title: String, subtitle: String?, browseSystemImageName: String)
    case bible(title: String, subtitle: String, hasPrevious: Bool, hasNext: Bool)
}

/**
 Renders the reader document header without owning reader state.

 The parent coordinator supplies resolved titles, button enablement, and callbacks. This keeps the
 iPad-sensitive conditional header tree out of `BibleReaderView` while preserving the explicit
 branch type-erasure that avoided the device-only header crash tracked in issue #11.
 */
struct BibleReaderDocumentHeader<ToolbarActions: View>: View {
    private let mode: BibleReaderDocumentHeaderMode
    private let currentReference: String
    private let avoidanceInsets: EdgeInsets
    private let onOpenNavigationDrawer: () -> Void
    private let onNavigatePrevious: () -> Void
    private let onShowBookChooser: () -> Void
    private let onNavigateNext: () -> Void
    private let onReturnFromMyNotes: () -> Void
    private let onReturnFromStudyPad: () -> Void
    private let onReturnFromAuxiliary: () -> Void
    private let onBrowseAuxiliary: () -> Void
    private let toolbarActions: () -> ToolbarActions

    init(
        mode: BibleReaderDocumentHeaderMode,
        currentReference: String,
        avoidanceInsets: EdgeInsets,
        onOpenNavigationDrawer: @escaping () -> Void,
        onNavigatePrevious: @escaping () -> Void,
        onShowBookChooser: @escaping () -> Void,
        onNavigateNext: @escaping () -> Void,
        onReturnFromMyNotes: @escaping () -> Void,
        onReturnFromStudyPad: @escaping () -> Void,
        onReturnFromAuxiliary: @escaping () -> Void,
        onBrowseAuxiliary: @escaping () -> Void,
        @ViewBuilder toolbarActions: @escaping () -> ToolbarActions
    ) {
        self.mode = mode
        self.currentReference = currentReference
        self.avoidanceInsets = avoidanceInsets
        self.onOpenNavigationDrawer = onOpenNavigationDrawer
        self.onNavigatePrevious = onNavigatePrevious
        self.onShowBookChooser = onShowBookChooser
        self.onNavigateNext = onNavigateNext
        self.onReturnFromMyNotes = onReturnFromMyNotes
        self.onReturnFromStudyPad = onReturnFromStudyPad
        self.onReturnFromAuxiliary = onReturnFromAuxiliary
        self.onBrowseAuxiliary = onBrowseAuxiliary
        self.toolbarActions = toolbarActions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                content
            }
            .padding(.top, 8 + avoidanceInsets.top)
            .padding(.bottom, 8)
            .padding(.leading, 16 + avoidanceInsets.leading)
            .padding(.trailing, 16)
            .background(.bar)
        }
    }

    private var content: AnyView {
        switch mode {
        case .myNotes:
            return AnyView(myNotesHeader)
        case .studyPad(let title):
            return AnyView(studyPadHeader(title: title))
        case .auxiliary(let title, let subtitle, let browseSystemImageName):
            return AnyView(auxiliaryHeader(
                title: title,
                subtitle: subtitle,
                browseSystemImageName: browseSystemImageName
            ))
        case .bible(let title, let subtitle, let hasPrevious, let hasNext):
            return AnyView(bibleHeader(
                title: title,
                subtitle: subtitle,
                hasPrevious: hasPrevious,
                hasNext: hasNext
            ))
        }
    }

    private var myNotesHeader: some View {
        Group {
            Button(action: onReturnFromMyNotes) {
                backToBibleLabel
            }
            .accessibilityLabel(String(localized: "back_to_bible"))
            .accessibilityIdentifier("readerReturnFromMyNotesButton")

            Spacer()

            Text(String(localized: "my_notes"))
                .font(.headline)
                .accessibilityIdentifier("readerMyNotesTitle")

            Spacer()
            Color.clear.frame(width: 80, height: 1)
        }
    }

    private func studyPadHeader(title: String) -> some View {
        Group {
            Button(action: onReturnFromStudyPad) {
                backToBibleLabel
            }
            .accessibilityLabel(String(localized: "back_to_bible"))

            Spacer()

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier("readerStudyPadTitle")

            Spacer()
            Color.clear.frame(width: 80, height: 1)
        }
    }

    private func auxiliaryHeader(
        title: String,
        subtitle: String?,
        browseSystemImageName: String
    ) -> some View {
        Group {
            Button(action: onReturnFromAuxiliary) {
                backToBibleLabel
            }
            .accessibilityLabel(String(localized: "back_to_bible"))

            Spacer()

            VStack(spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onBrowseAuxiliary) {
                Image(systemName: browseSystemImageName)
                    .font(.body)
            }
        }
    }

    private func bibleHeader(
        title: String,
        subtitle: String,
        hasPrevious: Bool,
        hasNext: Bool
    ) -> some View {
        Group {
            readerNavigationDrawerButton

            Button(action: onNavigatePrevious) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(hasPrevious ? .primary : .tertiary)
            }
            .disabled(!hasPrevious)
            .accessibilityLabel(String(localized: "previous_chapter"))

            Button(action: onShowBookChooser) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("bookChooserButton")
            .accessibilityValue("\(title), \(subtitle)")

            Button(action: onNavigateNext) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(hasNext ? .primary : .tertiary)
            }
            .disabled(!hasNext)
            .accessibilityLabel(String(localized: "next_chapter"))

            toolbarActions()
                .layoutPriority(1)
        }
    }

    private var backToBibleLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
            Text(currentReference)
                .font(.subheadline)
        }
    }

    private var readerNavigationDrawerButton: some View {
        Button(action: onOpenNavigationDrawer) {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("readerNavigationDrawerButton")
        .accessibilityLabel(localizedDrawerString("main_menu", default: "Main menu"))
    }

    private func localizedDrawerString(_ key: String, default defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}
