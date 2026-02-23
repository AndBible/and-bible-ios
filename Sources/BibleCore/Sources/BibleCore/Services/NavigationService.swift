// NavigationService.swift — Bible navigation and history

import Foundation
import Observation
import SwordKit

/// Manages Bible navigation: book/chapter/verse selection and history.
@Observable
public final class NavigationService {
    private let swordManager: SwordManager
    private let workspaceStore: WorkspaceStore

    /// Navigation history stack for back/forward.
    private var backStack: [NavigationEntry] = []
    private var forwardStack: [NavigationEntry] = []

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public init(swordManager: SwordManager, workspaceStore: WorkspaceStore) {
        self.swordManager = swordManager
        self.workspaceStore = workspaceStore
    }

    /// Navigate to a specific verse in a module.
    public func navigateTo(module: String, key: String, window: Window) {
        // Push current position to back stack
        if let pm = window.pageManager, let doc = pm.bibleDocument {
            let currentKey = buildKeyString(pm)
            backStack.append(NavigationEntry(document: doc, key: currentKey))
            forwardStack.removeAll()
        }

        // Update page manager
        if let pm = window.pageManager {
            pm.bibleDocument = module
            // Parse the key to update verse position
            parseAndSetKey(key, on: pm)
        }

        // Record history
        workspaceStore.addHistoryItem(to: window, document: module, key: key)
    }

    /// Go back in navigation history.
    public func goBack(window: Window) {
        guard let entry = backStack.popLast() else { return }

        // Push current to forward stack
        if let pm = window.pageManager, let doc = pm.bibleDocument {
            forwardStack.append(NavigationEntry(document: doc, key: buildKeyString(pm)))
        }

        // Restore the back entry
        if let pm = window.pageManager {
            pm.bibleDocument = entry.document
            parseAndSetKey(entry.key, on: pm)
        }
    }

    /// Go forward in navigation history.
    public func goForward(window: Window) {
        guard let entry = forwardStack.popLast() else { return }

        if let pm = window.pageManager, let doc = pm.bibleDocument {
            backStack.append(NavigationEntry(document: doc, key: buildKeyString(pm)))
        }

        if let pm = window.pageManager {
            pm.bibleDocument = entry.document
            parseAndSetKey(entry.key, on: pm)
        }
    }

    /// Get chapter text for a module at a given key.
    public func getChapterText(module: String, key: String) -> String? {
        guard let mod = swordManager.module(named: module) else { return nil }
        mod.setKey(key)
        return mod.renderText()
    }

    // MARK: - Private

    private func buildKeyString(_ pm: PageManager) -> String {
        guard let book = pm.bibleBibleBook,
              let chapter = pm.bibleChapterNo,
              let verse = pm.bibleVerseNo else { return "" }
        return "\(book).\(chapter).\(verse)"
    }

    private func parseAndSetKey(_ key: String, on pm: PageManager) {
        // Simple key parsing — full implementation would use SWORD's key parser
        let parts = key.split(separator: ".")
        if parts.count >= 3 {
            pm.bibleBibleBook = Int(parts[0])
            pm.bibleChapterNo = Int(parts[1])
            pm.bibleVerseNo = Int(parts[2])
        }
    }
}

/// A navigation history entry.
struct NavigationEntry {
    let document: String
    let key: String
}
