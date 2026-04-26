import SwiftUI

/// User actions emitted by the Android-style reader overflow menu.
enum BibleReaderOverflowMenuAction {
    case toggleFullscreen
    case toggleNightMode
    case openWorkspaces
    case toggleTiltToScroll
    case toggleReverseSplitMode
    case toggleWindowPinning
    case openLabelSettings
    case toggleSectionTitles
    case openStrongsMode
    case toggleVerseNumbers
    case openTextOptions
}

/// Snapshot of the reader overflow menu state resolved by the parent coordinator.
struct BibleReaderOverflowMenuState {
    let isFullScreen: Bool
    let showsNightModeToggle: Bool
    let nightMode: Bool
    let showsTiltToScrollToggle: Bool
    let tiltToScrollEnabled: Bool
    let showsReverseSplitModeToggle: Bool
    let reverseSplitModeEnabled: Bool
    let windowPinningEnabled: Bool
    let showsBibleDisplayOptions: Bool
    let sectionTitlesEnabled: Bool
    let moduleHasStrongs: Bool
    let strongsMenuIconAssetName: String
    let verseNumbersEnabled: Bool
}

/**
 Renders the Android-style reader overflow popup.

 The parent view owns state mutation and presentation routing. This view owns only menu structure,
 Android-parity row labels, icons, and accessibility identifiers.
 */
struct BibleReaderOverflowMenu: View {
    let state: BibleReaderOverflowMenuState
    let colorScheme: ColorScheme
    let onAction: (BibleReaderOverflowMenuAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleRow(
                title: localizedDrawerString("toggle_fullscreen", default: "Fullscreen"),
                assetName: "OverflowFullscreen",
                isOn: state.isFullScreen,
                identifier: "readerOverflowFullscreenToggle",
                action: .toggleFullscreen
            )

            if state.showsNightModeToggle {
                Divider()
                toggleRow(
                    title: localizedDrawerString("options_menu_night_mode", default: "Night mode"),
                    assetName: "OverflowNightMode",
                    isOn: state.nightMode,
                    identifier: "readerOverflowNightModeToggle",
                    action: .toggleNightMode
                )
            }

            Divider()
            button(
                title: ellipsisTitle(localizedDrawerString("switch_to_workspace", default: "Workspaces")),
                assetName: "OverflowWorkspace",
                identifier: "readerOpenWorkspacesAction",
                action: .openWorkspaces
            )

            if state.showsTiltToScrollToggle {
                Divider()
                toggleRow(
                    title: String(localized: "tilt_to_scroll"),
                    assetName: "OverflowTiltToScroll",
                    isOn: state.tiltToScrollEnabled,
                    identifier: "readerOverflowTiltToScrollToggle",
                    action: .toggleTiltToScroll
                )
            }

            if state.showsReverseSplitModeToggle {
                Divider()
                toggleRow(
                    title: String(localized: "reversed_split_mode"),
                    assetName: "OverflowSplitMode",
                    isOn: state.reverseSplitModeEnabled,
                    identifier: "readerOverflowSplitModeToggle",
                    action: .toggleReverseSplitMode
                )
            }

            Divider()
            toggleRow(
                title: localizedDrawerString("window_pinning_menutitle", default: "Window pinning"),
                assetName: "OverflowWindowPinning",
                isOn: state.windowPinningEnabled,
                identifier: "readerOverflowWindowPinningToggle",
                action: .toggleWindowPinning
            )

            Divider()
            button(
                title: ellipsisTitle(String(localized: "label_settings")),
                assetName: "OverflowLabelSettings",
                action: .openLabelSettings
            )

            if state.showsBibleDisplayOptions {
                Divider()
                toggleRow(
                    title: localizedAndroidOverflowString(
                        androidKey: "prefs_section_title_title",
                        fallbackKey: "section_titles",
                        default: "Section titles"
                    ),
                    assetName: "OverflowSectionTitles",
                    isOn: state.sectionTitlesEnabled,
                    identifier: "readerOverflowSectionTitlesToggle",
                    action: .toggleSectionTitles
                )
            }

            if state.moduleHasStrongs {
                Divider()
                button(
                    title: ellipsisTitle(
                        localizedAndroidOverflowString(
                            androidKey: "prefs_show_strongs_title",
                            fallbackKey: "strongs_numbers",
                            default: "Strong's numbers"
                        )
                    ),
                    assetName: state.strongsMenuIconAssetName,
                    identifier: "readerOverflowStrongsModeAction",
                    action: .openStrongsMode
                )
            }

            if state.showsBibleDisplayOptions {
                Divider()
                toggleRow(
                    title: localizedAndroidOverflowString(
                        androidKey: "prefs_show_verseno_title",
                        fallbackKey: nil,
                        default: "Chapter & verse numbers"
                    ),
                    assetName: "OverflowChapterVerseNumbers",
                    isOn: state.verseNumbersEnabled,
                    identifier: "readerOverflowVerseNumbersToggle",
                    action: .toggleVerseNumbers
                )
            }

            Divider()
            button(
                title: ellipsisTitle(
                    localizedDrawerString("all_text_options_window_menutitle", default: "All text options")
                ),
                assetName: "OverflowTextOptions",
                identifier: "readerOpenSettingsAction",
                action: .openTextOptions
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerOverflowMenu")
        .background(menuBackground)
    }

    @ViewBuilder
    private func button(
        title: String,
        assetName: String,
        identifier: String? = nil,
        action: BibleReaderOverflowMenuAction
    ) -> some View {
        if let identifier {
            Button {
                onAction(action)
            } label: {
                buttonLabel(title: title, assetName: assetName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        } else {
            Button {
                onAction(action)
            } label: {
                buttonLabel(title: title, assetName: assetName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
    }

    private func buttonLabel(
        title: String,
        assetName: String,
        trailingAccessory: TrailingAccessory = .none
    ) -> some View {
        HStack(spacing: 12) {
            ToolbarAssetIcon(name: assetName, size: 16)
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15))
            Spacer()
            switch trailingAccessory {
            case .none:
                EmptyView()
            case .checkbox(let isOn):
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOn ? checkboxTint : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func toggleRow(
        title: String,
        assetName: String,
        isOn: Bool,
        identifier: String,
        action: BibleReaderOverflowMenuAction
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            buttonLabel(
                title: title,
                assetName: assetName,
                trailingAccessory: .checkbox(isOn)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isOn ? "on" : "off")
    }

    private var checkboxTint: Color {
        Color(red: 111.0 / 255.0, green: 214.0 / 255.0, blue: 209.0 / 255.0)
    }

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

    private func localizedDrawerString(_ key: String, default defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    private func localizedAndroidOverflowString(
        androidKey: String,
        fallbackKey: String?,
        default defaultValue: String
    ) -> String {
        let androidValue = Bundle.main.localizedString(forKey: androidKey, value: nil, table: nil)
        if androidValue != androidKey {
            return androidValue
        }
        if let fallbackKey {
            return Bundle.main.localizedString(forKey: fallbackKey, value: defaultValue, table: nil)
        }
        return defaultValue
    }

    private func ellipsisTitle(_ title: String) -> String {
        if title.hasSuffix("...") || title.hasSuffix("…") {
            return title
        }
        return "\(title)…"
    }

    private enum TrailingAccessory {
        case none
        case checkbox(Bool)
    }
}
