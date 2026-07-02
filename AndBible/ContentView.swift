// ContentView.swift — Root navigation container

import SwiftUI
import BibleUI

/**
 Root content view for the app's reader-first shell.

 The Android-parity reader drawer is the supported top-level navigation surface.
 */
struct ContentView: View {
    /// Identity used to refresh reader panes after the app rebuilds its persistence runtime.
    let readerContentIdentity: UUID?

    /**
     Creates the reader-first app shell.

     - Parameter readerContentIdentity: Optional identity propagated to `BibleReaderView` so the
       pane subtree can recreate controllers after a live data-stack rebuild without tearing down
       app-owned presentation state such as Settings.
     */
    init(readerContentIdentity: UUID? = nil) {
        self.readerContentIdentity = readerContentIdentity
    }

    var body: some View {
        NavigationStack {
            BibleReaderView(readerContentIdentity: readerContentIdentity)
        }
    }
}
