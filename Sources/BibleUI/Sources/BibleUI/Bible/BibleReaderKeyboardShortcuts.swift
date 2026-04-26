import SwiftUI

/**
 Hidden keyboard shortcut surface for iPad and Mac reader commands.

 SwiftUI keyboard shortcuts need concrete buttons in the view tree. This view keeps those invisible
 command buttons out of `BibleReaderView` while forwarding every action to the coordinator.
 */
struct BibleReaderKeyboardShortcuts: View {
    let onSearch: () -> Void
    let onShowBookChooser: () -> Void
    let onOpenBookmarks: () -> Void
    let onNavigatePrevious: () -> Void
    let onNavigateNext: () -> Void
    let onOpenDownloads: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            Button("", action: onSearch)
                .keyboardShortcut("f", modifiers: .command)
            Button("", action: onShowBookChooser)
                .keyboardShortcut("g", modifiers: .command)
            Button("", action: onOpenBookmarks)
                .keyboardShortcut("b", modifiers: .command)
            Button("", action: onNavigatePrevious)
                .keyboardShortcut("[", modifiers: .command)
            Button("", action: onNavigateNext)
                .keyboardShortcut("]", modifiers: .command)
            Button("", action: onOpenDownloads)
                .keyboardShortcut("d", modifiers: .command)
            Button("", action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }
}
