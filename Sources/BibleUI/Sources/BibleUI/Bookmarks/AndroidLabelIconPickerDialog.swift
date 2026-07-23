// AndroidLabelIconPickerDialog.swift -- App-owned Android label icon picker

import BibleCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/**
 Canonical app-owned equivalent of Android Label Edit's custom-icon grid dialog.

 The picker consumes the ordered icon contract from `BibleCore.Label`, renders every canonical icon
 plus Android's disabled/no-icon choice, and dismisses immediately after selection. It composes the
 shared dialog window and does not introduce a native iOS sheet, menu, or feature-local icon list.

 Inputs: current canonical icon name and cancel/selection callbacks

 Output: selected canonical name or nil for no custom icon

 Side effects: invokes one caller callback after outside cancellation or explicit selection

 Failure modes: unknown persisted names render with the model's compatibility fallback until the
 user selects a canonical replacement
 */
struct AndroidLabelIconPickerDialog: View {
    /// Current persisted custom icon.
    let selectedIcon: String?

    /// Caller-owned cancel action.
    let onCancel: () -> Void

    /// Caller-owned selection action; nil clears the custom icon.
    let onSelect: (String?) -> Void

    /// Active application scheme for shared dialog colors.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidLabelIconPickerDialog",
            onOutsideTap: onCancel
        ) {
            AndroidDialogScaffold(
                title: String(localized: "select_custom_icon", defaultValue: "Select custom icon")
            ) {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 40, maximum: 56), spacing: 0)],
                        spacing: 0
                    ) {
                        ForEach(BibleCore.Label.customIconNames, id: \.self) { name in
                            iconButton(name)
                        }
                        iconButton(nil)
                    }
                    .padding(16)
                }
                .frame(minHeight: minimumGridHeight, maxHeight: minimumGridHeight)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "cancel"),
                    accessibilityIdentifier: "androidLabelIconPickerCancelButton",
                    action: onCancel
                )
            }
        }
    }

    /** Builds one canonical icon choice using Android's selected-cell treatment. */
    private func iconButton(_ name: String?) -> some View {
        let isSelected = selectedIcon == name
        return Button {
            onSelect(name)
        } label: {
            Group {
                if let name {
                    AndroidLabelIconView(name: name, size: 24)
                } else {
                    AndBibleIconView(name: AndroidLabelIconAsset.disabledAssetName, size: 24)
                }
            }
            .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .background(isSelected ? AndroidResourcePalette.grey500 : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name ?? String(localized: "disabled", defaultValue: "Disabled"))
        .accessibilityIdentifier("androidLabelIconChoice::\(name ?? "none")")
    }

    /// Android makes the icon grid at least half the device display height.
    private var minimumGridHeight: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.bounds.height * 0.5
        #else
        360
        #endif
    }
}
