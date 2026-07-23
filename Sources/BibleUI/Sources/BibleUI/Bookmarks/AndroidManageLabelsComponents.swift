// AndroidManageLabelsComponents.swift -- Shared Android Manage Labels presentation

import BibleCore
import SwiftUI

/** Android category headers inserted by `ManageLabels.updateLabelList`. */
enum AndroidManageLabelCategory: String, Identifiable, CaseIterable {
    case active
    case recent
    case other

    var id: String { rawValue }

    /// Localized Android category title.
    var localizedTitle: String {
        switch self {
        case .active:
            String(localized: "active_labels", defaultValue: "Selected labels")
        case .recent:
            String(localized: "recent_labels", defaultValue: "Recent labels")
        case .other:
            String(localized: "other_labels", defaultValue: "Other labels")
        }
    }
}

/** One stable row in Android's mixed category-and-label list. */
enum AndroidManageLabelListItem: Identifiable, Equatable {
    case category(AndroidManageLabelCategory)
    case label(UUID)

    var id: String {
        switch self {
        case .category(let category): "category::\(category.rawValue)"
        case .label(let id): "label::\(id.uuidString)"
        }
    }
}

/**
 Canonical list projection for Android's non-Study-Pad Manage Labels modes.

 Android inserts Active/Recent/Other category rows into the same collection as labels and sorts the
 mixed collection by category, header-before-label, localized name, and stable identity. Assignment
 and Hide Labels keep selected labels visible while filtering; Workspace intentionally filters
 auto-assigned labels like Android because its `selectedLabels` set is empty. Centralizing that
 distinction prevents each app-owned route from approximating `ManageLabels.updateLabelList()`.

 Inputs: candidate labels, active/recent identities, name-search mode, and identities forced visible

 Output: one deterministically ordered mixed category-and-label collection

 Side effects: none

 Failure modes: none; stale identities simply do not produce rows
 */
enum AndroidManageLabelsListProjection {
    /** Builds Android's retained category projection after load, search, or explicit Reorder. */
    static func items(
        labels: [BibleCore.Label],
        activeLabelIDs: Set<UUID>,
        recentLabelIDs: [UUID],
        alwaysVisibleLabelIDs: Set<UUID>,
        searchText: String,
        searchesAnywhereInName: Bool
    ) -> [AndroidManageLabelListItem] {
        let recentIDs = Set(recentLabelIDs)
        let matchingLabels = labels.filter { label in
            alwaysVisibleLabelIDs.contains(label.id)
                || matches(
                    label,
                    searchText: searchText,
                    searchesAnywhereInName: searchesAnywhereInName
                )
        }
        var rankedItems: [RankedItem] = []
        if !activeLabelIDs.isEmpty {
            rankedItems.append(RankedItem(rank: 1, headerRank: 0, name: "", item: .category(.active)))
        }
        rankedItems.append(RankedItem(rank: 2, headerRank: 0, name: "", item: .category(.recent)))
        rankedItems.append(RankedItem(rank: 3, headerRank: 0, name: "", item: .category(.other)))

        for label in matchingLabels {
            let rank: Int
            if activeLabelIDs.contains(label.id) {
                rank = 1
            } else if recentIDs.contains(label.id) {
                rank = 2
            } else {
                rank = 3
            }
            rankedItems.append(RankedItem(
                rank: rank,
                headerRank: 1,
                name: AndroidLabelPresentation.displayName(for: label).localizedLowercase,
                item: .label(label.id)
            ))
        }

        return rankedItems.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.headerRank != rhs.headerRank { return lhs.headerRank < rhs.headerRank }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.item.id < rhs.item.id
        }.map(\.item)
    }

    /** Applies Android's anchored/contains name filter to one localized label title. */
    private static func matches(
        _ label: BibleCore.Label,
        searchText: String,
        searchesAnywhereInName: Bool
    ) -> Bool {
        guard !searchText.isEmpty else { return true }
        let options: String.CompareOptions = searchesAnywhereInName
            ? [.caseInsensitive]
            : [.caseInsensitive, .anchored]
        return AndroidLabelPresentation.displayName(for: label)
            .range(of: searchText, options: options) != nil
    }

    /** Sort tuple retained only inside the canonical mixed-list projection. */
    private struct RankedItem {
        let rank: Int
        let headerRank: Int
        let name: String
        let item: AndroidManageLabelListItem
    }
}

/**
 Composes the one shared Android `ManageLabels` activity used by every presentation mode.

 Android owns Study Pads, Workspace Labels, Assign Labels, and Hidden Labels as modes of the same
 activity. Those modes vary their commands, rows, and persistence, but they do not own independent
 app bars, search-strip placement, backgrounds, or native-navigation suppression. Keeping that
 common structure here prevents one mode from losing an overflow action, palette update, or safe-
 area correction while the others remain correct.

 Inputs: localized mode title, app-bar identity, owner palette, Back command, search-mode state,
 search binding, mode-specific app-bar actions, and mode-specific results

 Output: one full app-owned Manage Labels activity using the shared activity and search components

 Side effects: updates the search binding and invokes caller-owned Back, search-mode, or action
 commands after explicit user interaction

 Failure modes: none; persistence and workflow failures remain owned by each mode's presentation
 layer
 */
struct AndroidManageLabelsActivityScreen<Actions: View, Results: View>: View {
    let title: String
    let appBarAccessibilityIdentifier: String
    let surfacePalette: ReaderThemeSurfacePalette
    let onBack: () -> Void
    let compactModeTitle: String
    let localizedModeTitle: String
    let isModeActive: Bool
    @Binding var searchText: String
    let accessibilityPrefix: String
    let popupAnchorID: String?
    let onSelectSearchMode: () -> Void

    private let actions: Actions
    private let results: Results

    /** Creates the shared activity shell without invoking any supplied command. */
    init(
        title: String,
        appBarAccessibilityIdentifier: String,
        surfacePalette: ReaderThemeSurfacePalette,
        onBack: @escaping () -> Void,
        compactModeTitle: String,
        localizedModeTitle: String,
        isModeActive: Bool,
        searchText: Binding<String>,
        accessibilityPrefix: String,
        popupAnchorID: String? = nil,
        onSelectSearchMode: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder results: () -> Results
    ) {
        self.title = title
        self.appBarAccessibilityIdentifier = appBarAccessibilityIdentifier
        self.surfacePalette = surfacePalette
        self.onBack = onBack
        self.compactModeTitle = compactModeTitle
        self.localizedModeTitle = localizedModeTitle
        self.isModeActive = isModeActive
        _searchText = searchText
        self.accessibilityPrefix = accessibilityPrefix
        self.popupAnchorID = popupAnchorID
        self.onSelectSearchMode = onSelectSearchMode
        self.actions = actions()
        self.results = results()
    }

    var body: some View {
        AndroidActivityScreen(
            title: title,
            accessibilityIdentifier: appBarAccessibilityIdentifier,
            palette: surfacePalette,
            onBack: onBack
        ) {
            actions
        } content: {
            VStack(spacing: 0) {
                AndroidManageLabelsSearchBar(
                    compactModeTitle: compactModeTitle,
                    localizedModeTitle: localizedModeTitle,
                    isModeActive: isModeActive,
                    searchText: $searchText,
                    surfacePalette: surfacePalette,
                    accessibilityPrefix: accessibilityPrefix,
                    popupAnchorID: popupAnchorID,
                    onSelectMode: onSelectSearchMode
                )
                Divider().overlay(surfacePalette.inactiveBorderColor)
                results
            }
        }
    }
}

/**
 Shared search strip used by every app-owned Android Manage Labels mode.

 Android uses one outlined compact search-mode button, an owner-colored text field underline, and
 a trailing clear action. The caller owns search-mode persistence and popup presentation so this
 component remains reusable by Study Pads, Assignment, Workspace, and Hide Labels modes.

 Inputs: owner palette, compact/localized mode titles, search binding, and mode-selection action

 Output: one Android `textSearchLayout` equivalent

 Side effects: updates `searchText`, clears it, or invokes `onSelectMode`

 Failure modes: none
 */
struct AndroidManageLabelsSearchBar: View {
    let compactModeTitle: String
    let localizedModeTitle: String
    let isModeActive: Bool
    @Binding var searchText: String
    let surfacePalette: ReaderThemeSurfacePalette
    let accessibilityPrefix: String
    let popupAnchorID: String?
    let onSelectMode: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /** Creates a shared Manage Labels search strip with an optional popup anchor. */
    init(
        compactModeTitle: String,
        localizedModeTitle: String,
        isModeActive: Bool,
        searchText: Binding<String>,
        surfacePalette: ReaderThemeSurfacePalette,
        accessibilityPrefix: String,
        popupAnchorID: String? = nil,
        onSelectMode: @escaping () -> Void
    ) {
        self.compactModeTitle = compactModeTitle
        self.localizedModeTitle = localizedModeTitle
        self.isModeActive = isModeActive
        _searchText = searchText
        self.surfacePalette = surfacePalette
        self.accessibilityPrefix = accessibilityPrefix
        self.popupAnchorID = popupAnchorID
        self.onSelectMode = onSelectMode
    }

    var body: some View {
        HStack(spacing: 8) {
            anchoredModeButton

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField(
                        "",
                        text: $searchText,
                        prompt: Text(String(localized: "labels_search_hint", defaultValue: "Search"))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    )
                    .textFieldStyle(.plain)
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .accessibilityIdentifier("\(accessibilityPrefix)SearchField")

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            AndBibleIconView(name: "ActivityClose", size: 24)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AndroidResourcePalette.grey600)
                        .accessibilityLabel(String(localized: "clear", defaultValue: "Clear"))
                        .accessibilityIdentifier("\(accessibilityPrefix)ClearSearchButton")
                    }
                }
                Rectangle()
                    .fill(AndroidDialogSurfacePalette.accent(for: colorScheme))
                    .frame(height: 2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .background(surfacePalette.backgroundColor)
    }

    /// Applies the shared popup anchor only for modes whose compact control opens a menu.
    @ViewBuilder
    private var anchoredModeButton: some View {
        if let popupAnchorID {
            modeButton.androidPopupMenuAnchor(id: popupAnchorID)
        } else {
            modeButton
        }
    }

    /// Outlined compact Android search-mode control shared by toggle and popup modes.
    private var modeButton: some View {
        Button(action: onSelectMode) {
            Text(compactModeTitle)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 48, height: 38)
                .foregroundStyle(isModeActive ? Color.black : surfacePalette.foregroundColor)
                .background(isModeActive ? AndroidResourcePalette.blue200 : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(AndroidResourcePalette.grey500, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(accessibilityPrefix)SearchModeButton")
        .accessibilityLabel(localizedModeTitle)
    }
}

/**
 Shared category heading from Android `manage_labels_list_item`.

 Inputs: semantic category and owner palette

 Output: one noninteractive category row

 Side effects: none

 Failure modes: none
 */
struct AndroidManageLabelCategoryRow: View {
    let category: AndroidManageLabelCategory
    let surfacePalette: ReaderThemeSurfacePalette

    var body: some View {
        Text(category.localizedTitle)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(surfacePalette.foregroundColor)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.leading, 20)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("manageLabelsCategory::\(category.rawValue)")
    }
}

/**
 Reusable app-owned equivalent of Android `manage_labels_list_item` for editable label modes.

 The row preserves Android's control order and independent actions: auto-assign label icon,
 favourite, assignment checkbox, primary bookmark, label name/edit target, workspace-override
 indicator, and optional custom icon. All vector icons come from the shared Android asset catalog;
 the row does not redraw feature-local approximations.

 Inputs: persisted label, draft state, mode visibility flags, owner palette, and action closures

 Output: one compact Android Manage Labels row

 Side effects: invokes only the explicitly tapped action

 Failure modes: none
 */
struct AndroidManageLabelRow: View {
    let label: BibleCore.Label
    let isSelected: Bool
    let isFavourite: Bool
    let isPrimary: Bool
    let isAutoAssigned: Bool
    let hasWorkspaceOverride: Bool
    let showsAssignment: Bool
    let showsFavourite: Bool
    let showsPrimary: Bool
    let showsAutoAssign: Bool
    let surfacePalette: ReaderThemeSurfacePalette
    let onEdit: () -> Void
    let onToggleAssignment: () -> Void
    let onToggleFavourite: () -> Void
    let onSelectPrimary: () -> Void
    let onToggleAutoAssign: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color {
        AndroidDialogSurfacePalette.accent(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsAutoAssign {
                iconAction(
                    asset: isAutoAssigned ? "LabelAutoAssign" : "BookmarkLabel",
                    tint: Color(argbInt: label.color),
                    label: String(
                        localized: "auto_assign_labels1",
                        defaultValue: "Auto-assign label to new bookmarks"
                    ),
                    identifier: "manageLabelsAutoAssign::\(label.id.uuidString)",
                    action: onToggleAutoAssign
                )
            } else {
                AndBibleIconView(name: "BookmarkLabel", size: 24)
                    .foregroundStyle(Color(argbInt: label.color))
                    .frame(width: 36, height: 40)
            }

            if showsFavourite {
                iconAction(
                    asset: isFavourite ? "BookmarkFavoriteFilled" : "BookmarkFavoriteOutline",
                    tint: AndroidResourcePalette.grey500,
                    label: String(localized: "favourite_label", defaultValue: "Favourite label"),
                    identifier: "manageLabelsFavourite::\(label.id.uuidString)",
                    action: onToggleFavourite
                )
            }

            if showsAssignment {
                Button(action: onToggleAssignment) {
                    AndroidCheckboxIndicator(
                        isOn: isSelected,
                        uncheckedColor: AndroidResourcePalette.grey500,
                        accentColor: accentColor
                    )
                    .frame(width: 36, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AndroidLabelPresentation.displayName(for: label))
                .accessibilityValue(isSelected ? String(localized: "on") : String(localized: "off"))
                .accessibilityIdentifier("manageLabelsAssignment::\(label.id.uuidString)")
            }

            if showsPrimary, isSelected {
                iconAction(
                    asset: isPrimary ? "BookmarkPrimaryFilled" : "BookmarkPrimaryOutline",
                    tint: AndroidResourcePalette.grey500,
                    label: String(localized: "primary_label", defaultValue: "Primary label"),
                    identifier: "manageLabelsPrimary::\(label.id.uuidString)",
                    action: onSelectPrimary
                )
            }

            Button(action: onEdit) {
                Text(AndroidLabelPresentation.displayName(for: label))
                    .font(.system(size: 17))
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("manageLabelsEdit::\(label.id.uuidString)")

            if hasWorkspaceOverride {
                AndBibleIconView(name: "WorkspaceOverride", size: 16)
                    .foregroundStyle(AndroidResourcePalette.grey500)
                    .accessibilityLabel(String(
                        localized: "workspace_override_indicator",
                        defaultValue: "This label has workspace-specific display mode"
                    ))
            }

            if let customIcon = label.customIcon, !customIcon.isEmpty {
                AndroidLabelIconView(name: customIcon, size: 24)
                    .foregroundStyle(Color(argbInt: label.color))
                    .frame(width: 30, height: 40)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manageLabelsRow::\(label.id.uuidString)")
    }

    /// Builds one exact Android asset action with a minimum accessible touch target.
    private func iconAction(
        asset: String,
        tint: Color,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            AndBibleIconView(name: asset, size: 24)
                .foregroundStyle(tint)
                .frame(width: 36, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/** Android help variants owned by the shared Manage Labels activity. */
enum AndroidManageLabelsHelpMode {
    case assign
    case workspace(isWindow: Bool)
    case hideLabels(isWindow: Bool)

    var title: String {
        switch self {
        case .assign:
            String(localized: "assign_labels", defaultValue: "Assign labels")
        case .workspace:
            String(localized: "labels", defaultValue: "Labels")
        case .hideLabels:
            String(
                localized: "bookmark_settings_hide_labels_title",
                defaultValue: "Hide specified labels"
            )
        }
    }
}

/**
 Canonical app-owned help dialog for Android Manage Labels modes.

 This content mirrors `ManageLabels.help(HelpMode)`: tutorial link, mode introduction, workspace
 scope, and explanations using the same shared bookmark/label/favourite/reorder assets as the live
 route. It composes the global Android dialog window and palette rather than inventing a feature
 card or inheriting iOS alert styling.
 */
struct AndroidManageLabelsHelpDialog: View {
    let mode: AndroidManageLabelsHelpMode
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidManageLabelsHelpDialog",
            onOutsideTap: onDismiss
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image("DrawerLogo", bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                    Text(mode.title)
                        .font(.system(size: 24, weight: .semibold))
                }

                AndroidAdaptiveDialogScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AndroidDialogLink(
                            String(localized: "watch_tutorial_video", defaultValue: "Watch tutorial video (English)"),
                            destination: URL(
                                string: "https://www.youtube.com/playlist?list=PLD-W_Iw-N2MlzNt0Zpna-QoTBpEpWSden"
                            )!,
                            isItalic: true
                        )

                        Text(introduction)

                        if let scopeText {
                            Text(scopeText)
                        }

                        if showsAssignmentExplanations {
                            explanationRow(
                                assets: ["BookmarkPrimaryFilled"],
                                text: localizedFormattingText(
                                    key: "assing_labels_help2",
                                    defaultValue: "Use %@ to specify which label color is shown."
                                )
                            )
                            explanationRow(
                                assets: ["BookmarkLabel", "LabelAutoAssign"],
                                text: localizedFormattingText(
                                    key: "assing_labels_help3",
                                    defaultValue: "Tap %@ icon to have that label is assigned automatically to new bookmarks."
                                )
                            )
                            explanationRow(
                                assets: ["BookmarkFavoriteFilled"],
                                text: localizedFormattingText(
                                    key: "assing_labels_help4",
                                    defaultValue: "Tap %@ to add label to your favourite list for quick access."
                                )
                            )
                        }

                        explanationRow(
                            assets: ["ManageLabelsReorder"],
                            text: localizedFormattingText(
                                key: "assing_labels_help5",
                                defaultValue: "Tap %@ to re-order the list based on your selections."
                            )
                        )
                    }
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()
                    Button(String(localized: "okay", defaultValue: "OK"), action: onDismiss)
                        .font(.system(size: 17, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                        .accessibilityIdentifier("androidManageLabelsHelpOKButton")
                }
            }
            .padding(24)
            .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
        }
    }

    private var introduction: String {
        switch mode {
        case .assign:
            String(localized: "assing_labels_help1", defaultValue: "Each bookmark can be assigned multiple labels.")
        case .workspace:
            String(
                localized: "auto_assing_labels_help1",
                defaultValue: "Here you can adjust which labels are assigned automatically to bookmarks that you create."
            )
        case .hideLabels:
            String(
                localized: "bookmark_settings_hide_labels_summary",
                defaultValue: "Hide bookmarks that are marked with specified label(s)"
            )
        }
    }

    private var scopeText: String? {
        let isWindow: Bool
        switch mode {
        case .workspace(let ownerIsWindow), .hideLabels(let ownerIsWindow):
            isWindow = ownerIsWindow
        case .assign:
            return nil
        }
        let scope = isWindow
            ? String(localized: "setting_scope_window", defaultValue: "this window")
            : String(localized: "setting_scope_workspace", defaultValue: "this workspace")
        return String(
            format: String(localized: "setting_scope", defaultValue: "This setting applies to %@."),
            scope
        )
    }

    private var showsAssignmentExplanations: Bool {
        if case .hideLabels = mode { return false }
        return true
    }

    /// Builds one icon-led explanation using the exact assets from the live controls.
    private func explanationRow(assets: [String], text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(assets, id: \.self) { asset in
                    AndBibleIconView(name: asset, size: 22)
                }
            }
            .foregroundStyle(AndroidResourcePalette.grey500)
            .frame(minWidth: CGFloat(assets.count) * 24, alignment: .leading)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Removes Android's inline drawable placeholder after the exact icon is rendered beside it.
    private func localizedFormattingText(key: String, defaultValue: String) -> String {
        let format: String
        switch key {
        case "assing_labels_help2":
            format = String(
                localized: "assing_labels_help2",
                defaultValue: "Use %@ to specify which label color is shown."
            )
        case "assing_labels_help3":
            format = String(
                localized: "assing_labels_help3",
                defaultValue: "Tap %@ icon to have that label is assigned automatically to new bookmarks."
            )
        case "assing_labels_help4":
            format = String(
                localized: "assing_labels_help4",
                defaultValue: "Tap %@ to add label to your favourite list for quick access."
            )
        case "assing_labels_help5":
            format = String(
                localized: "assing_labels_help5",
                defaultValue: "Tap %@ to re-order the list based on your selections."
            )
        default:
            format = defaultValue
        }
        return String(format: format, "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
