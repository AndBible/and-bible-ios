// BibleReaderPreparedCompositeDocument.swift -- Immutable Multi and Compare preparation

import BibleCore
import BibleView
import Foundation
import SwordKit

/** Exact structural identity for one source-domain verse inside a Multi request. */
struct BibleReaderCompositeVerseIdentity: Hashable, Sendable {
    let osisBookID: BibleReaderPreparationExactText
    let chapter: Int
    let verse: Int

    init(_ coordinate: OsisVerseCoordinate) {
        osisBookID = BibleReaderPreparationExactText(coordinate.osisBookId)
        chapter = coordinate.chapter
        verse = coordinate.verse
    }
}

/** Exact structural identity for one source-aware Multi passage. */
struct BibleReaderCompositeReferenceIdentity: Hashable, Sendable {
    let book: BibleReaderPreparationExactText
    let chapter: Int
    let verse: Int
    let osisID: BibleReaderPreparationExactText
    let sourceVersification: BibleReaderPreparationExactText
    let targetBookInitials: BibleReaderPreparationExactText?
    let sourceVerses: [BibleReaderCompositeVerseIdentity]
    let sourceOsisRef: BibleReaderPreparationExactText
    let endBook: BibleReaderPreparationExactText

    init(_ reference: OsisRef) {
        book = BibleReaderPreparationExactText(reference.book)
        chapter = reference.chapter
        verse = reference.verse
        osisID = BibleReaderPreparationExactText(reference.osisId)
        sourceVersification = BibleReaderPreparationExactText(reference.sourceVersification)
        targetBookInitials = reference.targetBookInitials.map {
            BibleReaderPreparationExactText($0)
        }
        sourceVerses = reference.sourceVerses.map(BibleReaderCompositeVerseIdentity.init)
        sourceOsisRef = BibleReaderPreparationExactText(reference.sourceOsisRef)
        endBook = BibleReaderPreparationExactText(reference.endBook)
    }
}

/** Collision-free identity for every source operation that produces a Multi document. */
enum BibleReaderCompositePreparationRequestIdentity: Hashable, Sendable {
    /// Ordered source-domain passages plus the current fallback Bible identity.
    case multiReferences(
        references: [BibleReaderCompositeReferenceIdentity],
        activeModuleName: BibleReaderPreparationExactText
    )
    /// Exact Android `BookAndKeyList` persistence key plus its null-document fallback.
    case restoredMulti(
        pageKey: BibleReaderPreparationExactText,
        activeModuleName: BibleReaderPreparationExactText?
    )
    /// Exact selected-module ordinal range.
    case compareOrdinals(
        bookInitials: BibleReaderPreparationExactText,
        startOrdinal: Int,
        endOrdinal: Int
    )
    /// Whole chapter resolved inside the serialized source operation.
    case compareChapter(
        bookInitials: BibleReaderPreparationExactText,
        osisBookID: BibleReaderPreparationExactText,
        chapter: Int
    )
}

/** Source-only request for a live, restored, or Search-result Multi document. */
struct BibleReaderMultiReferencePreparationRequest: Sendable {
    let references: [OsisRef]
    let activeModuleName: String

    var identity: BibleReaderCompositePreparationRequestIdentity {
        .multiReferences(
            references: references.map(BibleReaderCompositeReferenceIdentity.init),
            activeModuleName: BibleReaderPreparationExactText(activeModuleName)
        )
    }
}

/** Source-only request for Android's persisted `general_book/Multi` fake document. */
struct BibleReaderRestoredMultiPreparationRequest: Sendable {
    let pageKey: String
    let activeModuleName: String?

    var identity: BibleReaderCompositePreparationRequestIdentity {
        .restoredMulti(
            pageKey: BibleReaderPreparationExactText(pageKey),
            activeModuleName: activeModuleName.map { BibleReaderPreparationExactText($0) }
        )
    }
}

/** Immutable source coordinate for one Compare operation. */
enum BibleReaderComparePreparationRequest: Sendable {
    /// Explicit selection ordinals owned by `bookInitials`.
    case ordinals(bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Complete source chapter whose range must be resolved under the source lease.
    case chapter(bookInitials: String, osisBookID: String, chapter: Int)

    var identity: BibleReaderCompositePreparationRequestIdentity {
        switch self {
        case .ordinals(let bookInitials, let startOrdinal, let endOrdinal):
            return .compareOrdinals(
                bookInitials: BibleReaderPreparationExactText(bookInitials),
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            )
        case .chapter(let bookInitials, let osisBookID, let chapter):
            return .compareChapter(
                bookInitials: BibleReaderPreparationExactText(bookInitials),
                osisBookID: BibleReaderPreparationExactText(osisBookID),
                chapter: chapter
            )
        }
    }
}

/** One typed source operation retained for client-ready replay and config-driven reconstruction. */
enum BibleReaderCompositePreparationRequest: Sendable {
    case multiReferences(BibleReaderMultiReferencePreparationRequest)
    case restoredMulti(BibleReaderRestoredMultiPreparationRequest)
    case compare(BibleReaderComparePreparationRequest)

    var identity: BibleReaderCompositePreparationRequestIdentity {
        switch self {
        case .multiReferences(let request): return request.identity
        case .restoredMulti(let request): return request.identity
        case .compare(let request): return request.identity
        }
    }

    /** Exact installed identities whose access contributes to this source operation. */
    func requestedModuleNames(installedBibleModules: [ModuleInfo]) -> [String] {
        let candidates: [String]
        switch self {
        case .multiReferences(let request):
            candidates = request.references.map {
                $0.targetBookInitials ?? request.activeModuleName
            }
        case .restoredMulti(let request):
            candidates = AndroidSpecialDocumentIdentity.parseBookAndKeyListReference(
                request.pageKey
            ).compactMap { $0.documentInitials ?? request.activeModuleName }
        case .compare(let request):
            let sourceName: String
            switch request {
            case .ordinals(let bookInitials, _, _),
                 .chapter(let bookInitials, _, _):
                sourceName = bookInitials
            }
            candidates = [sourceName] + installedBibleModules.map(\.name)
        }
        var result: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            let identity = SwordJavaExactStringIdentity(candidate)
            guard !result.contains(where: {
                SwordJavaExactStringIdentity($0) == identity
            }) else { continue }
            result.append(candidate)
        }
        return result
    }
}

/** Copied source fragments and authorization produced by one serialized native operation. */
struct BibleReaderCompositeSourceCapture: Sendable {
    let fragments: [OsisFragment]
    let renderedKey: String
    let pageKey: String?
    let contentType: String?
    let compare: Bool
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
    let sourceProvenance: BibleReaderRenderSourceProvenance
}

/** Bridge-ready Multi document plus the copied source authorization that produced it. */
struct BibleReaderPreparedCompositeDocument: Sendable {
    let documentJSON: String
    let renderedKey: String
    let pageKey: String?
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
    let sourceProvenance: BibleReaderRenderSourceProvenance

    /**
     Captures every source fragment through one immutable installed-module registry.

     - Parameters:
       - request: Typed Multi or Compare source operation.
       - resolver: Registry captured inside the caller's serialized source lease.
       - installedBibleModules: Copied Bible metadata used to order Compare targets.
       - sourceDependencies: Exact manager and SQLite generations authorizing the registry.
       - sqliteModules: Captured SQLite registrations used to classify output provenance.
     - Returns: Copied fragments and render metadata, or nil when no complete document exists.
     - Side effects: Reads exact SWORD or SQLite entries through family builders.
     - Failure modes: Missing sources, invalid ranges, partial live passages, and empty restored
       documents fail closed without encoding a partial bridge payload.
     */
    static func capture(
        request: BibleReaderCompositePreparationRequest,
        resolver: BibleReaderInstalledModuleResolver,
        installedBibleModules: [ModuleInfo],
        sourceDependencies: [BibleReaderPreparationSourceDependency],
        sqliteModules: [BibleReaderSQLiteModuleHandle]
    ) -> BibleReaderCompositeSourceCapture? {
        let fragments: [OsisFragment]
        let renderedKey: String
        let pageKey: String?
        let contentType: String?
        let compare: Bool

        switch request {
        case .multiReferences(let multi):
            guard let captured = BibleReaderMultiReferenceDocumentBuilder(
                moduleResolver: resolver,
                activeModuleName: multi.activeModuleName
            ).buildFragments(refs: multi.references) else { return nil }
            fragments = captured
            renderedKey = AndroidSpecialDocumentIdentity.multiRenderedKey
            pageKey = nil
            contentType = nil
            compare = false

        case .restoredMulti(let restored):
            guard let captured = BibleReaderRestoredMultiDocumentBuilder(
                moduleResolver: resolver,
                activeModuleName: restored.activeModuleName
            ).capture(pageKey: restored.pageKey) else { return nil }
            fragments = captured.fragments
            renderedKey = captured.renderedKey
            pageKey = captured.pageKey
            contentType = captured.contentType
            compare = false

        case .compare(let compareRequest):
            let builder = BibleReaderCompareDocumentBuilder(
                moduleResolver: resolver,
                installedBibleModules: installedBibleModules
            )
            let builderRequest: BibleReaderCompareDocumentBuilder.Request?
            switch compareRequest {
            case .ordinals(let bookInitials, let startOrdinal, let endOrdinal):
                builderRequest = builder.makeRequest(
                    bookInitials: bookInitials,
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
                )
            case .chapter(let bookInitials, let osisBookID, let chapter):
                builderRequest = builder.makeChapterRequest(
                    bookInitials: bookInitials,
                    osisBookID: osisBookID,
                    chapter: chapter
                )
            }
            guard let builderRequest,
                  let captured = BibleReaderCompareDocumentBuilder.buildFragments(
                    builderRequest
                  ) else { return nil }
            fragments = captured
            renderedKey = "compare"
            pageKey = nil
            contentType = nil
            compare = true
        }

        return BibleReaderCompositeSourceCapture(
            fragments: fragments,
            renderedKey: renderedKey,
            pageKey: pageKey,
            contentType: contentType,
            compare: compare,
            sourceDependencies: sourceDependencies,
            sourceProvenance: sourceProvenance(
                fragments: fragments,
                sqliteModules: sqliteModules
            )
        )
    }

    /** Purely encodes copied fragments after every native source handle has left scope. */
    static func encode(_ capture: BibleReaderCompositeSourceCapture) -> Self? {
        let prefix = capture.compare ? "compare" : "multi"
        guard let documentJSON = BibleReaderMultiFragmentDocumentBuilder.buildJSON(
            fragments: capture.fragments,
            compare: capture.compare,
            contentType: capture.contentType,
            id: "\(prefix)-\(UUID().uuidString)"
        ) else { return nil }
        return Self(
            documentJSON: documentJSON,
            renderedKey: capture.renderedKey,
            pageKey: capture.pageKey ?? AndroidSpecialDocumentIdentity.bookAndKeyListReference(
                from: documentJSON
            ),
            sourceDependencies: capture.sourceDependencies,
            sourceProvenance: capture.sourceProvenance
        )
    }

    /** Classifies copied fragment owners without consulting mutable installed state. */
    private static func sourceProvenance(
        fragments: [OsisFragment],
        sqliteModules: [BibleReaderSQLiteModuleHandle]
    ) -> BibleReaderRenderSourceProvenance {
        let sqliteNames = sqliteModules.map { SwordJavaExactStringIdentity($0.info.name) }
        var emittedSQLiteNames: [String] = []
        var includesSword = false
        for fragment in fragments {
            let identity = SwordJavaExactStringIdentity(fragment.bookInitials)
            if sqliteNames.contains(identity) {
                if !emittedSQLiteNames.contains(where: {
                    SwordJavaExactStringIdentity($0) == identity
                }) {
                    emittedSQLiteNames.append(fragment.bookInitials)
                }
            } else {
                includesSword = true
            }
        }
        if includesSword { return .compositeMayUseSword }
        return emittedSQLiteNames.isEmpty ? .independent : .sqliteModules(emittedSQLiteNames)
    }
}
