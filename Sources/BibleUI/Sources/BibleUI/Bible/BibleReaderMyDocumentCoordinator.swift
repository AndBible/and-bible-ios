// BibleReaderMyDocumentCoordinator.swift -- My Documents reader state and payload assembly

import BibleCore
import Foundation

/**
 Owns reader-local My Documents page identity and WebView payload assembly.

 Android presents My Documents as generated general-book modules while raw editable content is
 fetched and saved through bridge calls. This coordinator keeps the iOS reader aligned with that
 contract without making `BibleReaderController` own the active page slots or duplicate the
 `OsisDocument` JSON shape. The type is intentionally value-scoped to one reader pane and does not
 perform SwiftData fetches, bridge emission, pasteboard writes, or persistence.

 - Side effects: Mutates only its active document/page identity.
 - Failure modes: Document JSON serialization returns `nil` if the assembled payload cannot be
   encoded; callers should avoid emitting invalid placeholder JSON.
 - Note: Content-type rendering preserves the existing iOS bridge semantics: Markdown and HTML
   content are XML-escaped and wrapped for Vue rendering, while OSIS content is already structured
   and passes through unchanged.
 */
struct BibleReaderMyDocumentCoordinator {
    /// Active local My Documents document initials currently rendered in the pane.
    private var activeBookInitials: String?

    /// Active local My Documents page key currently rendered in the pane.
    private var activePageKey: String?

    /**
     Records the My Documents page currently visible in the reader.

     - Parameters:
       - bookInitials: Android-compatible generated general-book initials for the document.
       - pageKey: Page key scoped to `bookInitials`.
     - Side effects: Replaces the active document/page identity for this coordinator.
     - Failure modes: None; callers are responsible for resolving the page before recording it.
     */
    mutating func setActivePage(bookInitials: String, pageKey: String) {
        activeBookInitials = bookInitials
        activePageKey = pageKey
    }

    /**
     Clears any active My Documents page identity.

     - Side effects: Removes the active document/page identity for this coordinator.
     - Failure modes: None.
     */
    mutating func clearActivePage() {
        activeBookInitials = nil
        activePageKey = nil
    }

    /**
     Clears active My Documents state when rendered content moves away from that local document.

     `BibleReaderController.setRenderedContentState` calls this for every native content emission.
     The active My Documents page is preserved only when the rendered content remains the same
     generated general-book module, matching the previous controller-owned reload/delete guard.

     - Parameters:
       - category: Rendered document category being sent to the reader.
       - moduleName: Rendered module/document initials, if any.
     - Side effects: Clears active identity when the rendered content is not the active My Document.
     - Failure modes: None.
     */
    mutating func clearActivePageUnless(category: DocumentCategory, moduleName: String?) {
        if category != .generalBook || moduleName != activeBookInitials {
            clearActivePage()
        }
    }

    /**
     Returns the active page key only when it belongs to the requested My Documents collection.

     - Parameter bookInitials: Android-compatible generated general-book initials to match.
     - Returns: Active page key for the document, or `nil` when another document/category is active.
     - Side effects: None.
     - Failure modes: None.
     */
    func activePageKey(for bookInitials: String) -> String? {
        activeBookInitials == bookInitials ? activePageKey : nil
    }

    /**
     Checks whether an AI page action belongs to the active My Documents collection.

     - Parameter context: Store-validated AI page action context.
     - Returns: `true` when the action's document initials match the active document.
     - Side effects: None.
     - Failure modes: None.
     */
    func isActiveDocument(_ context: MyDocumentAIPageActionContext) -> Bool {
        activeBookInitials == context.bookInitials
    }

    /**
     Checks whether an AI page action targets the exact active My Documents page.

     - Parameter context: Store-validated AI page action context.
     - Returns: `true` when both document initials and page key match the active page.
     - Side effects: None.
     - Failure modes: None.
     */
    func isActivePage(_ context: MyDocumentAIPageActionContext) -> Bool {
        activeBookInitials == context.bookInitials && activePageKey == context.pageKey
    }

    /**
     Builds the share text for a raw My Documents payload.

     Android shares the page title as heading text when present and otherwise shares only the raw
     page body. Keeping this formatting here prevents every bridge caller from re-encoding that
     title/body rule.

     - Parameter payload: Raw page payload resolved by `MyDocumentStore`.
     - Returns: Shareable plain text for the native sharing surface.
     - Side effects: None.
     - Failure modes: None.
     */
    func shareText(for payload: MyDocumentRawContentPayload) -> String {
        if payload.title.isEmpty {
            return payload.content
        }
        return "\(payload.title)\n\n\(payload.content)"
    }

    /**
     Builds the Vue.js `OsisDocument` payload for one stored My Documents page.

     - Parameters:
       - document: Parent My Documents collection resolved by Android-compatible initials.
       - page: Page metadata/content to render.
     - Returns: Sorted-key JSON string for the WebView `add_documents` event, or `nil` if encoding
       fails.
     - Side effects: None.
     - Failure modes: Returns `nil` instead of an empty placeholder object so callers do not emit an
       invalid document payload to Vue.
     */
    func documentJSON(document: MyDocument, page: MyDocumentPage) -> String? {
        let content = page.pageContent?.content ?? ""
        let xml = renderedXML(content: content, contentType: page.contentType)
        let promptId: Any = page.sourcePromptId?.uuidString ?? NSNull()
        let languageCode = page.languageCode ?? Locale.current.language.languageCode?.identifier ?? "en"

        let osisFragment: [String: Any] = [
            "xml": xml,
            "key": page.pageKey,
            "keyName": page.title,
            "v11n": "KJVA",
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookInitials": document.initials,
            "bookAbbreviation": document.initials,
            "osisRef": page.pageKey,
            "isNewTestament": false,
            "features": [String: Any](),
            "hasStrongs": false,
            "ordinalRange": [0, 0],
            "language": languageCode,
            "direction": "ltr",
        ]

        let renderedDocument: [String: Any] = [
            "id": "my-document-\(page.id.uuidString)",
            "type": "osis",
            "osisFragment": osisFragment,
            "bookInitials": document.initials,
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookAbbreviation": document.initials,
            "bookName": document.name,
            "key": page.pageKey,
            "v11n": "KJVA",
            "osisRef": page.pageKey,
            "annotateRef": page.pageKey,
            "genericBookmarks": [Any](),
            "ordinalRange": [0, 0],
            "isNativeHtml": false,
            "highlightedOrdinalRange": NSNull(),
            "isMyDocument": true,
            "isAiDocument": document.initials == "AIDocuments",
            "myDocumentPageId": page.id.uuidString,
            "sourcePromptId": promptId,
            "sourcePromptName": NSNull(),
            "sourceModelName": NSNull(),
            "aiDocMarkers": [Any](),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: renderedDocument, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /**
     Converts stored raw My Documents content into the OSIS-template fragment consumed by Vue.js.

     - Parameters:
       - content: Raw page body stored in the local My Documents table.
       - contentType: Stored content type matching Android's My Documents enum values.
     - Returns: XML fragment string suitable for the rendered `osisFragment.xml` field.
     - Side effects: None.
     - Failure modes: None; OSIS content is trusted as caller-authored structured markup.
     */
    private func renderedXML(content: String, contentType: MyDocumentContentType) -> String {
        switch contentType {
        case .markdown:
            return "<div class=\"mydoc-markdown\"><markdown>\(Self.escapeXML(content))</markdown></div>"
        case .html:
            return "<div class=\"mydoc-html\"><html>\(Self.escapeXML(content))</html></div>"
        case .osis:
            return content
        }
    }

    /**
     Escapes text content for XML wrapper fragments.

     - Parameter text: Raw Markdown or HTML text from the local My Documents store.
     - Returns: XML-safe text with the same character replacement set previously used by the
       controller.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
