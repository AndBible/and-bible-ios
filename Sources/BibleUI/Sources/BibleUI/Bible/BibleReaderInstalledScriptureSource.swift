// BibleReaderInstalledScriptureSource.swift -- Exact reads across installed Bible backends

import BibleCore
import Foundation
import SwordKit

/** One addressable verse captured from an installed Bible's own source domain. */
struct BibleReaderInstalledScriptureVerse: Equatable, Sendable {
    /// Exact source-versification identity and ordinal.
    let reference: VerseKeyReference

    /// Source-safe OSIS fragment content without an invented verse wrapper.
    let sourceXML: String

    /// Canonical visible text produced by the source backend.
    let plainText: String
}

/** One bounded, exact passage captured without retaining a mutable backend cursor. */
struct BibleReaderInstalledScripturePassage: Equatable, Sendable {
    /// Addressable source verses in ordinal order; introduction and empty slots are omitted.
    let verses: [BibleReaderInstalledScriptureVerse]

    /// Inclusive source ordinal requested by the caller.
    let sourceOrdinalRange: ClosedRange<Int>

    /// Source-versification OSIS identity for the validated endpoints.
    let sourceOSISRange: String

    /// Canonical visible passage text in source order.
    let plainText: String
}

/** Fail-closed validation errors for backend-neutral installed-Bible reads. */
enum BibleReaderInstalledScriptureSourceError: Error, Equatable, Sendable {
    /// Endpoints are non-positive, reversed, or paired with an invalid work limit.
    case invalidRange

    /// The inclusive ordinal span exceeds the caller's explicit work bound.
    case rangeTooLarge(maximumCount: Int)

    /// One endpoint does not identify a concrete verse in the source's versification.
    case nonAddressableEndpoint(Int)
}

/**
 Resolves Android's globally installed Bible abstraction across SWORD and custom SQLite books.

 Android registers MyBible, MySword, and e-Sword books in the same `Books.installed()` registry as
 ordinary SWORD modules. Reader actions must therefore resolve the bridge-supplied initials first,
 then read the selected backend's own ordinal domain. This value centralizes that boundary so
 Search, Compare, links, copy/share, speech, and transient documents do not each invent a fallback.

 SWORD reads use cursor-restoring source inspection. SQLite reads use immutable module handles with
 operation-owned read-only connections. No method substitutes the active pane, another module, or
 static placeholder content after a source has been selected.
 */
enum BibleReaderInstalledScriptureSource: @unchecked Sendable {
    /// Native SWORD Bible and its declared versification.
    case sword(SwordModule)

    /// Android-compatible MyBible, MySword, or e-Sword Bible in exact KJVA coordinates.
    case sqlite(BibleReaderSQLiteModuleHandle)

    /// Installed-module metadata used by global identity and picker contracts.
    var info: ModuleInfo {
        switch self {
        case .sword(let module):
            return module.info
        case .sqlite(let module):
            return module.info
        }
    }

    /// Source versification that owns all ordinals accepted and returned by this value.
    var versificationName: String {
        switch self {
        case .sword(let module):
            return VersificationMapper.versificationName(for: module)
        case .sqlite:
            return JSwordKJVAVersification.name
        }
    }

    /// User-visible abbreviation used by Android's document and sharing surfaces.
    var abbreviation: String {
        switch self {
        case .sword(let module):
            return BibleReaderStrongsDocumentBuilder.moduleDisplayLabel(module)
        case .sqlite(let module):
            let value = module.metadata.abbreviation.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return value.isEmpty ? module.info.name : value
        }
    }

    /**
     Returns the real-key-derived source book list.

     - Returns: Source books in canonical reader order.
     - Side effects: SWORD reads module metadata; SQLite enumerates real navigation keys.
     - Throws: Re-throws SQLite enumeration failures. SWORD metadata access does not throw.
     */
    func bookList() throws -> [BookInfo] {
        switch self {
        case .sword(let module):
            return module.getBookList()
        case .sqlite(let module):
            return try module.bookList()
        }
    }

    /**
     Resolves one exact source coordinate into its own intro-inclusive ordinal domain.

     - Parameters describe a concrete one-based verse.
     - Returns: Exact source ordinal, or `nil` when the source cannot address the coordinate.
     - Side effects: SWORD temporarily inspects and restores its cursor; SQLite uses static KJVA.
     - Failure modes: Invalid and unsupported coordinates return `nil` without normalization.
     */
    func verseOrdinal(osisBookId: String, chapter: Int, verse: Int) -> Int? {
        switch self {
        case .sword(let module):
            return module.verseOrdinal(
                osisBookId: osisBookId,
                chapter: chapter,
                verse: verse
            )
        case .sqlite:
            return JSwordKJVAVersification.verseOrdinal(
                osisId: osisBookId,
                chapter: chapter,
                verse: verse
            )
        }
    }

    /**
     Resolves one exact source ordinal into a concrete verse.

     - Parameter ordinal: Intro-inclusive ordinal owned by `versificationName`.
     - Returns: Concrete positive-verse reference, or `nil` for introductions and invalid values.
     - Side effects: SWORD temporarily inspects and restores its cursor; SQLite uses static KJVA.
     - Failure modes: No nearest-verse or cross-backend fallback is performed.
     */
    func verseReference(ordinal: Int) -> VerseKeyReference? {
        switch self {
        case .sword(let module):
            return module.verseReference(ordinal: ordinal)
        case .sqlite:
            guard let reference = JSwordKJVAVersification.verseReference(ordinal: ordinal) else {
                return nil
            }
            return VerseKeyReference(
                osisBookId: reference.osisId,
                chapter: reference.chapter,
                verse: reference.verse,
                ordinal: reference.ordinal
            )
        }
    }

    /**
     Converts one source coordinate authoritatively into this installed Bible's ordinal domain.

     - Parameters:
       - osisBookId: Canonical source OSIS book identifier.
       - chapter: One-based source chapter.
       - verse: One-based source verse.
       - sourceVersification: Named versification owning the supplied coordinate.
     - Returns: Exact target-owned reference after forward and reverse identity checks.
     - Side effects: SWORD may perform cursor-restoring ordinal lookup; SQLite uses static KJVA.
     - Failure modes: Unsupported conversion, absent target content address, or any identity mismatch
       returns nil without nearest-verse fallback.
     */
    func mappedReference(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        from sourceVersification: String
    ) -> VerseKeyReference? {
        guard let mapped = VersificationMapper.convertStrictly(
                  osisBookId: osisBookId,
                  chapter: chapter,
                  verse: verse,
                  from: sourceVersification,
                  to: versificationName
              )?.reference,
              let ordinal = verseOrdinal(
                  osisBookId: mapped.osisBookId,
                  chapter: mapped.chapter,
                  verse: mapped.verse
              ),
              let reference = verseReference(ordinal: ordinal),
              reference.osisBookId == mapped.osisBookId,
              reference.chapter == mapped.chapter,
              reference.verse == mapped.verse else {
            return nil
        }
        return reference
    }

    /**
     Formats an exact source range with Android's locale-sensitive JSword book names.

     - Parameters:
       - start: First source-owned concrete verse.
       - end: Last source-owned concrete verse.
     - Returns: Human-readable single-verse or inclusive range label.
     - Side effects: Reads the source's real book inventory for identifiers absent from JSword's
       pinned locale catalog.
     - Throws: Re-throws SQLite book-list failures; missing JSword and source metadata yields nil.
     */
    func displayName(
        start: VerseKeyReference,
        end: VerseKeyReference
    ) throws -> String? {
        let booksByOSIS = Dictionary(
            uniqueKeysWithValues: try bookList().map { ($0.osisId, $0.name) }
        )
        guard let startBook = JSwordBibleNames.localizedLongName(osisId: start.osisBookId)
                ?? booksByOSIS[start.osisBookId],
              let endBook = JSwordBibleNames.localizedLongName(osisId: end.osisBookId)
                ?? booksByOSIS[end.osisBookId] else {
            return nil
        }
        if start == end {
            return "\(startBook) \(start.chapter):\(start.verse)"
        }
        if start.osisBookId == end.osisBookId {
            if start.chapter == end.chapter {
                return "\(startBook) \(start.chapter):\(start.verse)-\(end.verse)"
            }
            return "\(startBook) \(start.chapter):\(start.verse)-\(end.chapter):\(end.verse)"
        }
        return "\(startBook) \(start.chapter):\(start.verse)-\(endBook) \(end.chapter):\(end.verse)"
    }

    /**
     Reads one exact verse without retaining mutable backend state.

     - Parameter reference: Source-owned verse identity whose ordinal and coordinate must agree.
     - Returns: Source OSIS plus canonical visible text, or `nil` for absent/empty content.
     - Side effects: SWORD restores its exact prior cursor; SQLite performs one read-only query.
     - Throws: Re-throws bounded SWORD source-inspection or SQLite reader failures.
     */
    func verse(_ reference: VerseKeyReference) throws -> BibleReaderInstalledScriptureVerse? {
        guard verseReference(ordinal: reference.ordinal) == reference else { return nil }

        switch self {
        case .sword(let module):
            let capture = try module.inspectVerseSourceRangeRestoringPrevious(
                startOrdinal: reference.ordinal,
                endOrdinal: reference.ordinal,
                maximumVerseCount: 1
            )
            guard let entry = capture.entries.first,
                  capture.entries.count == 1,
                  entry.reference == reference else {
                return nil
            }
            let sourceXML = entry.osisFragment?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let plainText = entry.canonicalText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sourceXML.isEmpty || !plainText.isEmpty else { return nil }
            return BibleReaderInstalledScriptureVerse(
                reference: reference,
                sourceXML: sourceXML,
                plainText: plainText
            )

        case .sqlite(let module):
            guard let content = try module.verseContent(
                osisId: reference.osisBookId,
                chapter: reference.chapter,
                verse: reference.verse
            ) else {
                return nil
            }
            return Self.sqliteVerse(
                reference: reference,
                text: content.text,
                module: module
            )
        }
    }

    /**
     Captures one bounded inclusive source passage for a bridge or document action.

     - Parameters:
       - startOrdinal: First concrete source verse ordinal.
       - endOrdinal: Last concrete source verse ordinal.
       - maximumVerseCount: Maximum inclusive ordinal span accepted before any source walk.
     - Returns: Real non-empty verses and canonical text in source order.
     - Side effects: SWORD holds one serialized cursor lease and restores it exactly; SQLite opens
       operation-owned read-only connections for concrete verses in the bounded span.
     - Throws: Cancellation, validation errors above, SWORD source-inspection errors, or SQLite
       reader failures.
     - Important: Interior introduction or absent-content slots are skipped like Android's key
       iteration; both requested endpoints must still identify concrete verses.
     */
    func passage(
        startOrdinal: Int,
        endOrdinal: Int,
        maximumVerseCount: Int = 5_000
    ) throws -> BibleReaderInstalledScripturePassage {
        try Task.checkCancellation()
        guard startOrdinal > 0, endOrdinal >= startOrdinal, maximumVerseCount > 0 else {
            throw BibleReaderInstalledScriptureSourceError.invalidRange
        }
        let distance = endOrdinal - startOrdinal
        guard distance < maximumVerseCount else {
            throw BibleReaderInstalledScriptureSourceError.rangeTooLarge(
                maximumCount: maximumVerseCount
            )
        }
        guard let start = verseReference(ordinal: startOrdinal) else {
            throw BibleReaderInstalledScriptureSourceError.nonAddressableEndpoint(startOrdinal)
        }
        guard let end = verseReference(ordinal: endOrdinal) else {
            throw BibleReaderInstalledScriptureSourceError.nonAddressableEndpoint(endOrdinal)
        }

        let verses: [BibleReaderInstalledScriptureVerse]
        switch self {
        case .sword(let module):
            let capture = try module.inspectVerseSourceRangeRestoringPrevious(
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                maximumVerseCount: maximumVerseCount
            )
            verses = capture.entries.compactMap { entry in
                let sourceXML = entry.osisFragment?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let plainText = entry.canonicalText?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !sourceXML.isEmpty || !plainText.isEmpty else { return nil }
                return BibleReaderInstalledScriptureVerse(
                    reference: entry.reference,
                    sourceXML: sourceXML,
                    plainText: plainText
                )
            }

        case .sqlite(let module):
            let references = (startOrdinal...endOrdinal).compactMap {
                verseReference(ordinal: $0)
            }
            var captured: [BibleReaderInstalledScriptureVerse] = []
            captured.reserveCapacity(references.count)

            var index = references.startIndex
            while index < references.endIndex {
                try Task.checkCancellation()
                let chapterStart = references[index]
                var chapterEnd = references.index(after: index)
                while chapterEnd < references.endIndex,
                      references[chapterEnd].osisBookId == chapterStart.osisBookId,
                      references[chapterEnd].chapter == chapterStart.chapter {
                    chapterEnd = references.index(after: chapterEnd)
                }

                let rows = try module.chapterContent(
                    osisId: chapterStart.osisBookId,
                    chapter: chapterStart.chapter
                )
                let textByVerse = Dictionary(
                    rows.map { ($0.verse, $0.text) },
                    uniquingKeysWith: { first, _ in first }
                )
                for reference in references[index..<chapterEnd] {
                    guard let text = textByVerse[reference.verse],
                          let entry = Self.sqliteVerse(
                              reference: reference,
                              text: text,
                              module: module
                          ) else {
                        continue
                    }
                    captured.append(entry)
                }
                index = chapterEnd
            }
            verses = captured
        }

        let sourceOSISRange = start == end
            ? start.osisRef
            : "\(start.osisRef)-\(end.osisRef)"
        return BibleReaderInstalledScripturePassage(
            verses: verses,
            sourceOrdinalRange: startOrdinal...endOrdinal,
            sourceOSISRange: sourceOSISRange,
            plainText: verses.map(\.plainText).filter { !$0.isEmpty }.joined(separator: " ")
        )
    }

    /**
     Checks canonical adjacency while skipping only introduction ordinals.

     - Parameters are two source-owned concrete references in ascending order.
     - Returns: `true` only when `candidate` is the next concrete verse after `previous`.
     - Side effects: SWORD may perform bounded cursor-restoring ordinal lookups.
     - Failure modes: Missing, reversed, duplicate, or intervening concrete verses return `false`.
     */
    func isCanonicallyAdjacent(
        _ candidate: VerseKeyReference,
        after previous: VerseKeyReference
    ) -> Bool {
        guard candidate.ordinal > previous.ordinal else { return false }
        for ordinal in (previous.ordinal + 1)...candidate.ordinal {
            guard let reference = verseReference(ordinal: ordinal) else { continue }
            return reference == candidate
        }
        return false
    }

    /** Projects one exact SQLite row without opening another source connection. */
    private static func sqliteVerse(
        reference: VerseKeyReference,
        text: String,
        module: BibleReaderSQLiteModuleHandle
    ) -> BibleReaderInstalledScriptureVerse? {
        let sourceXML = SQLiteReaderMarkupProjection.bibleVerseXML(
            text,
            module: module
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let plainText = SQLiteReaderMarkupProjection.plainText(
            text,
            module: module
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceXML.isEmpty || !plainText.isEmpty else { return nil }
        return BibleReaderInstalledScriptureVerse(
            reference: reference,
            sourceXML: sourceXML,
            plainText: plainText
        )
    }
}

/** One installed dictionary exposed through Android's global book behavior. */
enum BibleReaderInstalledDictionarySource: @unchecked Sendable {
    /// Native SWORD dictionary or glossary.
    case sword(SwordModule)

    /// Android-compatible MyBible or MySword dictionary.
    case sqlite(BibleReaderSQLiteModuleHandle)

    /// Installed metadata used by preferences and Vue fragment identity.
    var info: ModuleInfo {
        switch self {
        case .sword(let module): return module.info
        case .sqlite(let module): return module.info
        }
    }

    /// Source versification for SWORD books; Android SQLite dictionaries have no passage domain.
    var versificationName: String? {
        switch self {
        case .sword(let module): return VersificationMapper.versificationName(for: module)
        case .sqlite: return nil
        }
    }

    /// User-visible short label used by Android-style dictionary tabs.
    var abbreviation: String {
        switch self {
        case .sword(let module):
            return BibleReaderStrongsDocumentBuilder.moduleDisplayLabel(module)
        case .sqlite(let module):
            let value = module.metadata.abbreviation.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return value.isEmpty ? module.info.name : value
        }
    }

    /**
     Resolves the first exact dictionary key variant without cross-module fallback.

     - Parameter keyOptions: Ordered Android-compatible key candidates.
     - Returns: Exact source entry and rendering metadata, or nil when every candidate is absent.
     - Side effects: SWORD restores its cursor after lookup; SQLite opens operation-owned read-only
       connections for attempted exact keys.
     - Failure modes: Backend read/markup failures fail the affected source closed.
     */
    func lookup(
        keyOptions: [String]
    ) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult? {
        switch self {
        case .sword(let module):
            return BibleReaderStrongsDocumentBuilder.lookupInModule(
                module,
                keyOptions: keyOptions
            )
        case .sqlite(let module):
            for key in keyOptions {
                guard let content = try? module.dictionaryContent(for: key),
                      !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return BibleReaderStrongsDocumentBuilder.DictionaryLookupResult(
                    actualKey: key,
                    rawEntry: text,
                    renderedText: text,
                    isNativeHtml: module.metadata.format == .myBible
                )
            }
            return nil
        }
    }
}

/** One globally registered installed module before a category-specific projection is requested. */
enum BibleReaderInstalledModuleSource: @unchecked Sendable {
    /// Native readable SWORD module.
    case sword(SwordModule)

    /// Readable Android-compatible SQLite module.
    case sqlite(BibleReaderSQLiteModuleHandle)

    /// Canonical installed metadata for category and identity checks.
    var info: ModuleInfo {
        switch self {
        case .sword(let module): return module.info
        case .sqlite(let module): return module.info
        }
    }

    /// Projects a Bible only after global lookup has selected this exact module.
    var scripture: BibleReaderInstalledScriptureSource? {
        guard info.category == .bible else { return nil }
        switch self {
        case .sword(let module): return .sword(module)
        case .sqlite(let module): return .sqlite(module)
        }
    }

    /// Projects a dictionary/glossary only after global lookup has selected this exact module.
    var dictionary: BibleReaderInstalledDictionarySource? {
        guard info.category == .dictionary || info.category == .glossary else { return nil }
        switch self {
        case .sword(let module): return .sword(module)
        case .sqlite(let module): return .sqlite(module)
        }
    }
}

/**
 Resolves Android's global installed-book registry with genuine SWORD precedence over SQLite.

 JSword resolves exact initials, exact full name, then the first registration-order
 case-insensitive initials/full-name match. iOS applies that sequence to all genuine SWORD modules
 first, then to unshadowed SQLite modules. Category projection happens only after global resolution,
 so an exact wrong-category book fails closed instead of falling through to a namesake.
 */
struct BibleReaderInstalledModuleResolver {
    /// Genuine readable SWORD modules in manager registration order.
    private let swordModules: [SwordModule]

    /// Unshadowed readable SQLite modules in Android registration order.
    private let sqliteModules: [BibleReaderSQLiteModuleHandle]

    /**
     Captures the current installed registry from one configured reader runtime.

     - Parameters:
       - swordManager: Manager used to enumerate and prove genuine readable SWORD modules.
       - sqliteModules: Runtime-filtered SQLite modules not shadowed during registration.
     - Side effects: Enumerates installed SWORD metadata and resolves each genuine module once.
     - Failure modes: Missing/unreadable modules are omitted; later lookup fails closed.
     */
    init(
        swordManager: SwordManager?,
        sqliteModules: [BibleReaderSQLiteModuleHandle]
    ) {
        self.swordModules = swordManager?.installedModules().compactMap { info in
            guard !BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info) else { return nil }
            return swordManager?.module(named: info.name)
        } ?? []
        self.sqliteModules = sqliteModules
    }

    /** Creates an explicit deterministic registry for focused tests. */
    init(
        swordModules: [SwordModule],
        sqliteModules: [BibleReaderSQLiteModuleHandle]
    ) {
        self.swordModules = swordModules
        self.sqliteModules = sqliteModules
    }

    /**
     Resolves one global installed-book token using JSword precedence.

     - Parameter name: Initials or full book name; exact UTF-16 identity is preserved.
     - Returns: Genuine SWORD first, then SQLite, or nil when no global book matches.
     - Side effects: None after resolver construction.
     - Failure modes: Empty, absent, and shadowed identities return nil.
     */
    func module(named name: String) -> BibleReaderInstalledModuleSource? {
        if let module = Self.lookup(name, in: swordModules, info: { $0.info }) {
            return .sword(module)
        }
        if let module = Self.lookup(name, in: sqliteModules, info: { $0.info }) {
            return .sqlite(module)
        }
        return nil
    }

    /** Returns an exact Bible projection after global resolution and category validation. */
    func scripture(named name: String) -> BibleReaderInstalledScriptureSource? {
        module(named: name)?.scripture
    }

    /** Returns an exact dictionary/glossary projection after global resolution. */
    func dictionary(named name: String) -> BibleReaderInstalledDictionarySource? {
        module(named: name)?.dictionary
    }

    /**
     Resolves a category inventory through the same global path while preserving caller order.

     - Parameters:
       - category: Required installed module category.
       - metadata: Ordered merged inventory shown by the reader.
     - Returns: Distinct globally resolvable modules in metadata order.
     - Side effects: None after resolver construction.
     - Failure modes: Stale, shadowed, and wrong-category metadata rows are omitted.
     */
    func modules(
        category: ModuleCategory,
        orderedBy metadata: [ModuleInfo]
    ) -> [BibleReaderInstalledModuleSource] {
        var seen = Set<SQLiteDocumentIdentity>()
        return metadata.compactMap { info in
            guard let module = module(named: info.name),
                  module.info.category == category,
                  seen.insert(SQLiteDocumentIdentity(module.info.name)).inserted else {
                return nil
            }
            return module
        }
    }

    /** Returns globally registered modules for the requested categories in backend order. */
    func modules(categories: Set<ModuleCategory>) -> [BibleReaderInstalledModuleSource] {
        let sword = swordModules.compactMap { module -> BibleReaderInstalledModuleSource? in
            guard categories.contains(module.info.category) else { return nil }
            return .sword(module)
        }
        let sqlite = sqliteModules.compactMap { module -> BibleReaderInstalledModuleSource? in
            guard categories.contains(module.info.category) else { return nil }
            return .sqlite(module)
        }
        return sword + sqlite
    }

    /** Applies JSword exact-initials, exact-full-name, then case-insensitive lookup precedence. */
    private static func lookup<Value>(
        _ name: String,
        in values: [Value],
        info: (Value) -> ModuleInfo
    ) -> Value? {
        values.first { javaStringEquals(info($0).name, name) }
            ?? values.last { javaStringEquals(info($0).description, name) }
            ?? {
                let identity = SQLiteDocumentIdentity(name)
                return values.first {
                    SQLiteDocumentIdentity(info($0).name) == identity
                        || SQLiteDocumentIdentity(info($0).description) == identity
                }
            }()
    }

    /** Compares Java `String.equals` values by exact UTF-16 code units. */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
