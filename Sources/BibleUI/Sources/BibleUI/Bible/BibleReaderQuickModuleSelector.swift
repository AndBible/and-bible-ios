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
    /**
     One rendered row in the quick selector popup.

     The row keeps the full module for selection while exposing a compact Android label and enabled
     state for rendering. It has no side effects; equality is limited to fields that affect selector
     behavior and visible output.
     */
    struct Row: Identifiable, Equatable {
        /// Installed SWORD module represented by this row.
        let module: ModuleInfo

        /// Compact Android-parity title, formatted as abbreviation plus language code.
        let title: String

        /// Whether the row can be selected. The current document is visible but disabled.
        let isEnabled: Bool

        /// Stable row identity derived from the module abbreviation.
        var id: String { module.name }

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
            lhs.module.name == rhs.module.name &&
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
        modules
            .sorted { lhs, rhs in
                if lhs.language != rhs.language {
                    return lhs.language < rhs.language
                }
                return lhs.name < rhs.name
            }
            .map { module in
                Row(
                    module: module,
                    title: "\(module.name) (\(module.language))",
                    isEnabled: module.name != activeModuleName
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
        let rows = rows(for: modules, activeModuleName: activeModuleName)
        guard !rows.isEmpty else {
            return .none
        }
        if rows.count == 2 {
            guard let directRow = rows.first(where: { $0.module.name != activeModuleName }) ?? rows.first else {
                return .none
            }
            return .switchDirectly(directRow)
        }
        return .showPopup(rows)
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

     The parent computes these rows from installed Bible modules so the view remains a stateless
     renderer. Empty arrays render no buttons.
     */
    let rows: [BibleReaderQuickModuleSelectorPresentation.Row]

    /**
     Current app color scheme used to choose the popup surface color.

     Android uses a compact popup surface rather than the iOS document sheet; this input lets the
     iOS overlay keep that dedicated popup treatment without reading global state internally.
     */
    let colorScheme: ColorScheme

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

     - Side effects: The parent is expected to dismiss the popup and switch the pane's Bible module.
     - Failure modes: Disabled rows never call this closure.
     */
    let onSelect: (ModuleInfo) -> Void

    /**
     Creates a stateless quick-selector popup renderer.

     - Parameters:
       - rows: Sorted Android-parity rows to render.
       - colorScheme: Current app color scheme used for the popup surface.
       - maximumHeight: Visible viewport for the popup; long lists scroll within this height.
       - accessibilityIdentifier: Stable identifier for the popup container.
       - rowAccessibilityIdentifierPrefix: Stable identifier prefix for row controls.
       - onSelect: Callback invoked only for enabled module rows.
     - Side effects: none at initialization; row taps later invoke `onSelect`.
     - Failure modes: none; empty rows produce a zero-height popup body.
     */
    init(
        rows: [BibleReaderQuickModuleSelectorPresentation.Row],
        colorScheme: ColorScheme,
        maximumHeight: CGFloat = .infinity,
        accessibilityIdentifier: String = "readerBibleQuickSelector",
        rowAccessibilityIdentifierPrefix: String = "readerBibleQuickSelectorRow",
        onSelect: @escaping (ModuleInfo) -> Void
    ) {
        self.rows = rows
        self.colorScheme = colorScheme
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
        ScrollView(.vertical, showsIndicators: contentHeight > popupHeight) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider()
                    }
                    selectorRow(row)
                }
            }
        }
        .frame(height: popupHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .background(menuBackground)
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
        Button {
            guard row.isEnabled else { return }
            onSelect(row.module)
        } label: {
            Text(row.title)
                .font(.system(size: 15))
                .lineLimit(1)
                .foregroundStyle(row.isEnabled ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight, alignment: .center)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .opacity(row.isEnabled ? 1 : 0.48)
        .accessibilityIdentifier("\(rowAccessibilityIdentifierPrefix)_\(row.module.name)")
        .accessibilityValue(row.isEnabled ? "available" : "current")
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

    /// Popup surface color matching the existing Android-style reader overflow menu.
    private var menuBackground: Color {
        if colorScheme == .dark {
            return Color(red: 0.22, green: 0.22, blue: 0.22)
        }
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
