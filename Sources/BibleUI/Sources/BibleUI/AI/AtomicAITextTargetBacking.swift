// AtomicAITextTargetBacking.swift -- Conflict-safe writes to editable app text

import BibleCore
import Foundation

/**
 Main-actor backing for every editable AI text destination.

 Bookmark and StudyPad models inherit the supplied BookmarkService context confinement, while My
 Documents writes use MyDocumentStore's rollback-aware page transaction. Each compare-and-write
 performs its final read, equality check, mutation, save, and verification without suspension, so a
 UI or sync write cannot land between stale-content validation and replacement on the main actor.
 */
@MainActor
public final class BibleUIAITextTargetBacking: AITextTargetBacking {
    private let bookmarkService: BookmarkService
    private let myDocumentStore: MyDocumentStore
    /// Fresh combined-registry proof required before a My Documents page is read or written.
    private let isMyDocumentPageAuthorized: (UUID) -> Bool

    /**
     Creates production text-target routing over existing persistence services.

     - Parameters:
       - bookmarkService: Existing Bible/generic bookmark and StudyPad service.
       - myDocumentStore: Existing rollback-aware My Documents page store.
       - isMyDocumentPageAuthorized: Fresh reader-ownership proof for My Documents page ids. The
         default preserves explicit non-reader management callers that already own their store.
     - Side effects: None.
     - Failure modes: None; both dependencies retain ownership of their model contexts.
     */
    public init(
        bookmarkService: BookmarkService,
        myDocumentStore: MyDocumentStore,
        isMyDocumentPageAuthorized: @escaping (UUID) -> Bool = { _ in true }
    ) {
        self.bookmarkService = bookmarkService
        self.myDocumentStore = myDocumentStore
        self.isMyDocumentPageAuthorized = isMyDocumentPageAuthorized
    }

    /**
     Reads current editable source text and its durable representation.

     - Parameter target: Exact bookmark note, StudyPad text row, or My Documents page identity.
     - Returns: Current value, including an empty body when the owning entity exists without a
       detached content row, or nil when the owning entity is absent.
     - Side effects: Reads model-context-backed services on the main actor.
     - Failure modes: Missing entities and My Documents pages no longer owned by the reader's fresh
       combined registry return nil before page content is read.
     */
    public func read(_ target: AITextTarget) async throws -> AITextTargetValue? {
        currentValue(for: target)
    }

    /**
     Conditionally writes replacement content while preserving its captured content type.

     - Parameters:
       - value: Replacement source content and unchanged durable type.
       - target: Exact owning entity identity.
       - expectedValue: Value captured before model execution.
     - Returns: Written, targetNotFound, or staleContent.
     - Side effects: Commits through BookmarkService or MyDocumentStore on the main actor.
     - Failure modes: Persistence refusal is reported as staleContent so callers never treat an
       uncommitted write as successful.
     */
    public func compareAndWrite(
        _ value: AITextTargetValue,
        to target: AITextTarget,
        replacing expectedValue: AITextTargetValue
    ) async throws -> AITextTargetWriteResult {
        guard let current = currentValue(for: target) else {
            return .targetNotFound
        }
        guard current == expectedValue, value.contentType == expectedValue.contentType else {
            return .staleContent
        }

        switch target {
        case .bibleBookmarkNote(let id):
            bookmarkService.saveBibleBookmarkNote(
                bookmarkId: id,
                note: value.content,
                defaultContentType: value.contentType.bookmarkRawValue
            )
        case .genericBookmarkNote(let id):
            bookmarkService.saveBibleBookmarkNote(
                bookmarkId: id,
                note: value.content,
                defaultContentType: value.contentType.bookmarkRawValue
            )
        case .studyPadText(let id):
            bookmarkService.updateStudyPadTextEntryText(id: id, text: value.content)
        case .myDocumentPage(let id):
            guard isMyDocumentPageAuthorized(id) else {
                return .staleContent
            }
            guard let page = myDocumentStore.page(pageId: id) else {
                return .targetNotFound
            }
            guard
                  let initials = page.document?.initials,
                  myDocumentStore.savePageContent(
                      bookInitials: initials,
                      pageId: id,
                      content: value.content,
                      title: nil
                  )
            else {
                return .staleContent
            }
        }

        return currentValue(for: target) == value ? .written : .staleContent
    }

    /** Reads one target synchronously so conditional writes contain no suspension point. */
    private func currentValue(for target: AITextTarget) -> AITextTargetValue? {
        switch target {
        case .bibleBookmarkNote(let id):
            guard let bookmark = bookmarkService.bibleBookmark(id: id) else { return nil }
            return AITextTargetValue(
                content: bookmark.notes?.notes ?? "",
                contentType: Self.noteContentType(bookmark.notes?.contentType)
            )
        case .genericBookmarkNote(let id):
            guard let bookmark = bookmarkService.genericBookmark(id: id) else { return nil }
            return AITextTargetValue(
                content: bookmark.notes?.notes ?? "",
                contentType: Self.noteContentType(bookmark.notes?.contentType)
            )
        case .studyPadText(let id):
            guard let entry = bookmarkService.studyPadEntry(id: id) else { return nil }
            return AITextTargetValue(
                content: entry.textEntry?.text ?? "",
                contentType: Self.noteContentType(entry.contentType)
            )
        case .myDocumentPage(let id):
            guard isMyDocumentPageAuthorized(id),
                  let page = myDocumentStore.page(pageId: id) else { return nil }
            return AITextTargetValue(
                content: page.pageContent?.content ?? "",
                contentType: page.contentType.aiTextContentType
            )
        }
    }

    /** Maps nullable legacy note types to Android's HTML inheritance default. */
    private static func noteContentType(_ rawValue: String?) -> AITextContentType {
        rawValue?.uppercased() == "MARKDOWN" ? .markdown : .html
    }
}

private extension AITextContentType {
    /** BookmarkService row value used only when creating a previously absent note payload. */
    var bookmarkRawValue: String {
        self == .markdown ? "MARKDOWN" : "HTML"
    }
}

private extension MyDocumentContentType {
    /** Lossless My Documents to AI text transformation content-type mapping. */
    var aiTextContentType: AITextContentType {
        switch self {
        case .markdown: return .markdown
        case .html: return .html
        case .osis: return .osis
        }
    }
}

/** Discoverable production-name alias for app composition roots. */
public typealias ProductionAITextTargetBacking = BibleUIAITextTargetBacking
