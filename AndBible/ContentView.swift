// ContentView.swift — Root navigation container

import SwiftUI
import BibleUI

/**
 Root content view for the app's reader-first shell.

 The Android-parity reader drawer is the supported top-level navigation surface.
 */
struct ContentView: View {
    var body: some View {
        NavigationStack {
            BibleReaderView()
        }
    }
}
