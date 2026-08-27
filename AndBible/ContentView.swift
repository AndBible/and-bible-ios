// ContentView.swift — Root navigation container

import SwiftUI
import BibleCore
import BibleUI

/**
 Root content view for the app's reader-first shell.

 The Android-parity reader drawer is the supported top-level navigation surface. The app injects
 its application-scoped `SpeakService`; this view forwards that same instance so reader rebuilds do
 not replace active playback or register a second system media-command owner.
 */
struct ContentView: View {
    /// Identity used to refresh reader panes after the app rebuilds its persistence runtime.
    let readerContentIdentity: UUID?

    /// Application-owned speech service forwarded unchanged into the reader hierarchy.
    let speakService: SpeakService

    /**
     Reader root built from the app-owned identity and speech dependencies.

     - Returns: A reader observing the same `SpeakService` instance retained by `AndBibleApp`.
     - Side effects: Construction registers no additional service owner; SwiftUI rendering performs
       the reader's documented appearance work.
     - Failure modes: none.
     */
    var readerView: BibleReaderView {
        BibleReaderView(
            readerContentIdentity: readerContentIdentity,
            speakService: speakService
        )
    }

    /**
     Creates the reader-first app shell.

     - Parameters:
       - readerContentIdentity: Optional identity propagated to `BibleReaderView` so the pane subtree
         can recreate controllers after a live data-stack rebuild without tearing down app-owned
         presentation state such as Settings.
       - speakService: Application-scoped service whose playback and media-command ownership must
         survive reader reconstruction.
     - Side effects: Retains references only; service setup remains reader-appearance driven.
     - Failure modes: none.
     */
    init(
        readerContentIdentity: UUID? = nil,
        speakService: SpeakService
    ) {
        self.readerContentIdentity = readerContentIdentity
        self.speakService = speakService
    }

    /// Hosts the injected reader inside the app's single navigation stack.
    var body: some View {
        NavigationStack {
            readerView
        }
    }
}
