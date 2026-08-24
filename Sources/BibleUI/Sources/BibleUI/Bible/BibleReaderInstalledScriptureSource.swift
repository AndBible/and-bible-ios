// BibleReaderInstalledScriptureSource.swift -- Exact reads across installed Bible backends

import BibleCore
import Foundation
import SwordKit

/**
 Normalizes generated SWORD config values at Android's `IniSection` parsing boundary.

 SQLite Description, Lang, and Abbreviation metadata are interpolated into custom-driver config and
 parsed by Java before the book enters `Books`. This namespace keeps the abbreviation fallback
 shared across TreeSet ordering and fragment display while preserving nonbreaking spaces.

 - Side effects: None.
 - Failure modes: Missing or Java-trimmed-empty abbreviations deterministically fall back to the
   installed initials; no Foundation Unicode whitespace rules are applied.
 */
enum BibleReaderJSwordConfigValue {
    /**
     Resolves a parsed JSword abbreviation with the installed initials fallback.

     - Parameters:
       - rawValue: Value interpolated into or read from a SWORD `IniSection`.
       - initials: Installed book initials used when the parsed value is empty.
     - Returns: The value after removing only leading/trailing UTF-16 units `<= U+0020`, or
       `initials` when absent/empty. Nonbreaking spaces and other Unicode whitespace remain intact.
     - Side effects: None.
     - Failure modes: None; Swift strings are decoded losslessly from their valid UTF-16 units.
     */
    static func abbreviation(_ rawValue: String?, initials: String) -> String {
        guard let rawValue else { return initials }
        let trimmed = SwordJavaStringIdentity.trim(rawValue)
        return trimmed.isEmpty ? initials : trimmed
    }
}

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
            return BibleReaderJSwordConfigValue.abbreviation(
                module.metadata.abbreviation,
                initials: module.info.name
            )
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

    /**
     Returns versification only for native backends Android serializes as `SwordBook`.

     Android's `OsisFragment` checks the concrete JSword class, so `SwordDictionary`, general-book,
     map, and SQLite key sources serialize a null `v11n` even when their config declares KJVA.
     Native verse-text and commentary drivers retain their mapped versification when an explicit
     global selection routes them through the key facade.
     */
    var versificationName: String? {
        switch self {
        case .sword(let module):
            if module.info.isJSwordSwordBook {
                return VersificationMapper.versificationName(for: module)
            }
            return nil
        case .sqlite:
            return nil
        }
    }

    /// User-visible short label used by Android-style dictionary tabs.
    var abbreviation: String {
        switch self {
        case .sword(let module):
            return BibleReaderStrongsDocumentBuilder.moduleDisplayLabel(module)
        case .sqlite(let module):
            return BibleReaderJSwordConfigValue.abbreviation(
                module.metadata.abbreviation,
                initials: module.info.name
            )
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
                      let processed = try? SwordOSISFragmentProcessor.processDictionarySource(
                        sourceXML: content.text,
                        keyName: key,
                        moduleInitials: module.info.name
                      ) else {
                    continue
                }
                return BibleReaderStrongsDocumentBuilder.DictionaryLookupResult(
                    actualKey: key,
                    rawEntry: processed.originalXML,
                    renderedText: processed.originalXML,
                    payloadReadyXML: processed.xml
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

    /**
     Projects one readable Bible as an index source after global ownership authorization.

     - Returns: The selected native or SQLite Bible backend, or nil for a non-Bible category.
     - Side effects: None; the resolver already captured and authorized the backend handle.
     - Failure modes: Wrong-category sources fail closed without substituting another module.
     */
    var searchIndexSource: (any BibleSearchIndexSource)? {
        guard info.category == .bible else { return nil }
        switch self {
        case .sword(let module): return module
        case .sqlite(let module): return module.searchIndexSource
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

    /**
     Projects the concrete JSword `SwordBook` contract used by restored Multi children.

     Android restore dispatches on the concrete book class rather than configured category. Native
     verse-text/commentary drivers are `SwordBook` even under contradictory category metadata;
     MyBible/MySword commentary and Bible drivers expose the same verse-key contract through their
     custom book classes.

     - Returns: A verse-key source for native pinned SwordBook drivers and SQLite Bible/commentary
       drivers, otherwise `nil`.
     - Side effects: None; the globally selected readable handle is only reprojected.
     - Failure modes: Dictionary, general-book, locked, and unsupported custom drivers fail closed
       without being reinterpreted from category alone.
     */
    var verseKeySource: BibleReaderInstalledScriptureSource? {
        switch self {
        case .sword(let module):
            guard module.info.isJSwordSwordBook else { return nil }
            return .sword(module)
        case .sqlite(let module):
            guard module.info.category == .bible || module.info.category == .commentary else {
                return nil
            }
            return .sqlite(module)
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

    /**
     Projects a globally selected book into Android's explicit dictionary-key lookup contract.

     Android resolves configured Strong's and morphology selections through global `Books.getBook`
     identity without applying a second category or feature filter. Native SWORD books all expose
     the required key API, while SQLite scripture backends do not faithfully expose dictionary keys
     and therefore remain limited to dictionary/glossary formats.

     - Returns: A readable exact-key source for the globally selected book, or `nil` when an SQLite
       backend cannot implement Android's dictionary-key contract.
     - Side effects: None; global ownership and authorization were resolved before projection.
     - Failure modes: Unsupported SQLite categories fail closed without falling through to a
       colliding backend.
     */
    var explicitDictionaryKeySource: BibleReaderInstalledDictionarySource? {
        switch self {
        case .sword(let module):
            return .sword(module)
        case .sqlite(let module):
            guard info.category == .dictionary || info.category == .glossary else { return nil }
            return .sqlite(module)
        }
    }
}

/**
 One globally resolved installed owner or a lower-priority local-document fallback.

 Android resolves the complete installed-book registry before local My Documents or EPUB adapters
 may claim an identity. The installed case deliberately carries metadata even when its content
 handle is nil so a locked native owner cannot redirect a read to unrelated local content.
 */
enum BibleReaderInstalledOrLocalDocumentOwner<LocalDocument> {
    /// Native or SQLite global owner; `readableSource` is nil only for an unreadable native owner.
    case installed(info: ModuleInfo, readableSource: BibleReaderInstalledModuleSource?)

    /// Exactly one caller-supplied local candidate, admitted only when the global registry is empty.
    case local(LocalDocument)

    /// Neither the global registry nor the caller's local inventory owns the requested identity.
    case missing

}

/** One Android custom-book registration backed by an iOS-local document adapter. */
struct BibleReaderLocalDocumentRegistration<LocalDocument> {
    /// Caller-owned metadata/content adapter retained without reading an entry.
    let document: LocalDocument

    /// Android `Book.initials` used for candidate admission and exact-initials lookup.
    let initials: String

    /// Android `Book.name` used by the exact-name and case-insensitive lookup tiers.
    let fullName: String

    /// JSword `Book.getAbbreviation()` used by installed TreeSet ordering.
    let abbreviation: String

    /// JSword category ordinal used as the first installed TreeSet comparison field.
    let category: ModuleCategory

    /**
     Creates one local registration after Android generated-config parsing.

     - Parameters describe the caller-owned adapter and raw generated config values.
     - Side effects: None.
     - Failure modes: Java-trimmed-empty abbreviations fall back to exact initials; full names may
       remain empty because JSword metadata permits an empty Description value.
     */
    init(
        document: LocalDocument,
        initials: String,
        fullName: String,
        abbreviation: String,
        category: ModuleCategory
    ) {
        self.document = document
        self.initials = initials
        self.fullName = SwordJavaStringIdentity.trim(fullName)
        self.abbreviation = BibleReaderJSwordConfigValue.abbreviation(
            abbreviation,
            initials: initials
        )
        self.category = category
    }
}

/**
 One installed chooser book retaining Android's display abbreviation after global admission.

 The reader uses `ModuleInfo` for content/category actions, while Android's document chooser renders
 and sorts the separate JSword abbreviation. Values are immutable and already reflect native-first
 plus custom-driver registration ownership.
 */
struct BibleReaderInstalledBookPresentation {
    /// Inclusive installed owner metadata used by reader actions and secondary display text.
    let info: ModuleInfo

    /// JSword abbreviation used by Android as primary row text and locale-aware sort input.
    let abbreviation: String
}

/**
 Resolves Android's single global installed-book registry across native and SQLite backends.

 Each custom SQLite driver first asks the current registry for its proposed initials and skips
 registration when any existing initials/full-name/case-insensitive tier matches. JSword then
 resolves exact initials and exact full name through last-added maps, then scans its installed-book
 TreeSet for the first case-insensitive initials/full-name match. Category projection happens only
 after global resolution, so exact wrong-category and locked owners fail closed.

 - Side effects: Initializers snapshot native access state and SQLite registration candidates;
   projections replay immutable Android admission and TreeSet ordering without reading content.
 - Failure modes: Missing, unsupported, shadowed, or locked registrations remain absent from
   readable projections, and a selected locked owner never falls through to another backend.
 */
struct BibleReaderInstalledModuleResolver {
    /** One inclusive native owner plus its independently authorized content handle. */
    private struct NativeRegistration {
        /// Fresh installed metadata used for JSword global ownership precedence.
        let info: ModuleInfo

        /// Native content handle exposed only after the manager reports `.readable`.
        let readableModule: SwordModule?

        /// JSword abbreviation used by installed-book TreeSet ordering.
        let abbreviation: String
    }

    /** One globally ordered registration before readability and backend projection. */
    private enum GlobalRegistration {
        /// Inclusive native owner, which may be locked and therefore unreadable.
        case native(NativeRegistration)

        /// Readable SQLite registration admitted by Android's complete current-registry lookup.
        case sqlite(BibleReaderSQLiteModuleHandle)

        /// Installed metadata used by the shared JSword identity tiers.
        var info: ModuleInfo {
            switch self {
            case .native(let registration): return registration.info
            case .sqlite(let module): return module.info
            }
        }

        /// JSword abbreviation used after category in global case-insensitive lookup order.
        var abbreviation: String {
            switch self {
            case .native(let registration): return registration.abbreviation
            case .sqlite(let module):
                return BibleReaderJSwordConfigValue.abbreviation(
                    module.metadata.abbreviation,
                    initials: module.info.name
                )
            }
        }

        /// Authorized content source, or `nil` for a selected locked native registration.
        var readableSource: BibleReaderInstalledModuleSource? {
            switch self {
            case .native(let registration):
                return registration.readableModule.map(BibleReaderInstalledModuleSource.sword)
            case .sqlite(let module):
                return .sqlite(module)
            }
        }

        /// Shared JSword BookSet registration retaining this exact backend owner.
        var bookSetRegistration: BibleReaderInstalledBookSetRegistration<GlobalRegistration> {
            BibleReaderInstalledBookSetRegistration(
                value: self,
                initials: info.name,
                fullName: info.description,
                abbreviation: abbreviation,
                category: info.category
            )
        }
    }

    /** One combined installed or admitted local registration in Android add order. */
    private enum CombinedRegistration<LocalDocument> {
        /// Native/SQLite registration admitted before local custom books.
        case installed(GlobalRegistration)

        /// EPUB or My Documents adapter admitted by its initials lookup preflight.
        case local(BibleReaderLocalDocumentRegistration<LocalDocument>)

        /// Exact Android initials for maps, admission, and TreeSet comparison.
        var initials: String {
            switch self {
            case .installed(let registration): return registration.info.name
            case .local(let registration): return registration.initials
            }
        }

        /// Exact Android full display name for name-map and case-insensitive lookup tiers.
        var fullName: String {
            switch self {
            case .installed(let registration): return registration.info.description
            case .local(let registration): return registration.fullName
            }
        }

        /// JSword abbreviation used after category by the installed TreeSet comparator.
        var abbreviation: String {
            switch self {
            case .installed(let registration): return registration.abbreviation
            case .local(let registration): return registration.abbreviation
            }
        }

        /// JSword category used as the first installed TreeSet comparator field.
        var category: ModuleCategory {
            switch self {
            case .installed(let registration): return registration.info.category
            case .local(let registration): return registration.category
            }
        }

        /// Public owner projection retaining locked installed metadata without content fallback.
        var owner: BibleReaderInstalledOrLocalDocumentOwner<LocalDocument> {
            switch self {
            case .installed(let registration):
                return .installed(
                    info: registration.info,
                    readableSource: registration.readableSource
                )
            case .local(let registration):
                return .local(registration.document)
            }
        }
    }

    /// Inclusive native registrations in manager order, including locked ownership rows.
    private let nativeRegistrations: [NativeRegistration]

    /// Unshadowed readable SQLite modules in Android registration order.
    private let sqliteModules: [BibleReaderSQLiteModuleHandle]

    /**
     Replays Android custom-driver admission after native registration.

     MyBible, MySword, and e-Sword drivers call `Books.getBook(candidate.initials)` before adding
     each book. That complete lookup can reject a candidate whose initials equal an existing full
     name or case-insensitive alias, while distinct initials with a duplicate full name remain
     admissible and become the later exact-name owner.
     */
    private var admittedRegistrations: [GlobalRegistration] {
        var registrations = nativeRegistrations.map(GlobalRegistration.native)
        for module in sqliteModules {
            guard Self.lookup(module.info.name, in: registrations) == nil else { continue }
            registrations.append(.sqlite(module))
        }
        return BibleReaderInstalledBookSet.registrationOrderProjection(
            registrations.map(\.bookSetRegistration)
        ).map(\.value)
    }

    /**
     Projects admitted books into the TreeSet order exposed by `Books.installed().books`.

     - Returns: Comparator-distinct registrations sorted by pinned JSword category, abbreviation,
       initials, and full-name rules.
     - Side effects: Replays immutable custom admission and comparator-equal replacement on access.
     - Failure modes: An empty registry returns an empty projection; unreadable registrations remain
       present as metadata without exposing content handles.
     */
    private var jswordSortedRegistrations: [GlobalRegistration] {
        BibleReaderInstalledBookSet.treeSetOrderProjection(
            admittedRegistrations.map(\.bookSetRegistration)
        ).map(\.value)
    }

    /**
     Captures the current installed registry from one configured reader runtime.

     - Parameters:
       - swordManager: Manager used to enumerate inclusive native ownership and authorize content.
       - sqliteModules: Runtime-filtered SQLite modules not shadowed during registration.
     - Side effects: Enumerates one fresh, session-adjusted installed SWORD snapshot and resolves a
       native module only when that same row reports readable access.
     - Failure modes: Missing managers produce no native registrations. Locked/unavailable native
       rows retain global ownership but have no content handle, so lookup fails closed without
       falling through to a colliding SQLite module.
     */
    init(
        swordManager: SwordManager?,
        sqliteModules: [BibleReaderSQLiteModuleHandle]
    ) {
        let installedSnapshot = swordManager?.installedBookRegistrations() ?? []
        self.nativeRegistrations = installedSnapshot.compactMap { installedBook in
            let info = installedBook.moduleInfo
            guard !BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info) else { return nil }
            let installedModule = swordManager?.module(named: info.name)
            let readableModule = (!info.isEncrypted || info.isUnlocked) ? installedModule : nil
            return NativeRegistration(
                info: info,
                readableModule: readableModule,
                abbreviation: installedBook.abbreviation
            )
        }
        self.sqliteModules = sqliteModules
    }

    /**
     Captures one complete readable-content registry from the app's installed backend libraries.

     - Parameters:
       - swordManager: Manager supplying inclusive native ownership and fresh access state.
       - sqliteLibrary: Android-compatible SQLite discovery snapshot whose raw candidates are
         replayed after native rows through the combined global registry.
     - Side effects: Enumerates native inventory once and wraps already-discovered SQLite modules;
       no SQLite content query occurs.
     - Failure modes: Locked native owners retain precedence without a readable handle or SQLite
       fallthrough. Candidates rejected by native identity never suppress a later SQLite candidate;
       missing native managers produce a SQLite-only registry.
     */
    init(
        swordManager: SwordManager?,
        sqliteLibrary: SQLiteDocumentModuleLibrary
    ) {
        self.init(
            swordManager: swordManager,
            sqliteModules: sqliteLibrary.registrationCandidates.map(
                BibleReaderSQLiteModuleHandle.init(module:)
            )
        )
    }

    /**
     Creates an explicit deterministic registry for focused tests and pure builders.

     - Parameters:
       - swordModules: Native handles in registration order.
       - sqliteModules: SQLite handles in registration order.
     - Side effects: None.
     - Failure modes: Encrypted handles whose immutable metadata is still locked retain ownership
       but are not exposed for content. Callers that need fresh live-unlock state must use the
       manager-backed initializer.
     */
    init(
        swordModules: [SwordModule],
        sqliteModules: [BibleReaderSQLiteModuleHandle]
    ) {
        self.nativeRegistrations = swordModules.map { module in
            NativeRegistration(
                info: module.info,
                readableModule: module.info.isEncrypted && !module.info.isUnlocked ? nil : module,
                abbreviation: BibleReaderJSwordConfigValue.abbreviation(
                    module.configEntry("Abbreviation"),
                    initials: module.info.name
                )
            )
        }
        self.sqliteModules = sqliteModules
    }

    /**
     Resolves one global installed-book token using JSword precedence.

     - Parameter name: Initials or full book name; exact UTF-16 identity is preserved.
     - Returns: Readable content for the globally selected registration, or nil when it is absent
       or the selected native owner is locked.
     - Side effects: None after resolver construction.
     - Failure modes: Empty, absent, locked-native, and shadowed identities return nil. A locked
       native match never falls through to a colliding readable SQLite module.
     */
    func module(named name: String) -> BibleReaderInstalledModuleSource? {
        selectedRegistration(named: name)?.readableSource
    }

    /**
     Returns inclusive metadata for the globally selected installed registration.

     - Parameter name: Initials or full-name token resolved with pinned JSword lookup precedence.
     - Returns: Canonical admitted metadata, including a currently locked native owner, or nil when
       no installed registration owns the token.
     - Side effects: Replays immutable custom admission; no content handle is opened or read.
     - Failure modes: Empty, missing, and Java-distinct identities return nil. Authorization does
       not hide locked metadata because callers use this projection to suppress local fallthrough.
     */
    func registeredModuleInfo(named name: String) -> ModuleInfo? {
        selectedRegistration(named: name)?.info
    }

    /**
     Reports whether inclusive native registration owns one global lookup token.

     - Parameter name: Initials or full module name resolved with JSword lookup precedence.
     - Returns: `true` when any native row owns the identity, including a currently locked row.
     - Side effects: None after resolver construction.
     - Failure modes: Empty and unmatched values return `false`; authorization does not affect
       ownership, so callers can prevent SQLite, My Documents, or EPUB collision fallthrough.
     */
    func hasNativeRegistration(named name: String) -> Bool {
        guard let registration = selectedRegistration(named: name) else { return false }
        if case .native = registration { return true }
        return false
    }

    /** Returns an exact Bible projection after global resolution and category validation. */
    func scripture(named name: String) -> BibleReaderInstalledScriptureSource? {
        module(named: name)?.scripture
    }

    /** Returns an exact dictionary/glossary projection after global resolution. */
    func dictionary(named name: String) -> BibleReaderInstalledDictionarySource? {
        module(named: name)?.dictionary
    }

    /** Returns an authorized Bible index source after global category and ownership resolution. */
    func searchIndexSource(named name: String) -> (any BibleSearchIndexSource)? {
        module(named: name)?.searchIndexSource
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

    /**
     Projects readable registered books in Android add order for category-based legacy consumers.

     - Parameter categories: Accepted actual categories after global custom-driver admission.
     - Returns: Native-then-custom readable sources in registration order; this intentionally does
       not replace APIs whose Android contract consumes `Books.installed().books` TreeSet order.
     - Side effects: Replays immutable SQLite admission against the captured native registry.
     - Failure modes: Locked native owners, unreadable sources, rejected custom registrations, and
       sources outside `categories` are omitted without collision fallthrough.
     */
    func modules(categories: Set<ModuleCategory>) -> [BibleReaderInstalledModuleSource] {
        admittedRegistrations.compactMap { registration in
            guard let source = registration.readableSource,
                  categories.contains(source.info.category) else {
                return nil
            }
            return source
        }
    }

    /**
     Projects readable installed books in the TreeSet order consumed by Android automatic defaults.

     - Parameter categories: Accepted actual categories after global custom-driver admission.
     - Returns: Readable, category-correct sources after JSword comparator replacement and sorting by
       category, abbreviation, initials, then full name.
     - Side effects: Replays immutable registration metadata only; no document content is read.
     - Failure modes: Locked/unreadable and wrong-category registrations are omitted while retaining
       their ownership; exact requested lookups continue to use the resolver's map/tier APIs.
     */
    func readableModulesInBookSetOrder(
        categories: Set<ModuleCategory>
    ) -> [BibleReaderInstalledModuleSource] {
        jswordSortedRegistrations.compactMap { registration in
            guard let source = registration.readableSource,
                  categories.contains(source.info.category) else {
                return nil
            }
            return source
        }
    }

    /**
     Returns every readable installed book that can implement Android's dictionary-key API.

     Android automatic Strong's and morphology discovery feature-filters the global `Books`
     inventory without first restricting book category. Every readable native SWORD book exposes
     `getKey`; SQLite sources participate only when their dictionary backend can faithfully perform
     exact key reads. Global native ownership still shadows a colliding SQLite registration.

     - Returns: Readable key sources in JSword's installed-book TreeSet order.
     - Side effects: None after resolver construction.
     - Failure modes: Locked native owners and SQLite scripture/commentary backends are omitted;
       neither can be replaced by a colliding secondary source.
     */
    func dictionaryKeySources() -> [BibleReaderInstalledDictionarySource] {
        jswordSortedRegistrations.compactMap { registration in
            registration.readableSource?.explicitDictionaryKeySource
        }
    }

    /**
     Returns Android's enabled-word-lookup source inventory before preference filtering.

     `SwordDocumentFacade.wordLookupDictionaries` filters `Books.installed().books`, whose source is
     JSword's category/abbreviation/initials/name TreeSet. Keeping this projection distinct from
     registration-order category inventories preserves Android's dictionary tab/result order when
     module initials and configured abbreviations sort differently.

     - Returns: Readable dictionary-category key sources in JSword TreeSet order. Glossaries remain
       excluded because Android selected-word lookup accepts `BookCategory.DICTIONARY` only.
     - Side effects: Replays immutable custom-driver admission and TreeSet projection on access.
     - Failure modes: Locked, unreadable, wrong-category, and non-key-capable registrations are
       omitted without falling through to shadowed sources.
     */
    func wordLookupDictionarySources() -> [BibleReaderInstalledDictionarySource] {
        jswordSortedRegistrations.compactMap { registration in
            guard registration.info.category == .dictionary else { return nil }
            return registration.readableSource?.dictionary
        }
    }

    /**
     Returns inclusive admitted-book metadata without exposing locked content handles.

     Android automatic dictionary discovery feature-filters `Books.installed()` before attempting
     content access, so a locked compatible book still proves the document is installed and
     suppresses the synthetic download book.

     - Returns: Admitted native and SQLite metadata in JSword's installed-book TreeSet order.
     - Side effects: Replays deterministic custom-driver admission over captured metadata.
     - Failure modes: Driver candidates rejected during Android admission are omitted; locked native
       books remain present only as immutable metadata.
     */
    func registeredBookMetadata() -> [ModuleInfo] {
        jswordSortedRegistrations.map(\.info)
    }

    /**
     Returns globally admitted installed books with Android's chooser abbreviation retained.

     - Returns: Native and SQLite registrations in final installed TreeSet order.
     - Side effects: Replays immutable custom admission and comparator replacement only.
     - Failure modes: Rejected custom candidates remain absent; locked native owners retain metadata
       and abbreviation without exposing a readable content handle.
     */
    func registeredBookPresentations() -> [BibleReaderInstalledBookPresentation] {
        jswordSortedRegistrations.map {
            BibleReaderInstalledBookPresentation(
                info: $0.info,
                abbreviation: $0.abbreviation
            )
        }
    }

    /**
     Returns the SQLite handles that survived Android's complete global registration sequence.

     Runtime catalogs must consume this projection rather than `SQLiteDocumentModuleLibrary.modules`.
     The library's ordinary module list applies only custom-to-custom admission, so a custom row
     later rejected by a native alias can otherwise suppress a subsequent valid custom candidate.

     - Returns: Admitted readable SQLite handles in MyBible, MySword, then e-Sword registration
       order, preserving the exact handle created for each raw discovery candidate.
     - Side effects: Replays immutable custom admission against the captured native registry; no
       content query, rediscovery, or handle recreation occurs.
     - Failure modes: Native-shadowed and earlier-custom-shadowed candidates are omitted. Locked
       native registrations retain ownership and therefore reject colliding SQLite candidates.
     */
    func registeredSQLiteModulesInRegistrationOrder() -> [BibleReaderSQLiteModuleHandle] {
        admittedRegistrations.compactMap { registration in
            guard case .sqlite(let module) = registration else { return nil }
            return module
        }
    }

    /**
     Resolves one document after replaying Android's EPUB/My Documents registration sequence.

     - Parameters:
       - name: Initials/full-name token resolved by exact maps then TreeSet case-insensitive scan.
       - localRegistrations: Lazy local registrations in Android add order: EPUB before My Documents.
     - Returns: Globally selected installed or local owner, or `.missing` when no admitted book owns
       the token. JSword maps resolve every admitted duplicate deterministically.
     - Side effects: Replays metadata-only registration and TreeSet projection; no content entry is
       read. Exact installed-initials matches return without evaluating local metadata because no
       admitted local name can outrank JSword's exact-initials map.
     - Failure modes: Local candidates whose initials resolve to an earlier installed/local book are
       rejected exactly like `Books.installed().getBook(candidate.initials)` before `addBook`.
     */
    func resolveDocumentOwner<LocalDocument>(
        named name: String,
        localRegistrations: () -> [BibleReaderLocalDocumentRegistration<LocalDocument>]
    ) -> BibleReaderInstalledOrLocalDocumentOwner<LocalDocument> {
        if let exactInstalled = admittedRegistrations.last(where: {
            Self.javaStringEquals($0.info.name, name)
        }) {
            return .installed(
                info: exactInstalled.info,
                readableSource: exactInstalled.readableSource
            )
        }
        let combined = admittedCombinedRegistrations(localRegistrations())
        return Self.lookupCombined(name, in: combined)?.owner ?? .missing
    }

    /**
     Returns the complete Android installed-book TreeSet after local custom-book registration.

     - Parameter localRegistrations: EPUB then My Documents registrations in their source order.
     - Returns: Installed/local owners in category, abbreviation, initials, and full-name order,
       retaining later comparator-equal replacements exactly like JSword's `TreeSet`.
     - Side effects: Replays metadata-only admission and sorting; no content handle is read.
     - Failure modes: Candidate-initials collisions are omitted. Locked native owners remain as
       installed metadata with nil readable content and still participate in lookup/admission.
     */
    func registeredDocumentOwners<LocalDocument>(
        localRegistrations: [BibleReaderLocalDocumentRegistration<LocalDocument>]
    ) -> [BibleReaderInstalledOrLocalDocumentOwner<LocalDocument>] {
        Self.combinedTreeSetProjection(admittedCombinedRegistrations(localRegistrations))
            .sorted(by: Self.precedesInCombinedJSwordBookSet)
            .map(\.owner)
    }

    /**
     Reports whether Android's complete current registry owns a proposed local initials token.

     - Parameters:
       - initials: Candidate generated by `MyDocumentBookManager.generateInitials` parity logic.
       - localRegistrations: Existing EPUB then My Documents registrations in Android add order.
     - Returns: True for any exact initials, exact full-name, or Java case-tier owner.
     - Side effects: Replays metadata-only local registration; no local page or EPUB fragment read.
     - Failure modes: Rejected local candidates cannot reserve a later token, matching startup.
     */
    func hasRegisteredDocument<LocalDocument>(
        named initials: String,
        localRegistrations: [BibleReaderLocalDocumentRegistration<LocalDocument>]
    ) -> Bool {
        Self.lookupCombined(
            initials,
            in: admittedCombinedRegistrations(localRegistrations)
        ) != nil
    }

    /** Replays EPUB/My Documents `getBook(initials)` admission after installed registrations. */
    private func admittedCombinedRegistrations<LocalDocument>(
        _ localRegistrations: [BibleReaderLocalDocumentRegistration<LocalDocument>]
    ) -> [CombinedRegistration<LocalDocument>] {
        var combined: [CombinedRegistration<LocalDocument>] = admittedRegistrations.map {
            .installed($0)
        }
        for local in localRegistrations {
            guard Self.lookupCombined(local.initials, in: combined) == nil else { continue }
            combined.append(.local(local))
        }
        return combined
    }

    /** Applies JSword exact maps and case-insensitive TreeSet scan to the combined registry. */
    private static func lookupCombined<LocalDocument>(
        _ name: String,
        in registrations: [CombinedRegistration<LocalDocument>]
    ) -> CombinedRegistration<LocalDocument>? {
        registrations.last { javaStringEquals($0.initials, name) }
            ?? registrations.last { javaStringEquals($0.fullName, name) }
            ?? {
                let identity = SQLiteDocumentIdentity(name)
                return combinedTreeSetProjection(registrations)
                    .sorted(by: precedesInCombinedJSwordBookSet)
                    .first {
                        SQLiteDocumentIdentity($0.initials) == identity
                            || SQLiteDocumentIdentity($0.fullName) == identity
                    }
            }()
    }

    /** Orders combined installed/local registrations with JSword's pinned book comparator. */
    private static func precedesInCombinedJSwordBookSet<LocalDocument>(
        _ lhs: CombinedRegistration<LocalDocument>,
        _ rhs: CombinedRegistration<LocalDocument>
    ) -> Bool {
        combinedJSwordBookSetComparison(lhs, rhs) < 0
    }

    /** Returns the JSword comparator result for two combined installed/local registrations. */
    private static func combinedJSwordBookSetComparison<LocalDocument>(
        _ lhs: CombinedRegistration<LocalDocument>,
        _ rhs: CombinedRegistration<LocalDocument>
    ) -> Int {
        let leftCategory = jswordCategoryOrdinal(lhs.category)
        let rightCategory = jswordCategoryOrdinal(rhs.category)
        if leftCategory != rightCategory { return leftCategory - rightCategory }

        let abbreviationOrder = SwordJavaStringIdentity.compareIgnoreCase(
            lhs.abbreviation,
            rhs.abbreviation
        )
        if abbreviationOrder != 0 { return abbreviationOrder }

        let initialsOrder = javaStringCompare(lhs.initials, rhs.initials)
        if initialsOrder != 0 { return initialsOrder }
        return javaStringCompare(lhs.fullName, rhs.fullName)
    }

    /** Retains the later combined registration for every JSword comparator-equal identity. */
    private static func combinedTreeSetProjection<LocalDocument>(
        _ registrations: [CombinedRegistration<LocalDocument>]
    ) -> [CombinedRegistration<LocalDocument>] {
        var treeValues: [CombinedRegistration<LocalDocument>] = []
        for registration in registrations {
            if let existing = treeValues.firstIndex(where: {
                combinedJSwordBookSetComparison($0, registration) == 0
            }) {
                treeValues[existing] = registration
            } else {
                treeValues.append(registration)
            }
        }
        return treeValues
    }

    /**
     Applies each JSword identity tier across the one combined global registration sequence.

     - Parameter name: Persisted or routed installed-book initials/full-name token.
     - Returns: Selected inclusive registration before readability projection.
     - Side effects: None.
     - Failure modes: Empty and unmatched identities return `nil`; SQLite rows with native-owned
       initials are omitted before tier evaluation, preserving locked native collision ownership.
     */
    private func selectedRegistration(named name: String) -> GlobalRegistration? {
        Self.lookup(name, in: admittedRegistrations)
    }

    /**
     Applies pinned `Books.getBook` identity tiers over one admitted global registry.

     - Parameters:
       - name: Requested initials or full-name identity.
       - registrations: Books in Android add order, before TreeSet projection.
     - Returns: Last-added exact-initials owner, last-added exact-name owner, then the first
       case-insensitive initials/name match in JSword TreeSet order; otherwise `nil`.
     - Side effects: Loads the pinned Java case-fold table for the final tier.
     - Failure modes: Empty or unmatched input returns `nil`; comparator-equal earlier books are
       removed before the case-insensitive scan, matching `Books.addBook` replacement.
     */
    private static func lookup(
        _ name: String,
        in registrations: [GlobalRegistration]
    ) -> GlobalRegistration? {
        BibleReaderInstalledBookSet.registration(
            named: name,
            in: registrations.map(\.bookSetRegistration)
        )?.value
    }

    /**
     Maps one installed category to pinned JSword `BookCategory.ordinal()`.

     - Parameter category: Actual selected-book category, including questionable/essay/image cases.
     - Returns: Stable Android enum ordinal used as the first TreeSet comparison field.
     - Side effects: None.
     - Failure modes: None; every `ModuleCategory` has an explicit pinned ordinal.
     */
    private static func jswordCategoryOrdinal(_ category: ModuleCategory) -> Int {
        switch category {
        case .bible: return 0
        case .dictionary: return 1
        case .commentary: return 2
        case .dailyDevotion: return 3
        case .glossary: return 4
        case .questionable: return 5
        case .essays: return 6
        case .images: return 7
        case .map: return 8
        case .generalBook: return 9
        case .unknown: return 10
        case .addon: return 11
        }
    }

    /**
     Compares two strings with Java `String.compareTo` unsigned UTF-16 semantics.

     - Parameters:
       - lhs: Left comparison operand.
       - rhs: Right comparison operand.
     - Returns: Negative, zero, or positive according to the first differing code unit or length.
     - Side effects: None.
     - Failure modes: None; malformed Unicode cannot occur in Swift `String` input.
     */
    private static func javaStringCompare(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        for (leftUnit, rightUnit) in zip(left, right) where leftUnit != rightUnit {
            return Int(leftUnit) - Int(rightUnit)
        }
        return left.count - right.count
    }

    /**
     Tests Java `String.equals` identity without Swift canonical-equivalence folding.

     - Parameters:
       - lhs: Left identity string.
       - rhs: Right identity string.
     - Returns: `true` only when both unsigned UTF-16 sequences are identical.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        SwordJavaStringIdentity.equals(lhs, rhs)
    }
}
