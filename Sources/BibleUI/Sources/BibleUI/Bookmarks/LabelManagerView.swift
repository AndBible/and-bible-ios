// LabelManagerView.swift — Label management screen

import SwiftUI
import SwiftData
import BibleCore

/**
 Manages user-created bookmark labels and launches label-specific editing flows.

 The screen lists all real user labels, supports creating new labels inline, presents a dedicated
 edit sheet for label styling changes, and optionally forwards the selected label into the
 StudyPad flow.

 Data dependencies:
 - `modelContext` persists label creation, deletion, and edit changes
 - `allLabels` streams the current label set from SwiftData and is filtered down to user-visible
   labels
 - `onOpenStudyPad` is supplied by the parent when StudyPad navigation should be exposed

 Side effects:
 - creating or deleting a label mutates SwiftData and attempts to save the updated label set
 - selecting a label presents `LabelEditView`, which edits the bound label in place and persists
   changes on interaction and dismissal
 - swipe and context-menu actions can route into the StudyPad flow for a specific label
 */
public struct LabelManagerView: View {
    /// Stable selection token used to navigate to one label edit screen across SwiftData refreshes.
    private struct EditingSelection: Identifiable, Hashable {
        let id: UUID
    }

    /// SwiftData context used for label creation, deletion, and persistence.
    @Environment(\.modelContext) private var modelContext

    /// All labels ordered by name, including system labels that are filtered from the visible list.
    @Query(sort: \BibleCore.Label.name) private var allLabels: [BibleCore.Label]

    /// Whether the inline create-label alert is presented.
    @State private var showNewLabel = false

    /// Pending name for the new label being created from the alert.
    @State private var newLabelName = ""

    /// Label selected for context-menu-driven edit navigation.
    @State private var editingSelection: EditingSelection?

    /// Optional callback used to open the selected label in StudyPad.
    var onOpenStudyPad: ((UUID) -> Void)?

    /**
     Creates the label manager and optionally enables StudyPad handoff actions.

     - Parameter onOpenStudyPad: Callback invoked with a label identifier when the user chooses to
       open that label in StudyPad.
     */
    public init(onOpenStudyPad: ((UUID) -> Void)? = nil) {
        self.onOpenStudyPad = onOpenStudyPad
    }

    /// Visible label list after filtering out non-user/system labels.
    private var userLabels: [BibleCore.Label] {
        allLabels.filter { $0.isRealLabel }
    }

    /**
     Builds the label list, create-label alert, and edit-label navigation flow.
     */
    public var body: some View {
        ZStack {
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
        .accessibilityIdentifier("labelManagerScreen")
        .navigationTitle(String(localized: "labels"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "add"), systemImage: "plus") {
                    showNewLabel = true
                }
                .accessibilityIdentifier("labelManagerAddButton")
            }
        }
        .alert(String(localized: "new_label"), isPresented: $showNewLabel) {
            TextField(String(localized: "label_name"), text: $newLabelName)
                .accessibilityIdentifier("labelManagerNewLabelNameField")
            Button(String(localized: "create")) { createLabel() }
                .accessibilityIdentifier("labelManagerCreateButton")
            Button(String(localized: "cancel"), role: .cancel) { newLabelName = "" }
        }
        .navigationDestination(item: $editingSelection) { selection in
            labelEditDestination(for: selection.id)
        }
    }

    /**
     Builds the list of visible user labels with edit, delete, and optional StudyPad actions.
     */
    private var labelList: some View {
        List {
            ForEach(userLabels) { label in
                labelSelectionButton(label)
            }
        }
    }

    /**
     Builds the main label-selection row button for one label.
     *
     * - Parameter label: Label represented by the selectable row body.
     * - Returns: A button that opens the label editor for the requested label.
     * - Side effects:
     *   - stores the selected label in local state and navigates to the edit destination
     * - Failure modes: This helper cannot fail.
     */
    private func labelSelectionButton(_ label: BibleCore.Label) -> some View {
        NavigationLink {
            labelEditDestination(for: label.id)
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
        .contentShape(Rectangle())
        .accessibilityIdentifier(labelRowIdentifier(label))
        .accessibilityLabel(label.name)
        .swipeActions(edge: .trailing) {
            Button(String(localized: "delete"), role: .destructive) {
                deleteLabel(label)
            }
            .accessibilityIdentifier("labelManagerDeleteAction")
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
                editingSelection = EditingSelection(id: label.id)
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

    /**
     Builds the label-edit destination from a stable identifier instead of retaining one live
     SwiftData object across navigation updates.
     */
    @ViewBuilder
    private func labelEditDestination(for id: UUID) -> some View {
        if let label = allLabels.first(where: { $0.id == id }) {
            LabelEditView(label: label)
        }
    }

    /**
     Resolves the deterministic XCUITest accessibility identifier for one label row.
     *
     * - Parameter label: Label whose row identifier should be derived.
     * - Returns: A stable row identifier that incorporates the current label name.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func labelRowIdentifier(_ label: BibleCore.Label) -> String {
        "labelManagerRowButton-\(label.name)"
    }

    /**
     Creates one new label from the pending alert input and persists it.

     Side effects:
     - inserts a new `Label` into SwiftData and attempts to save the context
     - clears the pending label-name field after a successful insert path

     Failure modes:
     - returns without mutating state when the pending name is empty
     - context-save failures are swallowed by `try?`, leaving the in-memory change subject to
       SwiftData's own reconciliation behavior
     */
    private func createLabel() {
        createLabel(named: newLabelName)
        newLabelName = ""
    }

    /**
     Creates one new label with an explicit name and persists it.

     - Parameter name: Name that should be assigned to the newly inserted label.
     *
     Side effects:
     - inserts a new `Label` into SwiftData and attempts to save the context
     *
     Failure modes:
     - returns without mutating state when `name` is empty
     - context-save failures are swallowed by `try?`, leaving the in-memory change subject to
       SwiftData's own reconciliation behavior
     */
    private func createLabel(named name: String) {
        guard !name.isEmpty else { return }
        let label = BibleCore.Label(name: name)
        modelContext.insert(label)
        try? modelContext.save()
    }

    /**
     Renames one existing label and attempts to persist the change.

     - Parameters:
     - label: Label whose name should be updated.
     - name: Replacement label name that should be persisted.

     Side effects:
     - mutates the label name in place and attempts to save the updated value

     Failure modes:
     - returns without mutating state when `name` is empty
     - save failures are swallowed by `try?`, so a failed persistence write will not surface an
       error to the user from this view
     */
    private func renameLabel(_ label: BibleCore.Label, to name: String) {
        guard !name.isEmpty else { return }
        label.name = name
        try? modelContext.save()
    }

    /**
     Deletes one label and attempts to persist the removal.

     - Parameter label: Label to delete from SwiftData.

     Side effects:
     - removes the label through `BookmarkService`, which also detaches bookmark relations and
       clears any matching primary-label references before saving

     Failure modes:
     - save failures are swallowed inside `BookmarkService`, so a failed persistence write will
       not surface an error to the user from this view
     */
    private func deleteLabel(_ label: BibleCore.Label) {
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        BookmarkService(store: bookmarkStore).deleteLabel(id: label.id)
    }
}

// MARK: - Label Edit View

/**
 Edits the visual style and metadata for one label.

 The editor binds directly to a live `Label` model, so changes apply immediately to the underlying
 SwiftData object and are persisted on each interaction as well as again on dismissal.

 Data dependencies:
 - `label` is a bindable SwiftData model whose fields are mutated directly by the form controls
 - `modelContext` persists those mutations to storage
 - `dismiss` closes the modal presentation after explicit completion

 Side effects:
 - color, icon, and toggle interactions mutate the bound label and immediately attempt to save
 - dismissing the editor triggers one final save attempt through `onDisappear`
 */
private struct LabelEditView: View {
    /// Bindable label being edited in place.
    @Bindable var label: BibleCore.Label

    /// SwiftData context used to persist edits to the bound label.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss action for the modal edit presentation.
    @Environment(\.dismiss) private var dismiss

    /**
     Canonical Android icon names offered for `Label.customIcon`.

     These names are persisted for compatibility with the Vue.js renderer, while the native UI maps
     them through `Label.sfSymbol(for:)` for SF Symbol display.
     */
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

    /// Preset highlight colors aligned with Android's label-style palette.
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

    /**
     Builds the label-edit form, including name, color, icon, and display-style controls.
     */
    var body: some View {
        Form {
            Section(String(localized: "label_edit_name")) {
                TextField(String(localized: "label_name"), text: $label.name)
                    .accessibilityIdentifier("labelEditNameField")
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
        .accessibilityIdentifier("labelEditScreen")
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
                .accessibilityIdentifier("labelEditDoneButton")
            }
        }
        .onDisappear { save() }
    }

    /**
     Attempts to persist the current label edits to SwiftData.

     Failure modes:
     - save failures are swallowed by `try?`, so the editor does not surface persistence errors
       directly
     */
    private func save() {
        try? modelContext.save()
    }

}
