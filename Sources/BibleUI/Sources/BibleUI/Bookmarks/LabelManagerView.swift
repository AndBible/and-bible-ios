// LabelManagerView.swift — Label management screen

import SwiftUI
import SwiftData
import BibleCore

/// View for creating, editing, and deleting bookmark labels.
/// Supports rename, color change, favourite toggle, and display style.
public struct LabelManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BibleCore.Label.name) private var allLabels: [BibleCore.Label]
    @State private var showNewLabel = false
    @State private var newLabelName = ""
    @State private var editingLabel: BibleCore.Label?
    var onOpenStudyPad: ((UUID) -> Void)?

    public init(onOpenStudyPad: ((UUID) -> Void)? = nil) {
        self.onOpenStudyPad = onOpenStudyPad
    }

    private var userLabels: [BibleCore.Label] {
        allLabels.filter { $0.isRealLabel }
    }

    public var body: some View {
        Group {
            if userLabels.isEmpty {
                ContentUnavailableView(
                    String(localized: "no_labels"),
                    systemImage: "tag",
                    description: Text(String(localized: "no_labels_description"))
                )
            } else {
                labelList
            }
        }
        .navigationTitle(String(localized: "labels"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "add"), systemImage: "plus") {
                    showNewLabel = true
                }
            }
        }
        .alert(String(localized: "new_label"), isPresented: $showNewLabel) {
            TextField(String(localized: "label_name"), text: $newLabelName)
            Button(String(localized: "create")) { createLabel() }
            Button(String(localized: "cancel"), role: .cancel) { newLabelName = "" }
        }
        .sheet(item: $editingLabel) { label in
            NavigationStack {
                LabelEditView(label: label)
            }
        }
    }

    private var labelList: some View {
        List {
            ForEach(userLabels) { label in
                Button {
                    editingLabel = label
                } label: {
                    HStack(spacing: 10) {
                        if let icon = label.customIcon, !icon.isEmpty {
                            Image(systemName: BibleCore.Label.sfSymbol(for: icon) ?? icon)
                                .font(.body)
                                .foregroundStyle(Color(argbInt: label.color))
                        } else {
                            Circle()
                                .fill(Color(argbInt: label.color))
                                .frame(width: 14, height: 14)
                        }

                        Text(label.name)
                            .font(.body)
                            .foregroundStyle(.primary)

                        Spacer()

                        if label.favourite {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }

                        if label.underlineStyle {
                            Image(systemName: "underline")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }

                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(String(localized: "delete"), role: .destructive) {
                        deleteLabel(label)
                    }
                }
                .swipeActions(edge: .leading) {
                    if onOpenStudyPad != nil {
                        Button {
                            onOpenStudyPad?(label.id)
                        } label: {
                            SwiftUI.Label(String(localized: "studypad"), systemImage: "book")
                        }
                        .tint(Color(argbInt: label.color))
                    }
                }
                .contextMenu {
                    Button {
                        editingLabel = label
                    } label: {
                        SwiftUI.Label(String(localized: "edit"), systemImage: "pencil")
                    }
                    if onOpenStudyPad != nil {
                        Button {
                            onOpenStudyPad?(label.id)
                        } label: {
                            SwiftUI.Label(String(localized: "open_studypad"), systemImage: "book")
                        }
                    }
                    Button(role: .destructive) {
                        deleteLabel(label)
                    } label: {
                        SwiftUI.Label(String(localized: "delete"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private func createLabel() {
        guard !newLabelName.isEmpty else { return }
        let label = BibleCore.Label(name: newLabelName)
        modelContext.insert(label)
        try? modelContext.save()
        newLabelName = ""
    }

    private func deleteLabel(_ label: BibleCore.Label) {
        modelContext.delete(label)
        try? modelContext.save()
    }
}

// MARK: - Label Edit View

/// Edit screen for a single label: name, color, favourite, display style.
private struct LabelEditView: View {
    @Bindable var label: BibleCore.Label
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Android canonical icon names — stored in Label.customIcon for Vue.js compatibility.
    // Displayed via Label.sfSymbol(for:) which maps to SF Symbols for native rendering.
    private static let iconNames: [String] = [
        "book", "book-bible", "cross",
        "church", "star-of-david", "person-praying",
        "info", "question", "exclamation",
        "lightbulb", "bell", "flag",
        "star", "tag", "envelope",
        "comment", "share-nodes", "link",
        "handshake", "clock", "map-marker",
        "globe", "landmark", "calendar",
        "user", "music", "microphone",
        "key", "crown", "heart", "heart-crack",
    ]

    // Preset colors matching Android's highlight palette
    private static let presetColors: [(name: String, argb: Int)] = [
        ("Red", Int(Int32(bitPattern: 0xFFFF0000))),
        ("Green", Int(Int32(bitPattern: 0xFF00FF00))),
        ("Blue", Int(Int32(bitPattern: 0xFF0000FF))),
        ("Yellow", Int(Int32(bitPattern: 0xFFFFFF00))),
        ("Orange", Int(Int32(bitPattern: 0xFFFFA500))),
        ("Purple", Int(Int32(bitPattern: 0xFF640096))),
        ("Magenta", Int(Int32(bitPattern: 0xFFFF00FF))),
        ("Cyan", Int(Int32(bitPattern: 0xFF00FFFF))),
        ("Light Blue", Int(Int32(bitPattern: 0xFF91A7FF))),
        ("Pink", Int(Int32(bitPattern: 0xFFFF69B4))),
        ("Teal", Int(Int32(bitPattern: 0xFF008080))),
        ("Brown", Int(Int32(bitPattern: 0xFF8B4513))),
    ]

    var body: some View {
        Form {
            Section(String(localized: "label_edit_name")) {
                TextField(String(localized: "label_name"), text: $label.name)
            }

            Section(String(localized: "label_edit_color")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(Self.presetColors, id: \.argb) { preset in
                        Button {
                            label.color = preset.argb
                            save()
                        } label: {
                            Circle()
                                .fill(Color(argbInt: preset.argb))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if label.color == preset.argb {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "label_edit_icon")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    // "No Icon" clear button
                    Button {
                        label.customIcon = nil
                        save()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.title2)
                            .frame(width: 36, height: 36)
                            .foregroundStyle(label.customIcon == nil ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    ForEach(Self.iconNames, id: \.self) { canonicalName in
                        Button {
                            if label.customIcon == canonicalName {
                                label.customIcon = nil
                            } else {
                                label.customIcon = canonicalName
                            }
                            save()
                        } label: {
                            Image(systemName: BibleCore.Label.sfSymbol(for: canonicalName) ?? "questionmark")
                                .font(.title2)
                                .frame(width: 36, height: 36)
                                .foregroundStyle(label.customIcon == canonicalName ? Color(argbInt: label.color) : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "label_edit_options")) {
                Toggle(String(localized: "favourite"), isOn: $label.favourite)
                    .onChange(of: label.favourite) { _, _ in save() }

                Toggle(String(localized: "underline_style"), isOn: $label.underlineStyle)
                    .onChange(of: label.underlineStyle) { _, _ in save() }

                if label.underlineStyle {
                    Toggle(String(localized: "underline_whole_verse"), isOn: $label.underlineStyleWholeVerse)
                        .onChange(of: label.underlineStyleWholeVerse) { _, _ in save() }
                }
            }
        }
        .navigationTitle(String(localized: "edit_label"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done")) {
                    save()
                    dismiss()
                }
            }
        }
        .onDisappear { save() }
    }

    private func save() {
        try? modelContext.save()
    }
}
