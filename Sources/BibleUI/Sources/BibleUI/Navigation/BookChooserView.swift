// BookChooserView.swift — Book selection grid

import SwiftUI
import BibleCore
import SwiftData
import SwordKit

/** Stable layout anchor identities for the app-owned passage chooser popup. */
private enum PassageChooserPopupAnchor {
    /// Top-app-bar overflow button used by Android's chooser options menu.
    static let overflow = "passageChooserOverflowAnchor"
}

/**
 Describes the next step after selecting a book in Android's passage chooser.

 Single-chapter books bypass the redundant chapter grid. Verse-oriented flows open chapter one's
 verse grid, while chapter-oriented flows immediately select chapter one.
 */
enum PassageBookSelectionDestination: Equatable, Sendable {
    /// Continue through the normal chapter grid.
    case chapterChooser

    /// Open the verse grid for the supplied chapter.
    case verseChooser(chapter: Int)

    /// Complete selection immediately with the supplied chapter and optional verse.
    case selection(chapter: Int, verse: Int?)

    /**
     Resolves Android's book-cell navigation shortcut.

     - Parameters:
       - book: Selected module-specific book metadata.
       - navigateToVerse: Whether the caller requires a verse result.
     - Returns: Direct chapter-one selection/verse routing for one-chapter books, otherwise the
       normal chapter chooser.
     - Side Effects: None.
     - Failure Modes: Non-positive chapter counts are treated as single-chapter metadata so the
       chooser never renders an empty chapter grid.
     */
    static func resolve(
        book: BookInfo,
        navigateToVerse: Bool
    ) -> PassageBookSelectionDestination {
        guard book.chapterCount <= 1 else { return .chapterChooser }
        if navigateToVerse {
            return .verseChooser(chapter: 1)
        }
        return .selection(chapter: 1, verse: nil)
    }
}

/**
 Grid-based chooser for selecting a book and then drilling down to chapter or verse.

 The chooser uses the active module's `BookInfo` list instead of a static canon, so modules with
 expanded canons surface their additional books automatically. Depending on `navigateToVerse`, the
 flow ends after chapter selection or adds a verse-selection step.

 The grid layout and colors mirror Android's `GridChoosePassageBook` and `ButtonGrid` defaults:
 standard 66-book canons render in a dense column-major portrait matrix, expanded canons use
 Android's dynamic matrix, and the current passage is highlighted with its book category color.

 Data dependencies:
 - `books` is the module-specific canon and chapter metadata provided by the caller
 - `currentBook`, `currentChapter`, and `currentVerse` are the reader's active location used only
   for Android-compatible highlighting
 - `workspaceName` is shown on the first chooser step to mirror Android's activity title context
 - `verseCountProvider` supplies module-specific `Versification.getLastVerse` equivalents when
   the chooser drills into verse selection; `nil` means the active module could not resolve the
   selected chapter and no synthetic verse list should be shown
 - `SettingsStore` supplies Android `BibleBookSortOrder` and `book_grid_*` option state
 - progress providers supply Android KJVA reading/memorization fractions for visible grid cells
 - `onCancel` lets custom drawer presenters close their own presentation state; without it the view
   falls back to SwiftUI's environment dismiss action for sheet/navigation-stack hosts

 Side effects:
 - tapping a book mutates local selection state to advance to the chapter step
 - tapping a chapter may either complete the flow or advance to the verse step
 - tapping toolbar back actions resets the local step state without dismissing the chooser
 - tapping overflow-menu rows persists Android-compatible chooser options in `SettingsStore`
 - tapping the deuterocanonical toolbar action toggles a view-local book scope, matching Android
 */
public struct BookChooserView: View {
    /// Dynamic book list derived from the active module's versification.
    let books: [BookInfo]

    /// Optional Android activity title supplied by specialized passage-selection flows.
    let selectionTitle: String?

    /// Whether the flow should include a verse chooser after chapter selection.
    let navigateToVerse: Bool

    /// Current reader book name, used to highlight the active book.
    let currentBook: String?

    /// Current reader chapter, used to highlight the active chapter in the active book.
    let currentChapter: Int?

    /// Current reader verse, used to highlight the active verse in the active chapter.
    let currentVerse: Int?

    /// Active workspace name appended to the first-step title for Android parity.
    let workspaceName: String?

    /// Provides the last verse number for a selected book/chapter.
    let verseCountProvider: (BookInfo, Int) -> Int?

    /// Provides Android KJVA progress for a book cell.
    let bookProgressProvider: (BookInfo) -> PassageGridProgress

    /// Provides Android KJVA progress for a chapter cell.
    let chapterProgressProvider: (BookInfo, Int) -> PassageGridProgress

    /// Provides Android KJVA progress for a verse cell.
    let verseProgressProvider: (BookInfo, Int, Int) -> PassageGridProgress

    /// Optional explicit cancellation callback for non-sheet presentations.
    let onCancel: (() -> Void)?

    /// Callback invoked when the user has completed the selection flow.
    let onSelect: (String, Int, Int?) -> Void

    /// Currently selected book, or `nil` while the grid step is visible.
    @State private var selectedBook: BookInfo?

    /// Currently selected chapter when the verse step is active.
    @State private var selectedChapter: Int?

    /// Android chooser overflow-menu state loaded from `SettingsStore`.
    @State private var chooserOptions = PassageChooserOptions.androidDefault

    /// Android scripture/non-scripture book scope for the current chooser presentation.
    @State private var bookScope = PassageBookScriptureScope.scripture

    /// Tracks first appearance so option state is not reloaded after in-view menu changes.
    @State private var hasLoadedChooserOptions = false

    /// Whether Android's book-chooser overflow popup is visible.
    @State private var isChooserMenuPresented = false

    /// Dismiss action for canceling the chooser flow.
    @Environment(\.dismiss) private var dismiss

    /// SwiftData context backing Android-compatible chooser option persistence.
    @Environment(\.modelContext) private var modelContext

    /**
     Creates a book chooser for a specific module canon.

     - Parameters:
       - books: Book list from the active module's versification.
       - selectionTitle: Optional activity title such as Speak's beginning/end prompts. A nil value
         preserves the standard localized `choose_book` title and workspace suffix.
       - navigateToVerse: Whether the flow should include verse selection.
       - currentBook: Current reader book name, used only for selector highlighting.
       - currentChapter: Current reader chapter, used only for selector highlighting.
       - currentVerse: Current reader verse, used only for selector highlighting.
       - workspaceName: Active workspace name appended to the first-step chooser title.
       - verseCountProvider: Optional provider for module-specific chapter verse counts. A missing
         provider keeps existing no-module callers functional by falling back to the static
         compatibility table.
       - bookProgressProvider: Optional provider for Android KJVA book-cell progress.
       - chapterProgressProvider: Optional provider for Android KJVA chapter-cell progress.
       - verseProgressProvider: Optional provider for Android KJVA verse-cell progress.
       - onCancel: Optional callback used by custom drawer hosts to close their presentation state.
       - onSelect: Callback receiving `(bookName, chapter, verse?)` when selection completes.
     */
    public init(
        books: [BookInfo],
        selectionTitle: String? = nil,
        navigateToVerse: Bool = false,
        currentBook: String? = nil,
        currentChapter: Int? = nil,
        currentVerse: Int? = nil,
        workspaceName: String? = nil,
        verseCountProvider: ((BookInfo, Int) -> Int?)? = nil,
        bookProgressProvider: ((BookInfo) -> PassageGridProgress)? = nil,
        chapterProgressProvider: ((BookInfo, Int) -> PassageGridProgress)? = nil,
        verseProgressProvider: ((BookInfo, Int, Int) -> PassageGridProgress)? = nil,
        onCancel: (() -> Void)? = nil,
        onSelect: @escaping (String, Int, Int?) -> Void
    ) {
        self.books = books
        self.selectionTitle = selectionTitle
        self.navigateToVerse = navigateToVerse
        self.currentBook = currentBook
        self.currentChapter = currentChapter
        self.currentVerse = currentVerse
        self.workspaceName = workspaceName
        self.verseCountProvider = verseCountProvider ?? { book, chapter in
            BibleReaderController.verseCount(for: book.name, chapter: chapter)
        }
        self.bookProgressProvider = bookProgressProvider ?? { _ in .none }
        self.chapterProgressProvider = chapterProgressProvider ?? { _, _ in .none }
        self.verseProgressProvider = verseProgressProvider ?? { _, _, _ in .none }
        self.onCancel = onCancel
        self.onSelect = onSelect
    }

    /**
     Builds Android's fixed-dark passage chooser without changing its enclosing reader window.

     Android hosts the chooser in a separately themed `GridChoosePassageTheme` activity and sets
     `allowThemeChange = false`. The SwiftUI equivalent injects `.dark` only into this view's
     environment, so chooser controls retain Android's palette while the parent reader continues
     observing the real system appearance.

     - Returns: The chooser app bar, active book/chapter/verse step, and anchored options popup.
     - Side effects: Loads persisted chooser options on first appearance; chooser actions can
       persist option changes and invoke the caller's selection or cancellation callbacks.
     - Failure modes: Missing optional progress providers render empty progress, and missing
       cancellation ownership falls back to SwiftUI's dismiss action.
     - Note: Do not replace the subtree environment with `preferredColorScheme`; that preference
       propagates to a navigation presentation boundary and corrupts System night-mode detection.
     */
    public var body: some View {
        VStack(spacing: 0) {
            PassageChooserAppBar(
                title: navigationTitle,
                showsOverflowButton: selectedBook == nil,
                deuterocanonicalToggleTitle: selectedBook == nil ? deuterocanonicalToggleTitle : nil,
                onBack: navigateBackOrCancel,
                onToggleDeuterocanonical: toggleDeuterocanonicalScope,
                onOverflow: {
                    isChooserMenuPresented.toggle()
                }
            )

            chooserStep
        }
        .background(PassageChooserSurfacePalette.background.swiftUIColor.ignoresSafeArea())
        .tint(.white)
        .onAppear { loadChooserOptionsIfNeeded() }
        .androidAnchoredPopupMenu(
            anchorID: PassageChooserPopupAnchor.overflow,
            isPresented: $isChooserMenuPresented,
            menuWidth: 340,
            estimatedMenuHeight: CGFloat(PassageChooserMenuEntry.androidBookChooserOrder.count) * 48,
            accessibilityIdentifier: "passageChooserOverflowPopup"
        ) {
            PassageChooserOverflowMenuPopup(options: chooserOptions) { option in
                applyChooserOption(option)
                isChooserMenuPresented = false
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .environment(\.colorScheme, .dark)
    }

    /**
     Builds the current chooser step: book grid, chapter grid, or verse grid.
     */
    @ViewBuilder
    private var chooserStep: some View {
        if let book = selectedBook {
            if navigateToVerse, let chapter = selectedChapter {
                VerseChooserView(
                    bookName: book.name,
                    osisBookId: book.osisId,
                    chapter: chapter,
                    verseCount: verseCountProvider(book, chapter) ?? 0,
                    currentVerse: currentVerseForSelectedContext(book: book, chapter: chapter),
                    rowOrder: chooserOptions.rowOrder,
                    progressProvider: { verse in
                        chooserOptions.showProgressBars
                            ? verseProgressProvider(book, chapter, verse)
                            : .none
                    }
                ) { verse in
                    onSelect(book.name, chapter, verse)
                }
            } else {
                ChapterChooserView(
                    bookName: book.name,
                    osisBookId: book.osisId,
                    chapterCount: book.chapterCount,
                    currentChapter: currentChapterForSelectedBook(book),
                    rowOrder: chooserOptions.rowOrder,
                    progressProvider: { chapter in
                        chooserOptions.showProgressBars
                            ? chapterProgressProvider(book, chapter)
                            : .none
                    }
                ) { chapter in
                    if navigateToVerse {
                        selectedChapter = chapter
                    } else {
                        onSelect(book.name, chapter, nil)
                    }
                }
            }
        } else {
            bookGrid
        }
    }

    /**
     Cancels the chooser through the host-provided callback when present.

     Custom drawer presentation is owned by `BibleReaderView`, so SwiftUI's environment dismiss
     action is not sufficient there. Sheet-based callers keep the legacy path by omitting
     `onCancel`, which delegates to the environment dismiss action.
     */
    private func cancelChooser() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    /**
     Navigates backward within the chooser or closes it from the first step.

     Android's chooser surfaces use a toolbar back arrow. Within this SwiftUI-hosted flow, the same
     affordance returns from verse to chapter, from chapter to book, and finally dismisses the
     reader-owned chooser presentation.
     */
    private func navigateBackOrCancel() {
        if isChooserMenuPresented {
            isChooserMenuPresented = false
        } else if selectedChapter != nil {
            selectedChapter = nil
        } else if selectedBook != nil {
            selectedBook = nil
            selectedChapter = nil
        } else {
            cancelChooser()
        }
    }

    /**
     Applies and persists one Android chooser-menu option.

     - Parameter option: Menu option selected by the user.
     - Side effects: Mutates local option state and writes Android-compatible settings.
     - Failure modes: SwiftData save errors are swallowed by `SettingsStore`.
     */
    private func applyChooserOption(_ option: PassageChooserMenuOption) {
        chooserOptions.apply(option)
        chooserOptions.persist(to: SettingsStore(modelContext: modelContext))
    }

    /**
     Toggles Android's session-local scripture/deuterocanonical book scope.

     Android invalidates the book chooser menu and rebuilds the grid without persisting this state.
     iOS mirrors that by mutating only view-local state and leaving the durable chooser options
     untouched.

     - Side effects: Hides the overflow popup and changes the visible book grid scope.
     - Failure modes: none.
     */
    private func toggleDeuterocanonicalScope() {
        isChooserMenuPresented = false
        bookScope.toggle()
    }

    /**
     Loads persisted chooser options on first appearance.

     - Side effects: Reads SwiftData through `SettingsStore` once per view lifetime.
     - Failure modes: Missing settings use Android defaults.
     */
    private func loadChooserOptionsIfNeeded() {
        guard !hasLoadedChooserOptions else {
            return
        }
        chooserOptions = PassageChooserOptions.from(settingsStore: SettingsStore(modelContext: modelContext))
        hasLoadedChooserOptions = true
    }

    /// Navigation title reflecting the current chooser step.
    private var navigationTitle: String {
        if let book = selectedBook, let chapter = selectedChapter {
            return "\(book.name) \(chapter)"
        }
        if let selectedBook {
            return selectedBook.name
        }

        if let selectionTitle, !selectionTitle.isEmpty {
            return selectionTitle
        }

        return PassageChooserTitle.bookSelectionTitle(
            baseTitle: String(localized: "choose_book"),
            workspaceName: workspaceName
        )
    }

    /// Active module books filtered through Android's current scripture/deuterocanonical scope.
    private var visibleBooks: [BookInfo] {
        PassageBookScriptureScope.books(from: books, scope: bookScope)
    }

    /// Whether Android would show the book chooser deuterocanonical action for this module.
    private var hasDeuterocanonicalBooks: Bool {
        PassageBookScriptureScope.hasDeuterocanonicalBooks(books)
    }

    /// Localized title for Android's `deut_toggle` action item, or `nil` when hidden.
    private var deuterocanonicalToggleTitle: String? {
        guard hasDeuterocanonicalBooks else {
            return nil
        }
        return NSLocalizedString(
            bookScope.androidToolbarLocalizationKey,
            value: bookScope.androidToolbarDefaultTitle,
            comment: ""
        )
    }

    /// Non-scrolling fill-the-screen container for the Android-aligned book grid.
    private var bookGrid: some View {
        GeometryReader { proxy in
            let orientation = PassageGridOrientation(size: proxy.size)
            let scopedBooks = visibleBooks
            let allowsCategoryGrouping = bookScope == .scripture
            let slots = PassageBookOrdering.displaySlots(
                for: scopedBooks,
                options: chooserOptions,
                orientation: orientation,
                allowsCategoryGrouping: allowsCategoryGrouping
            )
            let columnCount = max(
                PassageBookOrdering.columnCount(
                    itemCount: scopedBooks.count,
                    options: chooserOptions,
                    orientation: orientation,
                    allowsCategoryGrouping: allowsCategoryGrouping
                ),
                1
            )
            let metrics = PassageGridMetrics.fittedCells(
                availableSize: proxy.size,
                rows: PassageGridMetrics.rowCount(slotCount: slots.count, columns: columnCount),
                columns: columnCount
            )
            let columns = Array(
                repeating: GridItem(.fixed(metrics.cellWidth), spacing: PassageGridMetrics.spacing),
                count: columnCount
            )

            LazyVGrid(columns: columns, spacing: PassageGridMetrics.spacing) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, book in
                    if let book {
                        PassageGridButton(
                            title: PassageBookDisplayName.title(
                                for: book,
                                showLongName: chooserOptions.showLongBookName
                            ),
                            accessibilityLabel: book.name,
                            accessibilityIdentifier: "passageBookCell.\(book.osisId)",
                            palette: PassageGridCellPalette.bookPalette(
                                for: book,
                                currentOsisId: currentOsisBookId
                            ),
                            font: .subheadline.weight(.semibold),
                            progress: chooserOptions.showProgressBars
                                ? bookProgressProvider(book)
                                : .none,
                            cellWidth: metrics.cellWidth,
                            cellHeight: metrics.cellHeight
                        ) {
                            isChooserMenuPresented = false
                            switch PassageBookSelectionDestination.resolve(
                                book: book,
                                navigateToVerse: navigateToVerse
                            ) {
                            case .chapterChooser:
                                selectedBook = book
                                selectedChapter = nil
                            case .verseChooser(let chapter):
                                selectedBook = book
                                selectedChapter = chapter
                            case .selection(let chapter, let verse):
                                onSelect(book.name, chapter, verse)
                            }
                        }
                    } else {
                        Color.clear
                            .frame(width: metrics.cellWidth, height: metrics.cellHeight)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(width: metrics.gridWidth)
            .padding(.horizontal, PassageGridMetrics.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /**
     Resolves the current reader OSIS id against the active module's book list.

     - Returns: Current book OSIS id if it exists in the active module or static fallback table.
     */
    private var currentOsisBookId: String? {
        guard let currentBook else {
            return nil
        }
        if let book = books.first(where: { $0.name == currentBook || $0.osisId == currentBook }) {
            return book.osisId
        }
        return BibleReaderController.osisBookId(for: currentBook)
    }

    /**
     Returns the current chapter when the selected book matches the active reader book.

     - Parameter book: Book currently selected in the chooser flow.
     - Returns: Current chapter for matching books; otherwise `nil`.
     */
    private func currentChapterForSelectedBook(_ book: BookInfo) -> Int? {
        guard book.osisId == currentOsisBookId else {
            return nil
        }
        return currentChapter
    }

    /**
     Returns the current verse when the selected book and chapter match the active reader context.

     - Parameters:
       - book: Book currently selected in the chooser flow.
       - chapter: Chapter currently selected in the chooser flow.
     - Returns: Current verse for matching book/chapter contexts; otherwise `nil`.
     */
    private func currentVerseForSelectedContext(book: BookInfo, chapter: Int) -> Int? {
        guard book.osisId == currentOsisBookId, chapter == currentChapter else {
            return nil
        }
        return currentVerse
    }
}

/**
 Android-style app bar owned by the passage chooser content.

 Android's book/chapter/verse chooser uses activity-owned chrome with a back arrow, changing title,
 and a top-right menu only on the book grid. Rendering this as chooser content avoids depending on
 iOS navigation bars that the reader shell intentionally hides for its custom toolbar.
 */
private struct PassageChooserAppBar: View {
    /// Fixed Material toolbar height used by Android's passage chooser activity.
    static let height: CGFloat = 56

    /// Current chooser title, including workspace suffix on the book step.
    let title: String

    /// Whether the Android overflow menu should be available for the current chooser step.
    let showsOverflowButton: Bool

    /// Title for Android's separate scripture/deuterocanonical action item.
    let deuterocanonicalToggleTitle: String?

    /// Back action for stepping back within the chooser or closing it from the book grid.
    let onBack: () -> Void

    /// Action that toggles Android's scripture/deuterocanonical book scope.
    let onToggleDeuterocanonical: () -> Void

    /// Action that toggles Android's chooser option popup.
    let onOverflow: () -> Void

    /// Renders the chooser-owned app bar.
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 52, height: Self.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "back", defaultValue: "Back"))
            .accessibilityIdentifier("passageChooserBackButton")

            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("passageChooserTitle")

            if showsOverflowButton,
               let deuterocanonicalToggleTitle {
                Button(action: onToggleDeuterocanonical) {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 52, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(deuterocanonicalToggleTitle)
                .accessibilityIdentifier("passageChooserDeuterocanonicalToggleButton")
            }

            if showsOverflowButton {
                Button(action: onOverflow) {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 52, height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "more_options", defaultValue: "More options"))
                .accessibilityIdentifier("passageChooserOverflowButton")
                .androidPopupMenuAnchor(id: PassageChooserPopupAnchor.overflow)
            } else {
                Color.clear
                    .frame(width: 52, height: Self.height)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: Self.height)
        .foregroundStyle(Color.white)
        .background(PassageChooserSurfacePalette.toolbarBackground.swiftUIColor)
        .accessibilityIdentifier("passageChooserAppBar")
    }
}

/**
 Android-style popup surface for passage book chooser menu actions.

 The Android chooser uses a dark overflow popup with text on the left and checkboxes on the right.
 SwiftUI's native `Menu` renders platform command rows and left-side symbols, so this view keeps
 the passage selector visually aligned with Android while delegating all behavior to
 `PassageChooserOptions`.
 */
private struct PassageChooserOverflowMenuPopup: View {
    /// Forced-dark chooser appearance supplied to the shared popup palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Current Android chooser option state used to render row checkmarks.
    let options: PassageChooserOptions

    /// Callback invoked with the selected Android menu option.
    let onSelect: (PassageChooserMenuOption) -> Void

    /**
     Renders Android's passage chooser overflow popup.
     */
    var body: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "passageChooserOverflowPopup",
            backgroundColor: PassageChooserSurfacePalette.background.swiftUIColor,
            primaryTextColor: .white,
            secondaryTextColor: .white.opacity(0.82),
            accentColor: AndroidDialogSurfacePalette.accent(for: .dark)
        ) {
            VStack(spacing: 0) {
                ForEach(PassageChooserMenuEntry.androidBookChooserOrder) { entry in
                    menuRow(for: entry)
                }
            }
        }
    }

    /**
     Renders one Android chooser menu row with its checkbox state.
     */
    private func menuRow(for entry: PassageChooserMenuEntry) -> some View {
                AndroidPopupMenuRow(
                    title: localizedTitle(for: entry),
                    accessory: .checkbox(isOn: isChecked(entry.option)),
                    accessibilityIdentifier: "passageChooserMenu.\(entry.localizationKey)",
                    accessibilityValue: isChecked(entry.option) ? "on" : "off"
                ) {
                    onSelect(entry.option)
                }
    }

    /**
     Resolves localized text for an Android menu row.

     - Parameter entry: Android menu row metadata.
     - Returns: Localized menu title or the Android English fallback.
     */
    private func localizedTitle(for entry: PassageChooserMenuEntry) -> String {
        NSLocalizedString(entry.localizationKey, value: entry.defaultTitle, comment: "")
    }

    /**
     Returns whether one Android menu option is enabled.

     - Parameter option: Android chooser option represented by a popup row.
     - Returns: Current checked state for the row.
     */
    private func isChecked(_ option: PassageChooserMenuOption) -> Bool {
        switch option {
        case .alphabeticalOrder:
            return options.alphabeticalOrder
        case .rowOrder:
            return options.rowOrder
        case .groupByCategory:
            return options.groupByCategory
        case .showLongBookName:
            return options.showLongBookName
        case .showProgressBars:
            return options.showProgressBars
        }
    }
}
