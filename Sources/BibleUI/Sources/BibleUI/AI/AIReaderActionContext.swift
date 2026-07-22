// AIReaderActionContext.swift -- Immutable reader context and Android-compatible message composition

import BibleCore
import Foundation

/** Exact app context captured before an AI prompt chooser is presented. */
struct AIReaderActionRequest: Equatable, Sendable {
    /// Prompt surface used to filter Android's action catalog.
    let promptContext: PromptContext
    /// Current document category used by `bibleOnly` filtering.
    let documentCategory: DocumentCategory?
    /// Workspace that owns tool mutations and result routing.
    let workspaceID: UUID?
    /// Reader window captured when the action started.
    let windowID: UUID?
    /// Exact active document initials, when a document is selected.
    let activeDocumentInitials: String?
    /// Exact active key or selection key inside the source document.
    let sourceBookKey: String?
    /// Inclusive source-domain ordinal range supplied by Vue or the active page.
    let sourceOrdinalStart: Int?
    let sourceOrdinalEnd: Int?
    /// Inclusive verified KJVA range for Bible context and marker persistence.
    let kjvaOrdinalStart: Int?
    let kjvaOrdinalEnd: Int?
    /// OSIS verse range derived from the verified KJVA coordinates.
    let verseReference: String?
    /// Full source context available before the run.
    let selectedContent: String?
    /// Source text extracted from the selected range or page.
    let selectedText: String?
    /// Exact user-highlighted text supplied by the web client.
    let highlightedText: String?
    /// Character offsets for a sub-verse highlight.
    let selectionStartOffset: Int?
    let selectionEndOffset: Int?
    /// Optional note-editor writeback destination.
    let textTarget: AITextTarget?
    /// Note editor metadata retained for system and user messages.
    let noteEditorContent: String?
    let noteEditorContentType: String?
    /// Workspace summary used only by workspace actions.
    let workspaceWindowsSummary: String?

    /**
     Creates a core execution context for one selected prompt.

     - Parameters:
       - prompt: Effective built-in, add-on, or user prompt.
       - userSpecification: Optional task text collected before execution.
       - previousResponse: Optional prior generated content used by regeneration.
       - additionalInstructions: Optional regeneration-specific instructions.
     - Returns: Immutable context consumed by the production tool dispatcher.
     - Side effects: None.
     - Failure modes: None; source validation occurs before this request is created.
     */
    func executionContext(
        prompt: AgentPrompt,
        userSpecification: String? = nil,
        previousResponse: String? = nil,
        additionalInstructions: String? = nil
    ) -> AgentExecutionContext {
        AgentExecutionContext(
            promptId: prompt.id,
            workspaceId: workspaceID,
            kjvOrdinalStart: kjvaOrdinalStart,
            kjvOrdinalEnd: kjvaOrdinalEnd,
            verseReference: verseReference,
            selectedContent: selectedContent,
            activeDocumentInitials: activeDocumentInitials,
            windowId: windowID,
            selectedText: selectedText,
            highlightedText: highlightedText,
            selectionStartOffset: selectionStartOffset,
            selectionEndOffset: selectionEndOffset,
            selectionStartOrdinal: documentCategory == .bible ? nil : sourceOrdinalStart,
            selectionEndOrdinal: documentCategory == .bible ? nil : sourceOrdinalEnd,
            userSpecification: userSpecification,
            previousResponse: previousResponse,
            additionalInstructions: additionalInstructions,
            sourceBookKey: sourceBookKey,
            noteEditorEntityType: textTarget?.noteEditorEntityType,
            noteEditorEntityId: textTarget?.id.uuidString,
            noteEditorContent: noteEditorContent,
            noteEditorContentType: noteEditorContentType,
            workspaceWindowsSummary: workspaceWindowsSummary,
            isTextTransformation: prompt.isTextTransformation,
            noDocumentCreation: prompt.noDocumentCreation
        )
    }

    /** Returns a copy carrying the exact source state persisted with a generated page. */
    func replacingSource(
        activeDocumentInitials: String?,
        sourceBookKey: String?,
        kjvaOrdinalStart: Int?,
        kjvaOrdinalEnd: Int?,
        selectedText: String?
    ) -> AIReaderActionRequest {
        AIReaderActionRequest(
            promptContext: promptContext,
            documentCategory: documentCategory,
            workspaceID: workspaceID,
            windowID: windowID,
            activeDocumentInitials: activeDocumentInitials,
            sourceBookKey: sourceBookKey,
            sourceOrdinalStart: nil,
            sourceOrdinalEnd: nil,
            kjvaOrdinalStart: kjvaOrdinalStart,
            kjvaOrdinalEnd: kjvaOrdinalEnd,
            verseReference: Self.verseReference(
                start: kjvaOrdinalStart,
                end: kjvaOrdinalEnd
            ),
            selectedContent: nil,
            selectedText: selectedText,
            highlightedText: nil,
            selectionStartOffset: nil,
            selectionEndOffset: nil,
            textTarget: nil,
            noteEditorContent: nil,
            noteEditorContentType: nil,
            workspaceWindowsSummary: workspaceWindowsSummary
        )
    }

    /** Builds an OSIS range from inclusive KJVA ordinals without inventing endpoints. */
    static func verseReference(start: Int?, end: Int?) -> String? {
        guard let start,
              let startReference = JSwordKJVAVersification.verseReference(ordinal: start) else {
            return nil
        }
        let normalizedEnd = max(end ?? start, start)
        guard let endReference = JSwordKJVAVersification.verseReference(ordinal: normalizedEnd) else {
            return nil
        }
        return startReference.ordinal == endReference.ordinal
            ? startReference.osisRef
            : "\(startReference.osisRef)-\(endReference.osisRef)"
    }
}

/** User choices applied to a safe AI page regeneration. */
struct AIReaderRegenerationOptions: Equatable, Sendable {
    let additionalInstructions: String?
    let keepPrevious: Bool
    let freshRun: Bool
    let modelOverrideID: UUID?

    /** Creates a normalized immutable regeneration request. */
    init(
        additionalInstructions: String?,
        keepPrevious: Bool,
        freshRun: Bool,
        modelOverrideID: UUID?
    ) {
        let value = additionalInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.additionalInstructions = value.flatMap { $0.isEmpty ? nil : $0 }
        self.keepPrevious = keepPrevious
        self.freshRun = freshRun
        self.modelOverrideID = modelOverrideID
    }
}

/** One category section rendered in the native AI action chooser. */
struct AIReaderPromptGroup: Identifiable {
    let id: String
    let title: String
    let prompts: [ResolvedAgentPrompt]
    let isFavorites: Bool
}

/** Pure prompt filtering and grouping shared by native presentation and focused tests. */
enum AIReaderPromptCatalog {
    /**
     Filters visible prompts and emits Android's favorites, uncategorized, then category order.

     - Parameters:
       - entries: Effective visible prompt entries in repository order.
       - categories: Effective categories in display order.
       - favoriteIDs: Persisted favorite prompt identities.
       - hiddenCategoryIDs: Categories excluded from action dialogs.
       - context: Prompt surface being presented.
       - documentCategory: Current document category, if applicable.
     - Returns: Non-empty chooser groups in Android order.
     - Side effects: None.
     - Failure modes: Prompts referencing missing categories are treated as uncategorized.
     */
    static func groups(
        entries: [ResolvedAgentPrompt],
        categories: [PromptCategory],
        favoriteIDs: Set<UUID>,
        hiddenCategoryIDs: Set<UUID>,
        context: PromptContext,
        documentCategory: DocumentCategory?
    ) -> [AIReaderPromptGroup] {
        let visible = entries.filter { entry in
            let prompt = entry.prompt
            guard prompt.showIn.contains(context) else { return false }
            guard documentCategory == nil || !prompt.bibleOnly || documentCategory == .bible else {
                return false
            }
            if let categoryID = prompt.categoryId, hiddenCategoryIDs.contains(categoryID) {
                return false
            }
            return true
        }
        guard !visible.isEmpty else { return [] }

        var result: [AIReaderPromptGroup] = []
        let favorites = visible.filter { favoriteIDs.contains($0.prompt.id) }
        if !favorites.isEmpty {
            result.append(
                AIReaderPromptGroup(
                    id: "favorites",
                    title: String(localized: "prompt_category_favorites", defaultValue: "Favorites"),
                    prompts: favorites,
                    isFavorites: true
                )
            )
        }

        let categoryIDs = Set(categories.map(\.id))
        let uncategorized = visible.filter {
            $0.prompt.categoryId == nil || !categoryIDs.contains($0.prompt.categoryId!)
        }
        if !uncategorized.isEmpty {
            result.append(
                AIReaderPromptGroup(
                    id: "uncategorized",
                    title: String(
                        localized: "prompt_category_uncategorized",
                        defaultValue: "Uncategorized"
                    ),
                    prompts: uncategorized,
                    isFavorites: false
                )
            )
        }

        for category in categories where !hiddenCategoryIDs.contains(category.id) && !category.hidden {
            let prompts = visible.filter { $0.prompt.categoryId == category.id }
            if !prompts.isEmpty {
                result.append(
                    AIReaderPromptGroup(
                        id: category.id.uuidString,
                        title: category.name,
                        prompts: prompts,
                        isFavorites: false
                    )
                )
            }
        }
        return result
    }
}

/** Android-compatible initial system and user message construction. */
enum AIReaderMessageComposer {
    /** Indexed Bible identity Android exposes to the `searchBible` tool through the system message. */
    struct SearchBible: Equatable, Sendable {
        /// Installed document initials accepted by the search tool.
        let initials: String
        /// Human-readable source language, or `nil` when module metadata omits it.
        let language: String?

        /**
         Creates a detached search-document descriptor.

         - Parameters:
           - initials: Exact installed document initials.
           - language: Optional human-readable module language.
         - Side effects: None.
         - Failure modes: Validation belongs to the installed-document resolver; values are retained
           exactly so provider instructions identify the same source as Android.
         */
        init(initials: String, language: String?) {
            self.initials = initials
            self.language = language
        }
    }

    /** Input assembled before model execution without retaining a credential or querying app state. */
    struct Input {
        /// Effective built-in, add-on, or user prompt.
        let prompt: AgentPrompt
        /// Immutable reader and note-editor context captured before execution.
        let context: AgentExecutionContext
        /// AI display language substituted into the selected system prompt.
        let appLanguage: String
        /// Effective ordinary-agent system prompt after user-setting resolution.
        let agentSystemPrompt: String
        /// Effective text-transformation system prompt after user-setting resolution.
        let transformationSystemPrompt: String
        /// Serialized installed-document result when prompt prefetch is enabled.
        let installedDocuments: String?
        /// Serialized commentary result when prompt prefetch is enabled.
        let commentaryEntries: String?
        /// First allowed indexed Bible Android would use for `searchBible`.
        let defaultSearchBible: SearchBible?
        /// Preferred installed Strong's Hebrew dictionary initials.
        let preferredStrongsHebrew: String?
        /// Preferred installed Strong's Greek dictionary initials.
        let preferredStrongsGreek: String?
        /// Preferred installed Robinson Greek morphology dictionary initials.
        let preferredGreekMorphology: String?

        /**
         Creates the complete pure message-composition input.

         Reference-document values default to `nil` so construction remains source-compatible while
         the host resolves installed modules asynchronously. Omitting them suppresses only their
         matching advisory lines; it never invents module identities or languages.

         - Parameters:
           - prompt: Effective prompt and tool policy.
           - context: Captured execution context.
           - appLanguage: Android-compatible AI display language.
           - agentSystemPrompt: Effective ordinary-agent prompt resource or customization.
           - transformationSystemPrompt: Effective transformation prompt resource or customization.
           - installedDocuments: Optional serialized document prefetch.
           - commentaryEntries: Optional serialized commentary prefetch.
           - defaultSearchBible: Optional first allowed indexed search Bible.
           - preferredStrongsHebrew: Optional preferred Hebrew dictionary initials.
           - preferredStrongsGreek: Optional preferred Greek dictionary initials.
           - preferredGreekMorphology: Optional preferred morphology dictionary initials.
         - Side effects: None.
         - Failure modes: None; unavailable optional context remains absent from provider messages.
         */
        init(
            prompt: AgentPrompt,
            context: AgentExecutionContext,
            appLanguage: String,
            agentSystemPrompt: String,
            transformationSystemPrompt: String,
            installedDocuments: String?,
            commentaryEntries: String?,
            defaultSearchBible: SearchBible? = nil,
            preferredStrongsHebrew: String? = nil,
            preferredStrongsGreek: String? = nil,
            preferredGreekMorphology: String? = nil
        ) {
            self.prompt = prompt
            self.context = context
            self.appLanguage = appLanguage
            self.agentSystemPrompt = agentSystemPrompt
            self.transformationSystemPrompt = transformationSystemPrompt
            self.installedDocuments = installedDocuments
            self.commentaryEntries = commentaryEntries
            self.defaultSearchBible = defaultSearchBible
            self.preferredStrongsHebrew = preferredStrongsHebrew
            self.preferredStrongsGreek = preferredStrongsGreek
            self.preferredGreekMorphology = preferredGreekMorphology
        }
    }

    /**
     Creates the initial provider-neutral conversation.

     - Parameter input: Prompt, captured source context, localized language, and optional prefetches.
     - Returns: Exactly one system and one user message; regeneration suffixes are added by core.
     - Side effects: None.
     - Failure modes: None; unavailable prefetch data is omitted.
     */
    static func messages(_ input: Input) -> [LLMMessage] {
        [
            LLMMessage(role: .system, content: systemMessage(input)),
            LLMMessage(role: .user, content: userMessage(input)),
        ]
    }

    /**
     Builds Android's contextual system message without secrets or transport metadata.

     - Parameter input: Pure prompt, reader context, and pre-resolved reference-document metadata.
     - Returns: Base prompt plus Android's contextual advisory lines in source order.
     - Side effects: None.
     - Failure modes: Missing optional metadata is omitted rather than represented by a placeholder,
       except Android's explicit `unknown language` label for a selected search Bible.
     */
    private static func systemMessage(_ input: Input) -> String {
        let context = input.context
        var value = (input.prompt.isTextTransformation
            ? input.transformationSystemPrompt
            : input.agentSystemPrompt)
            .replacingOccurrences(of: "{{APP_LANGUAGE}}", with: input.appLanguage)
        guard !input.prompt.isTextTransformation else { return value }

        if let initials = context.activeDocumentInitials {
            value += "Current active document: \(initials)\n"
        }
        if let reference = context.verseReference {
            value += "Selected verse reference: \(reference)\n"
        }
        if (input.prompt.allowedTools == nil || input.prompt.allowedTools?.contains(.searchBible) == true),
           let searchBible = input.defaultSearchBible {
            value += "Default search Bible (for searchBible tool): \(searchBible.initials) "
            value += "(\(searchBible.language ?? "unknown language"))\n"
        }
        if context.selectionStartOffset != nil, context.selectionEndOffset != nil {
            let translation = context.activeDocumentInitials ?? "null"
            value += "The user has highlighted specific text within a verse. "
            value += "Character offsets (startOffset/endOffset) are provided — these are character positions "
            value += "from the start of the verse text in the current translation (\(translation)). "
            value += "Use createBookmark with startOffset, endOffset, and bookInitials to create a sub-verse bookmark "
            value += "covering exactly the highlighted text, or adjust the offsets as needed.\n"
        }
        if let labelID = context.activeLabelId {
            value += "Active label/StudyPad ID: \(labelID.uuidString)\n"
        }
        if context.noDocumentCreation {
            value += "\nIMPORTANT: This prompt is configured for action-only mode (no document creation). "
            value += "Do NOT call setDocumentTitle. When you are done, call finishWithoutDocument "
            value += "with a brief summary of what you did. Any text output will appear only in the activity log.\n"
        }
        if let entityType = context.noteEditorEntityType {
            let entityID = context.noteEditorEntityId ?? ""
            let contentType = context.noteEditorContentType ?? ""
            value += "\n--- Note Editor Context ---\n"
            value += "Entity type: \(entityType.rawValue)\n"
            value += "Entity ID: \(entityID)\n"
            value += "Content type: \(contentType)\n"
            switch entityType {
            case .bookmarkNote:
                value += "Use updateBookmarkNote with this bookmark ID to save changes.\n"
            case .studyPadText:
                value += "Use updateStudyPadTextEntry with this entry ID to save changes.\n"
            case .myDocumentPage:
                value += "Use editMyDocumentPage with this page ID to save changes.\n"
            }
        }
        if let summary = context.workspaceWindowsSummary {
            value += "\n--- Current Workspace ---\n\(summary)"
        }
        if input.preferredStrongsGreek != nil
            || input.preferredStrongsHebrew != nil
            || input.preferredGreekMorphology != nil {
            value += "\nPreferred reference dictionaries:\n"
            if let hebrew = input.preferredStrongsHebrew {
                value += "- Strong's Hebrew: \(hebrew)\n"
            }
            if let greek = input.preferredStrongsGreek {
                value += "- Strong's Greek: \(greek)\n"
            }
            if let morphology = input.preferredGreekMorphology {
                value += "- Greek morphology: \(morphology)\n"
            }
        }
        return value
    }

    /**
     Builds Android's prompt, selection, prefetch, and note content message.

     - Parameter input: Prompt and captured content, including optional serialized prefetch results.
     - Returns: One user message with selected OSIS converted to semantic plain text. Analytical
       prompts receive local sentence anchors; transformations do not.
     - Side effects: Parses selected XML entirely in memory.
     - Failure modes: Malformed selected XML falls back to the original content exactly as Android
       does; optional prefetch failures are handled before this pure boundary.
     */
    private static func userMessage(_ input: Input) -> String {
        let context = input.context
        var value = input.prompt.promptTemplate
        if let specification = context.userSpecification {
            value += "\n\n--- User's Task Specification ---\n\(specification)"
        }
        if let highlighted = context.highlightedText {
            value += "\n\n--- User's Highlighted Text (FOCUS ON THIS) ---\n\(highlighted)"
            if let start = context.selectionStartOffset, let end = context.selectionEndOffset {
                value += "\n(Text offsets within verse: startOffset=\(start), endOffset=\(end))"
            }
        }
        if let start = context.selectionStartOrdinal {
            let end = context.selectionEndOrdinal ?? start
            value += "\n\n--- User's Selection (FOCUS ON THIS) ---\n"
            value += start == end
                ? "The user selected sentence §\(start) in the following document. Focus on this part.\n"
                : "The user selected sentences §\(start) to §\(end) in the following document. Focus on this part.\n"
        }
        if let selectedContent = context.selectedContent {
            let plainText = AIReaderSelectedContentConverter.plainText(
                from: selectedContent,
                injectAnchors: !input.prompt.isTextTransformation
            ) ?? selectedContent
            value += "\n\n--- Context ---\n\(plainText)"
        } else if let selectedText = context.selectedText {
            value += "\n\n--- Context ---\n\(selectedText)"
        }
        if let installedDocuments = input.installedDocuments {
            value += "\n\n--- Installed Documents (auto-included) ---\n\(installedDocuments)"
        }
        if let commentaryEntries = input.commentaryEntries {
            value += "\n\n--- Commentary Entries (auto-included, same format as getCommentaries tool) ---\n\n"
            value += commentaryEntries
        }
        if let note = context.noteEditorContent {
            value += "\n\n--- Current Note Content ---\n\(note)"
        }
        return value
    }
}

/**
 Converts captured OSIS into Android's lightweight provider-facing text representation.

 This parser deliberately consumes existing `BVA` elements without creating new anchors. Reader
 content already carries Android-compatible sentence ordinals, and re-anchoring it would change the
 selection and citation contract. A fresh parser is created per call, making conversion deterministic
 and safe across concurrent AI runs.
 */
enum AIReaderSelectedContentConverter {
    /**
     Converts one well-formed XML document to Android-compatible semantic text.

     - Parameters:
       - source: Captured OSIS XML with exactly one document element.
       - injectAnchors: Whether existing `BVA` ordinals become `[§N]` markers.
     - Returns: Normalized semantic text, or `nil` when XML is malformed.
     - Side effects: Parses in memory; external entity resolution is disabled.
     - Failure modes: Returns `nil` for malformed XML, multiple roots, or interrupted parsing so the
       caller can preserve Android's raw-content fallback.
     */
    static func plainText(from source: String, injectAnchors: Bool) -> String? {
        let delegate = AIReaderSelectedContentXMLParser(injectAnchors: injectAnchors)
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.completedSuccessfully else { return nil }
        return delegate.result
    }
}

/** Stateful delegate that folds XML elements into Android's semantic text during parsing. */
private final class AIReaderSelectedContentXMLParser: NSObject, XMLParserDelegate {
    /** One open XML element and its already-converted child content. */
    private struct Frame {
        /// Local element name used by Android's JDOM converter.
        let name: String
        /// Exact unqualified attributes consumed by semantic element rules.
        let attributes: [String: String]
        /// Text and rendered descendants accumulated in document order.
        var content = ""
    }

    /// Whether existing `BVA` elements emit citation markers.
    private let injectAnchors: Bool
    /// Open elements in document order.
    private var frames: [Frame] = []
    /// Number of completed top-level elements.
    private var rootCount = 0
    /// Parse-integrity flag set by malformed callbacks or illegal top-level text.
    private var malformed = false
    /// Unnormalized rendered root text.
    private var rootText: String?

    /// Whether parsing produced exactly one complete root and no structural error.
    private(set) var completedSuccessfully = false
    /// Android-normalized semantic result after a successful parse.
    private(set) var result = ""

    /** Creates an isolated parser delegate for one selected-content conversion. */
    init(injectAnchors: Bool) {
        self.injectAnchors = injectAnchors
    }

    /** Starts one frame, retaining only the local component of a qualified XML name. */
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        frames.append(Frame(name: Self.localName(qName ?? elementName), attributes: attributeDict))
    }

    /** Appends decoded element text or rejects non-whitespace text outside the root. */
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !frames.isEmpty else {
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                malformed = true
            }
            return
        }
        frames[frames.count - 1].content += string
    }

    /** Appends decoded CDATA as ordinary visible source text. */
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].content += String(decoding: CDATABlock, as: UTF8.self)
    }

    /** Closes one frame and appends its semantic representation to its parent or root result. */
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let frame = frames.popLast(), frame.name == Self.localName(qName ?? elementName) else {
            malformed = true
            return
        }
        let rendered = render(frame)
        if frames.isEmpty {
            rootCount += 1
            rootText = rendered
        } else {
            frames[frames.count - 1].content += rendered
        }
    }

    /** Marks malformed XML so partial output can never be mistaken for a complete conversion. */
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        malformed = true
    }

    /** Finalizes whitespace normalization only for one structurally complete document. */
    func parserDidEndDocument(_ parser: XMLParser) {
        guard !malformed, frames.isEmpty, rootCount == 1, let rootText else { return }
        result = Self.normalized(rootText)
        completedSuccessfully = true
    }

    /** Renders one completed element according to Android `OsisToPlainText.walkElement`. */
    private func render(_ frame: Frame) -> String {
        let name = frame.name
        if name == "milestone" || name == "chapter" || name.hasPrefix("x-") {
            return ""
        }
        if name == "BVA" {
            let marker = injectAnchors ? frame.attributes["ordinal"].map { "[§\($0)] " } ?? "" : ""
            return marker + frame.content
        }
        if name == "reference", let osisRef = frame.attributes["osisRef"] {
            return "[\(frame.content)](\(Self.osisReferenceURL(osisRef)))"
        }

        let opening: String
        switch name {
        case "title": opening = "\n## "
        case "note": opening = " [Footnote: "
        case "transChange": opening = "*"
        case "hi": opening = frame.attributes["type"] == "bold" ? "**" : "*"
        case "verse":
            opening = frame.attributes["osisID"]?.split(separator: ".").last.map { "\($0). " } ?? ""
        case "q": opening = frame.attributes["marker"] ?? ""
        case "l", "lb", "p", "div", "list", "lg", "row": opening = "\n"
        case "item": opening = "\n- "
        default: opening = ""
        }

        let closing: String
        switch name {
        case "title", "p", "div", "list", "lg", "row": closing = "\n"
        case "note": closing = "]"
        case "transChange": closing = "*"
        case "hi": closing = frame.attributes["type"] == "bold" ? "**" : "*"
        case "cell": closing = " "
        default: closing = ""
        }
        return opening + frame.content + closing
    }

    /** Normalizes spaces and blank lines exactly like Android's converter. */
    private static func normalized(_ source: String) -> String {
        source
            .replacingOccurrences(of: #" +\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /** Returns the namespace-local element name while preserving ordinary hyphenated names. */
    private static func localName(_ qualifiedName: String) -> String {
        qualifiedName.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init)
            ?? qualifiedName
    }

    /** Converts an OSIS reference to Android's module-qualified or unqualified `sword://` URL. */
    private static func osisReferenceURL(_ reference: String) -> String {
        if let colon = reference.firstIndex(of: ":"), colon != reference.startIndex {
            let prefix = String(reference[..<colon])
            if prefix.first?.isUppercase == true {
                let key = String(reference[reference.index(after: colon)...])
                return "sword://\(encodeOSISReference(prefix))/\(encodeOSISReference(key))"
            }
        }
        return "sword:///\(encodeOSISReference(reference))"
    }

    /** Percent-encodes OSIS URL components with Android's RFC 3986 allowlist. */
    private static func encodeOSISReference(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || "-._~".unicodeScalars.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    result += String(format: "%%%02X", byte)
                }
            }
        }
        return result
    }
}

/** Bundled Android system-prompt resource loader. */
enum AIReaderSystemPromptLoader {
    enum LoadError: Error, Equatable {
        case resourceMissing(String)
    }

    /** Loads both audited prompt resources from the BibleUI bundle. */
    static func load() throws -> (agent: String, transformation: String) {
        (
            try text(named: "agent-system-prompt"),
            try text(named: "text-transformation-system-prompt")
        )
    }

    /** Reads one UTF-8 Markdown resource without consulting app or user storage. */
    private static func text(named name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md"),
              let value = try? String(contentsOf: url, encoding: .utf8) else {
            throw LoadError.resourceMissing(name)
        }
        return value
    }
}
