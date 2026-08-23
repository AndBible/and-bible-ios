// AIReaderBridgeActionResolver.swift -- Validated bridge and reader context projection

import BibleCore
import BibleView
import Foundation
import SwordKit

/** Immutable source generation captured when an AI action is requested. */
struct AIReaderPaneSnapshot: Equatable, Sendable {
  /// Workspace owning the pane at capture time.
  let workspaceID: UUID?

  /// Window owning the pane at capture time.
  let windowID: UUID?

  /// Exact source document category.
  let documentCategory: DocumentCategory?

  /// Exact initials copied from the backend that produced the content.
  let activeDocumentInitials: String?

  /// Exact source-domain page key, including meaningful whitespace.
  let sourceBookKey: String?

  /// Source-versification OSIS passage for Bible prompt/reference lookup.
  let sourceOSISRange: String?

  /// Independently optional structured source content.
  let selectedContent: String?

  /// Independently optional Bible canonical text, or `""` for generic documents.
  let selectedText: String?

  /// Source-versification Bible range, or generic local-anchor range when supplied by the bridge.
  let sourceOrdinalRange: ClosedRange<Int>?

  /// Optional KJVA projection used only for strict cache identity.
  let kjvaOrdinalRange: ClosedRange<Int>?
}

/** Exact source context owned by a Bible bookmark note target. */
struct AIReaderBibleBookmarkContext: Equatable, Sendable {
  /// Exact originating Bible initials stored on the bookmark.
  let bookInitials: String

  /// Source-derived key for the bookmark passage.
  let sourceBookKey: String

  /// Source-versification OSIS identity for prompt and commentary lookup.
  let sourceOSISRange: String

  /// Bookmark ordinals in its originating module's own versification.
  let sourceOrdinalRange: ClosedRange<Int>

  /// Optional verified KJVA cache projection retained independently from source identity.
  let kjvaOrdinalRange: ClosedRange<Int>?

  /// Independently optional structured content read from the bookmark's own module.
  let selectedContent: String?

  /// Independently optional canonical text read from the bookmark's own module.
  let selectedText: String?
}

/** Pure validation and context construction for native AI reader entry points. */
enum AIReaderBridgeActionResolver {
  /**
   Resolves one exact Vue selection without requiring a KJVA cache projection.

   - Parameters:
     - request: Validated bridge payload containing raw source-domain endpoints.
     - pane: Exact source generation extracted for this request.
     - verifiedKJVARange: Optional durable KJVA cache identity for Bible selections.
   - Returns: Immutable prompt request, or `nil` for stale identity, invalid endpoints, or mismatched
     source extraction.
   - Side effects: None.
   - Failure modes: Fails closed before range construction for excessive/non-forward endpoints and
     rejects any module/key generation mismatch.
   */
  static func selection(
    _ request: AISelectionActionRequest,
    pane: AIReaderPaneSnapshot,
    verifiedKJVARange: ClosedRange<Int>?
  ) -> AIReaderActionRequest? {
    guard !request.bookInitials.isEmpty,
      let activeDocumentInitials = pane.activeDocumentInitials,
      SwordJavaStringIdentity.equals(request.bookInitials, activeDocumentInitials)
    else {
      return nil
    }

    let isBible = request.osisRef == nil
    let sourceBounds = isBible
      ? AIReaderSourceRange.bibleBounds(
        start: request.startOrdinal,
        end: request.endOrdinal
      )
      : AIReaderSourceRange.genericBounds(
        start: request.startOrdinal,
        end: request.endOrdinal
      )
    guard let sourceBounds else { return nil }

    if isBible {
      guard pane.documentCategory == .bible,
        pane.sourceOrdinalRange == sourceBounds.closedRange,
        pane.sourceOSISRange?.isEmpty == false
      else {
        return nil
      }
    } else {
      guard request.osisRef == pane.sourceBookKey else { return nil }
    }

    let cacheRange: ClosedRange<Int>?
    if let verifiedKJVARange,
      let verifiedBounds = AIReaderSourceRange.bibleBounds(
        start: verifiedKJVARange.lowerBound,
        end: verifiedKJVARange.upperBound
      )
    {
      cacheRange = verifiedBounds.closedRange
    } else {
      cacheRange = nil
    }
    let highlighted = request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? nil
      : request.text

    return AIReaderActionRequest(
      promptContext: isBible ? .verseSelection : .textSelection,
      documentCategory: isBible ? .bible : pane.documentCategory,
      workspaceID: pane.workspaceID,
      windowID: pane.windowID,
      activeDocumentInitials: request.bookInitials,
      sourceBookKey: pane.sourceBookKey,
      sourceOrdinalStart: sourceBounds.start,
      sourceOrdinalEnd: sourceBounds.end,
      kjvaOrdinalStart: cacheRange?.lowerBound,
      kjvaOrdinalEnd: cacheRange?.upperBound,
      verseReference: isBible ? pane.sourceOSISRange : nil,
      selectedContent: pane.selectedContent,
      selectedText: isBible ? pane.selectedText : "",
      highlightedText: highlighted,
      selectionStartOffset: nil,
      selectionEndOffset: nil,
      textTarget: nil,
      noteEditorContent: nil,
      noteEditorContentType: nil,
      workspaceWindowsSummary: nil
    )
  }

  /**
   Resolves an Android note-editor payload to one typed, conflict-safe writeback destination.

   - Parameters:
     - request: Validated bridge payload.
     - target: Existing bookmark, StudyPad, or My Documents identity selected by the host.
     - pane: Workspace/window identity captured with the editor request.
     - bibleBookmark: Entity-owned source context required only for a Bible bookmark note.
   - Returns: Immutable note-editor action, or `nil` for a type/target/source mismatch.
   - Side effects: None.
   - Failure modes: Generic targets reject Bible context and never inherit pane document content;
     Bible targets require bounded, internally consistent source context.
   */
  static func noteEditor(
    _ request: AINoteEditorActionRequest,
    target: AITextTarget,
    pane: AIReaderPaneSnapshot,
    bibleBookmark: AIReaderBibleBookmarkContext?
  ) -> AIReaderActionRequest? {
    guard UUID(uuidString: request.entityId) == target.id,
      NoteEditorEntityType(rawValue: request.entityType) == target.noteEditorEntityType
    else {
      return nil
    }

    let documentCategory: DocumentCategory?
    let activeDocumentInitials: String?
    let sourceBookKey: String?
    let sourceOrdinalRange: ClosedRange<Int>?
    let kjvaOrdinalRange: ClosedRange<Int>?
    let verseReference: String?
    let selectedContent: String?
    let selectedText: String?

    switch target {
    case .bibleBookmarkNote:
      guard let bibleBookmark,
        !bibleBookmark.bookInitials.isEmpty,
        !bibleBookmark.sourceBookKey.isEmpty,
        !bibleBookmark.sourceOSISRange.isEmpty,
        let bounds = AIReaderSourceRange.bibleBounds(
          start: bibleBookmark.sourceOrdinalRange.lowerBound,
          end: bibleBookmark.sourceOrdinalRange.upperBound
        ), bounds.closedRange == bibleBookmark.sourceOrdinalRange
      else {
        return nil
      }
      documentCategory = .bible
      activeDocumentInitials = bibleBookmark.bookInitials
      sourceBookKey = bibleBookmark.sourceBookKey
      sourceOrdinalRange = bibleBookmark.sourceOrdinalRange
      kjvaOrdinalRange = bibleBookmark.kjvaOrdinalRange.flatMap { range in
        AIReaderSourceRange.bibleBounds(
          start: range.lowerBound,
          end: range.upperBound
        )?.closedRange
      }
      verseReference = bibleBookmark.sourceOSISRange
      selectedContent = bibleBookmark.selectedContent
      selectedText = bibleBookmark.selectedText

    case .genericBookmarkNote, .studyPadText, .myDocumentPage:
      guard bibleBookmark == nil else { return nil }
      documentCategory = nil
      activeDocumentInitials = nil
      sourceBookKey = nil
      sourceOrdinalRange = nil
      kjvaOrdinalRange = nil
      verseReference = nil
      selectedContent = nil
      selectedText = ""
    }

    return AIReaderActionRequest(
      promptContext: .noteEditor,
      documentCategory: documentCategory,
      workspaceID: pane.workspaceID,
      windowID: pane.windowID,
      activeDocumentInitials: activeDocumentInitials,
      sourceBookKey: sourceBookKey,
      sourceOrdinalStart: sourceOrdinalRange?.lowerBound,
      sourceOrdinalEnd: sourceOrdinalRange?.upperBound,
      kjvaOrdinalStart: kjvaOrdinalRange?.lowerBound,
      kjvaOrdinalEnd: kjvaOrdinalRange?.upperBound,
      verseReference: verseReference,
      selectedContent: selectedContent,
      selectedText: selectedText,
      highlightedText: nil,
      selectionStartOffset: nil,
      selectionEndOffset: nil,
      textTarget: target,
      noteEditorContent: request.currentText,
      noteEditorContentType: request.contentType,
      workspaceWindowsSummary: nil
    )
  }

  /**
   Builds Android's whole-window action context for one exact document generation.

   - Parameter pane: Source-bound pane snapshot.
   - Returns: Immutable action, or `nil` when document/key or Bible source identity is incomplete.
   - Side effects: None.
   - Failure modes: Empty identity and inconsistent Bible source ranges fail closed.
   */
  static func window(_ pane: AIReaderPaneSnapshot) -> AIReaderActionRequest? {
    guard let initials = pane.activeDocumentInitials,
      !initials.isEmpty,
      let sourceBookKey = pane.sourceBookKey,
      !sourceBookKey.isEmpty
    else {
      return nil
    }
    if pane.documentCategory == .bible {
      guard let sourceRange = pane.sourceOrdinalRange,
        AIReaderSourceRange.bibleBounds(
          start: sourceRange.lowerBound,
          end: sourceRange.upperBound
        )?.closedRange == sourceRange,
        pane.sourceOSISRange?.isEmpty == false
      else {
        return nil
      }
    }
    return AIReaderActionRequest(
      promptContext: .windowMenu,
      documentCategory: pane.documentCategory,
      workspaceID: pane.workspaceID,
      windowID: pane.windowID,
      activeDocumentInitials: initials,
      sourceBookKey: sourceBookKey,
      sourceOrdinalStart: pane.sourceOrdinalRange?.lowerBound,
      sourceOrdinalEnd: pane.sourceOrdinalRange?.upperBound,
      kjvaOrdinalStart: pane.kjvaOrdinalRange?.lowerBound,
      kjvaOrdinalEnd: pane.kjvaOrdinalRange?.upperBound,
      verseReference: pane.documentCategory == .bible ? pane.sourceOSISRange : nil,
      selectedContent: pane.selectedContent,
      selectedText: pane.documentCategory == .bible ? pane.selectedText : "",
      highlightedText: nil,
      selectionStartOffset: nil,
      selectionEndOffset: nil,
      textTarget: nil,
      noteEditorContent: nil,
      noteEditorContentType: nil,
      workspaceWindowsSummary: nil
    )
  }

  /** Builds Android's workspace action context without inventing a document selection. */
  static func workspace(
    workspaceID: UUID?,
    activeWindowID: UUID?,
    summary: String
  ) -> AIReaderActionRequest {
    AIReaderActionRequest(
      promptContext: .workspaceMenu,
      documentCategory: nil,
      workspaceID: workspaceID,
      windowID: activeWindowID,
      activeDocumentInitials: nil,
      sourceBookKey: nil,
      sourceOrdinalStart: nil,
      sourceOrdinalEnd: nil,
      kjvaOrdinalStart: nil,
      kjvaOrdinalEnd: nil,
      verseReference: nil,
      selectedContent: nil,
      selectedText: nil,
      highlightedText: nil,
      selectionStartOffset: nil,
      selectionEndOffset: nil,
      textTarget: nil,
      noteEditorContent: nil,
      noteEditorContentType: nil,
      workspaceWindowsSummary: summary
    )
  }
}
