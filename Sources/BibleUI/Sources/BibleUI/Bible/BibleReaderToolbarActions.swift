import SwiftUI

/**
 Captures the Bible toolbar trigger bounds so Android-style popups can anchor to the button.

 The reader view consumes this preference when presenting the quick Bible selector. It carries only
 layout geometry, does not mutate state, and falls back to the previous anchor if SwiftUI reports no
 newer value during a reduction pass.
 */
struct ReaderBibleToolbarButtonBoundsPreferenceKey: PreferenceKey {
    /// No toolbar button anchor is known until the Bible toolbar icon publishes one.
    static var defaultValue: Anchor<CGRect>?

    /**
     Stores the newest non-nil toolbar anchor emitted by SwiftUI preference propagation.

     - Parameters:
       - value: Previously captured anchor, if any.
       - nextValue: Deferred provider for the next anchor candidate.
     - Side effects: Mutates `value` with the latest available anchor.
     - Failure modes: none; nil candidates leave the previous anchor intact.
     */
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/**
 Captures the commentary toolbar trigger bounds so Android-style popups can anchor to the button.

 The reader view consumes this preference when presenting the commentary/document quick selector.
 It mirrors `ReaderBibleToolbarButtonBoundsPreferenceKey` so Bible and commentary quick menus share
 the same toolbar anchoring contract without routing commentary through the overflow/menu sheet.
 */
struct ReaderCommentaryToolbarButtonBoundsPreferenceKey: PreferenceKey {
    /// No toolbar button anchor is known until the commentary toolbar icon publishes one.
    static var defaultValue: Anchor<CGRect>?

    /**
     Stores the newest non-nil toolbar anchor emitted by SwiftUI preference propagation.

     - Parameters:
       - value: Previously captured anchor, if any.
       - nextValue: Deferred provider for the next anchor candidate.
     - Side effects: Mutates `value` with the latest available anchor.
     - Failure modes: none; nil candidates leave the previous anchor intact.
     */
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Width-collapsible accessory buttons that compete for toolbar space ahead of workspaces.
enum BibleReaderToolbarAccessoryButton {
    case search
    case speak
}

/**
 Renders the responsive action cluster in the reader document header.

 The parent coordinator owns every side effect. This view only decides which Android-parity toolbar
 buttons fit in compact versus regular width and forwards taps through explicit callbacks.
 */
struct BibleReaderToolbarActions<OverflowButton: View>: View {
    private let usesCompactToolbar: Bool
    private let surfacePalette: ReaderThemeSurfacePalette
    private let preferredSingleAccessory: BibleReaderToolbarAccessoryButton?
    private let moduleHasStrongs: Bool
    private let strongsIconAssetName: String
    private let strongsMode: Int
    private let strongsEnabled: Bool
    private let isBibleActive: Bool
    private let isCommentaryActive: Bool
    /// Whether Android's page-search action is valid for the focused pane.
    private let searchEnabled: Bool
    /// Whether Android's page-speak action is valid for the focused pane.
    private let speakEnabled: Bool
    /// Whether Bible/commentary document actions can accept gestures for the focused pane.
    private let moduleActionsEnabled: Bool
    private let onShowSearch: () -> Void
    private let onShowSpeak: () -> Void
    private let onApplyStrongsMode: (Int) -> Void
    private let onShowStrongsModeDialog: () -> Void
    private let onBibleTap: () -> Void
    private let onBibleLongPress: () -> Void
    private let onCommentaryTap: () -> Void
    private let onCommentaryLongPress: () -> Void
    private let onShowWorkspaces: () -> Void
    private let overflowButton: () -> OverflowButton

    init(
        usesCompactToolbar: Bool,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        preferredSingleAccessory: BibleReaderToolbarAccessoryButton?,
        moduleHasStrongs: Bool,
        strongsIconAssetName: String,
        strongsMode: Int,
        strongsEnabled: Bool,
        isBibleActive: Bool,
        isCommentaryActive: Bool,
        searchEnabled: Bool,
        speakEnabled: Bool,
        moduleActionsEnabled: Bool,
        onShowSearch: @escaping () -> Void,
        onShowSpeak: @escaping () -> Void,
        onApplyStrongsMode: @escaping (Int) -> Void,
        onShowStrongsModeDialog: @escaping () -> Void,
        onBibleTap: @escaping () -> Void,
        onBibleLongPress: @escaping () -> Void,
        onCommentaryTap: @escaping () -> Void,
        onCommentaryLongPress: @escaping () -> Void,
        onShowWorkspaces: @escaping () -> Void,
        @ViewBuilder overflowButton: @escaping () -> OverflowButton
    ) {
        self.usesCompactToolbar = usesCompactToolbar
        self.surfacePalette = surfacePalette
        self.preferredSingleAccessory = preferredSingleAccessory
        self.moduleHasStrongs = moduleHasStrongs
        self.strongsIconAssetName = strongsIconAssetName
        self.strongsMode = strongsMode
        self.strongsEnabled = strongsEnabled
        self.isBibleActive = isBibleActive
        self.isCommentaryActive = isCommentaryActive
        self.searchEnabled = searchEnabled
        self.speakEnabled = speakEnabled
        self.moduleActionsEnabled = moduleActionsEnabled
        self.onShowSearch = onShowSearch
        self.onShowSpeak = onShowSpeak
        self.onApplyStrongsMode = onApplyStrongsMode
        self.onShowStrongsModeDialog = onShowStrongsModeDialog
        self.onBibleTap = onBibleTap
        self.onBibleLongPress = onBibleLongPress
        self.onCommentaryTap = onCommentaryTap
        self.onCommentaryLongPress = onCommentaryLongPress
        self.onShowWorkspaces = onShowWorkspaces
        self.overflowButton = overflowButton
    }

    var body: some View {
        if usesCompactToolbar {
            toolbarActionButtons(
                showSearch: searchEnabled,
                showSpeak: false,
                showWorkspace: false
            )
        } else {
            ViewThatFits(in: .horizontal) {
                toolbarActionButtons(
                    showSearch: searchEnabled,
                    showSpeak: speakEnabled,
                    showWorkspace: true
                )
                toolbarActionButtons(
                    showSearch: searchEnabled,
                    showSpeak: speakEnabled,
                    showWorkspace: false
                )
                toolbarActionButtons(
                    showSearch: searchEnabled && preferredSingleAccessory == .search,
                    showSpeak: speakEnabled && preferredSingleAccessory == .speak,
                    showWorkspace: true
                )
                toolbarActionButtons(
                    showSearch: searchEnabled && preferredSingleAccessory == .search,
                    showSpeak: speakEnabled && preferredSingleAccessory == .speak,
                    showWorkspace: false
                )
                toolbarActionButtons(
                    showSearch: false,
                    showSpeak: false,
                    showWorkspace: true
                )
                toolbarActionButtons(
                    showSearch: false,
                    showSpeak: false,
                    showWorkspace: false
                )
            }
        }
    }

    private func toolbarActionButtons(
        showSearch: Bool,
        showSpeak: Bool,
        showWorkspace: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if showSearch {
                Button(action: onShowSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.body)
                        .foregroundStyle(toolbarIconColor())
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("readerSearchButton")
            }

            if showSpeak {
                Button(action: onShowSpeak) {
                    Image(systemName: "headphones")
                        .font(.body)
                        .foregroundStyle(toolbarIconColor())
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
            }

            if moduleHasStrongs {
                strongsIcon
                    .foregroundStyle(toolbarIconColor(isActive: strongsEnabled))
                    .contentShape(Rectangle())
                    .gesture(strongsToolbarGesture)
                    .accessibilityIdentifier("readerStrongsToolbarButton")
                    .accessibilityLabel(String(localized: "toggle_strongs_numbers"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        onApplyStrongsMode((strongsMode + 1) % 3)
                    }
            }

            moduleToolbarAction(
                isActive: isBibleActive,
                accessibilityIdentifier: "readerBibleToolbarButton",
                accessibilityLabel: String(localized: "bible"),
                onTap: onBibleTap,
                onLongPress: onBibleLongPress
            ) {
                bibleToolbarIcon
            }
            .anchorPreference(key: ReaderBibleToolbarButtonBoundsPreferenceKey.self, value: .bounds) { $0 }

            moduleToolbarAction(
                isActive: isCommentaryActive,
                accessibilityIdentifier: "readerCommentaryToolbarButton",
                accessibilityLabel: String(localized: "commentaries"),
                onTap: onCommentaryTap,
                onLongPress: onCommentaryLongPress
            ) {
                commentaryToolbarIcon
            }
            .anchorPreference(key: ReaderCommentaryToolbarButtonBoundsPreferenceKey.self, value: .bounds) { $0 }

            if showWorkspace {
                Button(action: onShowWorkspaces) {
                    workspaceToolbarIcon
                        .foregroundStyle(toolbarIconColor())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("readerWorkspacesButton")
                .accessibilityLabel(String(localized: "workspaces"))
            }

            overflowButton()
        }
    }

    private var strongsIcon: some View {
        ToolbarAssetIcon(name: strongsIconAssetName)
            .frame(width: 24, height: 22)
    }

    /**
     Reproduces Android's mutually exclusive Strong's toolbar gestures without native `Menu` UI.

     A tap cycles the three modes immediately; a long press opens the shared window-scoped
     `StrongsPreference` dialog. The exclusive gesture prevents a long press from also cycling the
     value before the dialog appears.

     - Returns: A gesture that dispatches exactly one Android Strong's action.
     - Side effects: Invokes either `onApplyStrongsMode` or `onShowStrongsModeDialog`.
     - Failure modes: A cancelled long press does not mutate settings or present a dialog.
     */
    private var strongsToolbarGesture: some Gesture {
        LongPressGesture().exclusively(before: TapGesture()).onEnded { value in
            switch value {
            case .first(true):
                onShowStrongsModeDialog()
            case .second:
                onApplyStrongsMode((strongsMode + 1) % 3)
            case .first(false):
                break
            }
        }
    }

    private var bibleToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarBible")
            .frame(width: 24, height: 22)
    }

    private var commentaryToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarCommentary")
            .frame(width: 24, height: 22)
    }

    /**
     Renders a Bible/commentary module action with mutually exclusive tap and long-press dispatch.

     Android exposes the quick selector on tap and the full document chooser on long press. SwiftUI
     `Button` plus `simultaneousGesture` can dispatch both paths for a long press, so this helper
     owns the gesture contract directly and exposes a default accessibility action for the tap path.

     - Parameters:
       - isActive: Whether the represented document category is active in the focused pane.
       - accessibilityIdentifier: Stable UI-test identifier for the toolbar action.
       - accessibilityLabel: VoiceOver label for the toolbar action.
       - onTap: Action for Android's quick-selector path.
       - onLongPress: Action for Android's full-chooser path.
       - icon: Toolbar icon content supplied by the caller.
     - Returns: A toolbar icon view that dispatches either tap or long press, never both.
     - Side effects: Invokes the supplied callback for the recognized gesture.
     - Failure modes: Disabled module actions ignore gestures and hide from accessibility.
     */
    private func moduleToolbarAction<Icon: View>(
        isActive: Bool,
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        icon()
            .foregroundStyle(toolbarIconColor(isActive: isActive))
            .opacity(moduleActionsEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .gesture(moduleToolbarGesture(onTap: onTap, onLongPress: onLongPress))
            .disabled(!moduleActionsEnabled)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHidden(!moduleActionsEnabled)
            .accessibilityAction {
                guard moduleActionsEnabled else { return }
                onTap()
            }
    }

    /**
     Builds the mutually exclusive module toolbar gesture used for tap versus long press.

     - Parameters:
       - onTap: Action for a completed tap gesture.
       - onLongPress: Action for a completed long-press gesture.
     - Returns: An exclusive gesture that resolves to exactly one callback.
     - Side effects: Invokes one callback when the toolbar action is enabled.
     - Failure modes: Disabled module actions ignore completed gestures.
     */
    private func moduleToolbarGesture(
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void
    ) -> some Gesture {
        LongPressGesture().exclusively(before: TapGesture()).onEnded { value in
            guard moduleActionsEnabled else { return }
            switch value {
            case .first(true):
                onLongPress()
            case .second:
                onTap()
            case .first(false):
                break
            }
        }
    }

    private var workspaceToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarWorkspace")
            .frame(width: 24, height: 22)
    }

    private func toolbarIconColor(isActive: Bool = true) -> Color {
        isActive
            ? surfacePalette.toolbarForegroundColor
            : surfacePalette.toolbarSecondaryForegroundColor
    }
}
