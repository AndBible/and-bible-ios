// BibleReaderPreparedCommentaryNavigation.swift -- Immutable accepted commentary navigation

import Foundation
import SwordKit

/** Commentary block key paired with its source-Bible coordinate during source capture. */
struct BibleReaderCommentaryNavigationTarget: Equatable, Sendable {
    /// Exact key Vue reports for this rendered document.
    let key: String
    /// Exact source-module key that selected the linked block.
    let selectedKey: String
    let osisBookID: String
    let chapter: Int
    let verse: Int
    /// Versification that owns `sourceOrdinal` and the accepted source reference.
    let sourceVersification: String
    let sourceOrdinal: Int

    init(
        key: String,
        selectedKey: String? = nil,
        sourceVersification: String,
        sourceReference: SwordVersification.Reference,
        sourceOrdinal: Int
    ) {
        self.key = key
        self.selectedKey = selectedKey ?? key
        self.sourceVersification = sourceVersification
        self.sourceOrdinal = sourceOrdinal
        osisBookID = sourceReference.osisBookId
        chapter = sourceReference.chapter
        verse = sourceReference.verse
    }

    var navigationReference: BibleReaderNavigationVerseReference {
        BibleReaderNavigationVerseReference(
            chapter: chapter,
            verse: verse,
            osisBookId: osisBookID,
            ordinal: sourceOrdinal
        )
    }

    var sourceKey: String {
        "\(osisBookID).\(chapter).\(verse)"
    }

    /** Compares the requested block receipt without conflating it with rendered annotation text. */
    func hasSameSelectedEdge(as other: Self) -> Bool {
        SwordJavaStringIdentity.equals(selectedKey, other.selectedKey)
            && sourceVersification == other.sourceVersification
            && osisBookID == other.osisBookID
            && chapter == other.chapter
            && verse == other.verse
            && sourceOrdinal == other.sourceOrdinal
    }

    /** Compares navigation ownership with Java-exact rendered-key identity. */
    static func == (
        lhs: BibleReaderCommentaryNavigationTarget,
        rhs: BibleReaderCommentaryNavigationTarget
    ) -> Bool {
        SwordJavaStringIdentity.equals(lhs.key, rhs.key)
            && SwordJavaStringIdentity.equals(lhs.selectedKey, rhs.selectedKey)
            && lhs.osisBookID == rhs.osisBookID
            && lhs.chapter == rhs.chapter
            && lhs.verse == rhs.verse
            && lhs.sourceVersification == rhs.sourceVersification
            && lhs.sourceOrdinal == rhs.sourceOrdinal
    }
}

/** Rendered source target plus linked-block edges captured with accepted commentary. */
struct BibleReaderCommentaryNavigationAvailability: Equatable, Sendable {
    static let empty = BibleReaderCommentaryNavigationAvailability(
        current: nil,
        previous: nil,
        next: nil
    )

    /// Exact source target for the one document Vue accepted and can report as visible.
    let current: BibleReaderCommentaryNavigationTarget?
    /// Previous block target used by toolbar navigation and the lower infinite-scroll edge.
    let previous: BibleReaderCommentaryNavigationTarget?
    /// Next block target used by toolbar navigation and the upper infinite-scroll edge.
    let next: BibleReaderCommentaryNavigationTarget?

    /** Returns the source target only when the accepted rendered document owns the exact key. */
    func target(matchingRenderedKey key: String) -> BibleReaderCommentaryNavigationTarget? {
        guard let current,
              SwordJavaStringIdentity.equals(current.key, key) else { return nil }
        return current
    }

    /** Returns the rendered document's source target for one exact source ordinal. */
    func target(matchingSourceOrdinal ordinal: Int) -> BibleReaderCommentaryNavigationTarget? {
        guard let current, current.sourceOrdinal == ordinal else { return nil }
        return current
    }
}

/** One compact accepted commentary route retained for visible-position authorization. */
struct BibleReaderAcceptedCommentaryRoute: Sendable {
    /// Current and adjacent source targets for the accepted linked block.
    let navigation: BibleReaderCommentaryNavigationAvailability
    /// Exact immutable sources read while preparing the block.
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/**
 Owns the linked-block range accepted by one commentary WebView generation.

 The coordinator retains keys, source coordinates, and generation receipts only. Prepared XML,
 module handles, SwiftData models, and annotation graphs stay in the preparation operation. Bounds
 advance only after the bridge accepts a prepend or append response.
 */
struct BibleReaderCommentaryInfiniteScrollCoordinator {
    private var generation: UInt64?
    private var previous: BibleReaderCommentaryNavigationTarget?
    private var next: BibleReaderCommentaryNavigationTarget?
    /// Java-exact rendered key to accepted route.
    private var routesByKey: [BibleReaderPreparationExactText: BibleReaderAcceptedCommentaryRoute] = [:]
    /// One source ordinal may map from more than one exact commentary key after versification.
    private var keysBySourceOrdinal: [Int: [BibleReaderPreparationExactText]] = [:]

    /** Clears every route owned by the replaced or detached WebView document. */
    mutating func reset() {
        generation = nil
        previous = nil
        next = nil
        routesByKey = [:]
        keysBySourceOrdinal = [:]
    }

    /** Seeds the range after Vue accepts the initial commentary replacement. */
    mutating func seed(
        generation: UInt64,
        edgeNavigation: BibleReaderCommentaryNavigationAvailability,
        visibleNavigation: BibleReaderCommentaryNavigationAvailability,
        sourceDependencies: [BibleReaderPreparationSourceDependency]
    ) {
        reset()
        guard edgeNavigation.current != nil, visibleNavigation.current != nil else { return }
        self.generation = generation
        previous = edgeNavigation.previous
        next = edgeNavigation.next
        store(BibleReaderAcceptedCommentaryRoute(
            navigation: visibleNavigation,
            sourceDependencies: sourceDependencies
        ))
    }

    /** Seeds routes whose selected and visible navigation identities are identical. */
    mutating func seed(
        generation: UInt64,
        navigation: BibleReaderCommentaryNavigationAvailability,
        sourceDependencies: [BibleReaderPreparationSourceDependency]
    ) {
        seed(
            generation: generation,
            edgeNavigation: navigation,
            visibleNavigation: navigation,
            sourceDependencies: sourceDependencies
        )
    }

    /** Returns the exact uncommitted outer edge for one prepend or append lane. */
    func candidate(
        for scope: BibleReaderDocumentPreparationScope,
        generation: UInt64
    ) -> BibleReaderCommentaryNavigationTarget? {
        guard self.generation == generation else { return nil }
        switch scope {
        case .prepend: return previous
        case .append: return next
        case .replacement, .transient: return nil
        }
    }

    /** Commits one bridge-accepted outer block and exposes its visible-position route. */
    mutating func commit(
        _ target: BibleReaderCommentaryNavigationTarget,
        scope: BibleReaderDocumentPreparationScope,
        edgeNavigation: BibleReaderCommentaryNavigationAvailability,
        visibleNavigation: BibleReaderCommentaryNavigationAvailability,
        sourceDependencies: [BibleReaderPreparationSourceDependency],
        generation: UInt64
    ) {
        guard candidate(for: scope, generation: generation) == target,
              let selectedCurrent = edgeNavigation.current,
              selectedCurrent.hasSameSelectedEdge(as: target),
              visibleNavigation.current != nil else { return }
        switch scope {
        case .prepend: previous = edgeNavigation.previous
        case .append: next = edgeNavigation.next
        case .replacement, .transient: return
        }
        store(BibleReaderAcceptedCommentaryRoute(
            navigation: visibleNavigation,
            sourceDependencies: sourceDependencies
        ))
    }

    /** Commits routes whose selected and visible navigation identities are identical. */
    mutating func commit(
        _ target: BibleReaderCommentaryNavigationTarget,
        scope: BibleReaderDocumentPreparationScope,
        navigation: BibleReaderCommentaryNavigationAvailability,
        sourceDependencies: [BibleReaderPreparationSourceDependency],
        generation: UInt64
    ) {
        commit(
            target,
            scope: scope,
            edgeNavigation: navigation,
            visibleNavigation: navigation,
            sourceDependencies: sourceDependencies,
            generation: generation
        )
    }

    /** Resolves one visible rendered key only from blocks accepted in the current generation. */
    func route(
        matchingRenderedKey key: String,
        generation: UInt64
    ) -> BibleReaderAcceptedCommentaryRoute? {
        guard self.generation == generation else { return nil }
        return routesByKey[BibleReaderPreparationExactText(key)]
    }

    /** Resolves all exact accepted routes sharing one source ordinal. */
    func routes(
        matchingSourceOrdinal ordinal: Int,
        generation: UInt64
    ) -> [BibleReaderAcceptedCommentaryRoute] {
        guard self.generation == generation else { return [] }
        return keysBySourceOrdinal[ordinal, default: []].compactMap { routesByKey[$0] }
    }

    /** Inserts or replaces one Java-exact key and maintains its ordinal collision bucket. */
    private mutating func store(_ route: BibleReaderAcceptedCommentaryRoute) {
        guard let current = route.navigation.current else { return }
        let key = BibleReaderPreparationExactText(current.key)
        if let priorOrdinal = routesByKey[key]?.navigation.current?.sourceOrdinal,
           priorOrdinal != current.sourceOrdinal {
            keysBySourceOrdinal[priorOrdinal]?.removeAll { $0 == key }
            if keysBySourceOrdinal[priorOrdinal]?.isEmpty == true {
                keysBySourceOrdinal[priorOrdinal] = nil
            }
        }
        routesByKey[key] = route
        if keysBySourceOrdinal[current.sourceOrdinal]?.contains(key) != true {
            keysBySourceOrdinal[current.sourceOrdinal, default: []].append(key)
        }
    }
}
