import SwiftUI

/// Top-level header layouts shown above the focused reader pane.
enum BibleReaderDocumentHeaderMode: Equatable {
    case myNotes
    case studyPad(title: String)
    case androidMulti(title: String, subtitle: String)
    case auxiliary(title: String, subtitle: String?, browseSystemImageName: String)
    case bible(title: String, subtitle: String, hasPrevious: Bool, hasNext: Bool)
}

/**
 Renders the reader document header without owning reader state.

 The parent coordinator supplies resolved titles, button enablement, and callbacks. Every document
 mode invokes the same injected Android action cluster; contextual modes retain their Back and
 browse controls beside it. This keeps the iPad-sensitive conditional header tree out of
 `BibleReaderView` while preserving the explicit branch type-erasure that avoided the device-only
 header crash tracked in issue #11.
 */
struct BibleReaderDocumentHeader<ToolbarActions: View>: View {
    private let mode: BibleReaderDocumentHeaderMode
    private let currentReference: String
    private let avoidanceInsets: EdgeInsets
    private let surfacePalette: ReaderThemeSurfacePalette
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
        surfacePalette: ReaderThemeSurfacePalette = .standard,
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
        self.surfacePalette = surfacePalette
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
            .foregroundStyle(surfacePalette.toolbarForegroundColor)
            .background(surfacePalette.toolbarBackgroundColor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("readerDocumentHeader")
        }
    }

    private var content: AnyView {
        switch mode {
        case .myNotes:
            return AnyView(myNotesHeader)
        case .studyPad(let title):
            return AnyView(studyPadHeader(title: title))
        case .androidMulti(let title, let subtitle):
            return AnyView(androidMultiHeader(title: title, subtitle: subtitle))
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

    /**
     Renders Android's main-toolbar shape for `FakeBookFactory.multiDocument` pages.

     The `Multi` page is technically a general book, but Android does not use the general-book
     back/browse header for Strong's and multi-reference result windows. It keeps the drawer and
     reader action icons visible while showing the first child reference as the title.
     */
    private func androidMultiHeader(title: String, subtitle: String) -> some View {
        Group {
            readerNavigationDrawerButton

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(surfacePalette.toolbarSecondaryForegroundColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("readerAndroidMultiTitle")

            toolbarActions()
                .layoutPriority(1)
        }
    }

    /**
     Renders My Notes navigation together with the shared reader actions.

     The Back control and title remain native header context while the injected action cluster
     preserves Android's direct Bible/commentary switching from the My Notes page. The header owns
     no navigation state; button effects and missing-controller handling remain parent-owned.
     */
    private var myNotesHeader: some View {
        Group {
            Button(action: onReturnFromMyNotes) {
                backToBibleLabel
                    .frame(minWidth: 80, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "back_to_bible"))
            .accessibilityIdentifier("readerReturnFromMyNotesButton")
            .layoutPriority(2)

            Spacer()

            Text(String(localized: "my_notes"))
                .font(.headline)
                .accessibilityIdentifier("readerMyNotesTitle")

            Spacer()
            toolbarActions()
                .layoutPriority(1)
        }
    }

    /**
     Renders StudyPad navigation together with the shared reader actions.

     The Back control and StudyPad title remain available while the injected cluster preserves
     Android's direct document switching. The parent owns every resulting navigation side effect;
     an unavailable controller leaves its supplied actions disabled.
     */
    private func studyPadHeader(title: String) -> some View {
        Group {
            Button(action: onReturnFromStudyPad) {
                backToBibleLabel
            }
            .accessibilityLabel(String(localized: "back_to_bible"))
            .accessibilityIdentifier("readerReturnFromStudyPadButton")
            .layoutPriority(2)

            Spacer()

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier("readerStudyPadTitle")

            Spacer()
            toolbarActions()
                .layoutPriority(1)
        }
    }

    /**
     Renders an auxiliary document's Back, title, browser, and shared reader actions.

     - Parameters:
       - title: Active dictionary, general-book, map, or EPUB title.
       - subtitle: Optional exact key or page title.
       - browseSystemImageName: System icon for the category-specific browser.
     - Returns: Contextual auxiliary navigation that also preserves Android's direct document
       switching actions.
     - Side effects: Delegates Back, browse, and toolbar actions to parent-owned callbacks.
     - Failure modes: None; missing destinations are handled by the supplied callbacks.
     */
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
            .layoutPriority(2)

            Spacer()

            VStack(spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(surfacePalette.toolbarSecondaryForegroundColor)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onBrowseAuxiliary) {
                Image(systemName: browseSystemImageName)
                    .font(.body)
            }
            .layoutPriority(2)

            toolbarActions()
                .layoutPriority(1)
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
                    .foregroundStyle(
                        hasPrevious
                            ? surfacePalette.toolbarForegroundColor
                            : surfacePalette.toolbarDisabledForegroundColor
                    )
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
                        .foregroundStyle(surfacePalette.toolbarSecondaryForegroundColor)
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
                    .foregroundStyle(
                        hasNext
                            ? surfacePalette.toolbarForegroundColor
                            : surfacePalette.toolbarDisabledForegroundColor
                    )
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
                .foregroundStyle(surfacePalette.navigationDrawerColor)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .fixedSize()
        .layoutPriority(2)
        .accessibilityIdentifier("readerNavigationDrawerButton")
        .accessibilityLabel(localizedDrawerString("main_menu", default: "Main menu"))
    }

    private func localizedDrawerString(_ key: String, default defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}
