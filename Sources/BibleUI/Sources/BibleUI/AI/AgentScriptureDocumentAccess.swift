// AgentScriptureDocumentAccess.swift -- SWORD, SQLite, search, and general-book AI reads

import BibleCore
import Foundation
import SwordKit

/**
 Projects one processed non-Bible document entry into Android's AI-tool content formats.

 The shared SWORD processor assigns the same local `BVA` ordinals used by reader navigation and
 generic bookmarks. Text output exposes those ordinals as `[§N]`, while XML output preserves the
 corresponding `BVA` elements so a model can append `#oN` to the entry's existing `linkUrl`.
 Each instance is immutable and deterministic; processing performs only in-memory XML work.
 */
struct BibleUIAgentAnchoredDocumentContent: Equatable {
    /// Android-compatible text containing one marker for every processed `BVA` ordinal.
    let text: String
    /// Reader-compatible processed OSIS containing the exact anchors represented in `text`.
    let osisXML: String
    /// Inclusive local ordinal domain; Android represents an entry without anchors as `0...0`.
    let contentOrdinalRange: ClosedRange<Int>
    /// Whether the source contained visible text or structural content before anchor insertion.
    let hasRenderableContent: Bool

    /**
     Processes one canonical source fragment and creates aligned text and XML tool projections.

     - Parameters:
       - sourceXML: Canonical OSIS/XML source. Empty and multi-root fragments are accepted.
       - category: Document category controlling Android's commentary-unwrapping behavior.
       - moduleInitials: Exact source initials used by source-specific structural repair.
     - Side effects: Parses and transforms XML in memory only.
     - Throws: Source-processing errors for malformed XML, or a projection error if the generated
       XML cannot be parsed back into Android-compatible semantic text.
     */
    init(
        sourceXML: String,
        category: ModuleCategory,
        moduleInitials: String? = nil
    ) throws {
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: sourceXML,
            category: category,
            moduleInitials: moduleInitials
        )
        try self.init(
            anchoredXML: processed.xml,
            contentOrdinalRange: processed.contentOrdinalRange,
            hasRenderableContent: processed.hasRenderableContent
        )
    }

    /**
     Creates aligned tool projections from an exact SWORD reader fragment.

     - Parameter fragment: Immutable reader fragment already carrying stable local `BVA` ordinals.
     - Side effects: Parses the fragment XML in memory without moving the SWORD module cursor.
     - Throws: A projection error if the processor-produced XML cannot be converted to text.
     */
    init(fragment: SwordRawOSISFragment) throws {
        try self.init(
            anchoredXML: fragment.xml,
            contentOrdinalRange: fragment.contentOrdinalRange,
            hasRenderableContent: fragment.hasRenderableContent
        )
    }

    /**
     Returns the requested Android tool representation without changing its local anchor domain.

     - Parameter format: Text with `[§N]` markers or processed OSIS XML with matching `BVA` nodes.
     - Returns: The immutable representation selected by `format`.
     - Side effects: None.
     - Failure modes: None; construction validates both representations first.
     */
    func value(for format: BibleUIAgentContentFormat) -> String {
        format == .text ? text : osisXML
    }

    /** Builds text and XML views from one processor-validated anchored fragment. */
    private init(
        anchoredXML: String,
        contentOrdinalRange: ClosedRange<Int>,
        hasRenderableContent: Bool
    ) throws {
        guard let text = AIReaderSelectedContentConverter.plainText(
            from: anchoredXML,
            injectAnchors: true
        ) else {
            throw BibleUIAgentAnchoredDocumentContentError.invalidProcessedXML
        }
        self.text = text
        self.osisXML = anchoredXML
        self.contentOrdinalRange = contentOrdinalRange
        self.hasRenderableContent = hasRenderableContent
    }
}

/** Internal invariant failures while projecting processor-owned anchored XML. */
private enum BibleUIAgentAnchoredDocumentContentError: Error {
    /// The shared processor emitted XML that the Android-compatible text parser rejected.
    case invalidProcessedXML
}

/** One local general-book adapter admitted only after global installed ownership is absent. */
enum BibleUIAgentLocalGeneralBookDocument {
    /// Transactional My Documents metadata; page content remains unread until a tool selects it.
    case myDocument(MyDocumentDraft)

    /// Installed EPUB metadata; its immutable reader is opened only for a selected content read.
    case epub(EpubInfo)

    /// Exact Android-visible initials used by window routing and access policy checks.
    var initials: String {
        switch self {
        case .myDocument(let document): return document.initials
        case .epub(let info): return info.initials
        }
    }

    /// User-visible document name used by installed-document and general-book tool results.
    var displayName: String {
        switch self {
        case .myDocument(let document): return SwordJavaStringIdentity.trim(document.name)
        case .epub(let info): return SwordJavaStringIdentity.trim(info.title)
        }
    }

    /// JSword-generated abbreviation after Java config trimming and initials fallback.
    var abbreviation: String {
        switch self {
        case .myDocument(let document): return document.initials
        case .epub(let info):
            return BibleReaderJSwordConfigValue.abbreviation(
                info.title,
                initials: info.initials
            )
        }
    }

    /// Android-visible language of the generated local-book registration.
    var language: String {
        switch self {
        case .myDocument:
            return Locale.current.language.languageCode?.identifier ?? "und"
        case .epub(let info):
            let language = SwordJavaStringIdentity.trim(info.language)
            return language.isEmpty ? "und" : language
        }
    }

    /// Whether Android's generated-book index-status projection reports a completed index.
    var isIndexed: Bool {
        switch self {
        case .myDocument: return false
        case .epub: return true
        }
    }
}

@MainActor
extension BibleUIAgentDomainAdapter {
    func getVerseContent(
        book: String,
        reference: String,
        format: BibleUIAgentContentFormat
    ) throws -> AgentToolResult {
        guard let source = readableInstalledModuleResolver().module(named: book) else {
            throw domainError("BOOK_NOT_FOUND", "Book not found: \(book)")
        }
        try requireDocumentAllowed(source.info.name)
        guard source.info.category == .bible else {
            throw domainError("INVALID_BOOK_TYPE", "Book is not a Bible: \(book)")
        }

        switch source {
        case .sword(let module):
            let keys = module.parseKeyList(reference)
            guard !keys.isEmpty else {
                throw domainError("INVALID_REFERENCE", "The verse reference is invalid.")
            }
            guard keys.count <= BibleUIAgentKJVAReferenceParser.maximumVerses else {
                throw domainError("LIMIT_EXCEEDED", "The requested passage contains too many verses.")
            }
            let entries = keys.map { key in
                module.setKeyAndInspect(
                    key,
                    includeRenderedText: false,
                    includeStrippedText: format == .text
                )
            }
            let content = format == .xml
                ? "<div>\(entries.map(\.rawEntry).joined())</div>"
                : entries.map(\.strippedText).filter { !$0.isEmpty }.joined(separator: "\n")
            return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
                ("book", .string(book)),
                ("verseRef", .string(reference)),
                ("text", format == .text ? .string(try BibleUIAgentJSON.boundedText(content)) : nil),
                ("osisXml", format == .xml ? .string(try BibleUIAgentJSON.boundedText(content)) : nil)
            ))

        case .sqlite(let module):
            let verses = try BibleUIAgentKJVAReferenceParser.parse(reference)
            let values = try verses.compactMap {
                try module.verseContent(
                    osisId: $0.osisBookID,
                    chapter: $0.chapter,
                    verse: $0.verse
                )?.text
            }
            let content = format == .xml
                ? "<div>\(values.joined())</div>"
                : values.map(BibleUIAgentJSON.plainText).joined(separator: "\n")
            return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
                ("book", .string(book)),
                ("verseRef", .string(reference)),
                ("text", format == .text ? .string(try BibleUIAgentJSON.boundedText(content)) : nil),
                ("osisXml", format == .xml ? .string(try BibleUIAgentJSON.boundedText(content)) : nil)
            ))
        }
    }

    /**
     Searches readable, allowed Bibles through their exact installed source generations.

     - Parameters:
       - query: Android/Lucene-compatible query text.
       - books: Optional installed-book tokens; an empty list selects the first ready Bible in
         Android's installed `BookSet` order.
       - maximum: Maximum hits returned after cross-module collection.
       - offset: Number of ordered hits skipped before paging.
     - Returns: Android-shaped result metadata and canonical verse identities.
     - Side effects: Captures one fresh readable registry and performs read-only generated-index queries.
     - Throws: Stable domain errors when no exact current source is indexed, plus query/index failures.
     */
    func searchBible(
        query: String,
        books: [String],
        maximum: Int,
        offset: Int
    ) throws -> AgentToolResult {
        let resolver = readableInstalledModuleResolver()
        let selected: [SearchIndexSourceIdentity]
        if books.isEmpty {
            guard let first = resolver.readableModulesInBookSetOrder(categories: [.bible]).compactMap({
                $0.searchIndexSource
            }).first(where: {
                let info = $0.searchIndexModuleInfo
                return documentAccessPolicy.allows(documentInitials: info.name)
                    && searchIndexService.hasIndex(for: $0.searchIndexSourceIdentity)
            }) else {
                throw domainError("NO_INDEX", "No indexed Bible found. Please index a Bible first.")
            }
            selected = [first.searchIndexSourceIdentity]
        } else {
            selected = books.compactMap { initials in
                guard let source = resolver.searchIndexSource(named: initials) else {
                    return nil
                }
                let canonicalInitials = source.searchIndexModuleInfo.name
                let sourceIdentity = source.searchIndexSourceIdentity
                guard documentAccessPolicy.allows(documentInitials: canonicalInitials),
                      searchIndexService.hasIndex(for: sourceIdentity) else {
                    return nil
                }
                return sourceIdentity
            }
            guard !selected.isEmpty else {
                throw domainError(
                    "NOT_INDEXED",
                    "The requested Bibles were not found or are not indexed."
                )
            }
        }

        var allHits: [SearchModuleHit] = []
        for sourceIdentity in selected {
            let result = try searchIndexService.search(
                query: query,
                sourceIdentity: sourceIdentity,
                wordMode: .anyWord
            )
            allHits.append(contentsOf: result.hits)
        }
        let page = Array(allHits.dropFirst(min(offset, allHits.count)).prefix(maximum))
        let values = page.map { hit in
            BibleUIAgentJSON.object(
                ("book", .string(hit.moduleName)),
                ("verseRef", .string(osisReference(hit.identity))),
                ("verseName", .string(hit.key))
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("query", .string(query)),
            ("totalResults", BibleUIAgentJSON.integer(allHits.count)),
            ("returnedResults", BibleUIAgentJSON.integer(values.count)),
            ("offset", BibleUIAgentJSON.integer(offset)),
            ("hasMore", .bool(offset + values.count < allHits.count)),
            ("results", .array(values))
        ))
    }

    /**
     Searches one readable Strong's Bible only through its exact installed index generation.

     - Parameters:
       - reportedNumber: User-facing Strong's number preserved in the response.
       - canonicalToken: Normalized token used by the lexical index.
       - book: Optional installed-book token; nil selects the first exact ready Strong's source in
         Android's installed `BookSet` order.
       - maximum: Maximum hits returned after paging.
       - offset: Number of ordered hits skipped before paging.
     - Returns: Android-shaped Strong's metadata and canonical verse identities.
     - Side effects: Captures one fresh readable registry and performs a read-only lexical query.
     - Throws: Stable category, feature, and readiness errors plus generated-index failures.
     */
    func searchByStrongs(
        reportedNumber: String,
        canonicalToken: String,
        book: String?,
        maximum: Int,
        offset: Int
    ) throws -> AgentToolResult {
        let resolver = readableInstalledModuleResolver()
        let selectedSource: any BibleSearchIndexSource
        if let book {
            guard let source = resolver.searchIndexSource(named: book) else {
                throw domainError("NO_STRONGS_BIBLE", "No Bible with Strong's numbers was found.")
            }
            try requireDocumentAllowed(source.searchIndexModuleInfo.name)
            selectedSource = source
        } else {
            let eligible = resolver.readableModulesInBookSetOrder(categories: [.bible]).compactMap {
                $0.searchIndexSource
            }.filter {
                let info = $0.searchIndexModuleInfo
                return info.features.contains(.strongsNumbers)
                    && documentAccessPolicy.allows(documentInitials: info.name)
            }
            guard let source = eligible.first(where: {
                searchIndexService.hasStrongsIndex(for: $0.searchIndexSourceIdentity)
            }) ?? eligible.first else {
                throw domainError("NO_STRONGS_BIBLE", "No Bible with Strong's numbers was found.")
            }
            selectedSource = source
        }
        let moduleInfo = selectedSource.searchIndexModuleInfo
        let sourceIdentity = selectedSource.searchIndexSourceIdentity
        guard moduleInfo.features.contains(.strongsNumbers) else {
            throw domainError(
                "NO_STRONGS",
                "Bible '\(moduleInfo.name)' does not contain Strong's numbers."
            )
        }
        guard searchIndexService.hasStrongsIndex(for: sourceIdentity) else {
            throw domainError(
                "NOT_INDEXED",
                "Bible '\(moduleInfo.name)' is not indexed for Strong's search."
            )
        }

        let allHits = try searchIndexService.searchStrongs(
            canonicalTokens: [canonicalToken],
            sourceIdentity: sourceIdentity
        ).hits
        let page = Array(allHits.dropFirst(min(offset, allHits.count)).prefix(maximum))
        let values = page.map { hit in
            BibleUIAgentJSON.object(
                ("verseRef", .string(osisReference(hit.identity))),
                ("verseName", .string(hit.key))
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("strongsNumber", .string(reportedNumber)),
            ("searchedBook", .string(moduleInfo.name)),
            ("totalResults", BibleUIAgentJSON.integer(allHits.count)),
            ("returnedResults", BibleUIAgentJSON.integer(values.count)),
            ("offset", BibleUIAgentJSON.integer(offset)),
            ("hasMore", .bool(offset + values.count < allHits.count)),
            ("results", .array(values))
        ))
    }

    /**
     Reads and deduplicates installed commentary entries using Android's local passage anchors.

     - Parameters:
       - reference: OSIS verse or verse range expanded against each commentary's versification.
       - requestedInitials: Optional installed commentary initials; an empty list selects all
         allowed commentaries.
       - format: Text with `[§N]` markers or processed OSIS XML with matching `BVA` ordinals.
     - Returns: Android-shaped commentary metadata and consecutive content blocks. Every marker is
       local to the block's `linkUrl`, allowing a follow-up `#oN` or `#oN-M` navigation fragment.
     - Side effects: Reads installed SWORD or SQLite commentary content; no cursor or store state is
       retained after the call.
     - Throws: Stable domain errors when no commentary is available or the requested range exceeds
       the tool limit. Missing, empty, or malformed individual entries are omitted like Android.
     */
    func getCommentaries(
        reference: String,
        requestedInitials: [String],
        format: BibleUIAgentContentFormat
    ) throws -> AgentToolResult {
        let resolver = readableInstalledModuleResolver()
        let candidates = commentaryInitials(
            requested: requestedInitials,
            resolver: resolver
        )
        guard !candidates.isEmpty else {
            throw domainError("NO_COMMENTARIES", "No commentaries available")
        }

        var results: [JSONValue] = []
        for initials in candidates {
            let rendered: [(reference: String, content: String?)]
            let info: ModuleInfo
            guard let source = resolver.module(named: initials) else { continue }
            switch source {
            case .sword(let module):
                info = module.info
                let keys = module.parseKeyList(reference)
                guard keys.count <= BibleUIAgentKJVAReferenceParser.maximumVerses else {
                    throw domainError(
                        "LIMIT_EXCEEDED",
                        "The requested passage contains too many verses."
                    )
                }
                rendered = keys.map { key in
                    guard let fragment = try? module.rawOSISFragment(forKey: key),
                          let content = try? BibleUIAgentAnchoredDocumentContent(
                              fragment: fragment
                          ),
                          content.hasRenderableContent else {
                        return (key, nil)
                    }
                    return (fragment.osisRef, content.value(for: format))
                }
            case .sqlite(let module):
                info = module.info
                let verses = try BibleUIAgentKJVAReferenceParser.parse(reference)
                rendered = try verses.map { verse in
                    guard let source = try module.verseContent(
                        osisId: verse.osisBookID,
                        chapter: verse.chapter,
                        verse: verse.verse
                    )?.text else {
                        return (verse.osisReference, nil)
                    }
                    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let content = try? BibleUIAgentAnchoredDocumentContent(
                              sourceXML: "<div>\(trimmed)</div>",
                              category: .commentary,
                              moduleInitials: initials
                          ),
                          content.hasRenderableContent else {
                        return (verse.osisReference, nil)
                    }
                    return (verse.osisReference, content.value(for: format))
                }
            }

            let blocks = deduplicatedCommentaryBlocks(rendered)
            guard !blocks.isEmpty else { continue }
            let entries = blocks.map { block in
                let range = block.start == block.end ? block.start : "\(block.start)-\(block.end)"
                return BibleUIAgentJSON.object(
                    ("verseRange", .string(range)),
                    ("linkUrl", .string(BibleUIAgentJSON.swordURL(
                        initials: initials,
                        key: block.start
                    ))),
                    ("text", format == .text ? .string(block.content) : nil),
                    ("osisXml", format == .xml ? .string(block.content) : nil)
                )
            }
            results.append(BibleUIAgentJSON.object(
                ("initials", .string(initials)),
                ("name", .string(info.description)),
                ("abbreviation", .string(info.name)),
                ("entries", .array(entries))
            ))
        }

        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("verseRef", .string(reference)),
            ("commentaryCount", BibleUIAgentJSON.integer(results.count)),
            ("commentaries", .array(results)),
            ("note", nil)
        ))
    }

    func getDictionaryEntry(
        dictionary: String,
        key: String,
        format: BibleUIAgentContentFormat
    ) throws -> AgentToolResult {
        guard let source = readableInstalledModuleResolver().module(named: dictionary) else {
            throw domainError("DICT_NOT_FOUND", "Dictionary not found: \(dictionary)")
        }
        try requireDocumentAllowed(source.info.name)
        guard source.info.category == .dictionary else {
            throw domainError("INVALID_BOOK_TYPE", "Book is not a dictionary: \(dictionary)")
        }
        let info: ModuleInfo
        let resolvedContent: String
        let isStrongs: Bool
        switch source {
        case .sword(let module):
            info = module.info
            isStrongs = info.features.contains(.greekDef) || info.features.contains(.hebrewDef)
            guard let resolvedKey = try exactDictionaryKey(key, module: module) else {
                throw domainError("KEY_NOT_FOUND", "Key not found in dictionary.")
            }
            let entry = module.setKeyAndInspect(
                resolvedKey,
                includeRenderedText: false,
                includeStrippedText: format == .text
            )
            resolvedContent = format == .xml ? entry.rawEntry : entry.strippedText
        case .sqlite(let module):
            info = module.info
            isStrongs = info.features.contains(.greekDef) || info.features.contains(.hebrewDef)
            guard let content = try module.dictionaryContent(for: key)?.text else {
                throw domainError("KEY_NOT_FOUND", "Key not found in dictionary.")
            }
            resolvedContent = format == .xml ? content : BibleUIAgentJSON.plainText(content)
        }

        let linkURL = isStrongs
            ? "strongs://\(BibleUIAgentJSON.encodedPathComponent(key))"
            : BibleUIAgentJSON.swordURL(initials: dictionary, key: key)
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("dictionary", .string(dictionary)),
            ("dictionaryName", .string(info.description)),
            ("key", .string(key)),
            ("linkUrl", .string(linkURL)),
            ("text", format == .text ? .string(try BibleUIAgentJSON.boundedText(resolvedContent)) : nil),
            ("osisXml", format == .xml ? .string(try BibleUIAgentJSON.boundedText(resolvedContent)) : nil)
        ))
    }

    /**
     Lists Android's globally admitted installed-book registry with current Search readiness.

     - Parameter category: Optional Android document-category filter.
     - Returns: Native, SQLite, EPUB, and My Documents metadata in JSword TreeSet order after
       Android's EPUB-then-My Documents initials-admission preflight.
     - Side effects: Captures one fresh readable registry and reads index/local-book metadata only;
       no local document entry is opened.
     - Throws: Persistence or result-bound failures.
     */
    func getInstalledDocuments(
        category: BibleUIAgentDocumentCategory?
    ) throws -> AgentToolResult {
        let resolver = readableInstalledModuleResolver()
        let session = try myDocumentLibraryStore.loadSession()
        let localRegistrations = localGeneralBookRegistrations(
            documents: session.documents,
            epubs: EpubReader.installedEpubs()
        )
        var values: [JSONValue] = []
        for owner in resolver.registeredDocumentOwners(localRegistrations: localRegistrations) {
            switch owner {
            case .installed(let info, _):
                guard documentAccessPolicy.allows(documentInitials: info.name),
                      category.map({ moduleCategory(info.category) == $0 }) != false else {
                    continue
                }
                values.append(installedDocumentJSON(info, resolver: resolver))
            case .local(let document):
                guard category == nil || category == .generalBook,
                      documentAccessPolicy.allows(documentInitials: document.initials) else {
                    continue
                }
                values.append(installedLocalDocumentJSON(document))
            case .missing:
                continue
            }
            guard values.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
                throw domainError("LIMIT_EXCEEDED", "Too many installed documents were returned.")
            }
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("documentCount", BibleUIAgentJSON.integer(values.count)),
            ("documents", .array(values))
        ))
    }

    /**
     Lists one general book only after Android's global installed-book owner has been selected.

     - Parameters:
       - book: Installed or local initials/full-name/case alias resolved through global JSword tiers.
       - offset: Number of ordered navigation keys to skip.
       - limit: Maximum number of keys returned by the validated tool request.
     - Returns: Android's general-book key result for the canonical installed or local owner.
     - Side effects: Captures installed/local metadata, then reads only the selected owner's key list.
     - Throws: Access, ownership, lock, category, persistence, EPUB-open, and result-bound failures.
     - Important: A readable or locked installed owner suppresses every colliding local source before
       local page, EPUB TOC, or content access occurs.
     */
    func getGenBookKeys(book: String, offset: Int, limit: Int) throws -> AgentToolResult {
        switch try installedOrLocalGeneralBook(named: book) {
        case .local(.myDocument(let document)):
            let keys = document.pages.sorted(by: pageOrder)
            let clampedOffset = min(offset, keys.count)
            let page = Array(keys.dropFirst(clampedOffset).prefix(limit))
            return try genBookKeysResult(
                book: document.initials,
                name: SwordJavaStringIdentity.trim(document.name),
                allCount: keys.count,
                offset: clampedOffset,
                keys: page.map { ($0.title, $0.pageKey) }
            )

        case .local(.epub(let info)):
            guard let reader = EpubReader(identifier: info.identifier) else {
                throw domainError("READ_ERROR", "Failed to open EPUB: \(info.initials)")
            }
            let keys = reader.tableOfContents()
            let clampedOffset = min(offset, keys.count)
            let page = Array(keys.dropFirst(clampedOffset).prefix(limit))
            return try genBookKeysResult(
                book: info.initials,
                name: SwordJavaStringIdentity.trim(info.title),
                allCount: keys.count,
                offset: clampedOffset,
                keys: page.map { ($0.title, $0.key) }
            )

        case .installed(let info, let readableSource):
            guard let readableSource, case .sword(let module) = readableSource else {
                throw domainError("BOOK_NOT_FOUND", "Book not found: \(book)")
            }
            guard info.category == .generalBook else {
                throw domainError("INVALID_BOOK_TYPE", "Book is not a general book: \(book)")
            }
            let keys = try module.loadAllKeys().filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let clampedOffset = min(offset, keys.count)
            let page = Array(keys.dropFirst(clampedOffset).prefix(limit))
            return try genBookKeysResult(
                book: info.name,
                name: info.description,
                allCount: keys.count,
                offset: clampedOffset,
                keys: page.map { ($0, $0) }
            )

        case .missing:
            throw domainError("BOOK_NOT_FOUND", "Book not found: \(book)")
        }
    }

    /**
     Reads one exact general-book entry with Android-compatible local passage anchors.

     - Parameters:
       - book: Allowed installed SWORD, My Documents, or EPUB general-book identity.
       - key: Exact page or module key returned by `getGenBookKeys`.
       - format: Text with `[§N]` markers or processed OSIS XML with matching `BVA` ordinals.
     - Returns: Android's general-book result shape. Anchor ordinals are entry-local and align with
       the unchanged `linkUrl`, making `#oN` and `#oN-M` follow-up navigation stable.
     - Side effects: Resolves global ownership before reading one selected My Documents, EPUB, or
       SWORD entry. SWORD cursor movement is restored by `rawOSISFragment` before return.
     - Throws: Stable document/key/category errors, or `READ_ERROR` when source XML cannot be
       processed without returning misleading unanchored content. Empty exact entries remain valid.
     */
    func getGenBookContent(
        book: String,
        key: String,
        format: BibleUIAgentContentFormat
    ) throws -> AgentToolResult {
        switch try installedOrLocalGeneralBook(named: book) {
        case .local(.myDocument(let document)):
            guard let page = document.pages.first(where: { $0.pageKey == key }) else {
                throw domainError("KEY_NOT_FOUND", "Key not found: \(key)")
            }
            let rendered = MyDocumentContentRenderer.render(page.content, contentType: page.contentType)
            let content: BibleUIAgentAnchoredDocumentContent
            do {
                content = try BibleUIAgentAnchoredDocumentContent(
                    sourceXML: rendered,
                    category: .generalBook,
                    moduleInitials: document.initials
                )
            } catch {
                throw domainError("READ_ERROR", "Failed to read content: \(error.localizedDescription)")
            }
            return try genBookContentResult(
                book: document.initials,
                name: SwordJavaStringIdentity.trim(document.name),
                key: key,
                keyName: page.title,
                content: content.value(for: format),
                format: format
            )

        case .local(.epub(let info)):
            guard let reader = EpubReader(identifier: info.identifier) else {
                throw domainError("READ_ERROR", "Failed to open EPUB: \(info.initials)")
            }
            guard let entry = reader.content(forKey: key) else {
                throw domainError("KEY_NOT_FOUND", "Key not found: \(key)")
            }
            let projectedContent: String
            if format == .xml {
                projectedContent = entry.html
            } else if let text = AIReaderSelectedContentConverter.plainText(
                from: entry.html,
                injectAnchors: true
            ) {
                projectedContent = text
            } else {
                throw domainError("READ_ERROR", "Failed to read content: \(key)")
            }
            return try genBookContentResult(
                book: info.initials,
                name: SwordJavaStringIdentity.trim(info.title),
                key: key,
                keyName: entry.title,
                content: projectedContent,
                format: format
            )

        case .installed(let info, let readableSource):
            guard let readableSource, case .sword(let module) = readableSource else {
                throw domainError("BOOK_NOT_FOUND", "Book not found: \(book)")
            }
            guard info.category == .generalBook else {
                throw domainError("INVALID_BOOK_TYPE", "Book is not a general book: \(book)")
            }
            guard try module.containsExactKey(key) else {
                throw domainError("KEY_NOT_FOUND", "Key not found: \(key)")
            }
            let fragment: SwordRawOSISFragment
            let content: BibleUIAgentAnchoredDocumentContent
            do {
                fragment = try module.rawOSISFragment(forKey: key)
                content = try BibleUIAgentAnchoredDocumentContent(fragment: fragment)
            } catch {
                throw domainError("READ_ERROR", "Failed to read content: \(error.localizedDescription)")
            }
            return try genBookContentResult(
                book: info.name,
                name: info.description,
                key: key,
                keyName: fragment.keyName,
                content: content.value(for: format),
                format: format
            )

        case .missing:
            throw domainError("BOOK_NOT_FOUND", "Book not found: \(book)")
        }
    }

    /**
     Captures one fresh readable installed-module registry for a single AI tool operation.

     - Returns: SWORD-first global ownership with authorized native and SQLite content handles.
     - Side effects: Enumerates native access state once and wraps the existing SQLite snapshot.
     - Failure modes: Locked native owners remain registered but expose no content and never fall
       through to a colliding SQLite module.
     */
    func readableInstalledModuleResolver() -> BibleReaderInstalledModuleResolver {
        BibleReaderInstalledModuleResolver(
            swordManager: swordManager,
            sqliteLibrary: sqliteLibrary
        )
    }

    /**
     Resolves installed ownership before lazily evaluating My Documents and EPUB metadata.

     - Parameter name: Installed/local initials or full-name token at any JSword exact/case tier.
     - Returns: Inclusive installed owner, the admitted canonical local owner, or missing.
     - Side effects: Captures installed metadata first. Only when globally unowned does it load one
       transactional My Documents snapshot and the installed EPUB metadata list; no page, TOC, or
       content entry is read.
     - Throws: My Documents snapshot failures when no other source can satisfy the local lookup, or
       the document exclusion error for the canonical selected identity.
     - Important: Locked installed ownership is returned without a content handle and never falls
       through to a colliding local source.
     */
    func installedOrLocalGeneralBook(
        named name: String
    ) throws -> BibleReaderInstalledOrLocalDocumentOwner<BibleUIAgentLocalGeneralBookDocument> {
        let resolver = readableInstalledModuleResolver()
        var localMetadataError: Error?
        let owner = resolver.resolveDocumentOwner(named: name, localRegistrations: {
            var documents: [MyDocumentDraft] = []
            do {
                documents = try myDocumentLibraryStore.loadSession().documents
            } catch {
                localMetadataError = error
            }
            return localGeneralBookRegistrations(
                documents: documents,
                epubs: EpubReader.installedEpubs()
            )
        })

        switch owner {
        case .installed(let info, _):
            try requireDocumentAllowed(info.name)
        case .local(let local):
            try requireDocumentAllowed(local.initials)
        case .missing where localMetadataError != nil:
            throw domainError("READ_ERROR", "Failed to read local document metadata.")
        case .missing:
            break
        }
        return owner
    }

    /**
     Builds Android's EPUB-then-My Documents custom-book registration sequence.

     - Parameters:
       - documents: Transactional My Documents metadata in database registration order.
       - epubs: Valid EPUB metadata in the order returned by the library scanner.
     - Returns: Metadata-only local registrations with Android full-name, abbreviation, and category.
     - Side effects: None; supplied values are projected without opening pages or EPUB fragments.
     - Failure modes: None. The shared resolver applies candidate admission and TreeSet replacement.
     */
    func localGeneralBookRegistrations(
        documents: [MyDocumentDraft],
        epubs: [EpubInfo]
    ) -> [BibleReaderLocalDocumentRegistration<BibleUIAgentLocalGeneralBookDocument>] {
        epubs.map { info in
            BibleReaderLocalDocumentRegistration(
                document: .epub(info),
                initials: info.initials,
                fullName: info.title,
                abbreviation: info.title,
                category: .generalBook
            )
        } + documents.map { document in
            BibleReaderLocalDocumentRegistration(
                document: .myDocument(document),
                initials: document.initials,
                fullName: document.name,
                abbreviation: document.initials,
                category: .generalBook
            )
        }
    }

    /** Projects one unshadowed My Documents or EPUB row into Android's installed-book shape. */
    private func installedLocalDocumentJSON(
        _ document: BibleUIAgentLocalGeneralBookDocument
    ) -> JSONValue {
        return BibleUIAgentJSON.object(
            ("initials", .string(document.initials)),
            ("name", .string(document.displayName)),
            ("category", .string(BibleUIAgentDocumentCategory.generalBook.rawValue)),
            ("language", .string(document.language)),
            ("isLocked", .bool(false)),
            ("isIndexed", .bool(document.isIndexed)),
            ("abbreviation", .string(document.abbreviation)),
            ("hasStrongsNumbers", nil)
        )
    }

    private func requireDocumentAllowed(_ initials: String) throws {
        guard documentAccessPolicy.allows(documentInitials: initials) else {
            throw domainError(
                "DOCUMENT_EXCLUDED",
                "Document excluded by user settings: \(initials)"
            )
        }
    }

    private func commentaryInitials(
        requested: [String],
        resolver: BibleReaderInstalledModuleResolver
    ) -> [String] {
        let source: [String]
        if requested.isEmpty {
            source = resolver.readableModulesInBookSetOrder(categories: [.commentary]).map(\.info.name)
        } else {
            source = requested.compactMap { initials in
                guard let module = resolver.module(named: initials),
                      module.info.category == .commentary else {
                    return nil
                }
                return module.info.name
            }
        }
        return source.filter(documentAccessPolicy.allows(documentInitials:))
    }

    private struct CommentaryBlock {
        let start: String
        var end: String
        let content: String
    }

    private func deduplicatedCommentaryBlocks(
        _ values: [(reference: String, content: String?)]
    ) -> [CommentaryBlock] {
        var result: [CommentaryBlock] = []
        var current: CommentaryBlock?
        for value in values {
            guard let content = value.content else {
                if let current { result.append(current) }
                current = nil
                continue
            }
            if current?.content == content {
                current?.end = value.reference
            } else {
                if let current { result.append(current) }
                current = CommentaryBlock(
                    start: value.reference,
                    end: value.reference,
                    content: content
                )
            }
        }
        if let current { result.append(current) }
        return result
    }

    private func exactDictionaryKey(_ supplied: String, module: SwordModule) throws -> String? {
        if try module.containsExactKey(supplied) { return supplied }
        let isGreek = module.info.features.contains(.greekDef)
        let isHebrew = module.info.features.contains(.hebrewDef)
        guard isGreek || isHebrew else { return nil }
        let prefix = isGreek ? "G" : "H"
        let digits = supplied.uppercased().hasPrefix(prefix)
            ? String(supplied.dropFirst())
            : supplied
        for candidate in ["\(prefix)\(digits)", digits] where try module.containsExactKey(candidate) {
            return candidate
        }
        return nil
    }

    /**
     Maps installed JSword categories into the agent document-category vocabulary.

     - Parameter category: Actual installed-book category.
     - Returns: Agent-facing category, or nil for add-on/unknown sources the document tool cannot
       read. Questionable, Essays, and Images retain Android's generic-book navigation surface.
     - Side effects: None.
     - Failure modes: None; every known module category is handled explicitly.
     */
    private func moduleCategory(_ category: ModuleCategory) -> BibleUIAgentDocumentCategory? {
        switch category {
        case .bible: return .bible
        case .commentary: return .commentary
        case .dictionary, .glossary: return .dictionary
        case .generalBook, .dailyDevotion, .questionable, .essays, .images:
            return .generalBook
        case .map: return .maps
        case .addon, .unknown: return nil
        }
    }

    private func androidCategoryName(_ category: ModuleCategory) -> String {
        moduleCategory(category)?.rawValue ?? "OTHER"
    }

    /**
     Projects one installed metadata row with generation-specific Search readiness.

     - Parameters:
       - info: Inclusive installed metadata retained for management and lock presentation.
       - resolver: Operation-owned readable registry enforcing native collision precedence.
     - Returns: Android-shaped document metadata; `isIndexed` is true only when this exact readable
       Bible generation owns current completion metadata.
     - Side effects: Performs one read-only index-readiness query for a resolved Bible.
     - Failure modes: Locked, shadowed, wrong-category, stale, and mismatched sources report false.
     */
    private func installedDocumentJSON(
        _ info: ModuleInfo,
        resolver: BibleReaderInstalledModuleResolver
    ) -> JSONValue {
        let sourceIdentity = info.category == .bible
            ? resolver.searchIndexSource(named: info.name)?.searchIndexSourceIdentity
            : nil
        let isIndexed = sourceIdentity.map {
            $0.moduleName.utf16.elementsEqual(info.name.utf16)
                && searchIndexService.hasIndex(for: $0)
        } ?? false
        return BibleUIAgentJSON.object(
            ("initials", .string(info.name)),
            ("name", .string(info.description)),
            ("category", .string(androidCategoryName(info.category))),
            ("language", .string(info.language.isEmpty ? "unknown" : info.language)),
            ("isLocked", .bool(info.isEncrypted && !info.isUnlocked)),
            ("isIndexed", .bool(isIndexed)),
            ("abbreviation", .string(info.name)),
            ("hasStrongsNumbers", info.category == .bible
                ? .bool(info.features.contains(.strongsNumbers))
                : nil)
        )
    }

    private func genBookKeysResult(
        book: String,
        name: String,
        allCount: Int,
        offset: Int,
        keys: [(name: String, reference: String)]
    ) throws -> AgentToolResult {
        let values = keys.map { key in
            BibleUIAgentJSON.object(
                ("name", .string(key.name)),
                ("osisRef", .string(key.reference)),
                ("linkUrl", .string(BibleUIAgentJSON.swordURL(
                    initials: book,
                    key: key.reference
                )))
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("book", .string(book)),
            ("bookName", .string(name)),
            ("totalCount", BibleUIAgentJSON.integer(allCount)),
            ("offset", BibleUIAgentJSON.integer(offset)),
            ("returnedCount", BibleUIAgentJSON.integer(values.count)),
            ("hasMore", .bool(offset + values.count < allCount)),
            ("keys", .array(values))
        ))
    }

    private func genBookContentResult(
        book: String,
        name: String,
        key: String,
        keyName: String,
        content: String,
        format: BibleUIAgentContentFormat
    ) throws -> AgentToolResult {
        let bounded = try BibleUIAgentJSON.boundedText(content)
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("book", .string(book)),
            ("bookName", .string(name)),
            ("key", .string(key)),
            ("keyName", .string(keyName)),
            ("linkUrl", .string(BibleUIAgentJSON.swordURL(initials: book, key: key))),
            ("text", format == .text ? .string(bounded) : nil),
            ("osisXml", format == .xml ? .string(bounded) : nil)
        ))
    }

    private func osisReference(_ identity: SearchVerseIdentity) -> String {
        "\(identity.osisBookId).\(identity.chapter).\(identity.verse)"
    }

    private func pageOrder(_ lhs: MyDocumentPageDraft, _ rhs: MyDocumentPageDraft) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func domainError(_ code: String, _ message: String) -> BibleUIAgentDomainError {
        BibleUIAgentDomainError(code: code, message: message)
    }
}
