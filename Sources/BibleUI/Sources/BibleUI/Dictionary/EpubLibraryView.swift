// EpubLibraryView.swift — Lists all installed EPUB files

import SwiftUI
import BibleCore

/** One installed EPUB awaiting a user-confirmed destructive action. */
struct EpubLibraryDeletionCandidate: Equatable {
    /// Stable library identity passed to the throwing storage API.
    let identifier: String

    /// User-visible title displayed by the confirmation dialog.
    let title: String
}

/**
 Owns confirmation and commit sequencing for EPUB library deletion.

 Requesting deletion only records candidates. `commit` clears that request, invokes the throwing
 storage operation in order, and notifies the owner only after each successful commit. This keeps
 reader reconciliation and visible-list updates behind the same durability boundary Android uses.

 - Side effects: Mutates pending confirmation state and invokes caller-supplied deletion/callback
   closures during `commit`.
 - Failure modes: Stops at the first thrown deletion error and returns it; later candidates are not
   attempted and no success callback is emitted for the failed candidate.
 */
struct EpubLibraryDeletionState {
    /// Candidates currently awaiting explicit destructive confirmation.
    private(set) var pending: [EpubLibraryDeletionCandidate] = []

    /// Whether the view should present its destructive confirmation dialog.
    var isAwaitingConfirmation: Bool { !pending.isEmpty }

    /**
     Records candidates for confirmation without touching the file system.

     - Parameter candidates: Installed EPUB identities selected by the list action.
     - Side effects: Replaces any prior pending request.
     - Failure modes: An empty input simply clears pending confirmation.
     */
    mutating func request(_ candidates: [EpubLibraryDeletionCandidate]) {
        pending = candidates
    }

    /** Clears a pending request without deleting or notifying. */
    mutating func cancel() {
        pending = []
    }

    /**
     Commits confirmed deletions in selection order.

     - Parameters:
       - delete: Throwing durable-storage operation for one stable EPUB identifier.
       - onDeleted: Callback emitted only after `delete` returns successfully.
     - Returns: The first deletion error, or `nil` when every requested EPUB committed.
     - Side effects: Clears pending state before I/O, then invokes the supplied closures in order.
     - Failure modes: Stops on the first thrown error; already committed deletions remain committed.
     */
    mutating func commit(
        delete: (String) throws -> Void,
        onDeleted: (String) -> Void
    ) -> Error? {
        let requested = pending
        pending = []
        for candidate in requested {
            do {
                try delete(candidate.identifier)
                onDeleted(candidate.identifier)
            } catch {
                return error
            }
        }
        return nil
    }
}

/**
 Library browser for installed EPUB books.

 The view loads all installed EPUB metadata, lets the caller open one selected book, and supports
 deleting library entries from the local EPUB store.

 Data dependencies:
 - `onSelectEpub` notifies the parent when the user chooses an EPUB identifier to open
 - `onDeleteEpub` notifies the reader owner after storage commits successfully

 Side effects:
 - loads installed EPUB metadata when the view appears
 - deleting rows removes EPUB content through `EpubReader.delete`
 - dismisses the library browser when the toolbar Done action is used
 */
struct EpubLibraryView: View {
    /// Callback invoked after an EPUB is no longer published in the local library.
    let onDeleteEpub: (String) -> Void

    /// Callback invoked when the user chooses an EPUB to open.
    let onSelectEpub: (String) -> Void

    /// Installed EPUB metadata loaded from the local library.
    @State private var epubs: [EpubInfo] = []

    /// Whether the EPUB library is still loading.
    @State private var isLoading = true

    /// Confirmation and success-only commit state for destructive row actions.
    @State private var deletionState = EpubLibraryDeletionState()

    /// File-system failure shown without pretending the affected row was removed.
    @State private var deletionErrorMessage: String?

    /// Dismiss action for closing the library browser.
    @Environment(\.dismiss) private var dismiss

    /**
     Creates an EPUB library with selection and committed-deletion callbacks.

     - Parameters:
       - onDeleteEpub: Called once per EPUB whose storage transaction succeeds.
       - onSelectEpub: Called when the user opens one EPUB.
     - Side effects: None during initialization.
     - Failure modes: None.
     */
    init(
        onDeleteEpub: @escaping (String) -> Void = { _ in },
        onSelectEpub: @escaping (String) -> Void
    ) {
        self.onDeleteEpub = onDeleteEpub
        self.onSelectEpub = onSelectEpub
    }

    /**
     Builds the loading state, empty library state, or installed EPUB list.
     */
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "epub_loading_library"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if epubs.isEmpty {
                    ContentUnavailableView(
                        String(localized: "epub_no_epubs_installed"),
                        systemImage: "book",
                        description: Text(String(localized: "epub_no_epubs_installed_description"))
                    )
                } else {
                    List {
                        ForEach(epubs, id: \.identifier) { epub in
                            Button {
                                onSelectEpub(epub.identifier)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(epub.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if !epub.author.isEmpty {
                                        Text(epub.author)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteEpubs)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(String(localized: "epub_library"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task {
                epubs = EpubReader.installedEpubs()
                isLoading = false
            }
            .confirmationDialog(
                String(localized: "delete"),
                isPresented: Binding(
                    get: { deletionState.isAwaitingConfirmation },
                    set: { if !$0 { deletionState.cancel() } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "delete"), role: .destructive, action: deletePendingEpubs)
                Button(String(localized: "cancel"), role: .cancel) {
                    deletionState.cancel()
                }
            } message: {
                Text(deletionState.pending.map(\.title).joined(separator: ", "))
            }
            .alert(
                String(localized: "error"),
                isPresented: Binding(
                    get: { deletionErrorMessage != nil },
                    set: { if !$0 { deletionErrorMessage = nil } }
                )
            ) {
                Button(String(localized: "ok"), role: .cancel) {
                    deletionErrorMessage = nil
                }
            } message: {
                Text(deletionErrorMessage ?? "")
            }
        }
    }

    /**
     Requests confirmation for the selected EPUB rows without mutating storage or visible state.

     - Parameter offsets: Selected row offsets in the current library list.
     - Side effects: Presents the destructive confirmation dialog.
     - Failure modes: Invalidated offsets are ignored.
     */
    private func deleteEpubs(at offsets: IndexSet) {
        deletionState.request(offsets.compactMap { index in
            guard epubs.indices.contains(index) else { return nil }
            let epub = epubs[index]
            return EpubLibraryDeletionCandidate(identifier: epub.identifier, title: epub.title)
        })
    }

    /**
     Commits every confirmed deletion and then reloads visible state from the library.

     - Side effects: Deletes local EPUBs, notifies the reader owner for each success, reloads the
       installed list, and presents the first file-system failure.
     - Failure modes: Stops after the first thrown deletion error. Already committed deletions stay
       deleted and the disk-backed reload prevents the list from claiming otherwise.
     */
    private func deletePendingEpubs() {
        deletionErrorMessage = deletionState.commit(
            delete: { try EpubReader.delete(identifier: $0) },
            onDeleted: onDeleteEpub
        )?.localizedDescription
        epubs = EpubReader.installedEpubs()
    }
}
