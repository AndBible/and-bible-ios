import Foundation
import SwiftUI
import SwordKit

/**
 Presentation contract for Android's Bible-toolbar quick module menu.

 Android implements this path in `MainBibleActivity.menuForDocs`: available books are sorted by
 language code and abbreviation, the current book is disabled, exactly two books switch directly,
 and every other non-empty list shows an anchored popup. This type keeps those rules pure and
 testable so the SwiftUI overlay cannot drift back toward the full document picker sheet.
 */
struct BibleReaderQuickModuleSelectorPresentation {
    /** Exact installed or local document selected by Android's shared toolbar popup. */
    enum Selection {
        /** Exact immutable owner identity used by SwiftUI and presentation equality. */
        enum Identity: Hashable {
            /// Java-exact installed initials.
            case installed(SwordJavaExactStringIdentity)

            /// Exact EPUB package, generation, and registered initials.
            case epub(
                identifier: SwordJavaExactStringIdentity,
                generationIdentifier: SwordJavaExactStringIdentity,
                initials: SwordJavaExactStringIdentity
            )

            /// Exact persisted My Documents owner and its registered initials.
            case myDocument(id: UUID, initials: SwordJavaExactStringIdentity)
        }

        /// Native or SQLite installed module.
        case installed(ModuleInfo)

        /// Imported EPUB registered as an Android general book.
        case epub(
            identifier: String,
            generationIdentifier: String,
            initials: String,
            title: String,
            language: String
        )

        /// Persisted My Documents collection registered as an Android general book.
        case myDocument(id: UUID, initials: String, name: String, language: String)

        /// Canonical registered identity used for row state and authoritative dispatch.
        var name: String {
            switch self {
            case .installed(let module): return module.name
            case .epub(_, _, let initials, _, _): return initials
            case .myDocument(_, let initials, _, _): return initials
            }
        }

        /// Typed Java-exact identity for row diffing and authorization-significant equality.
        var identity: Identity {
            switch self {
            case .installed(let module):
                return .installed(SwordJavaExactStringIdentity(module.name))
            case .epub(let identifier, let generationIdentifier, let initials, _, _):
                return .epub(
                    identifier: SwordJavaExactStringIdentity(identifier),
                    generationIdentifier: SwordJavaExactStringIdentity(generationIdentifier),
                    initials: SwordJavaExactStringIdentity(initials)
                )
            case .myDocument(let id, let initials, _, _):
                return .myDocument(
                    id: id,
                    initials: SwordJavaExactStringIdentity(initials)
                )
            }
        }

        /// Immutable Android book metadata used by the common row renderer and ordering contract.
        var presentationModule: ModuleInfo {
            switch self {
            case .installed(let module):
                return module
            case .epub(_, _, let initials, let title, let language):
                return ModuleInfo(
                    name: initials,
                    description: title,
                    category: .generalBook,
                    language: language
                )
            case .myDocument(_, let initials, let name, let language):
                return ModuleInfo(
                    name: initials,
                    description: name,
                    category: .generalBook,
                    language: language
                )
            }
        }

        /// Android popup abbreviation for the compact visible row.
        var abbreviation: String {
            switch self {
            case .installed(let module): return module.name
            case .epub(_, _, _, let title, _): return title
            case .myDocument(_, let initials, _, _): return initials
            }
        }
    }

    /**
     One rendered row in the quick selector popup.

     The row keeps the full module for selection while exposing a compact Android label and enabled
     state for rendering. It has no side effects; equality is limited to fields that affect selector
     behavior and visible output.
     */
    struct Row: Identifiable, Equatable {
        /// Exact document selection reauthorized by the owning reader controller.
        let selection: Selection

        /// Installed metadata or equivalent local general-book presentation metadata.
        let module: ModuleInfo

        /// Compact Android-parity title, formatted as abbreviation plus language code.
        let title: String

        /// Whether the row can be selected. The current document is visible but disabled.
        let isEnabled: Bool

        /// Stable exact owner identity retained across SwiftUI row diffing.
        var id: Selection.Identity { selection.identity }

        /** Creates the existing installed-module row without changing Bible callers. */
        init(module: ModuleInfo, title: String, isEnabled: Bool) {
            self.init(
                selection: .installed(module),
                module: module,
                title: title,
                isEnabled: isEnabled
            )
        }

        /** Creates one common installed/local document row. */
        init(selection: Selection, module: ModuleInfo, title: String, isEnabled: Bool) {
            self.selection = selection
            self.module = module
            self.title = title
            self.isEnabled = isEnabled
        }

        /**
         Compares rows by selector-visible identity and behavior.

         - Parameters:
           - lhs: First row to compare.
           - rhs: Second row to compare.
         - Returns: `true` when the row would render and behave equivalently in the quick selector.
         - Side effects: none.
         - Failure modes: none.
         */
        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.selection.identity == rhs.selection.identity &&
                lhs.title == rhs.title &&
                lhs.isEnabled == rhs.isEnabled
        }
    }

    /**
     Resolved toolbar behavior for the current Bible module set.

     The enum separates direct switching from popup presentation so reader routing can stay explicit:
     no installed modules do nothing, exactly two modules switch directly, and every other non-empty
     list renders rows in the anchored selector. Cases have no side effects by themselves.
     */
    enum Action: Equatable {
        /// No menu action is available because there are no candidate modules.
        case none

        /// Android's two-document shortcut: switch directly to the other module row.
        case switchDirectly(Row)

        /// Android's popup path: show the sorted compact rows in an anchored menu.
        case showPopup([Row])
    }

    /**
     Builds sorted quick-selector rows from installed Bible modules.

     - Parameters:
       - modules: Candidate Bible modules visible to the toolbar action.
       - activeModuleName: Current module abbreviation, if the pane has one.
     - Returns: Rows sorted by language code and module abbreviation, matching Android.
     - Side effects: none.
     - Failure modes: none; an empty input returns an empty row list.
     */
    static func rows(for modules: [ModuleInfo], activeModuleName: String?) -> [Row] {
        rows(
            for: modules.map(Selection.installed),
            activeModuleName: activeModuleName
        )
    }

    /** Builds common Android rows for installed, EPUB, and My Documents selections. */
    static func rows(for selections: [Selection], activeModuleName: String?) -> [Row] {
        selections
            .sorted { lhs, rhs in
                let left = lhs.presentationModule
                let right = rhs.presentationModule
                let leftLanguage = SwordJavaExactStringIdentity(left.language)
                let rightLanguage = SwordJavaExactStringIdentity(right.language)
                if leftLanguage != rightLanguage {
                    return leftLanguage.utf16CodeUnits.lexicographicallyPrecedes(
                        rightLanguage.utf16CodeUnits
                    )
                }
                return SwordJavaExactStringIdentity(lhs.abbreviation)
                    .utf16CodeUnits.lexicographicallyPrecedes(
                        SwordJavaExactStringIdentity(rhs.abbreviation).utf16CodeUnits
                    )
            }
            .map { selection in
                let module = selection.presentationModule
                return Row(
                    selection: selection,
                    module: module,
                    title: "\(selection.abbreviation) (\(module.language))",
                    isEnabled: activeModuleName.map {
                        SwordJavaExactStringIdentity(selection.name)
                            != SwordJavaExactStringIdentity($0)
                    } ?? true
                )
            }
    }

    /**
     Resolves Android's `menuForDocs` action for the current Bible module set.

     - Parameters:
       - modules: Candidate Bible modules visible to the toolbar action.
       - activeModuleName: Current module abbreviation, if the pane has one.
     - Returns: `.none` for no modules, `.switchDirectly` for exactly two modules, and `.showPopup`
       for every other non-empty module list.
     - Side effects: none.
     - Failure modes: none; invalid or missing active-module names fall back to the first sorted row
       for the two-document shortcut.
     */
    static func action(for modules: [ModuleInfo], activeModuleName: String?) -> Action {
        action(
            for: modules.map(Selection.installed),
            activeModuleName: activeModuleName
        )
    }

    /** Resolves the shared Android action over installed and local registered books. */
    static func action(for selections: [Selection], activeModuleName: String?) -> Action {
        let rows = rows(for: selections, activeModuleName: activeModuleName)
        guard !rows.isEmpty else {
            return .none
        }
        if rows.count == 2 {
            guard let directRow = rows.first(where: \.isEnabled) ?? rows.first else {
                return .none
            }
            return .switchDirectly(directRow)
        }
        return .showPopup(rows)
    }
}

/**
 Resolves Android's retained suggested-Bible identity without substituting another installed Bible.

 Android's `DocumentControl.suggestedBible` returns the active window's retained Bible when a
 non-Bible document is visible. Its source inventory is inclusive, so an installed locked identity
 remains the target. The reader owns the subsequent access preflight and any explicit iOS unlock
 adaptation.

 This policy performs no I/O or state mutation. Missing, non-Bible, and non-exact identities return
 `nil`; callers must leave the visible document unchanged in those cases.
 */
struct BibleReaderSuggestedBibleSelectionPolicy {
    /**
     Resolves the exact retained Bible from one inclusive installed snapshot.

     - Parameters:
       - retainedModuleName: Pane-scoped Bible initials retained while another category is visible.
       - installedModules: Inclusive installed inventory, including locked Bible rows.
     - Returns: The exact installed Bible row, or `nil` without a fallback substitution.
     - Side effects: None.
     - Failure modes: Missing, case-different, canonically equivalent, non-Bible, and uninstalled
       identities return `nil`.
     */
    static func module(
        retainedModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> ModuleInfo? {
        guard let retainedModuleName else { return nil }
        return installedModules.first {
            $0.category == .bible
                && SwordJavaStringIdentity.equals($0.name, retainedModuleName)
        }
    }
}

/**
 Binds one suggested-Bible unlock action to its captured pane, controller, module, and credential
 session.

 The value is an authorization check around the existing `ModuleUnlockSession`; it introduces no
 additional dialog states. Reader callbacks re-evaluate it immediately before manager key mutation
 and again before the accepted switch, preventing a delayed action from targeting a replacement
 controller or a newly retained Bible.
 */
struct BibleReaderSuggestedBibleUnlockAuthorization {
    /// Window that owned the non-Bible toolbar action.
    let windowID: UUID

    /// Exact controller instance registered when the action began.
    let controllerID: ObjectIdentifier

    /// Exact UTF-16 module identity retained by the pane and credential session.
    let moduleIdentity: SwordJavaExactStringIdentity

    /// Existing credential-session identity captured when the prompt was created.
    let sessionID: ModuleUnlockSession.ID

    /**
     Checks whether a rendered credential action still belongs to its original reader intent.

     - Parameters:
       - activeWindowID: Window currently accepting reader toolbar actions.
       - registeredControllerID: Controller currently registered for `windowID`.
       - retainedModuleName: Bible identity currently retained by that window's `PageManager`.
       - sessionModuleName: Module carried by the currently bound `ModuleUnlockSession`.
       - presentedSessionID: Identity of the currently bound credential session.
     - Returns: `true` only when every captured owner and exact module boundary still matches.
     - Side effects: None.
     - Failure modes: Missing or replaced owners and any exact UTF-16 identity mismatch return
       `false` before a caller performs manager or pane mutation.
     */
    func authorizes(
        activeWindowID: UUID?,
        registeredControllerID: ObjectIdentifier?,
        retainedModuleName: String?,
        sessionModuleName: String,
        presentedSessionID: ModuleUnlockSession.ID
    ) -> Bool {
        activeWindowID == windowID
            && registeredControllerID == controllerID
            && retainedModuleName.map(SwordJavaExactStringIdentity.init) == moduleIdentity
            && SwordJavaExactStringIdentity(sessionModuleName) == moduleIdentity
            && presentedSessionID == sessionID
    }
}

/**
 Compact Android-style popup for selecting an installed Bible module.

 The parent owns pane state and module switching. This view only renders sorted quick-selector rows
 and forwards enabled row selections. Disabled rows stay visible so the current Bible mirrors
 Android's disabled `PopupMenu` item instead of disappearing.
 */
struct BibleReaderQuickModuleSelector: View {
    /// Fixed compact menu row height used to keep viewport calculations deterministic.
    private static let rowHeight: CGFloat = 44

    /// Divider contribution between adjacent rows in the compact popup.
    private static let dividerHeight: CGFloat = 1

    /**
     Sorted rows to render in Android quick-selector order.

     The parent computes these rows from authorized installed or local documents so the view remains
     a stateless renderer. Empty arrays render no buttons.
     */
    let rows: [BibleReaderQuickModuleSelectorPresentation.Row]

    /// Current app color scheme used by the shared Android popup elevation treatment.
    let colorScheme: ColorScheme

    /// Reader/workspace palette inherited from the pane that owns the toolbar popup.
    let surfacePalette: ReaderThemeSurfacePalette

    /**
     Maximum visible height available to the selector popup.

     The toolbar overlay computes this from the trigger position and safe areas. Long module lists
     scroll within this height so installed Bibles remain reachable instead of expanding off-screen.
     */
    let maximumHeight: CGFloat

    /// Accessibility identifier applied to the popup container.
    let accessibilityIdentifier: String

    /// Accessibility identifier prefix applied to each popup row before the module abbreviation.
    let rowAccessibilityIdentifierPrefix: String

    /**
     Selection callback for enabled rows.

     - Side effects: The parent is expected to dismiss the popup and switch the exact document.
     - Failure modes: Disabled rows never call this closure.
     */
    let onSelect: (BibleReaderQuickModuleSelectorPresentation.Selection) -> Void

    /**
     Creates a stateless quick-selector popup renderer.

     - Parameters:
       - rows: Sorted Android-parity rows to render.
       - colorScheme: Current app color scheme used for the shared popup elevation treatment.
       - surfacePalette: Reader/workspace colors inherited from the toolbar's owning pane.
       - maximumHeight: Visible viewport for the popup; long lists scroll within this height.
       - accessibilityIdentifier: Stable identifier for the popup container; the real scroll
         surface appends `ScrollView` for semantic accessibility actions.
       - rowAccessibilityIdentifierPrefix: Stable identifier prefix for row controls.
       - onSelect: Callback invoked only for enabled module rows.
     - Side effects: none at initialization; row taps later invoke `onSelect`.
     - Failure modes: none; empty rows produce a zero-height popup body.
     */
    init(
        rows: [BibleReaderQuickModuleSelectorPresentation.Row],
        colorScheme: ColorScheme,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        maximumHeight: CGFloat = .infinity,
        accessibilityIdentifier: String = "readerBibleQuickSelector",
        rowAccessibilityIdentifierPrefix: String = "readerBibleQuickSelectorRow",
        onSelect: @escaping (BibleReaderQuickModuleSelectorPresentation.Selection) -> Void
    ) {
        self.rows = rows
        self.colorScheme = colorScheme
        self.surfacePalette = surfacePalette
        self.maximumHeight = maximumHeight
        self.accessibilityIdentifier = accessibilityIdentifier
        self.rowAccessibilityIdentifierPrefix = rowAccessibilityIdentifierPrefix
        self.onSelect = onSelect
    }

    /**
     Renders the compact quick selector rows.

     - Returns: A vertically sized SwiftUI popup body.
     - Side effects: Enabled row taps invoke `onSelect`; disabled current rows remain inert.
     - Failure modes: none; empty rows produce an empty popup body.
     */
    var body: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: accessibilityIdentifier,
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            ScrollView(.vertical, showsIndicators: contentHeight > popupHeight) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                                .overlay(surfacePalette.inactiveBorderColor)
                        }
                        selectorRow(row)
                    }
                }
            }
            .frame(height: popupHeight)
            .accessibilityIdentifier("\(accessibilityIdentifier)ScrollView")
            .accessibilityElement(children: .contain)
        }
    }

    /**
     Renders one Android popup-menu row as a real control inside the scrollable menu.

     Android popup rows are tap targets inside a scrollable menu. The SwiftUI row keeps a real
     `Button` for reliable activation and XCTest hit handling while the parent `LazyVStack` and
     bounded `ScrollView` preserve reachability for long installed-module lists.

     - Parameter row: Presentation row to render.
     - Returns: A tappable row for enabled modules or an inert current-module row.
     - Side effects: Tapping or activating an enabled row invokes `onSelect`.
     - Failure modes: Disabled rows ignore tap and accessibility activation.
     */
    private func selectorRow(_ row: BibleReaderQuickModuleSelectorPresentation.Row) -> some View {
        AndroidPopupMenuRow(
            title: row.title,
            accessibilityIdentifier: "\(rowAccessibilityIdentifierPrefix)_\(row.module.name)",
            accessibilityValue: row.isEnabled ? "available" : "current",
            isEnabled: row.isEnabled
        ) {
            guard row.isEnabled else { return }
            onSelect(row.selection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight, alignment: .center)
    }

    /// Intrinsic height of the rendered row stack before viewport clipping.
    private var contentHeight: CGFloat {
        guard !rows.isEmpty else { return 0 }
        return CGFloat(rows.count) * Self.rowHeight + CGFloat(rows.count - 1) * Self.dividerHeight
    }

    /// Height applied to the scroll container after respecting the available toolbar viewport.
    private var popupHeight: CGFloat {
        min(contentHeight, max(0, maximumHeight))
    }

}
