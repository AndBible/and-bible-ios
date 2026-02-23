// LabelAssignmentView.swift — Toggle labels on a bookmark

import SwiftUI
import SwiftData
import BibleCore

/// View for assigning/removing labels on a specific bookmark.
/// Shows all user labels with checkmarks for currently assigned ones.
/// Heart icon toggles favourite status (favourite labels appear in quick-assign bar).
struct LabelAssignmentView: View {
    let bookmarkId: UUID
    var onDismiss: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BibleCore.Label.name) private var allLabels: [BibleCore.Label]
    @State private var showNewLabel = false
    @State private var newLabelName = ""
    @State private var assignedLabelIds: Set<UUID> = []

    private var userLabels: [BibleCore.Label] {
        allLabels.filter { $0.isRealLabel }
    }

    var body: some View {
        List {
            Section {
                ForEach(userLabels) { label in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(argbInt: label.color))
                            .frame(width: 14, height: 14)

                        Text(label.name)
                            .font(.body)
                            .foregroundStyle(.primary)

                        Spacer()

                        Button {
                            toggleFavourite(label)
                        } label: {
                            Image(systemName: label.favourite ? "heart.fill" : "heart")
                                .foregroundStyle(label.favourite ? Color.red : Color.secondary)
                                .font(.body)
                        }
                        .buttonStyle(.plain)

                        Button {
                            toggleLabel(label)
                        } label: {
                            Image(systemName: assignedLabelIds.contains(label.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(assignedLabelIds.contains(label.id) ? Color.accentColor : Color.secondary)
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                }
            }

            Section {
                Button {
                    showNewLabel = true
                } label: {
                    SwiftUI.Label("Create New Label", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Assign Labels")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDismiss?() }
            }
        }
        .alert("New Label", isPresented: $showNewLabel) {
            TextField("Label name", text: $newLabelName)
            Button("Create") { createAndAssignLabel() }
            Button("Cancel", role: .cancel) { newLabelName = "" }
        }
        .onAppear { loadAssignedLabels() }
    }

    private func loadAssignedLabels() {
        let target = bookmarkId
        var descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        guard let bookmark = try? modelContext.fetch(descriptor).first else { return }
        let ids = bookmark.bookmarkToLabels?.compactMap { $0.label?.id } ?? []
        assignedLabelIds = Set(ids)
    }

    private func toggleLabel(_ label: BibleCore.Label) {
        let target = bookmarkId
        var descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        guard let bookmark = try? modelContext.fetch(descriptor).first else { return }

        if assignedLabelIds.contains(label.id) {
            bookmark.bookmarkToLabels?.removeAll { $0.label?.id == label.id }
            assignedLabelIds.remove(label.id)
        } else {
            let btl = BibleBookmarkToLabel()
            btl.bookmark = bookmark
            btl.label = label
            modelContext.insert(btl)
            assignedLabelIds.insert(label.id)
        }
        bookmark.lastUpdatedOn = Date()
        try? modelContext.save()
    }

    private func toggleFavourite(_ label: BibleCore.Label) {
        label.favourite.toggle()
        try? modelContext.save()
    }

    private func createAndAssignLabel() {
        guard !newLabelName.isEmpty else { return }
        let label = BibleCore.Label(name: newLabelName)
        modelContext.insert(label)

        let target = bookmarkId
        var descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        if let bookmark = try? modelContext.fetch(descriptor).first {
            let btl = BibleBookmarkToLabel()
            btl.bookmark = bookmark
            btl.label = label
            modelContext.insert(btl)
            bookmark.lastUpdatedOn = Date()
            assignedLabelIds.insert(label.id)
        }
        try? modelContext.save()
        newLabelName = ""
    }
}
