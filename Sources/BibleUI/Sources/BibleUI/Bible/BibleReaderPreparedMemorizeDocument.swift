// BibleReaderPreparedMemorizeDocument.swift -- Immutable Memorize document preparation

import BibleCore
import Foundation
import SwordKit

/** Exact structural identity for one copied KJVA reference. */
private struct BibleReaderMemorizeReferenceIdentity: Hashable, Sendable {
    let osisBookID: BibleReaderPreparationExactText
    let chapter: Int
    let verse: Int
    let ordinal: Int

    init(_ reference: VerseKeyReference) {
        osisBookID = BibleReaderPreparationExactText(reference.osisBookId)
        chapter = reference.chapter
        verse = reference.verse
        ordinal = reference.ordinal
    }
}

/** Collision-free request identity for one Android Memorize fake document. */
struct BibleReaderMemorizePreparationRequestIdentity: Hashable, Sendable {
    let bookInitials: BibleReaderPreparationExactText
    let startOrdinal: Int
    let endOrdinal: Int
    let currentBook: BibleReaderPreparationExactText
    let currentChapter: Int
    let osisBookID: BibleReaderPreparationExactText
    let stateJSON: BibleReaderPreparationExactText?
    private let directKJVAReferences: [BibleReaderMemorizeReferenceIdentity]?

    init(_ request: BibleReaderMemorizePreparationRequest) {
        bookInitials = BibleReaderPreparationExactText(request.bookInitials)
        startOrdinal = request.startOrdinal
        endOrdinal = request.endOrdinal
        currentBook = BibleReaderPreparationExactText(request.currentBook)
        currentChapter = request.currentChapter
        osisBookID = BibleReaderPreparationExactText(request.osisBookID)
        stateJSON = request.stateJSON.map { BibleReaderPreparationExactText($0) }
        directKJVAReferences = request.directKJVAReferences?.map(
            BibleReaderMemorizeReferenceIdentity.init
        )
    }
}

/** Exact source request for one Android Memorize fake document. */
struct BibleReaderMemorizePreparationRequest: Sendable {
    let bookInitials: String
    let startOrdinal: Int
    let endOrdinal: Int
    let currentBook: String
    let currentChapter: Int
    let osisBookID: String
    let stateJSON: String?
    let directKJVAReferences: [VerseKeyReference]?

    /** Collision-free UTF-16 request identity used without serializing source text. */
    var identity: BibleReaderMemorizePreparationRequestIdentity { .init(self) }
}

/** One copied verse row emitted by the Memorize Vue document. */
struct BibleReaderMemorizeTextItem: Hashable, Sendable {
    let key: BibleReaderPreparationExactText
    let text: BibleReaderPreparationExactText
}

/** Complete module-owned Memorize values captured in one serialized source transaction. */
struct BibleReaderMemorizeSourceCapture: Sendable {
    let bookInitials: String
    let startOrdinal: Int
    let endOrdinal: Int
    let title: String
    let osisReference: String
    let sourceBookAndKeyJSON: String?
    let sourceVersification: String
    let references: [VerseKeyReference]
    let textItems: [BibleReaderMemorizeTextItem]
    let memorizationProjections: [
        BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection
    ]
    let kjvaOrdinalStart: Int
    let kjvaOrdinalEnd: Int
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** Native copied values awaiting pure canonical-text projection outside the SWORD lease. */
private struct BibleReaderMemorizeNativeCapture: Sendable {
    let source: BibleReaderMemorizeSourceCapture
    let entries: [SwordVerseSourceEntry]
}

/** Typed reading-progress settings embedded in a Memorize document. */
struct BibleReaderMemorizeSettings: Hashable, Sendable {
    let autoMarkMemorized: Bool
    let memorizeTypeFullWords: Bool
    let memorizeWordVisibility: BibleReaderPreparationExactText
    let memorizeErrorHeatmap: Bool
    let memorizeScrambleHideUsed: Bool
    let memorizeIncludeReference: Bool

    init(payload: [String: Any]) {
        autoMarkMemorized = payload["autoMarkMemorized"] as? Bool ?? true
        memorizeTypeFullWords = payload["memorizeTypeFullWords"] as? Bool ?? false
        memorizeWordVisibility = BibleReaderPreparationExactText(
            payload["memorizeWordVisibility"] as? String ?? "light"
        )
        memorizeErrorHeatmap = payload["memorizeErrorHeatmap"] as? Bool ?? true
        memorizeScrambleHideUsed = payload["memorizeScrambleHideUsed"] as? Bool ?? false
        memorizeIncludeReference = payload["memorizeIncludeReference"] as? Bool ?? true
    }

    var jsonObject: [String: Any] {
        [
            "autoMarkMemorized": autoMarkMemorized,
            "memorizeTypeFullWords": memorizeTypeFullWords,
            "memorizeWordVisibility": memorizeWordVisibility.rawValue,
            "memorizeErrorHeatmap": memorizeErrorHeatmap,
            "memorizeScrambleHideUsed": memorizeScrambleHideUsed,
            "memorizeIncludeReference": memorizeIncludeReference,
        ]
    }
}

/** Persistence-owned progress values captured after the source range is known. */
struct BibleReaderMemorizeOwnerSnapshot: Hashable, Sendable {
    let memorizedKJVAOrdinals: [Int]
    let targetKJVAOrdinals: [Int]
    let settings: BibleReaderMemorizeSettings
}

/** Pure source capture and encoding for Android's Memorize fake document. */
enum BibleReaderPreparedMemorizeDocument {
    /**
     Captures exact module text, source mapping, and authorization under one manager lease.

     - Returns: Immutable source values, or nil for an unavailable source or range.
     - Side effects: Reads one native module and applies the supplied operation option snapshot.
     - Failure modes: Relocked/replaced modules, invalid ordinals, and mapping gaps fail closed.
       Empty canonical text remains an explicit row, matching Android's one-row-per-range-reference
       Memorize contract.
     */
    static func capture(
        request: BibleReaderMemorizePreparationRequest,
        manager: SwordManager,
        managerGeneration: SwordContentAuthorizationGeneration,
        optionSettings: [SwordManager.GlobalOptionSetting]
    ) -> BibleReaderMemorizeSourceCapture? {
        let canonicalSettings = optionSettings.map { setting in
            switch setting.option {
            case .strongsNumbers, .morphology:
                return SwordManager.GlobalOptionSetting(setting.option, enabled: false)
            default:
                return setting
            }
        }
        let nativeCapture = manager.performRenderOperation(settings: canonicalSettings) {
            () -> BibleReaderMemorizeNativeCapture? in
            guard manager.contentAuthorizationGeneration == managerGeneration else { return nil }
            let authorization = manager.contentAuthorizationSnapshot(for: [request.bookInitials])
            guard authorization.generation == managerGeneration,
                  authorization.modules.count == 1,
                  authorization.modules[0].accessState == .readable,
                  let module = manager.readableModule(named: request.bookInitials),
                  SwordJavaStringIdentity.equals(module.info.name, request.bookInitials) else {
                return nil
            }

            let sourceVersification = VersificationMapper.versificationName(for: module)
            let rangeStart = min(request.startOrdinal, request.endOrdinal > 0
                ? request.endOrdinal : request.startOrdinal)
            let rangeEnd = max(request.startOrdinal, request.endOrdinal > 0
                ? request.endOrdinal : request.startOrdinal)
            guard rangeStart > 0 else { return nil }

            let references: [VerseKeyReference]
            if let direct = request.directKJVAReferences {
                references = direct.compactMap { reference in
                    guard let exactKJVA = JSwordKJVAVersification.referenceIncludingIntroductions(
                        ordinal: reference.ordinal
                    ), exactKJVA.osisId == reference.osisBookId,
                    exactKJVA.chapter == reference.chapter,
                    exactKJVA.verse == reference.verse,
                    let projection = VersificationMapper.moduleProjection(
                        forKJVAOrdinal: reference.ordinal,
                        targetModule: module
                    ), let renderedOrdinal = renderedOrdinal(
                        for: projection,
                        versification: sourceVersification
                    ) else { return nil }
                    return VerseKeyReference(
                        osisBookId: projection.reference.osisBookId,
                        chapter: projection.reference.chapter,
                        verse: projection.reference.verse,
                        ordinal: renderedOrdinal
                    )
                }
                guard references.count == direct.count else { return nil }
            } else {
                references = (rangeStart...rangeEnd).compactMap { ordinal in
                    guard let reference = SwordVersification.reference(
                        forIndex: ordinal,
                        versification: sourceVersification
                    ) else { return nil }
                    return VerseKeyReference(
                        osisBookId: reference.osisBookId,
                        chapter: reference.chapter,
                        verse: reference.verse,
                        ordinal: ordinal
                    )
                }
            }
            guard let first = references.first, let last = references.last else { return nil }

            let sourceEntries = references.compactMap { reference -> SwordVerseSourceEntry? in
                module.setKey("=\(reference.osisRef)")
                guard let actual = module.currentVerseKeyChildren(),
                      SwordJavaStringIdentity.equals(
                        actual.osisBookName,
                        reference.osisBookId
                      ),
                      actual.chapter == reference.chapter,
                      actual.verse == reference.verse,
                      module.currentVerseKeyIndex() == reference.ordinal else { return nil }
                return module.currentVerseSourceEntry()
            }
            guard sourceEntries.count == references.count,
                  let kjvaRange = VersificationMapper.kjvaOrdinalRange(
                    start: first,
                    end: last,
                    sourceVersification: sourceVersification
                  ) else { return nil }

            let projections = memorizationProjections(kjvaRange: kjvaRange, module: module)
            guard !projections.isEmpty else { return nil }
            let title = referenceTitle(
                references: references,
                fallbackBook: request.currentBook,
                fallbackChapter: request.currentChapter
            )
            let osisReference = first.osisRef == last.osisRef
                ? first.osisRef : "\(first.osisRef)-\(last.osisRef)"
            return BibleReaderMemorizeNativeCapture(
                source: BibleReaderMemorizeSourceCapture(
                    bookInitials: module.info.name,
                    startOrdinal: rangeStart,
                    endOrdinal: rangeEnd,
                    title: title,
                    osisReference: osisReference,
                    sourceBookAndKeyJSON: sourceBookAndKeyJSON(
                        bookInitials: module.info.name,
                        osisReference: osisReference
                    ),
                    sourceVersification: sourceVersification,
                    references: references,
                    textItems: [],
                    memorizationProjections: projections,
                    kjvaOrdinalStart: kjvaRange.lowerBound,
                    kjvaOrdinalEnd: kjvaRange.upperBound,
                    sourceDependencies: [
                        .sword(manager: ObjectIdentifier(manager), authorization: authorization),
                    ]
                ),
                entries: sourceEntries
            )
        }
        guard let nativeCapture else { return nil }
        let textItems = nativeCapture.entries.compactMap { entry -> BibleReaderMemorizeTextItem? in
            guard let text = SwordBibleCanonicalTextProjection.project([entry]) else { return nil }
            return BibleReaderMemorizeTextItem(
                key: BibleReaderPreparationExactText(entry.reference.osisRef),
                text: BibleReaderPreparationExactText(text)
            )
        }
        guard textItems.count == nativeCapture.entries.count else { return nil }
        let source = nativeCapture.source
        return BibleReaderMemorizeSourceCapture(
            bookInitials: source.bookInitials,
            startOrdinal: source.startOrdinal,
            endOrdinal: source.endOrdinal,
            title: source.title,
            osisReference: source.osisReference,
            sourceBookAndKeyJSON: source.sourceBookAndKeyJSON,
            sourceVersification: source.sourceVersification,
            references: source.references,
            textItems: textItems,
            memorizationProjections: source.memorizationProjections,
            kjvaOrdinalStart: source.kjvaOrdinalStart,
            kjvaOrdinalEnd: source.kjvaOrdinalEnd,
            sourceDependencies: source.sourceDependencies
        )
    }

    /** Encodes copied source and owner values into one destination-agnostic emission. */
    static func encode(
        capture: BibleReaderMemorizeSourceCapture,
        owner: BibleReaderMemorizeOwnerSnapshot,
        stateJSON: String?
    ) -> MemorizeDocumentEmission? {
        let memorized = renderedOrdinals(
            stored: Set(owner.memorizedKJVAOrdinals),
            projections: capture.memorizationProjections
        )
        let targets = renderedOrdinals(
            stored: Set(owner.targetKJVAOrdinals),
            projections: capture.memorizationProjections
        )
        let document: [String: Any] = [
            "id": "memorize-\(capture.bookInitials)-\(capture.startOrdinal)-\(capture.endOrdinal)",
            "type": "memorize",
            "title": capture.title,
            "texts": capture.textItems.map {
                ["key": $0.key.rawValue, "text": $0.text.rawValue]
            },
            "state": decodedState(stateJSON),
            "bookInitials": capture.bookInitials,
            "v11n": capture.sourceVersification,
            "osisRef": capture.osisReference,
            "startOrdinal": capture.startOrdinal,
            "endOrdinal": capture.endOrdinal,
            "memorizedOrdinals": memorized,
            "targetOrdinals": targets,
            "readingProgressSettings": owner.settings.jsonObject,
        ]
        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return MemorizeDocumentEmission(
            documentJSON: json,
            bookInitials: capture.bookInitials,
            startOrdinal: capture.startOrdinal,
            endOrdinal: capture.endOrdinal,
            title: capture.title,
            sourceBookAndKeyJSON: capture.sourceBookAndKeyJSON,
            source: MemorizeDocumentSource(
                bookInitials: capture.bookInitials,
                references: capture.references
            )
        )
    }

    private static func renderedOrdinals(
        stored: Set<Int>,
        projections: [BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection]
    ) -> [Int] {
        projections.filter { stored.contains($0.kjvaOrdinal) }
            .map(\.renderedOrdinal).sorted()
    }

    private static func memorizationProjections(
        kjvaRange: ClosedRange<Int>,
        module: SwordModule
    ) -> [BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection] {
        kjvaRange.compactMap { ordinal in
            guard let projection = VersificationMapper.moduleProjection(
                forKJVAOrdinal: ordinal,
                targetModule: module
            ), let rendered = renderedOrdinal(
                for: projection,
                versification: VersificationMapper.versificationName(for: module)
            ) else { return nil }
            return .init(renderedOrdinal: rendered, kjvaOrdinal: ordinal)
        }
    }

    /** Resolves normal verses and exact chapter-introduction slots into the module's canon. */
    private static func renderedOrdinal(
        for projection: VersificationMapper.ModuleProjection,
        versification: String
    ) -> Int? {
        if projection.isAddressable {
            return projection.ordinal
        }
        guard projection.reference.verse == 0,
              let canonical = SwordVersification.referenceIndex(
                for: projection.reference,
                versification: versification
              ), canonical > 0,
              SwordVersification.reference(
                forIndex: canonical,
                versification: versification
              ) == projection.reference else { return nil }
        return canonical
    }

    private static func referenceTitle(
        references: [VerseKeyReference],
        fallbackBook: String,
        fallbackChapter: Int
    ) -> String {
        guard let first = references.first, let last = references.last else {
            return "\(fallbackBook) \(fallbackChapter)"
        }
        let firstBook = BibleReaderBookCatalog.bookName(forOsisId: first.osisBookId)
            ?? fallbackBook
        let lastBook = BibleReaderBookCatalog.bookName(forOsisId: last.osisBookId)
            ?? firstBook
        if first.osisBookId != last.osisBookId {
            return "\(firstBook) \(first.chapter):\(first.verse)-\(lastBook) \(last.chapter):\(last.verse)"
        }
        if first.chapter == last.chapter {
            let verses = first.verse == last.verse
                ? "\(first.verse)" : "\(first.verse)-\(last.verse)"
            return "\(firstBook) \(first.chapter):\(verses)"
        }
        return "\(firstBook) \(first.chapter):\(first.verse)-\(last.chapter):\(last.verse)"
    }

    private static func sourceBookAndKeyJSON(
        bookInitials: String,
        osisReference: String
    ) -> String? {
        let payload: [String: Any] = [
            "key": osisReference,
            "document": bookInitials,
            "ordinalRange": NSNull(),
            "htmlId": NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodedState(_ raw: String?) -> [String: Any] {
        if let raw,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           JSONSerialization.isValidJSONObject(object) {
            return object
        }
        return ["memorize": ["mode": "blur", "modeConfig": [String: Any]()]]
    }
}
