// GeneralBookBrowserView.swift — Flat key list browser for general books and maps

import SwiftUI
import SwordKit

/**
 Flat key browser for general-book and map modules.

 Unlike `DictionaryBrowserView`, this view presents the full key list without local search and is
 reused for both `.generalBook` and `.map` SWORD categories.

 Data dependencies:
 - `module` is the selected module whose keys should be listed
 - `title` is the user-visible navigation title supplied by the caller
 - `onEmptyKeys` receives Android's null-selection outcome and the raw first key, if one exists
 - `onSelectKey` notifies the parent when the user chooses an entry key

 Side effects:
 - loads the module key list asynchronously when the view appears
 - presents a retry action when the SWORD backend cannot enumerate keys
 - dismisses the sheet when the user taps the toolbar Done action

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

    /// Monotonic retry token used to restart the structured key-loading task.
    @State private var loadAttempt = 0

    /// Dismiss action for closing the browser.
    @Environment(\.dismiss) private var dismiss

    /**
     Creates a general-book/map chooser.

     - Parameters:
       - module: Module whose exact global keys are shown.
       - title: Visible navigation title.
       - onEmptyKeys: Android-equivalent null-selection callback carrying the raw first key, if any.
       - onSelectKey: Callback for an exact selected key.
     - Side effects: None.
     - Failure modes: None.
     */
    init(
        module: SwordModule,
        title: String,
        onEmptyKeys: @escaping (String?) -> Void = { _ in },
        onSelectKey: @escaping (String) -> Void
    ) {
        self.module = module
        self.title = title
        self.onEmptyKeys = onEmptyKeys
        self.onSelectKey = onSelectKey
    }

    /**
     Builds the loading, flat-list, Android empty-dismissal, and retryable-failure states.

     - Returns: A navigation stack bound to the selected general-book or map module.
     - Side effects: Starts one detached, `SwordRuntime`-serialized enumeration per `loadAttempt`;
       successful filtered-empty results invoke `onEmptyKeys` and dismiss, while failures update
       visible retry state without invoking the empty callback.
     - Failure modes: Enumeration errors remain visible and retryable; cancellation ignores the
       completed detached result instead of dismissing or reporting an empty module.
     - Important: `SwordModule` serializes cursor access internally, so retries cannot race cursor
       mutation even if a cancelled detached read finishes later.
     */
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "genbook_loading_entries"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadErrorMessage {
                    ContentUnavailableView {
                        Label(
                            String(localized: "error_occurred"),
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(loadErrorMessage)
                    } actions: {
                        Button(String(localized: "retry")) {
                            retryLoadingKeys()
                        }
                    }
                } else if allKeys.isEmpty {
                    ContentUnavailableView(
                        String(localized: "genbook_no_entries"),
                        systemImage: "book.closed",
                        description: Text(String(localized: "genbook_no_entries_description"))
                    )
                } else {
                    List(Array(allKeys.enumerated()), id: \.offset) { row in
                        let key = row.element
                        Button(key) {
                            onSelectKey(key)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task(id: loadAttempt) {
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
                    dismiss()
                case .failed(let message):
                    allKeys = []
                    loadErrorMessage = message
                    isLoading = false
                }
            }
        }
    }

    /**
     Restarts key enumeration after a visible backend failure.

     - Side effects: Clears the current error, restores loading UI, and increments the task identity.
     - Failure modes: A repeated backend failure returns to the same actionable error state.
     */
    private func retryLoadingKeys() {
        loadErrorMessage = nil
        isLoading = true
        loadAttempt += 1
    }
}
