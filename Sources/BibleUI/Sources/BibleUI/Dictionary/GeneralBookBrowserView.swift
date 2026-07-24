// GeneralBookBrowserView.swift — Flat key list browser for general books and maps

import SwiftUI
import SwordKit

/**
 Flat key browser for general-book and map modules.

 Unlike `DictionaryBrowserView`, this view presents the full key list without local search and is
 reused for both `.generalBook` and `.map` SWORD categories.

 Data dependencies:
 - `module` is the selected module whose keys should be listed
 - `title` is Android's localized Book or Map activity title supplied by the caller
 - `surfacePalette` is inherited from the launching reader window
 - `onBack` owns Android Up navigation and empty-list completion
 - `onEmptyKeys` receives Android's null-selection outcome and the raw first key, if one exists
 - `onSelectKey` notifies the parent when the user chooses an entry key

 Side effects:
 - loads the module key list asynchronously when the view appears
 - presents the shared app-owned Android error dialog when SWORD enumeration fails
 - invokes the reader-owned Back action after Up or Android's empty-list completion

 Failure modes:
 - a successful list with no presentable keys invokes Android's null-selection callback and dismisses
 - a backend failure remains visible with its diagnostic message and Retry action
 - cancellation discards the superseded task result without changing current browser state
 */
struct GeneralBookBrowserView: View {
    /// Module whose flat key list is being browsed.
    let module: SwordModule

    /// Navigation title shown while browsing the module.
    let title: String

    /// Reader/workspace palette inherited by this Android activity.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Explicit Android Up and finish command owned by the reader destination.
    let onBack: () -> Void

    /// Callback invoked when the user chooses an entry key.
    let onSelectKey: (String) -> Void

    /// Callback matching Android's `itemSelected(null)` empty-list outcome.
    let onEmptyKeys: (String?) -> Void

    /// Complete key list loaded from the module.
    @State private var allKeys: [String] = []

    /// Whether the module key list is still loading.
    @State private var isLoading = true

    /// Actionable backend error kept distinct from a successfully empty module.
    @State private var loadErrorMessage: String?

    /**
     Creates a general-book/map chooser.

     - Parameters:
       - module: Module whose exact global keys are shown.
       - title: Visible navigation title.
       - surfacePalette: Palette inherited from the launching reader window.
       - onBack: Explicit Android Up and finish command.
       - onEmptyKeys: Android-equivalent null-selection callback carrying the raw first key, if any.
       - onSelectKey: Callback for an exact selected key.
     - Side effects: None.
     - Failure modes: None.
     */
    init(
        module: SwordModule,
        title: String,
        surfacePalette: ReaderThemeSurfacePalette,
        onBack: @escaping () -> Void,
        onEmptyKeys: @escaping (String?) -> Void = { _ in },
        onSelectKey: @escaping (String) -> Void
    ) {
        self.module = module
        self.title = title
        self.surfacePalette = surfacePalette
        self.onBack = onBack
        self.onEmptyKeys = onEmptyKeys
        self.onSelectKey = onSelectKey
    }

    /**
     Builds the loading, flat-list, Android empty-dismissal, and retryable-failure states.

     - Returns: A full app-owned Android Book or Map activity.
     - Side effects: Starts one detached, `SwordRuntime`-serialized enumeration; successful empty
       results invoke `onEmptyKeys` and finish through `onBack`, while failures present the shared
       app-owned error dialog without invoking the empty callback.
     - Failure modes: Enumeration errors remain visible in a dialog; cancellation ignores the
       completed detached result instead of finishing or reporting an empty module.
     - Important: `SwordModule` serializes cursor access internally, so retries cannot race cursor
       mutation even if a cancelled detached read finishes later.
     */
    var body: some View {
        AndroidActivityScreen(
            title: title,
            accessibilityIdentifier: "generalBookBrowserTopAppBar",
            palette: surfacePalette,
            onBack: onBack,
            actions: { EmptyView() }
        ) {
            Group {
                if isLoading {
                    AndroidActivityLoadingView(
                        message: String(localized: "genbook_loading_entries"),
                        palette: surfacePalette,
                        accessibilityIdentifier: "generalBookBrowserLoadingState"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(allKeys.enumerated()), id: \.offset) { row in
                                let key = row.element
                                AndroidActivityListRow(
                                    palette: surfacePalette,
                                    accessibilityIdentifier: "generalBookBrowserRow::\(key)",
                                    action: { onSelectKey(key) }
                                ) {
                                    Text(key)
                                        .font(.system(size: 16))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .background(surfacePalette.backgroundColor)
                }
            }
            .task {
                let result: Result<[String], Error>
                do {
                    let keys = try await Task.detached { [module] in
                        try module.loadAllKeys()
                    }.value
                    result = .success(keys)
                } catch {
                    result = .failure(error)
                }
                guard !Task.isCancelled else { return }

                switch GenericSwordChooserResolver.resolve(result: result) {
                case .present(let validKeys):
                    allKeys = validKeys
                    isLoading = false
                case .dismissWithoutSelection:
                    isLoading = false
                    if case .success(let rawKeys) = result {
                        onEmptyKeys(rawKeys.first)
                    }
                    onBack()
                case .failed(let message):
                    allKeys = []
                    loadErrorMessage = message
                    isLoading = false
                }
            }
            .overlay {
                if let loadErrorMessage {
                    AndroidDecisionDialog(
                        title: String(localized: "error_occurred"),
                        message: loadErrorMessage,
                        actions: [
                            .init(
                                id: "okay",
                                title: String(localized: "okay", defaultValue: "OK"),
                                style: .normal
                            ) {
                                self.loadErrorMessage = nil
                            }
                        ]
                    )
                }
            }
        }
    }
}
