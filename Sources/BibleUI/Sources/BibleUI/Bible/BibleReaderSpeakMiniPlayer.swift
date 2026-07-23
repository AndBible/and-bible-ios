import BibleCore
import SwiftUI

/**
 Reader host for the same app-owned speech transport widget Android uses in `main_bible_view`.

 The reader coordinator decides visibility. This wrapper supplies the active reader reference,
 workspace/window palette, configuration command, and Speak-bookmark dialog while the shared
 transport component owns status, speed, exact drawables, and playback behavior.
 */
struct BibleReaderSpeakMiniPlayer: View {
    @ObservedObject var speakService: SpeakService
    let currentReference: String
    let onShowControls: () -> Void
    var surfacePalette: ReaderThemeSurfacePalette = .standard

    @State private var showsBookmarkPicker = false

    var body: some View {
        AndroidSpeakTransportView(
            speakService: speakService,
            surfacePalette: surfacePalette,
            fallbackStatus: currentReference,
            onShowBookmarks: { showsBookmarkPicker = true },
            onShowConfiguration: onShowControls
        )
        .overlay {
            if showsBookmarkPicker {
                AndroidSingleChoiceDialog(
                    title: String(
                        localized: "speak_bookmarks_menu_title",
                        defaultValue: "Speak from bookmark"
                    ),
                    selectedValue: -1,
                    options: speakService.resumeBookmarks.enumerated().map { index, bookmark in
                        AndroidSingleChoiceOption(
                            id: "\(index)",
                            value: index,
                            title: bookmarkTitle(bookmark)
                        )
                    },
                    accessibilityIdentifier: "readerSpeakBookmarkDialog",
                    onSelect: { index in
                        if speakService.resumeBookmarks.indices.contains(index) {
                            speakService.resume(from: speakService.resumeBookmarks[index])
                        }
                        showsBookmarkPicker = false
                    },
                    onCancel: { showsBookmarkPicker = false }
                )
            }
        }
    }

    /** Formats one Android Speak-bookmark row without crossing Bible and generic key domains. */
    private func bookmarkTitle(_ bookmark: SpeakResumeBookmark) -> String {
        let position = bookmark.position
        let source = position.bookName.isEmpty ? position.bookInitials : position.bookName
        let key = position.keyName.isEmpty ? position.key : position.keyName
        if source.isEmpty { return key }
        return key.isEmpty ? source : "\(source) \(key)"
    }
}
