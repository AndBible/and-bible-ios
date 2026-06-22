// TextDisplaySettingsCopyDialog.swift -- Selective text-settings copy dialog

import SwiftUI

/**
 Android-style multi-choice dialog for copying text-display settings.

 Android opens `chooseSettingsToCopy` before copying settings to a window, workspace, or global
 defaults. SwiftUI does not provide checkboxes inside `Alert`, so this view supplies the same
 functional contract as a centered dialog panel: unchecked by default, selectable rows, Select
 all/none, Cancel, and OK.
 */
struct TextDisplaySettingsCopyDialog: View {
    let targetTitle: String
    let onCancel: () -> Void
    let onConfirm: (Set<TextDisplaySettingsCopyField>) -> Void

    @State private var selectedFields: Set<TextDisplaySettingsCopyField> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized("copy_settings_title", default: "Which settings do you want to copy?"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                if !targetTitle.isEmpty {
                    Text(targetTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(TextDisplaySettingsCopyField.allCases) { field in
                        Button {
                            toggle(field)
                        } label: {
                            HStack(spacing: 12) {
                                Text(field.title)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: selectedFields.contains(field) ? "checkmark.square" : "square")
                                    .foregroundStyle(selectedFields.contains(field) ? Color.accentColor : Color.secondary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if field.id != TextDisplaySettingsCopyField.allCases.last?.id {
                            Divider()
                                .padding(.leading, 20)
                        }
                    }
                }
            }
            .frame(maxHeight: 430)

            Divider()

            HStack {
                Button(String(localized: "cancel")) {
                    onCancel()
                }

                Spacer()

                Button(selectToggleTitle) {
                    toggleAll()
                }

                Button(String(localized: "okay", defaultValue: "OK")) {
                    onConfirm(selectedFields)
                }
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .shadow(radius: 18)
    }

    private var selectToggleTitle: String {
        if selectedFields.count == TextDisplaySettingsCopyField.allCases.count {
            return localized("select_none", default: "Select none")
        }
        return localized("select_all", default: "Select all")
    }

    private func toggle(_ field: TextDisplaySettingsCopyField) {
        if selectedFields.contains(field) {
            selectedFields.remove(field)
        } else {
            selectedFields.insert(field)
        }
    }

    private func toggleAll() {
        if selectedFields.count == TextDisplaySettingsCopyField.allCases.count {
            selectedFields.removeAll()
        } else {
            selectedFields = Set(TextDisplaySettingsCopyField.allCases)
        }
    }

    private func localized(_ key: String, default defaultValue: String) -> String {
        let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? defaultValue : value
    }
}
