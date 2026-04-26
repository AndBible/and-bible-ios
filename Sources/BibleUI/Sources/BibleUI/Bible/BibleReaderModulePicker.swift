import BibleCore
import SwiftUI
import SwordKit

/**
 Presents document modules for the currently focused pane and routes category-specific selections.

 The reader coordinator owns whether the sheet is visible. This view owns the picker rows,
 localized category copy, and the Android-parity follow-up routing for auxiliary documents.
 */
struct BibleReaderModulePicker: View {
    let controller: BibleReaderController?
    let category: DocumentCategory
    let onDismiss: () -> Void
    let onOpenDownloads: () -> Void
    let onOpenDictionaryBrowser: () -> Void
    let onOpenGeneralBookBrowser: () -> Void
    let onOpenMapBrowser: () -> Void

    private var modules: [ModuleInfo] {
        controller?.installedModules(for: category) ?? []
    }

    private var activeNameForCategory: String? {
        controller?.activeModuleName(for: category)
    }

    var body: some View {
        NavigationStack {
            List {
                if modules.isEmpty {
                    emptyState
                } else {
                    moduleRows
                }
            }
            .accessibilityIdentifier("modulePickerScreen")
            .navigationTitle(navigationTitle)
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
            Button(String(localized: "download_modules")) {
                onDismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onOpenDownloads()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }

    private var moduleRows: some View {
        ForEach(modules, id: \.name) { module in
            Button {
                select(module)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.name)
                            .font(.headline)
                        Text(module.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(Locale.current.localizedString(forLanguageCode: module.language) ?? module.language)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if module.name == activeNameForCategory {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                            .fontWeight(.semibold)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("modulePickerRow::\(module.name)")
        }
    }

    private var emptyMessage: String {
        switch category {
        case .commentary:
            return String(localized: "picker_no_commentary_modules")
        case .dictionary:
            return String(localized: "picker_no_dictionary_modules")
        case .generalBook:
            return String(localized: "picker_no_general_book_modules")
        case .map:
            return String(localized: "picker_no_map_modules")
        default:
            return String(localized: "picker_no_bible_modules")
        }
    }

    private var navigationTitle: String {
        switch category {
        case .commentary:
            return String(localized: "picker_select_commentary")
        case .dictionary:
            return String(localized: "picker_select_dictionary")
        case .generalBook:
            return String(localized: "picker_select_general_book")
        case .map:
            return String(localized: "picker_select_map")
        default:
            return String(localized: "picker_select_translation")
        }
    }

    private func select(_ module: ModuleInfo) {
        switch category {
        case .commentary:
            controller?.switchCommentaryModule(to: module.name)
            if controller?.currentCategory != .commentary {
                controller?.switchCategory(to: .commentary)
            }
            onDismiss()
        case .dictionary:
            controller?.switchDictionaryModule(to: module.name)
            controller?.switchCategory(to: .dictionary)
            dismissAndPresentAuxiliaryBrowser(onOpenDictionaryBrowser)
        case .generalBook:
            controller?.switchGeneralBookModule(to: module.name)
            controller?.switchCategory(to: .generalBook)
            dismissAndPresentAuxiliaryBrowser(onOpenGeneralBookBrowser)
        case .map:
            controller?.switchMapModule(to: module.name)
            controller?.switchCategory(to: .map)
            dismissAndPresentAuxiliaryBrowser(onOpenMapBrowser)
        default:
            controller?.switchModule(to: module.name)
            if controller?.currentCategory != .bible {
                controller?.switchCategory(to: .bible)
            }
            onDismiss()
        }
    }

    private func dismissAndPresentAuxiliaryBrowser(_ presentation: @escaping () -> Void) {
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            presentation()
        }
    }
}
