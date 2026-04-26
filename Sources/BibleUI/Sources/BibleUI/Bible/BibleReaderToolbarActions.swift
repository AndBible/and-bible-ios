import SwiftUI

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
    private let preferredSingleAccessory: BibleReaderToolbarAccessoryButton?
    private let moduleHasStrongs: Bool
    private let strongsIconAssetName: String
    private let strongsMode: Int
    private let strongsEnabled: Bool
    private let isBibleActive: Bool
    private let isCommentaryActive: Bool
    private let onShowSearch: () -> Void
    private let onShowSpeak: () -> Void
    private let onApplyStrongsMode: (Int) -> Void
    private let onBibleTap: () -> Void
    private let onBibleLongPress: () -> Void
    private let onCommentaryTap: () -> Void
    private let onCommentaryLongPress: () -> Void
    private let onShowWorkspaces: () -> Void
    private let overflowButton: () -> OverflowButton

    init(
        usesCompactToolbar: Bool,
        preferredSingleAccessory: BibleReaderToolbarAccessoryButton?,
        moduleHasStrongs: Bool,
        strongsIconAssetName: String,
        strongsMode: Int,
        strongsEnabled: Bool,
        isBibleActive: Bool,
        isCommentaryActive: Bool,
        onShowSearch: @escaping () -> Void,
        onShowSpeak: @escaping () -> Void,
        onApplyStrongsMode: @escaping (Int) -> Void,
        onBibleTap: @escaping () -> Void,
        onBibleLongPress: @escaping () -> Void,
        onCommentaryTap: @escaping () -> Void,
        onCommentaryLongPress: @escaping () -> Void,
        onShowWorkspaces: @escaping () -> Void,
        @ViewBuilder overflowButton: @escaping () -> OverflowButton
    ) {
        self.usesCompactToolbar = usesCompactToolbar
        self.preferredSingleAccessory = preferredSingleAccessory
        self.moduleHasStrongs = moduleHasStrongs
        self.strongsIconAssetName = strongsIconAssetName
        self.strongsMode = strongsMode
        self.strongsEnabled = strongsEnabled
        self.isBibleActive = isBibleActive
        self.isCommentaryActive = isCommentaryActive
        self.onShowSearch = onShowSearch
        self.onShowSpeak = onShowSpeak
        self.onApplyStrongsMode = onApplyStrongsMode
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
                showSearch: true,
                showSpeak: false,
                showWorkspace: false
            )
        } else {
            ViewThatFits(in: .horizontal) {
                toolbarActionButtons(
                    showSearch: true,
                    showSpeak: true,
                    showWorkspace: true
                )
                toolbarActionButtons(
                    showSearch: true,
                    showSpeak: true,
                    showWorkspace: false
                )
                toolbarActionButtons(
                    showSearch: preferredSingleAccessory == .search,
                    showSpeak: preferredSingleAccessory == .speak,
                    showWorkspace: true
                )
                toolbarActionButtons(
                    showSearch: preferredSingleAccessory == .search,
                    showSpeak: preferredSingleAccessory == .speak,
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
                Menu {
                    ForEach(StrongsMode.allCases) { mode in
                        Button {
                            onApplyStrongsMode(mode.rawValue)
                        } label: {
                            if strongsMode == mode.rawValue {
                                SwiftUI.Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    strongsIcon
                        .foregroundStyle(toolbarIconColor(isActive: strongsEnabled))
                } primaryAction: {
                    onApplyStrongsMode((strongsMode + 1) % 3)
                }
                .accessibilityIdentifier("readerStrongsToolbarButton")
                .accessibilityLabel(String(localized: "toggle_strongs_numbers"))
            }

            bibleToolbarIcon
                .foregroundStyle(toolbarIconColor(isActive: isBibleActive))
                .contentShape(Rectangle())
                .accessibilityIdentifier("readerBibleToolbarButton")
                .accessibilityLabel(String(localized: "bible"))
                .accessibilityAddTraits(.isButton)
                .onTapGesture(perform: onBibleTap)
                .onLongPressGesture(perform: onBibleLongPress)

            commentaryToolbarIcon
                .foregroundStyle(toolbarIconColor(isActive: isCommentaryActive))
                .contentShape(Rectangle())
                .accessibilityIdentifier("readerCommentaryToolbarButton")
                .accessibilityLabel(String(localized: "commentaries"))
                .accessibilityAddTraits(.isButton)
                .onTapGesture(perform: onCommentaryTap)
                .onLongPressGesture(perform: onCommentaryLongPress)

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

    private var bibleToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarBible")
            .frame(width: 24, height: 22)
    }

    private var commentaryToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarCommentary")
            .frame(width: 24, height: 22)
    }

    private var workspaceToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarWorkspace")
            .frame(width: 24, height: 22)
    }

    private func toolbarIconColor(isActive: Bool = true) -> Color {
        isActive ? .primary : .secondary
    }
}
