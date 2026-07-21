// AgentWorkspaceWindowAccess.swift -- Workspace window and structural AI operations

import BibleCore
import Foundation

private struct BibleUIAgentWindowStateValue {
    let documentInitials: String?
    let documentName: String?
    let documentCategory: String?
    let currentKey: String?
    let currentKeyName: String?
}

@MainActor
extension BibleUIAgentDomainAdapter {
    /** Lists current-workspace windows in Android's persisted repository order. */
    func getWindows() throws -> AgentToolResult {
        guard let activeWindow = windowManager.activeWindow else {
            throw windowDomainError("READ_ERROR", "No active workspace window is available.")
        }
        let windows = windowManager.windowsInPersistedOrder
        guard windows.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw windowDomainError("LIMIT_EXCEEDED", "Too many workspace windows were returned.")
        }
        let values = windows.enumerated().map { index, window in
            let state = currentWindowState(window)
            return BibleUIAgentJSON.object(
                ("id", BibleUIAgentJSON.uuid(window.id)),
                ("state", .string(androidWindowState(window))),
                ("documentInitials", BibleUIAgentJSON.string(state.documentInitials)),
                ("documentName", BibleUIAgentJSON.string(state.documentName)),
                ("documentCategory", BibleUIAgentJSON.string(state.documentCategory)),
                ("currentKey", BibleUIAgentJSON.string(state.currentKey)),
                ("currentKeyName", BibleUIAgentJSON.string(state.currentKeyName)),
                ("isActive", .bool(window.id == activeWindow.id)),
                ("isSynchronized", .bool(window.isSynchronized)),
                ("isPinMode", .bool(window.isPinMode)),
                ("isLinksWindow", .bool(window.isLinksWindow)),
                ("orderNumber", BibleUIAgentJSON.integer(index))
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("windowCount", BibleUIAgentJSON.integer(values.count)),
            ("activeWindowId", BibleUIAgentJSON.uuid(activeWindow.id)),
            ("windows", .array(values))
        ))
    }

    /** Creates a cloned window and optionally routes it to a validated document and key. */
    func createWindow(
        documentInitials: String?,
        key: String?,
        minimized: Bool
    ) async throws -> AgentToolResult {
        if let documentInitials {
            try requireWindowDocument(documentInitials)
        }
        guard let window = windowManager.addWindow(from: windowManager.activeWindow) else {
            throw windowDomainError("CREATE_ERROR", "The workspace window could not be created.")
        }

        var routedState: BibleUIAgentWindowDocumentState?
        if let documentInitials {
            do {
                let observed = try await windowDocumentRouter.setDocument(
                    windowID: window.id,
                    documentInitials: documentInitials,
                    key: key
                )
                guard observed.windowID == window.id,
                      observed.documentInitials == documentInitials else {
                    throw windowDomainError(
                        "SET_ERROR",
                        "The new window did not reach the requested document."
                    )
                }
                routedState = observed
            } catch is CancellationError {
                windowManager.removeWindow(window)
                throw CancellationError()
            } catch let error as BibleUIAgentDomainError {
                windowManager.removeWindow(window)
                throw error
            } catch {
                windowManager.removeWindow(window)
                throw windowDomainError("CREATE_ERROR", "The new window could not open the document.")
            }
        }
        if minimized {
            windowManager.minimizeWindow(window)
            guard window.layoutState == "minimized" else {
                windowManager.removeWindow(window)
                throw windowDomainError("CREATE_ERROR", "The new window could not be minimized.")
            }
        }

        let persisted = currentWindowState(window)
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("windowId", BibleUIAgentJSON.uuid(window.id)),
            ("state", .string(androidWindowState(window))),
            ("documentInitials", BibleUIAgentJSON.string(
                routedState?.documentInitials ?? persisted.documentInitials
            )),
            ("currentKey", BibleUIAgentJSON.string(
                routedState?.currentKey ?? persisted.currentKey
            ))
        ))
    }

    /** Closes, minimizes, or restores one current-workspace window with Android guards. */
    func manageWindow(windowID: UUID, action: BibleUIAgentWindowAction) throws -> AgentToolResult {
        guard let window = windowManager.windowsInPersistedOrder.first(where: { $0.id == windowID }) else {
            throw windowDomainError(
                "WINDOW_NOT_FOUND",
                "Window not found: \(windowID.uuidString.lowercased())"
            )
        }
        let newState: String?
        let message: String
        switch action {
        case .close:
            guard windowManager.windowsInPersistedOrder.count > 1 else {
                throw windowDomainError("CANNOT_CLOSE", "Cannot close the last window")
            }
            windowManager.removeWindow(window)
            guard !windowManager.windowsInPersistedOrder.contains(where: { $0.id == windowID }) else {
                throw windowDomainError("MANAGE_ERROR", "The window could not be closed.")
            }
            newState = nil
            message = "Window closed"
        case .minimize:
            guard window.layoutState != "minimized",
                  windowManager.visibleWindows.count > 1,
                  windowManager.visibleWindows.contains(where: { $0.id == windowID }) else {
                throw windowDomainError(
                    "CANNOT_MINIMIZE",
                    "Cannot minimize: window is already minimized or is the last visible window"
                )
            }
            windowManager.minimizeWindow(window)
            guard window.layoutState == "minimized" else {
                throw windowDomainError("MANAGE_ERROR", "The window could not be minimized.")
            }
            newState = androidWindowState(window)
            message = "Window minimized"
        case .restore:
            guard window.layoutState == "minimized" else {
                throw windowDomainError("NOT_MINIMIZED", "Window is not minimized")
            }
            windowManager.restoreWindow(window)
            guard window.layoutState != "minimized" else {
                throw windowDomainError("MANAGE_ERROR", "The window could not be restored.")
            }
            newState = androidWindowState(window)
            message = "Window restored"
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("windowId", BibleUIAgentJSON.uuid(windowID)),
            ("action", .string(action.rawValue.lowercased())),
            ("newState", BibleUIAgentJSON.string(newState)),
            ("message", .string(message))
        ))
    }

    /** Routes a validated document mutation to a specific or active live pane. */
    func setWindowDocument(
        windowID: UUID?,
        documentInitials: String,
        key: String?
    ) async throws -> AgentToolResult {
        try requireWindowDocument(documentInitials)
        let target: Window
        if let windowID {
            guard let resolved = windowManager.windowsInPersistedOrder.first(where: {
                $0.id == windowID
            }) else {
                throw windowDomainError(
                    "WINDOW_NOT_FOUND",
                    "Window not found: \(windowID.uuidString.lowercased())"
                )
            }
            target = resolved
        } else if let active = windowManager.activeWindow {
            target = active
        } else {
            throw windowDomainError("WINDOW_NOT_FOUND", "No active window is available.")
        }

        let observed: BibleUIAgentWindowDocumentState
        do {
            observed = try await windowDocumentRouter.setDocument(
                windowID: target.id,
                documentInitials: documentInitials,
                key: key
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BibleUIAgentDomainError {
            throw error
        } catch {
            throw windowDomainError("SET_ERROR", "The window document could not be changed.")
        }
        guard observed.windowID == target.id,
              observed.documentInitials == documentInitials else {
            throw windowDomainError("SET_ERROR", "The window did not reach the requested document.")
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("windowId", BibleUIAgentJSON.uuid(observed.windowID)),
            ("documentInitials", .string(observed.documentInitials)),
            ("documentName", .string(observed.documentName)),
            ("currentKey", BibleUIAgentJSON.string(observed.currentKey)),
            ("currentKeyName", BibleUIAgentJSON.string(observed.currentKeyName))
        ))
    }

    /** Returns Android's title terminal marker for coordinator-owned document output. */
    func setDocumentTitle(title: String) throws -> AgentToolResult {
        try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("finished", .bool(true)),
            ("title", .string(title))
        ))
    }

    /** Validates and emits a StudyPad terminal destination. */
    func finishWithStudyPad(
        labelID: UUID,
        scrollToEntryID: UUID?,
        message: String
    ) throws -> AgentToolResult {
        guard bookmarkService.label(id: labelID) != nil else {
            throw windowDomainError(
                "LABEL_NOT_FOUND",
                "StudyPad not found: \(labelID.uuidString.lowercased())"
            )
        }
        let finalMessage = message.isEmpty ? "StudyPad opened" : message
        return try BibleUIAgentJSON.success(
            BibleUIAgentJSON.object(
                ("finished", .bool(true)),
                ("labelId", BibleUIAgentJSON.uuid(labelID)),
                ("scrollToEntryId", BibleUIAgentJSON.optionalUUID(scrollToEntryID)),
                ("message", .string(finalMessage))
            ),
            completion: .studyPad(
                labelId: labelID,
                scrollToEntryId: scrollToEntryID,
                message: finalMessage
            )
        )
    }

    /** Emits Android's explicit no-document terminal marker and completion. */
    func finishWithoutDocument(message: String) throws -> AgentToolResult {
        let finalMessage = message.isEmpty ? "Task completed" : message
        return try BibleUIAgentJSON.success(
            BibleUIAgentJSON.object(
                ("finished", .bool(true)),
                ("message", .string(finalMessage)),
                ("marker", .string("__FINISH_WITHOUT_DOCUMENT__"))
            ),
            completion: .withoutDocument(message: finalMessage)
        )
    }

    private func requireWindowDocument(_ initials: String) throws {
        guard documentAccessPolicy.allows(documentInitials: initials) else {
            throw windowDomainError("DOCUMENT_NOT_ALLOWED", "Document not allowed: \(initials)")
        }
        if swordManager.module(named: initials) != nil || sqliteLibrary.module(named: initials) != nil {
            return
        }
        if let session = try? myDocumentLibraryStore.loadSession(),
           session.documents.contains(where: { $0.initials == initials }) {
            return
        }
        throw windowDomainError("DOCUMENT_NOT_FOUND", "Document not found: \(initials)")
    }

    private func currentWindowState(_ window: Window) -> BibleUIAgentWindowStateValue {
        guard let manager = window.pageManager else {
            return BibleUIAgentWindowStateValue(
                documentInitials: nil,
                documentName: nil,
                documentCategory: nil,
                currentKey: nil,
                currentKeyName: nil
            )
        }
        let category = normalizedWindowCategory(manager.currentCategoryName)
        let initials: String?
        let currentKey: String?
        let currentKeyName: String?
        switch category {
        case .bible:
            initials = manager.bibleDocument
            let reference = bibleWindowReference(manager)
            currentKey = reference?.osis
            currentKeyName = reference?.name
        case .commentary:
            initials = manager.commentaryDocument
            let reference = manager.commentaryAnchorOrdinal.flatMap {
                JSwordKJVAVersification.verseReference(ordinal: $0)
            }
            currentKey = reference?.osisRef
            currentKeyName = reference.map {
                "\(JSwordKJVAVersification.localizedLongBookName(osisId: $0.osisId) ?? $0.osisId) \($0.chapter):\($0.verse)"
            }
        case .dictionary:
            initials = manager.dictionaryDocument
            currentKey = manager.dictionaryKey
            currentKeyName = manager.dictionaryKey
        case .generalBook, .dailyDevotion:
            initials = manager.generalBookDocument
            currentKey = manager.generalBookKey
            currentKeyName = manager.generalBookKey
        case .map:
            initials = manager.mapDocument
            currentKey = manager.mapKey
            currentKeyName = manager.mapKey
        case .epub:
            initials = manager.epubIdentifier
            currentKey = manager.epubHref
            currentKeyName = manager.epubHref
        }
        return BibleUIAgentWindowStateValue(
            documentInitials: initials,
            documentName: initials.flatMap(windowDocumentName),
            documentCategory: category.rawValue,
            currentKey: currentKey,
            currentKeyName: currentKeyName
        )
    }

    private func normalizedWindowCategory(_ rawValue: String) -> DocumentCategory {
        if let category = DocumentCategory(rawValue: rawValue.uppercased()) { return category }
        switch rawValue.lowercased() {
        case DocumentCategory.commentary.pageManagerKey: return .commentary
        case DocumentCategory.dictionary.pageManagerKey: return .dictionary
        case DocumentCategory.generalBook.pageManagerKey, "generalbook": return .generalBook
        case DocumentCategory.map.pageManagerKey: return .map
        case DocumentCategory.epub.pageManagerKey: return .epub
        case DocumentCategory.dailyDevotion.pageManagerKey, "dailydevotion": return .dailyDevotion
        default: return .bible
        }
    }

    private func bibleWindowReference(_ manager: PageManager) -> (osis: String, name: String)? {
        guard let bookIndex = manager.bibleBibleBook,
              let chapter = manager.bibleChapterNo,
              let verse = manager.bibleVerseNo else { return nil }
        let indexedBook = JSwordKJVAVersification.books.indices.contains(bookIndex)
            ? JSwordKJVAVersification.books[bookIndex]
            : nil
        let book = JSwordKJVAVersification.books.first { $0.bibleBookOrdinal == bookIndex }
            ?? indexedBook
        guard let book else { return nil }
        return (
            "\(book.osisId).\(chapter).\(verse)",
            "\(book.longName) \(chapter):\(verse)"
        )
    }

    private func windowDocumentName(_ initials: String) -> String? {
        if let module = swordManager.module(named: initials) {
            return module.info.description
        }
        if let module = sqliteLibrary.module(named: initials) {
            return module.info.description
        }
        return (try? myDocumentLibraryStore.loadSession())?.documents.first {
            $0.initials == initials
        }?.name
    }

    private func androidWindowState(_ window: Window) -> String {
        window.layoutState == "minimized" ? "MINIMISED" : "VISIBLE"
    }

    private func windowDomainError(_ code: String, _ message: String) -> BibleUIAgentDomainError {
        BibleUIAgentDomainError(code: code, message: message)
    }
}
