// AndroidDocumentSelectionControls.swift -- Shared DocumentSelectionBase chrome

import SwiftUI
import SwordKit

/**
 One selectable value rendered by Android's document language or type dropdown.

 Inputs: stable owner-defined identity and an already-localized title

 Output: immutable value consumed by `AndroidDocumentSelectionFilterBar`

 Side effects: none

 Failure modes: duplicate identifiers are caller errors and resolve according to SwiftUI's normal
 `ForEach` identity behavior
 */
struct AndroidDocumentSelectionOption: Identifiable, Equatable {
    /// Stable identity returned to the feature when the option is selected.
    let id: String

    /// Localized visible title.
    let title: String
}

/**
 Shared full-screen activity host for Android screens derived from `DocumentSelectionBase`.

 Android's Choose Document and Download Documents activities inherit the same activity base and
 therefore share more than individual controls: both own the complete app-bar/filter/list stack,
 fill the available activity viewport, consume the launching workspace/window palette, and suppress
 platform navigation chrome. Keeping that ownership in one host prevents either feature from
 drifting back into a constrained dialog or history-style modal while still allowing each activity
 to supply its contextual app bar and row behavior.

 Inputs:
 - the reader/workspace surface palette inherited by the launching route
 - an app bar that may switch between the normal title bar and Android's contextual action bar
 - the shared document-selection filter strip configured by the owning activity
 - scrollable or stateful rows supplied by the owning activity

 Output: one viewport-filling app-owned document-selection activity

 Side effects:
 - hides native iOS navigation chrome while the activity is visible
 - otherwise delegates all interactions to the supplied child views

 Failure modes:
 - child views with no flexible height remain top-aligned; the host still occupies the full viewport
 - accessibility-sized content may scroll only when the caller's row content provides scrolling,
   matching the ownership boundary of Android's `DocumentSelectionBase`
 */
struct AndroidDocumentSelectionActivityScreen<TopBar: View, FilterBar: View, Rows: View>: View {
    /// Reader/workspace colors shared by Choose Document and Download Documents.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Activity-specific normal or contextual app bar.
    private let topBar: TopBar

    /// Configured shared language/search/type filter strip.
    private let filterBar: FilterBar

    /// Activity-specific document rows and empty/loading states.
    private let rows: Rows

    /**
     Creates the shared Android document-selection activity host.

     - Parameters:
       - surfacePalette: Palette inherited from the launching reader window or workspace.
       - topBar: Normal or contextual app bar for the active activity state.
       - filterBar: Shared `document_selection.xml` filter projection.
       - rows: Activity-owned document rows and state content.
     - Returns: A configured viewport-filling activity host.
     - Side effects: Evaluates the view-builder closures once during initialization.
     - Failure modes: none; empty builders produce normal empty SwiftUI content.
     */
    init(
        surfacePalette: ReaderThemeSurfacePalette,
        @ViewBuilder topBar: () -> TopBar,
        @ViewBuilder filterBar: () -> FilterBar,
        @ViewBuilder rows: () -> Rows
    ) {
        self.surfacePalette = surfacePalette
        self.topBar = topBar()
        self.filterBar = filterBar()
        self.rows = rows()
    }

    var body: some View {
        AndroidActivitySurface(palette: surfacePalette) {
            topBar
        } content: {
            VStack(spacing: 0) {
                filterBar
                rows
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/**
 Shared filter strip for Android activities derived from `DocumentSelectionBase`.

 Android's Choose Document and Download Documents activities inflate the same
 `document_selection.xml`: a 55dp strip containing language autocomplete, free-text search,
 document-type spinner, and result count. This component preserves that shared ownership boundary
 on iOS and presents both dropdowns through the app-owned popup system rather than native `Menu`.

 Inputs:
 - owner palette for the active reader/workspace
 - localized labels and ordered language/type options
 - caller-owned search text and explicit selection callbacks
 - stable accessibility prefix used to distinguish chooser and downloader instances

 Output: one compact, app-owned document-selection filter strip

 Side effects:
 - opening the language dropdown invokes `onOpenLanguageOptions`, matching Android's clearing of the
   editable autocomplete field
 - search focus invokes `onSearchFocused`, allowing the owner to reset language/type filters exactly
   as `DocumentSelectionBase` does
 - selecting an option invokes the corresponding callback and closes its popup

 Failure modes:
 - empty option arrays render an empty popup surface but leave the search field usable
 - unusually long translations truncate at normal text sizes and gain a second line at
   accessibility Dynamic Type sizes
 */
struct AndroidDocumentSelectionFilterBar: View {
    /// Popup anchors shared by the trigger buttons and app-owned overlay modifiers.
    private enum PopupAnchor {
        static let language = "androidDocumentSelectionLanguageAnchor"
        static let documentType = "androidDocumentSelectionTypeAnchor"
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Reader/workspace colors resolved by the launching activity.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Current localized language field title.
    let languageTitle: String

    /// Ordered language dropdown values.
    let languageOptions: [AndroidDocumentSelectionOption]

    /// Current localized document-type field title.
    let documentTypeTitle: String

    /// Ordered document-type dropdown values.
    let documentTypeOptions: [AndroidDocumentSelectionOption]

    /// Localized visible-result count.
    let resultCountTitle: String

    /// Localized Android search hint.
    let searchPlaceholder: String

    /// Caller-owned free-text filter.
    @Binding var searchText: String

    /// Prefix used for stable accessibility identifiers.
    let accessibilityPrefix: String

    /// Android autocomplete-open callback.
    let onOpenLanguageOptions: () -> Void

    /// Language selection callback receiving the option identity.
    let onSelectLanguage: (String) -> Void

    /// Android search-focus callback.
    let onSearchFocused: () -> Void

    /// Document-type selection callback receiving the option identity.
    let onSelectDocumentType: (String) -> Void

    /// Whether the app-owned language dropdown is visible.
    @State private var showsLanguageOptions = false

    /// Whether the app-owned document-type dropdown is visible.
    @State private var showsDocumentTypeOptions = false

    /**
     Formats Android's shared visible-document count with the exact resource key and placeholder.

     Both Choose Document and Download Documents receive this value from
     `DocumentSelectionBase.filterDocuments()`. Keeping the formatter here prevents either activity
     from inventing a count key that the Android locale catalogs cannot translate.

     - Parameter count: Number of rows remaining after the active filters.
     - Returns: Localized Android `document_filter_results` text.
     - Side effects: Reads the application localization bundle.
     - Failure modes: Counts beyond `Int32` are clamped to the formatter's Android `%d` domain;
       missing translations use the exact English fallback.
     */
    static func localizedResultCount(_ count: Int) -> String {
        let format = String(
            localized: "document_filter_results",
            defaultValue: "%d documents"
        )
        return String(format: format, Int32(clamping: count))
    }

    var body: some View {
        filterLayout
            .background(surfacePalette.backgroundColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(surfacePalette.inactiveBorderColor)
                    .frame(height: 1)
            }
            .androidAnchoredPopupMenu(
                anchorID: PopupAnchor.language,
                isPresented: $showsLanguageOptions,
                menuWidth: 260,
                estimatedMenuHeight: popupHeight(optionCount: languageOptions.count),
                accessibilityIdentifier: "\(accessibilityPrefix)LanguageMenu"
            ) {
                optionsPopup(
                    languageOptions,
                    accessibilityIdentifier: "\(accessibilityPrefix)LanguageMenuSurface"
                ) { optionID in
                    showsLanguageOptions = false
                    onSelectLanguage(optionID)
                }
            }
            .androidAnchoredPopupMenu(
                anchorID: PopupAnchor.documentType,
                isPresented: $showsDocumentTypeOptions,
                menuWidth: 240,
                estimatedMenuHeight: popupHeight(optionCount: documentTypeOptions.count),
                accessibilityIdentifier: "\(accessibilityPrefix)DocumentTypeMenu"
            ) {
                optionsPopup(
                    documentTypeOptions,
                    accessibilityIdentifier: "\(accessibilityPrefix)DocumentTypeMenuSurface"
                ) { optionID in
                    showsDocumentTypeOptions = false
                    onSelectDocumentType(optionID)
                }
            }
    }

    /// Preserves Android's single 55dp row while allowing accessibility text to use two rows.
    @ViewBuilder
    private var filterLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    languageControl
                    documentTypeControl
                }
                searchControl
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                languageControl
                    .frame(maxWidth: .infinity, alignment: .leading)
                searchControl
                    .frame(maxWidth: .infinity)
                documentTypeControl
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 5)
            .frame(height: 55)
        }
    }

    /// Android autocomplete trigger backed by the shared app-owned popup surface.
    private var languageControl: some View {
        Button {
            showsDocumentTypeOptions = false
            onOpenLanguageOptions()
            showsLanguageOptions.toggle()
        } label: {
            underlinedLabel(languageTitle, alignment: .leading, includesDropdownIndicator: false)
        }
        .buttonStyle(.plain)
        .androidPopupMenuAnchor(id: PopupAnchor.language)
        .accessibilityIdentifier("\(accessibilityPrefix)LanguageFilter")
    }

    /// Android free-text input using the exact shared document-search hint.
    private var searchControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(
                searchPlaceholder,
                text: $searchText,
                onEditingChanged: { isEditing in
                    if isEditing {
                        showsLanguageOptions = false
                        showsDocumentTypeOptions = false
                        onSearchFocused()
                    }
                }
            )
            .font(.system(size: 16))
            .textFieldStyle(.plain)
            .foregroundStyle(surfacePalette.foregroundColor)
            .tint(AndroidDialogSurfacePalette.accent(for: colorScheme))
            .submitLabel(.search)

            Rectangle()
                .fill(surfacePalette.secondaryForegroundColor)
                .frame(height: 1)
        }
        .accessibilityIdentifier("\(accessibilityPrefix)SearchField")
    }

    /// Android spinner trigger with the XML-overlaid result count retained above its title.
    private var documentTypeControl: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(resultCountTitle)
                .font(.system(size: 11))
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .lineLimit(1)

            Button {
                showsLanguageOptions = false
                showsDocumentTypeOptions.toggle()
            } label: {
                underlinedLabel(
                    documentTypeTitle,
                    alignment: .trailing,
                    includesDropdownIndicator: true
                )
            }
            .buttonStyle(.plain)
            .androidPopupMenuAnchor(id: PopupAnchor.documentType)
        }
        .accessibilityIdentifier("\(accessibilityPrefix)CategoryFilter")
    }

    /** Builds one compact Android edit/spinner label without native iOS menu chrome. */
    private func underlinedLabel(
        _ title: String,
        alignment: Alignment,
        includesDropdownIndicator: Bool
    ) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 16))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                if includesDropdownIndicator {
                    AndBibleIconView(name: "PromptExpandIndicator", size: 16)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(surfacePalette.foregroundColor)
            .frame(maxWidth: .infinity, alignment: alignment)

            Rectangle()
                .fill(surfacePalette.secondaryForegroundColor)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
    }

    /** Builds a bounded shared popup so long language catalogs remain usable on compact screens. */
    private func optionsPopup(
        _ options: [AndroidDocumentSelectionOption],
        accessibilityIdentifier: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: accessibilityIdentifier,
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
        ) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(options) { option in
                        AndroidPopupMenuRow(
                            title: option.title,
                            accessibilityIdentifier: "\(accessibilityIdentifier)::\(option.id)"
                        ) {
                            onSelect(option.id)
                        }
                    }
                }
            }
            .frame(height: popupHeight(optionCount: options.count))
        }
    }

    /** Resolves the measured popup height while keeping at least one row tappable. */
    private func popupHeight(optionCount: Int) -> CGFloat {
        min(max(CGFloat(optionCount) * 48, 48), 336)
    }
}

/**
 Encryption marker rendered in Android's shared `document_list_item.xml` icon cluster.

 Inputs: installed-module encryption and unlock state projected by the owning activity

 Output: a stable choice between no glyph, Android's closed-lock glyph, and Android's open-lock
 glyph

 Side effects: none

 Failure modes: none; all states are explicit
 */
enum AndroidDocumentEncryptionState: Equatable {
    /// Ordinary unencrypted document.
    case none

    /// Enciphered document whose key is not currently accepted.
    case locked

    /// Enciphered document whose key is currently accepted.
    case unlocked
}

/**
 Shared leading column from Android's `document_list_item.xml`.

 Choose Document and Download Documents use the same XML row. The column owns the exact ported
 Android category, status, recommended, warning, and lock glyph positions plus the language and
 optional install-size labels. Feature screens supply only row state and the reader/workspace
 palette; fixed Android resource colors remain centralized in `AndroidResourcePalette`.

 Inputs:
 - module category, localized language, and optional localized install-size text
 - optional Android status asset and its exact resource tint
 - recommended, bad-document, and encryption projections
 - owner-resolved surface palette for text outside Android's fixed-color glyphs

 Output: one 70-point leading document-list column shared by chooser and downloader

 Side effects: loads packaged vector assets when rendered

 Failure modes: unsupported module categories fall back to Android's general-book glyph
 */
struct AndroidDocumentListLeadingColumn: View {
    /// Android document category represented by the row.
    let category: ModuleCategory

    /// Localized language title below the icon cluster.
    let languageTitle: String

    /// Optional localized install-size label used by Downloads.
    let installSizeTitle: String?

    /// Ported Android download-status asset, or nil for an empty status slot.
    let statusIconAssetName: String?

    /// Exact Android resource tint for the status asset.
    let statusIconColor: Color

    /// Whether Android's recommended star is visible.
    let isRecommended: Bool

    /// Whether Android's bad-document thumbs-down is visible.
    let isWarned: Bool

    /// Android encryption marker state.
    let encryptionState: AndroidDocumentEncryptionState

    /// Reader/workspace palette inherited by the activity.
    let surfacePalette: ReaderThemeSurfacePalette

    var body: some View {
        VStack(spacing: 2) {
            iconCluster

            Text(languageTitle)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let installSizeTitle {
                Text(installSizeTitle)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: 70)
    }

    /// Reproduces the overlapping `ConstraintLayout` glyph positions from Android's shared row.
    private var iconCluster: some View {
        ZStack(alignment: .topLeading) {
            AndBibleIconView(name: categoryIconAssetName, size: 24)
                .foregroundStyle(AndroidResourcePalette.grey600)
                .offset(x: 0, y: 10)

            if let statusIconAssetName {
                AndBibleIconView(name: statusIconAssetName, size: 24)
                    .foregroundStyle(statusIconColor)
                    .offset(x: 31, y: 10)
            }

            if isRecommended {
                AndBibleIconView(name: "DocumentRecommended", size: 15)
                    .foregroundStyle(AndroidResourcePalette.yellow600)
                    .offset(x: 25, y: 0)
            }

            if isWarned {
                AndBibleIconView(name: "DocumentWarning", size: 25)
                    .foregroundStyle(AndroidResourcePalette.documentErrorRed)
                    .offset(x: 25, y: 0)
            }

            encryptionIcon
                .offset(x: 25, y: 27)
        }
        .frame(width: 56, height: 50, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// Exact packaged category drawable selected by Android's `BookCategory.imageResource`.
    private var categoryIconAssetName: String {
        switch category {
        case .bible:
            return "ToolbarBible"
        case .commentary:
            return "ToolbarCommentary"
        case .dictionary:
            return "SettingsIconDictionary"
        case .generalBook:
            return "DrawerDocuments"
        case .map:
            return "DocumentMap"
        case .addon:
            return "DrawerDownloads"
        default:
            return "DrawerDocuments"
        }
    }

    /// Exact Android closed/open lock asset and fixed red/green resource tint.
    @ViewBuilder
    private var encryptionIcon: some View {
        switch encryptionState {
        case .none:
            EmptyView()
        case .locked:
            AndBibleIconView(name: "DocumentLock", size: 15)
                .foregroundStyle(AndroidResourcePalette.documentErrorRed)
        case .unlocked:
            AndBibleIconView(name: "DocumentLockOpen", size: 15)
                .foregroundStyle(AndroidResourcePalette.documentInstalledGreen)
        }
    }
}

/**
 Shared contextual action bar for Android document-selection rows.

 Android's `DocumentSelectionBase` enters a single-choice contextual action mode after a row long
 press. Its common menu orders About, Delete, Unlock, then Delete Index in overflow. This component
 reuses the app-owned activity bar and anchored popup primitives so Choose Document and Downloads
 cannot regress independently to native iOS swipe actions or context menus.

 Inputs:
 - ordered actions from `ModuleDownloadRowActionPlanner`
 - owner palette and stable accessibility prefix
 - callbacks for close, About, Delete, Unlock, and Delete Index

 Output: one app-owned contextual action bar with Android menu ordering and overflow behavior

 Side effects: invokes the supplied callback after an explicit toolbar or popup tap

 Failure modes: unavailable actions are omitted; an empty action array leaves only contextual Close
 */
struct AndroidDocumentContextActionBar: View {
    /// Stable anchor for Android's never-show-as-action Delete Index item.
    private enum PopupAnchor {
        static let overflow = "androidDocumentContextOverflowAnchor"
    }

    @Environment(\.colorScheme) private var colorScheme

    /// Android-ordered actions available for the selected row.
    let actions: [ModuleDownloadRowAction]

    /// Reader/workspace palette inherited by the activity.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Stable prefix distinguishing chooser and downloader instances.
    let accessibilityPrefix: String

    /// Exits contextual mode without closing the activity.
    let onClose: () -> Void

    /// Presents Android's document metadata dialog.
    let onAbout: () -> Void

    /// Requests Android's document deletion confirmation.
    let onDelete: () -> Void

    /// Presents Android's cipher-key dialog.
    let onUnlock: () -> Void

    /// Requests Android's search-index deletion confirmation.
    let onDeleteIndex: () -> Void

    /// Visibility of the app-owned Delete Index overflow popup.
    @State private var showsOverflow = false

    var body: some View {
        AndroidActivityTopAppBar(
            title: "",
            accessibilityIdentifier: "\(accessibilityPrefix)ContextActionBar",
            backgroundColor: surfacePalette.toolbarBackgroundColor,
            foregroundColor: surfacePalette.toolbarForegroundColor,
            onBack: onClose,
            navigationIcon: .asset("ActivityClose"),
            navigationAccessibilityLabel: String(localized: "close", defaultValue: "Close")
        ) {
            if actions.contains(.about) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("DocumentInfo"),
                    accessibilityLabel: String(localized: "about", defaultValue: "About"),
                    accessibilityIdentifier: "\(accessibilityPrefix)ContextAboutButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: onAbout
                )
            }

            if actions.contains(.uninstall) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityDelete"),
                    accessibilityLabel: String(localized: "delete", defaultValue: "Delete"),
                    accessibilityIdentifier: "\(accessibilityPrefix)ContextDeleteButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: onDelete
                )
            }

            if actions.contains(.unlock) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("DocumentLock"),
                    accessibilityLabel: String(
                        localized: "unlock_module",
                        defaultValue: "Unlock module"
                    ),
                    accessibilityIdentifier: "\(accessibilityPrefix)ContextUnlockButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: onUnlock
                )
            }

            if actions.contains(.deleteIndex) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "\(accessibilityPrefix)ContextOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    showsOverflow.toggle()
                }
                .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            }
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showsOverflow,
            menuWidth: 230,
            estimatedMenuHeight: 48,
            accessibilityIdentifier: "\(accessibilityPrefix)ContextOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "\(accessibilityPrefix)ContextOverflowSurface",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
            ) {
                AndroidPopupMenuRow(
                    title: String(localized: "delete_index", defaultValue: "Delete Index"),
                    accessibilityIdentifier: "\(accessibilityPrefix)ContextDeleteIndexButton"
                ) {
                    showsOverflow = false
                    onDeleteIndex()
                }
            }
        }
    }
}

/**
 Shared row interaction for Android document-selection contextual action mode.

 `DocumentSelectionBase` enters single-choice contextual mode only for manageable document rows.
 This modifier centralizes the selected highlight, 450ms long press, and accessibility Select action
 so Choose Document and Downloads cannot drift into different gestures. Rows without a contextual
 callback receive none of those affordances; in particular, accessibility never exposes a no-op
 Select action for non-manageable pseudo-document rows. Imported EPUB rows provide the callback
 because Android owns them as deletable General Book documents.

 Inputs:
 - whether the row is the active contextual selection
 - optional callback that enters contextual mode

 Output: the original row with Android-equivalent contextual interaction when supported

 Side effects: invokes `onLongPress` after a pointer/touch hold or explicit accessibility action

 Failure modes: none; a nil callback renders an ordinary row without contextual semantics
 */
private struct AndroidDocumentContextSelectionModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    /// Whether the owning activity currently selects this row.
    let isSelected: Bool

    /// Optional contextual-mode entry action; nil means the row is not manageable.
    let onLongPress: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onLongPress {
            content
                .background(selectionBackground)
                .onLongPressGesture(minimumDuration: 0.45, perform: onLongPress)
                .accessibilityAction(
                    named: Text(String(localized: "select", defaultValue: "Select")),
                    onLongPress
                )
        } else {
            content
        }
    }

    /// Shared Android selection highlight derived from the globally owned dialog accent.
    private var selectionBackground: Color {
        isSelected
            ? AndroidDialogSurfacePalette.accent(for: colorScheme).opacity(0.24)
            : .clear
    }
}

extension View {
    /**
     Applies shared Android contextual document-row interaction when the row supports it.

     - Parameters:
       - isSelected: Whether the row owns the current contextual action bar.
       - onLongPress: Optional action that enters contextual selection.
     - Returns: The row with shared highlight, long-press, and accessibility semantics.
     - Side effects: The callback runs only after a supported explicit interaction.
     - Failure modes: A nil callback leaves the row unchanged.
     */
    func androidDocumentContextSelection(
        isSelected: Bool,
        onLongPress: (() -> Void)?
    ) -> some View {
        modifier(
            AndroidDocumentContextSelectionModifier(
                isSelected: isSelected,
                onLongPress: onLongPress
            )
        )
    }
}
