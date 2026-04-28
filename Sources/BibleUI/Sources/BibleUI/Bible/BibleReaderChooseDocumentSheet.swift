import SwiftUI

/// Document categories exposed by the reader drawer's choose-document flow.
enum BibleReaderDocumentChoice: String, CaseIterable, Identifiable {
    case bible
    case commentary
    case dictionary
    case generalBook
    case map
    case epub

    var id: String { rawValue }
}

/**
 Android-style choose-document sheet for switching reader document categories.

 The sheet owns row presentation only. The reader coordinator supplies the active category,
 optional module subtitle, and the action to run when a category is selected.
 */
struct BibleReaderChooseDocumentSheet: View {
    let activeChoice: BibleReaderDocumentChoice
    let subtitle: (BibleReaderDocumentChoice) -> String?
    let onSelect: (BibleReaderDocumentChoice) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(BibleReaderDocumentChoice.allCases) { choice in
                    Button {
                        onSelect(choice)
                    } label: {
                        HStack(spacing: 12) {
                            icon(for: choice)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: choice))
                                    .foregroundStyle(.primary)
                                if let subtitle = subtitle(choice) {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if choice == activeChoice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("readerChooseDocument::\(choice.rawValue)")
                }
            }
            .navigationTitle(localizedDrawerString("chooce_document", default: "Choose Document"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done"), action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func title(for choice: BibleReaderDocumentChoice) -> String {
        switch choice {
        case .bible:
            return String(localized: "bible")
        case .commentary:
            return String(localized: "commentaries")
        case .dictionary:
            return String(localized: "dictionary")
        case .generalBook:
            return String(localized: "general_book")
        case .map:
            return String(localized: "map")
        case .epub:
            return String(localized: "epub_library")
        }
    }

    @ViewBuilder
    private func icon(for choice: BibleReaderDocumentChoice) -> some View {
        switch choice {
        case .bible:
            ToolbarAssetIcon(name: "ToolbarBible")
                .frame(width: 24, height: 22)
                .foregroundStyle(.primary)
        case .commentary:
            ToolbarAssetIcon(name: "ToolbarCommentary")
                .frame(width: 24, height: 22)
                .foregroundStyle(.primary)
        case .dictionary:
            Image(systemName: "character.book.closed")
                .foregroundStyle(.secondary)
        case .generalBook:
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.secondary)
        case .map:
            Image(systemName: "map.fill")
                .foregroundStyle(.secondary)
        case .epub:
            Image(systemName: "book.closed.fill")
                .foregroundStyle(.secondary)
        }
    }

    private func localizedDrawerString(_ key: String, default defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}
