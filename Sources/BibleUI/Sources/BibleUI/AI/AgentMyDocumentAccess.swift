// AgentMyDocumentAccess.swift -- Transactional My Documents AI operations

import BibleCore
import Foundation

@MainActor
extension BibleUIAgentDomainAdapter {
    /** Lists every My Documents collection and highlights Android's AI collection. */
    func getMyDocuments() throws -> AgentToolResult {
        let session = try loadMyDocumentSession(code: "READ_ERROR")
        guard session.documents.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw myDocumentDomainError("LIMIT_EXCEEDED", "Too many My Documents collections were returned.")
        }
        let aiDocument = session.documents.first {
            $0.initials == MyDocumentManagementSession.aiDocumentsInitials
        }
        let values = session.documents.map { document in
            BibleUIAgentJSON.object(
                ("id", BibleUIAgentJSON.uuid(document.id)),
                ("name", .string(document.name)),
                ("initials", .string(document.initials)),
                ("description", BibleUIAgentJSON.string(document.documentDescription)),
                ("pageCount", BibleUIAgentJSON.integer(document.pages.count)),
                ("isAIDocument", .bool(
                    document.initials == MyDocumentManagementSession.aiDocumentsInitials
                ))
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("documentCount", BibleUIAgentJSON.integer(values.count)),
            ("aiDocumentId", BibleUIAgentJSON.optionalUUID(aiDocument?.id)),
            ("aiDocumentInitials", .string(
                aiDocument?.initials ?? MyDocumentManagementSession.aiDocumentsInitials
            )),
            ("documents", .array(values))
        ))
    }

    /** Lists metadata or bounded raw content for one exactly resolved collection. */
    func getMyDocumentPages(
        documentID: UUID?,
        initials: String?,
        includeContent: Bool
    ) throws -> AgentToolResult {
        let session = try loadMyDocumentSession(code: "READ_ERROR")
        guard let document = resolveMyDocument(
            in: session,
            documentID: documentID,
            initials: initials
        ) else {
            throw myDocumentDomainError("DOCUMENT_NOT_FOUND", "Document not found")
        }
        guard document.pages.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw myDocumentDomainError("LIMIT_EXCEEDED", "The document contains too many pages.")
        }
        let pages = document.pages.sorted(by: myDocumentPageOrder)
        let values = try pages.map { page in
            if includeContent {
                _ = try BibleUIAgentJSON.boundedText(page.content)
            }
            return BibleUIAgentJSON.object(
                ("id", BibleUIAgentJSON.uuid(page.id)),
                ("title", .string(page.title)),
                ("pageKey", .string(page.pageKey)),
                ("contentType", .string(page.contentType.rawValue)),
                ("orderNumber", BibleUIAgentJSON.integer(page.orderNumber)),
                ("content", includeContent ? .string(page.content) : nil)
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("documentId", BibleUIAgentJSON.uuid(document.id)),
            ("documentName", .string(document.name)),
            ("initials", .string(document.initials)),
            ("pageCount", BibleUIAgentJSON.integer(values.count)),
            ("pages", .array(values))
        ))
    }

    /** Creates one AI-owned My Documents collection through a single session save. */
    func createMyDocument(
        name: String,
        description: String?,
        context: AgentExecutionContext
    ) throws -> AgentToolResult {
        var session = try loadMyDocumentSession(code: "CREATE_ERROR")
        let documentID: UUID
        do {
            documentID = try session.createDocument(
                name: name,
                documentDescription: description,
                reservedInitials: reservedDocumentInitials,
                sourcePromptId: context.promptId
            )
            try myDocumentLibraryStore.save(&session, reservedInitials: reservedDocumentInitials)
        } catch {
            throw myDocumentDomainError("CREATE_ERROR", "The document could not be created.")
        }
        guard let document = session.document(id: documentID) else {
            throw myDocumentDomainError("CREATE_ERROR", "The created document could not be reloaded.")
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("id", BibleUIAgentJSON.uuid(document.id)),
            ("name", .string(document.name)),
            ("initials", .string(document.initials)),
            ("description", BibleUIAgentJSON.string(document.documentDescription))
        ))
    }

    /** Adds one AI-owned page, defaulting to an atomically created AI Documents collection. */
    func addMyDocumentPage(
        documentID: UUID?,
        initials: String?,
        title: String,
        content: String,
        contentType: BibleUIAgentPageContentType,
        context: AgentExecutionContext
    ) throws -> AgentToolResult {
        let normalizedContent = BibleUIAgentToolRequestParser.normalizeModelText(content)
        guard !normalizedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw myDocumentDomainError("INVALID_ARGS", "Missing required parameter: content")
        }
        var session = try loadMyDocumentSession(code: "ADD_ERROR")
        let target: MyDocumentDraft
        if initials == MyDocumentManagementSession.aiDocumentsInitials
            || (documentID == nil && initials == nil) {
            target = try ensureAIDocument(in: &session, promptID: context.promptId)
        } else if let resolved = resolveMyDocument(
            in: session,
            documentID: documentID,
            initials: initials
        ) {
            target = resolved
        } else {
            throw myDocumentDomainError("DOCUMENT_NOT_FOUND", "Document not found")
        }

        let pageID: UUID
        do {
            pageID = try session.createPage(
                documentID: target.id,
                title: title,
                contentType: myDocumentContentType(contentType),
                content: normalizedContent,
                sourcePromptId: context.promptId
            )
            try myDocumentLibraryStore.save(&session, reservedInitials: reservedDocumentInitials)
        } catch let error as BibleUIAgentDomainError {
            throw error
        } catch {
            throw myDocumentDomainError("ADD_ERROR", "The page could not be added.")
        }

        guard let document = session.document(id: target.id),
              let page = document.pages.first(where: { $0.id == pageID }) else {
            throw myDocumentDomainError("ADD_ERROR", "The created page could not be reloaded.")
        }
        return try BibleUIAgentJSON.success(
            BibleUIAgentJSON.object(
                ("pageId", BibleUIAgentJSON.uuid(page.id)),
                ("documentId", BibleUIAgentJSON.uuid(document.id)),
                ("initials", .string(document.initials)),
                ("title", .string(page.title)),
                ("pageKey", .string(page.pageKey)),
                ("contentType", .string(page.contentType.rawValue)),
                ("orderNumber", BibleUIAgentJSON.integer(page.orderNumber))
            ),
            createdPageIDs: [page.id]
        )
    }

    /** Applies title, content, and order changes to one page in one transactional save. */
    func editMyDocumentPage(
        pageID: UUID,
        title: String?,
        content: String?,
        orderNumber: Int?
    ) throws -> AgentToolResult {
        var session = try loadMyDocumentSession(code: "EDIT_ERROR")
        guard let location = locatePage(pageID, in: session) else {
            throw myDocumentDomainError(
                "PAGE_NOT_FOUND",
                "Page not found: \(pageID.uuidString.lowercased())"
            )
        }
        do {
            if title != nil || content != nil {
                try session.updatePage(
                    documentID: location.document.id,
                    pageID: pageID,
                    title: title ?? location.page.title,
                    contentType: location.page.contentType,
                    content: content.map(BibleUIAgentToolRequestParser.normalizeModelText)
                        ?? location.page.content
                )
            }
            if let orderNumber {
                let pageCount = location.document.pages.count
                let destination = min(orderNumber, max(0, pageCount - 1))
                if destination != location.index {
                    let moveDestination = destination > location.index ? destination + 1 : destination
                    try session.movePages(
                        documentID: location.document.id,
                        fromOffsets: IndexSet(integer: location.index),
                        toOffset: moveDestination
                    )
                }
            }
            try myDocumentLibraryStore.save(&session, reservedInitials: reservedDocumentInitials)
        } catch {
            throw myDocumentDomainError("EDIT_ERROR", "The page could not be edited.")
        }
        guard let updated = locatePage(pageID, in: session) else {
            throw myDocumentDomainError("EDIT_ERROR", "The edited page could not be reloaded.")
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("pageId", BibleUIAgentJSON.uuid(pageID)),
            ("documentId", BibleUIAgentJSON.uuid(updated.document.id)),
            ("title", .string(updated.page.title)),
            ("contentType", .string(updated.page.contentType.rawValue)),
            ("orderNumber", BibleUIAgentJSON.integer(updated.page.orderNumber))
        ))
    }

    /** Deletes one page and compacts sibling order in one transactional save. */
    func deleteMyDocumentPage(pageID: UUID) throws -> AgentToolResult {
        var session = try loadMyDocumentSession(code: "DELETE_ERROR")
        guard let location = locatePage(pageID, in: session) else {
            throw myDocumentDomainError(
                "PAGE_NOT_FOUND",
                "Page not found: \(pageID.uuidString.lowercased())"
            )
        }
        let pageTitle = location.page.title
        do {
            try session.deletePage(documentID: location.document.id, pageID: pageID)
            try myDocumentLibraryStore.save(&session, reservedInitials: reservedDocumentInitials)
        } catch {
            throw myDocumentDomainError("DELETE_ERROR", "The page could not be deleted.")
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("deleted", .bool(true)),
            ("pageId", BibleUIAgentJSON.uuid(pageID)),
            ("pageTitle", .string(pageTitle))
        ))
    }

    /** Validates one page destination and produces Android's typed terminal completion. */
    func finishWithMyDocumentPage(pageID: UUID, message: String) throws -> AgentToolResult {
        let session = try loadMyDocumentSession(code: "READ_ERROR")
        guard let location = locatePage(pageID, in: session) else {
            throw myDocumentDomainError(
                "PAGE_NOT_FOUND",
                "Page not found: \(pageID.uuidString.lowercased())"
            )
        }
        let finalMessage = message.isEmpty ? "Task completed" : message
        return try BibleUIAgentJSON.success(
            BibleUIAgentJSON.object(
                ("finished", .bool(true)),
                ("documentInitials", .string(location.document.initials)),
                ("pageKey", .string(location.page.pageKey)),
                ("message", .string(finalMessage))
            ),
            completion: .myDocumentPage(
                documentInitials: location.document.initials,
                pageKey: location.page.pageKey,
                message: finalMessage
            )
        )
    }

    private struct MyDocumentPageLocation {
        let document: MyDocumentDraft
        let page: MyDocumentPageDraft
        let index: Int
    }

    private func locatePage(
        _ pageID: UUID,
        in session: MyDocumentManagementSession
    ) -> MyDocumentPageLocation? {
        for document in session.documents {
            if let index = document.pages.firstIndex(where: { $0.id == pageID }) {
                return MyDocumentPageLocation(
                    document: document,
                    page: document.pages[index],
                    index: index
                )
            }
        }
        return nil
    }

    private func resolveMyDocument(
        in session: MyDocumentManagementSession,
        documentID: UUID?,
        initials: String?
    ) -> MyDocumentDraft? {
        if let documentID {
            return session.documents.first { $0.id == documentID }
        }
        if let initials {
            return session.documents.first { $0.initials == initials }
        }
        return nil
    }

    private func ensureAIDocument(
        in session: inout MyDocumentManagementSession,
        promptID: UUID
    ) throws -> MyDocumentDraft {
        if let existing = session.documents.first(where: {
            $0.initials == MyDocumentManagementSession.aiDocumentsInitials
        }) {
            return existing
        }
        let id: UUID
        do {
            id = try session.createDocument(
                name: "AI Documents",
                reservedInitials: reservedDocumentInitials,
                initials: MyDocumentManagementSession.aiDocumentsInitials,
                sourcePromptId: promptID
            )
        } catch {
            throw myDocumentDomainError("ADD_ERROR", "AI Documents could not be created.")
        }
        guard let created = session.document(id: id) else {
            throw myDocumentDomainError("ADD_ERROR", "AI Documents could not be loaded.")
        }
        return created
    }

    private func loadMyDocumentSession(code: String) throws -> MyDocumentManagementSession {
        do {
            return try myDocumentLibraryStore.loadSession()
        } catch {
            throw myDocumentDomainError(code, "My Documents could not be read.")
        }
    }

    private func myDocumentContentType(
        _ value: BibleUIAgentPageContentType
    ) -> MyDocumentContentType {
        MyDocumentContentType(rawValue: value.rawValue) ?? .markdown
    }

    private func myDocumentPageOrder(
        _ lhs: MyDocumentPageDraft,
        _ rhs: MyDocumentPageDraft
    ) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func myDocumentDomainError(_ code: String, _ message: String) -> BibleUIAgentDomainError {
        BibleUIAgentDomainError(code: code, message: message)
    }
}
